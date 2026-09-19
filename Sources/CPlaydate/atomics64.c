// 64-bit atomic builtins for ARMv7-M.
//
// ARMv7-M has LDREX/STREX but not LDREXD/STREXD, so the compiler lowers 64-bit
// atomics to libatomic calls -- and the arm-none-eabi toolchain the Playdate
// SDK installs ships no libatomic. WasmKit references these unconditionally
// from its i64 atomic RMW handlers, so without them the device link fails with
// undefined references to __atomic_load_8 and friends.
//
// The Playdate is single-core, so masking interrupts for the duration of the
// operation is sufficient and correct: nothing can observe a torn value,
// including the higher-priority audio task. Note that WASM-4 carts never
// execute these instructions (the threads proposal is off), so this exists to
// satisfy the linker rather than to be fast.

#include <stdbool.h>
#include <stdint.h>

#if defined(TARGET_PLAYDATE) && TARGET_PLAYDATE

__attribute__((always_inline)) static inline uint32_t mask_interrupts(void) {
    uint32_t primask;
    __asm__ volatile("mrs %0, primask\n cpsid i" : "=r"(primask)::"memory");
    return primask;
}

__attribute__((always_inline)) static inline void restore_interrupts(uint32_t primask) {
    __asm__ volatile("msr primask, %0" ::"r"(primask) : "memory");
}

uint64_t __atomic_load_8(const volatile void *ptr, int memorder) {
    (void)memorder;
    uint32_t state = mask_interrupts();
    uint64_t value = *(const volatile uint64_t *)ptr;
    restore_interrupts(state);
    return value;
}

void __atomic_store_8(volatile void *ptr, uint64_t value, int memorder) {
    (void)memorder;
    uint32_t state = mask_interrupts();
    *(volatile uint64_t *)ptr = value;
    restore_interrupts(state);
}

uint64_t __atomic_exchange_8(volatile void *ptr, uint64_t value, int memorder) {
    (void)memorder;
    uint32_t state = mask_interrupts();
    volatile uint64_t *target = (volatile uint64_t *)ptr;
    uint64_t previous = *target;
    *target = value;
    restore_interrupts(state);
    return previous;
}

bool __atomic_compare_exchange_8(volatile void *ptr, void *expected, uint64_t desired,
                                 bool weak, int success_memorder, int failure_memorder) {
    (void)weak;
    (void)success_memorder;
    (void)failure_memorder;
    uint32_t state = mask_interrupts();
    volatile uint64_t *target = (volatile uint64_t *)ptr;
    uint64_t current = *target;
    bool matched = (current == *(uint64_t *)expected);
    if (matched) {
        *target = desired;
    } else {
        *(uint64_t *)expected = current;
    }
    restore_interrupts(state);
    return matched;
}

#define DEFINE_FETCH_OP(name, op)                                            \
    uint64_t __atomic_fetch_##name##_8(volatile void *ptr, uint64_t value,   \
                                       int memorder) {                       \
        (void)memorder;                                                      \
        uint32_t state = mask_interrupts();                                  \
        volatile uint64_t *target = (volatile uint64_t *)ptr;                \
        uint64_t previous = *target;                                         \
        *target = previous op value;                                         \
        restore_interrupts(state);                                           \
        return previous;                                                     \
    }

DEFINE_FETCH_OP(add, +)
DEFINE_FETCH_OP(sub, -)
DEFINE_FETCH_OP(and, &)
DEFINE_FETCH_OP(or, |)
DEFINE_FETCH_OP(xor, ^)

#undef DEFINE_FETCH_OP

#endif  // TARGET_PLAYDATE
