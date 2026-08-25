#define _POSIX_C_SOURCE 200809L
#include "kual.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
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
  struct timespec now;
  struct tm local;
  if (clock_gettime(CLOCK_REALTIME, &now) == 0 &&
      localtime_r(&now.tv_sec, &local)) {
    char timestamp[32];
    if (strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", &local))
      fprintf(f, "%s.%03ld ", timestamp, now.tv_nsec / 1000000L);
  }
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

const char *kual_privilege_indicator(bool is_root) {
  return is_root ? "#" : "%";
}

KualPrivilege kual_privilege_mode(bool is_root, bool gandalf_available) {
  if (is_root)
    return KUAL_PRIVILEGE_ROOT;
  return gandalf_available ? KUAL_PRIVILEGE_GANDALF : KUAL_PRIVILEGE_USER;
}

const char *kual_privilege_mode_indicator(KualPrivilege privilege) {
  if (privilege == KUAL_PRIVILEGE_ROOT)
    return "#";
  if (privilege == KUAL_PRIVILEGE_GANDALF)
    return "$";
  return "%";
}

void kual_exec_spec(KualPrivilege privilege, const char *command,
                    KualExecSpec *spec) {
  memset(spec, 0, sizeof(*spec));
  if (privilege == KUAL_PRIVILEGE_GANDALF) {
    spec->path = "/var/local/mkk/su";
    spec->argv[0] = "su";
    spec->argv[1] = "-s";
    spec->argv[2] = "/bin/ash";
    spec->argv[3] = "-c";
    spec->argv[4] = (char *)command;
  } else {
    spec->path = "/bin/sh";
    spec->argv[0] = "sh";
    spec->argv[1] = "-c";
    spec->argv[2] = (char *)command;
  }
}

int kual_cleanup_known_offenders(const char *killall_path) {
  if (!killall_path || !*killall_path) {
    errno = EINVAL;
    return -1;
  }
  pid_t pid = fork();
  if (pid == 0) {
    int nullfd = open("/dev/null", O_RDWR);
    if (nullfd >= 0) {
      dup2(nullfd, STDOUT_FILENO);
      dup2(nullfd, STDERR_FILENO);
      if (nullfd > STDERR_FILENO)
        close(nullfd);
    }
    execl(killall_path, killall_path, "matchbox-keyboard", "kterm", "skipstone",
          "cr3", (char *)NULL);
    _exit(127);
  }
  if (pid < 0)
    return -1;
  int status;
  while (waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR)
      return -1;
  }
  return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

void kual_route_status(bool footer_enabled, char *footer, size_t footer_size,
                       char *breadcrumb, size_t breadcrumb_size,
                       const char *message) {
  char *destination = footer_enabled ? footer : breadcrumb;
  size_t size = footer_enabled ? footer_size : breadcrumb_size;
  if (!destination || !size)
    return;
  snprintf(destination, size, "%s", message ? message : "");
}

void kual_navigation_init(KualNavigation *navigation) {
  memset(navigation, 0, sizeof(*navigation));
}

size_t kual_navigation_page(const KualNavigation *navigation) {
  return navigation->page[navigation->depth];
}

void kual_navigation_next_page(KualNavigation *navigation, size_t page_count) {
  if (!page_count)
    page_count = 1U;
  size_t *page = &navigation->page[navigation->depth];
  *page = (*page + 1U) % page_count;
}

bool kual_navigation_enter(KualNavigation *navigation) {
  if (navigation->depth >= KUAL_MAX_DEPTH)
    return false;
  navigation->depth++;
  navigation->page[navigation->depth] = 0;
  return true;
}

void kual_navigation_back(KualNavigation *navigation) {
  if (navigation->depth)
    navigation->depth--;
}

void kual_navigation_top(KualNavigation *navigation) { navigation->depth = 0; }

bool kual_power_event_is_unlock(const char *event, bool screen_saver_active) {
  return screen_saver_active && event &&
         !strncmp(event, "exitingScreenSaver", 18);
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
