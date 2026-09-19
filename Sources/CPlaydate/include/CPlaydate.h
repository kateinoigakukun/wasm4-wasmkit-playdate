#pragma once
#include "pd_api.h"

extern PlaydateAPI *playdate;

/// Wrapper for the variadic `logToConsole`, which Swift imports as an opaque
/// pointer and cannot call directly.
void w4_log(const char *message);

/// Acquiring 32-bit load and releasing 32-bit store, the pair needed to publish
/// data from the game task to the higher-priority audio task.
///
/// The Playdate SDK exposes no locking primitive for the audio callback, so
/// anything shared with it has to be published by hand. 32-bit atomics compile
/// to LDREX/STREX on this core and need no library support.
unsigned int w4_atomic_load(const volatile unsigned int *slot);
void w4_atomic_store(volatile unsigned int *slot, unsigned int value);

