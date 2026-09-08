#ifndef CFLOD_PANIC_H
#define CFLOD_PANIC_H

// What c-flod's bounds checks call instead of trapping into the debugger.
// Implemented in ../cflod.c, which sets a landing point before it hands a file
// to a player. See the note in include/debug.h.
void cflod_panic(void);

#endif
