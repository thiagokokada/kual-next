#define _POSIX_C_SOURCE 200809L
#include "kual.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

void *kual_xcalloc(size_t count, size_t size) {
  if (size && count > SIZE_MAX / size)
    abort();
  void *p = calloc(count, size);
  if (!p)
    abort();
  return p;
}

void *kual_xrealloc(void *ptr, size_t size) {
  void *p = realloc(ptr, size ? size : 1);
  if (!p)
    abort();
  return p;
}

char *kual_xstrdup(const char *s) {
  if (!s)
    return NULL;
  char *copy = strdup(s);
  if (!copy)
    abort();
  return copy;
}

char *kual_join_path(const char *a, const char *b) {
  if (!b || !*b)
    return kual_xstrdup(a ? a : "");
  if (b[0] == '/')
    return kual_xstrdup(b);
  size_t alen = a ? strlen(a) : 0;
  size_t blen = strlen(b);
  bool slash = alen && a[alen - 1] != '/';
  char *out = kual_xcalloc(alen + blen + (slash ? 2 : 1), 1);
  if (alen)
    memcpy(out, a, alen);
  if (slash)
    out[alen++] = '/';
  memcpy(out + alen, b, blen + 1);
  return out;
}

char *kual_dirname(const char *path) {
  char *copy = kual_xstrdup(path ? path : ".");
  char *slash = strrchr(copy, '/');
  if (!slash) {
    free(copy);
    return kual_xstrdup(".");
  }
  if (slash == copy)
    slash[1] = '\0';
  else
    *slash = '\0';
  return copy;
}

char *kual_read_file(const char *path, size_t *size_out) {
  FILE *f = fopen(path, "rb");
  if (!f)
    return NULL;
  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    return NULL;
  }
  long end = ftell(f);
  if (end < 0 || end > 4 * 1024 * 1024L || fseek(f, 0, SEEK_SET) != 0) {
    fclose(f);
    errno = EFBIG;
    return NULL;
  }
  size_t size = (size_t)end;
  char *data = kual_xcalloc(size + 1, 1);
  if (size && fread(data, 1, size, f) != size) {
    int saved = errno;
    free(data);
    fclose(f);
    errno = saved ? saved : EIO;
    return NULL;
  }
  fclose(f);
  if (size_out)
    *size_out = size;
  return data;
}

void kual_log(const char *format, ...) {
  FILE *f = fopen(KUAL_DEFAULT_LOG, "a");
  if (!f)
    return;
  va_list ap;
  va_start(ap, format);
  vfprintf(f, format, ap);
  va_end(ap);
  fputc('\n', f);
  fclose(f);
}

int kual_redirect_stderr(const char *path) {
  int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd < 0)
    return -1;
  if (dup2(fd, STDERR_FILENO) < 0) {
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
  }
  if (fd > STDERR_FILENO)
    close(fd);
  return 0;
}

void kual_errors_add(KualErrors *errors, const char *source, const char *format,
                     ...) {
  if (!errors || !format)
    return;
  if (errors->len == errors->cap) {
    errors->cap = errors->cap ? errors->cap * 2 : 8;
    errors->items =
        kual_xrealloc(errors->items, errors->cap * sizeof(*errors->items));
  }
  va_list ap;
  va_start(ap, format);
  va_list copy;
  va_copy(copy, ap);
  int needed = vsnprintf(NULL, 0, format, copy);
  va_end(copy);
  char *message = kual_xcalloc((size_t)(needed < 0 ? 0 : needed) + 1, 1);
  if (needed >= 0)
    vsnprintf(message, (size_t)needed + 1, format, ap);
  va_end(ap);
  errors->items[errors->len++] =
      (KualError){kual_xstrdup(source ? source : "launcher"), message};
  kual_log("%s: %s", source ? source : "launcher", message);
}

void kual_errors_free(KualErrors *errors) {
  if (!errors)
    return;
  for (size_t i = 0; i < errors->len; i++) {
    free(errors->items[i].source);
    free(errors->items[i].message);
  }
  free(errors->items);
  memset(errors, 0, sizeof(*errors));
}
