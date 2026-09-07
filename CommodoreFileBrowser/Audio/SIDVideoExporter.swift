import Foundation
import AVFoundation
import CoreGraphics
import AppKit

/// Renders the oscilloscope to an .mp4 with the tune as its soundtrack.
///
/// Playback is driven offline rather than in real time: for each video frame we
/// render exactly one frame's worth of audio, then draw the scope, so picture
/// and sound stay in step however long the export takes.
enum SIDVideoExporter {

    /// What the export pulls from. Both players are wrapped in one of these
    /// rather than the exporter knowing either: the writer plumbing is the same
    /// whichever engine is behind it, and only the channel count, the rewind
    /// and what the scope draws differ.
    struct Source {
        /// 1 for the SID, 2 for a module. Decides the audio track and how the
        /// rendered buffer is packed.
        var channels: Int
        /// Back to the beginning, without touching the audio graph.
        var rewind: () -> Void
        /// Render that many frames, interleaved when there are two channels.
        var render: (Int, inout [Int16]) -> Void
        var setScope: (Bool) -> Void
        /// The traces as of the last render, and how to lay them out.
        var traces: () -> [[Int16]]
        var columns: Int
        var lineWidth: CGFloat
    }

    struct Settings {
        var seconds: Double = 30
        var fps: Int = 50
        var size = VideoFormat.size(.p720, .sixteenNine)
        var foreground: CGColor = NSColor.white.cgColor
        var background: CGColor = NSColor.black.cgColor
        var grid: CGColor = NSColor.darkGray.cgColor
    }

    enum ExportError: LocalizedError {
        case cannotWrite(String)
        var errorDescription: String? {
            switch self { case .cannotWrite(let why): return "Could not write the video: \(why)" }
        }
    }

    /// The SID player as a source. Loading the tune is what rewinds it.
    static func source(tune: SIDTune, player: SIDPlayer, mode: ScopeMode) -> Source {
        let (rows, columns) = ScopeRenderer.grid(mode: mode, sidCount: player.sidCount)
        player.pause()
        player.load(tune)
        return Source(channels: 1,
                      rewind: { player.prepareForOfflineRender() },
                      render: { player.renderOffline(frames: $0, into: &$1) },
                      setScope: { player.setScope(enabled: $0) },
                      traces: {
                          let samples = player.scopeSnapshot(mode: mode)
                          return (0..<rows).flatMap { row in
                              (0..<columns).map { column in
                                  samples[ScopeRenderer.track(mode: mode, row: row, column: column)] ?? []
                              }
                          }
                      },
                      columns: columns,
                      lineWidth: mode == .mix ? 1.5 : 1.2)
    }

    /// The module player as a source. The module is already open in the engine,
    /// so there is nothing to load — only to rewind.
    static func source(player: ModulePlayer, mode: ModuleScopeMode) -> Source {
        player.pause()
        return Source(channels: 2,
                      rewind: { player.prepareForOfflineRender() },
                      render: { player.renderOffline(frames: $0, into: &$1) },
                      setScope: { player.setScope(enabled: $0) },
                      traces: { player.scopeSnapshot(mode: mode) },
                      columns: 1,
                      lineWidth: mode == .mix ? 1.5 : 1.2)
    }

