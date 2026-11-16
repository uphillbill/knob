#ifndef KNOB_ATOMICS_H
#define KNOB_ATOMICS_H

#include <stdint.h>

// Minimal atomics for handing EQ coefficients to the audio IO thread without locks.
// Inline, so there is no function call on the real-time path.

static inline uint64_t knob_load_acquire(const uint64_t *p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

static inline void knob_store_release(uint64_t *p, uint64_t value) {
    __atomic_store_n(p, value, __ATOMIC_RELEASE);
}

static inline void knob_fence_acquire(void) {
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
}

static inline void knob_fence_full(void) {
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
}

#endif
