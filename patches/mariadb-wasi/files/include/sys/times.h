#ifndef MYSQL_WASI_SYS_TIMES_H
#define MYSQL_WASI_SYS_TIMES_H

#if defined(__wasi__)

#include <string.h>
#include <time.h>

struct tms {
  clock_t tms_utime;
  clock_t tms_stime;
  clock_t tms_cutime;
  clock_t tms_cstime;
};

static inline clock_t times(struct tms *buffer) {
  if (buffer != NULL) memset(buffer, 0, sizeof(*buffer));
  return 0;
}

#else
#include_next <sys/times.h>
#endif

#endif /* MYSQL_WASI_SYS_TIMES_H */
