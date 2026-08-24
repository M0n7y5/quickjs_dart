/* Minimal <sys/time.h> for MSVC, which does not ship one.
 *
 * quickjs.c includes it unconditionally and uses exactly two things from it:
 * `struct timeval` and `gettimeofday` (js_Date_now and js_date_now sites).
 * Only on the include path for Windows builds; see hook/build.dart.
 */
#ifndef QUICKJS_DART_MSVC_SYS_TIME_H
#define QUICKJS_DART_MSVC_SYS_TIME_H

#include <winsock2.h> /* struct timeval */
#include <windows.h>

static __forceinline int gettimeofday(struct timeval *tv, void *tz) {
  FILETIME ft;
  ULARGE_INTEGER ticks;

  (void)tz;
  GetSystemTimePreciseAsFileTime(&ft);
  ticks.LowPart = ft.dwLowDateTime;
  ticks.HighPart = ft.dwHighDateTime;
  /* FILETIME counts 100 ns ticks from 1601-01-01; rebase on the Unix epoch. */
  ticks.QuadPart -= 116444736000000000ULL;
  tv->tv_sec = (long)(ticks.QuadPart / 10000000ULL);
  tv->tv_usec = (long)((ticks.QuadPart % 10000000ULL) / 10ULL);
  return 0;
}

#endif /* QUICKJS_DART_MSVC_SYS_TIME_H */