    static func export(source: Source, settings: Settings,
                       to url: URL, progress: @escaping (Double) -> Void) throws {
        try? FileManager.default.removeItem(at: url)

        let fps = settings.fps
        let channels = max(1, source.channels)
        let framesPerVideoFrame = Int(SIDPlayer.sampleRate) / fps
        let totalFrames = max(1, Int(settings.seconds * Double(fps)))

        // Pass one: the whole soundtrack. Playback is deterministic, so the
        // video pass can replay the same tune from the start and stay in step.
        source.rewind()
        var audioSamples = [Int16](repeating: 0, count: totalFrames * framesPerVideoFrame * channels)
        var chunk = [Int16](repeating: 0, count: framesPerVideoFrame * channels)
        for frame in 0..<totalFrames {
            source.render(framesPerVideoFrame, &chunk)
            let start = frame * framesPerVideoFrame * channels
            audioSamples.replaceSubrange(start..<(start + chunk.count), with: chunk)
        }

        // Pass two draws the scope, so rewind the engine and turn capture on.
        source.rewind()
        source.setScope(true)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let width = Int(settings.size.width), height = Int(settings.size.height)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])

        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: SIDPlayer.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 2 ? 192_000 : 128_000,
        ])
        audio.expectsMediaDataInRealTime = false

        guard writer.canAdd(video), writer.canAdd(audio) else {
            throw ExportError.cannotWrite("the writer rejected its inputs")
        }
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else {
            throw ExportError.cannotWrite(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        // Both inputs are pulled, not pushed. Spinning on isReadyForMoreMediaData
        // from a loop of our own deadlocks: the writer holds an input closed
        // until it is fed from the callback it hands out here.
        let colourSpace = CGColorSpaceCreateDeviceRGB()
        let group = DispatchGroup()
        var failure: Error?

        var videoFrame = 0
        var scratch = [Int16](repeating: 0, count: framesPerVideoFrame * channels)
        group.enter()
        video.requestMediaDataWhenReady(on: DispatchQueue(label: "sid.export.video")) {
            while video.isReadyForMoreMediaData {
                if videoFrame >= totalFrames || failure != nil {
                    video.markAsFinished(); group.leave(); return
                }
                // Advance the engine one frame so the scope window matches.
                source.render(framesPerVideoFrame, &scratch)

                guard let pool = adaptor.pixelBufferPool else {
                    failure = ExportError.cannotWrite("no pixel buffer pool")
                    video.markAsFinished(); group.leave(); return
                }
                var pixelBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                guard let pixelBuffer else {
                    failure = ExportError.cannotWrite("no pixel buffer")
                    video.markAsFinished(); group.leave(); return
                }
                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                if let context = CGContext(
                    data: CVPixelBufferGetBaseAddress(pixelBuffer),
                    width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                    space: colourSpace,
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                    ScopeRenderer.draw(in: context, size: settings.size,
                                       traces: source.traces(), columns: source.columns,
                                       lineWidth: source.lineWidth,
                                       foreground: settings.foreground,
                                       background: settings.background,
                                       grid: settings.grid)
                }
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

                if !adaptor.append(pixelBuffer, withPresentationTime:
                                    CMTime(value: CMTimeValue(videoFrame), timescale: CMTimeScale(fps))) {
                    failure = ExportError.cannotWrite("video frame \(videoFrame) rejected: "
                        + (writer.error?.localizedDescription ?? "unknown"))
                    video.markAsFinished(); group.leave(); return
                }
                videoFrame += 1
                if videoFrame % fps == 0 {
                    let fraction = Double(videoFrame) / Double(totalFrames)
                    DispatchQueue.main.async { progress(fraction) }
                }
            }
        }

        var audioFrame = 0
        group.enter()
        audio.requestMediaDataWhenReady(on: DispatchQueue(label: "sid.export.audio")) {
            while audio.isReadyForMoreMediaData {
                if audioFrame >= totalFrames || failure != nil {
                    audio.markAsFinished(); group.leave(); return
                }
                let start = audioFrame * framesPerVideoFrame * channels
                let slice = Array(audioSamples[start..<(start + framesPerVideoFrame * channels)])
                guard let buffer = sampleBuffer(slice, channels: channels,
                                                startFrame: Int64(audioFrame * framesPerVideoFrame))
                else {
                    failure = ExportError.cannotWrite("could not wrap audio at frame \(audioFrame)")
                    audio.markAsFinished(); group.leave(); return
                }
                if !audio.append(buffer) {
                    failure = ExportError.cannotWrite("audio frame \(audioFrame) rejected: "
                        + (writer.error?.localizedDescription ?? "unknown"))
                    audio.markAsFinished(); group.leave(); return
                }
                audioFrame += 1
            }
        }

        group.wait()
        source.setScope(false)
        if let failure { writer.cancelWriting(); throw failure }

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()

        guard writer.status == .completed else {
            throw ExportError.cannotWrite("writer ended in status \(writer.status.rawValue): "
                + (writer.error?.localizedDescription ?? "no error reported"))
        }
        DispatchQueue.main.async { progress(1) }
    }

    /// 16-bit interleaved LPCM wrapped for the writer.
    private static func sampleBuffer(_ samples: [Int16], channels: Int,
                                     startFrame: Int64) -> CMSampleBuffer? {
        let bytesPerFrame = UInt32(2 * channels)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: SIDPlayer.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                             layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &format) == noErr,
              let format else { return nil }

        let byteCount = samples.count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0,
                                                 dataLength: byteCount, flags: 0,
                                                 blockBufferOut: &block) == noErr,
              let block else { return nil }
        _ = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(SIDPlayer.sampleRate)),
            presentationTimeStamp: CMTime(value: startFrame, timescale: CMTimeScale(SIDPlayer.sampleRate)),
            decodeTimeStamp: .invalid)
        // A sample here is a frame, which is one short per channel: stereo
        // counts half as many as there are shorts, and each is twice the size.
        var sizes = Int(bytesPerFrame)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                   sampleCount: samples.count / channels, sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                   sampleSizeArray: &sizes, sampleBufferOut: &out) == noErr
        else { return nil }
        return out
    }
}
