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

    struct Settings {
        var mode: ScopeMode = .voices
        var seconds: Double = 30
        var fps: Int = 50
        var size = CGSize(width: 960, height: 540)
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

    static func export(tune: SIDTune, player: SIDPlayer, settings: Settings,
                       to url: URL, progress: @escaping (Double) -> Void) throws {
        try? FileManager.default.removeItem(at: url)

        let fps = settings.fps
        let framesPerVideoFrame = Int(SIDPlayer.sampleRate) / fps
        let totalFrames = max(1, Int(settings.seconds * Double(fps)))

        // The engine is ours alone for this.
        player.stop()

        // Pass one: the whole soundtrack. Playback is deterministic, so the
        // video pass can replay the same tune from the start and stay in step.
        player.load(tune)
        player.prepareForOfflineRender()
        var audioSamples = [Int16](repeating: 0, count: totalFrames * framesPerVideoFrame)
        var chunk = [Int16](repeating: 0, count: framesPerVideoFrame)
        for frame in 0..<totalFrames {
            player.renderOffline(frames: framesPerVideoFrame, into: &chunk)
            let start = frame * framesPerVideoFrame
            audioSamples.replaceSubrange(start..<(start + framesPerVideoFrame), with: chunk)
        }

        // Pass two draws the scope, so rewind the engine and turn capture on.
        player.prepareForOfflineRender()
        player.setScope(enabled: true)

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
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
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
        var scratch = [Int16](repeating: 0, count: framesPerVideoFrame)
        group.enter()
        video.requestMediaDataWhenReady(on: DispatchQueue(label: "sid.export.video")) {
            while video.isReadyForMoreMediaData {
                if videoFrame >= totalFrames || failure != nil {
                    video.markAsFinished(); group.leave(); return
                }
                // Advance the engine one frame so the scope window matches.
                player.renderOffline(frames: framesPerVideoFrame, into: &scratch)

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
                    ScopeRenderer.draw(in: context, size: settings.size, mode: settings.mode,
                                       sidCount: player.sidCount,
                                       samples: player.scopeSnapshot(mode: settings.mode),
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
                let start = audioFrame * framesPerVideoFrame
                let slice = Array(audioSamples[start..<(start + framesPerVideoFrame)])
                guard let buffer = sampleBuffer(slice, startFrame: Int64(start)) else {
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
        player.setScope(enabled: false)
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

    /// 16-bit mono LPCM wrapped for the writer.
    private static func sampleBuffer(_ samples: [Int16], startFrame: Int64) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: SIDPlayer.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
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
        var sizes = MemoryLayout<Int16>.size
        var out: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                   sampleCount: samples.count, sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                   sampleSizeArray: &sizes, sampleBufferOut: &out) == noErr
        else { return nil }
        return out
    }
}
