/* MSVC compatibility shim for Bellard's QuickJS.
 *
 * The vendored engine is a GCC/clang tree: cutils.h spells `likely`,
 * `force_inline`, the packed access helpers and the bit-scan helpers in terms
 * of `__builtin_expect`, `__attribute__` and `__builtin_clz`, none of which
 * MSVC has. Force-included by hook/build.dart when targeting Windows, so the
 * vendored sources stay unpatched.
 *
 * Mapping the two GNU spellings is enough to cover every user, because the
 * macros in cutils.h expand at the call site.
 */
#ifndef QUICKJS_DART_MSVC_COMPAT_H
#define QUICKJS_DART_MSVC_COMPAT_H

#ifdef _MSC_VER

#include <intrin.h>
#include <time.h>
#include <windows.h>
#include <malloc.h>
#include <stdint.h>

#define __builtin_expect(expr, expected_value) (expr)

/* Drops `format`, `warn_unused_result`, `always_inline`, `noinline` and
 * `unused`, which only affect diagnostics and inlining, plus:
 *
 * - `packed` on the single-member packed_u16/32/64 structs. MSVC has no packed
 *   attribute (only #pragma pack, which a macro cannot place). Layout is
 *   unchanged for a one-scalar struct, and the x64 loads MSVC emits for them
 *   do not require alignment.
 * - `aligned(JS_MALLOC_ALIGN)` on the three flexible array members. Their
 *   offsets are already multiples of 8 from the preceding members, and every
 *   instance comes from the host malloc, which is 16-byte aligned on Windows.
 */
#define __attribute__(ignored_gnu_attributes)

#define alloca _alloca

/* `__builtin_frame_address(0)` is only used to sample a stack address for the
 * stack-overflow guard, which is what the return address slot gives us. */
#define __builtin_frame_address(level) _AddressOfReturnAddress()

static __forceinline int quickjs_dart_clz32(unsigned int a) {
  unsigned long index;
  _BitScanReverse(&index, a);
  return 31 - (int)index;
}

static __forceinline int quickjs_dart_clz64(uint64_t a) {
  unsigned long index;
  _BitScanReverse64(&index, a);
  return 63 - (int)index;
}

static __forceinline int quickjs_dart_ctz32(unsigned int a) {
  unsigned long index;
  _BitScanForward(&index, a);
  return (int)index;
}

static __forceinline int quickjs_dart_ctz64(uint64_t a) {
  unsigned long index;
  _BitScanForward64(&index, a);
  return (int)index;
}

#define __builtin_clz(a) quickjs_dart_clz32(a)
#define __builtin_clzll(a) quickjs_dart_clz64(a)
#define __builtin_ctz(a) quickjs_dart_ctz32(a)
#define __builtin_ctzll(a) quickjs_dart_ctz64(a)

/* qjs_shim.c times its execution deadline with clock_gettime(CLOCK_MONOTONIC),
 * which the UCRT does not provide. QueryPerformanceCounter is the monotonic
 * clock on Windows and is unaffected by wall-clock changes. */
#define CLOCK_MONOTONIC 1

static __forceinline int clock_gettime(int clock_id, struct timespec *ts) {
  LARGE_INTEGER frequency;
  LARGE_INTEGER counter;

  (void)clock_id;
  QueryPerformanceFrequency(&frequency);
  QueryPerformanceCounter(&counter);
  ts->tv_sec = (time_t)(counter.QuadPart / frequency.QuadPart);
  ts->tv_nsec =
      (long)(((counter.QuadPart % frequency.QuadPart) * 1000000000LL) /
             frequency.QuadPart);
  return 0;
}

#endif /* _MSC_VER */

#endif /* QUICKJS_DART_MSVC_COMPAT_H */
