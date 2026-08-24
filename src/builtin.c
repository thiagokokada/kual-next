#define _POSIX_C_SOURCE 200809L
#include "kual.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
  char *data;
  size_t len;
  size_t cap;
} Buffer;

static int buffer_append(Buffer *buffer, const char *data, size_t len) {
  if (len > SIZE_MAX - buffer->len - 1U) {
    errno = EOVERFLOW;
    return -1;
  }
  size_t needed = buffer->len + len + 1U;
  if (needed > buffer->cap) {
    size_t cap = buffer->cap ? buffer->cap : 256U;
    while (cap < needed) {
      if (cap > SIZE_MAX / 2U) {
        errno = EOVERFLOW;
        return -1;
      }
      cap *= 2U;
    }
    buffer->data = kual_xrealloc(buffer->data, cap);
    buffer->cap = cap;
  }
  memcpy(buffer->data + buffer->len, data, len);
  buffer->len += len;
  buffer->data[buffer->len] = '\0';
  return 0;
}

static bool sort_assignment(const char *line, size_t len) {
  const char *cursor = line, *end = line + len;
  while (cursor < end && isspace((unsigned char)*cursor) && *cursor != '\n')
    cursor++;
  static const char key[] = "KUAL_sort_mode";
  if ((size_t)(end - cursor) < sizeof(key) - 1U ||
      memcmp(cursor, key, sizeof(key) - 1U))
    return false;
  cursor += sizeof(key) - 1U;
  while (cursor < end && isspace((unsigned char)*cursor) && *cursor != '\n')
    cursor++;
  return cursor < end && *cursor == '=';
}

static int write_all(int fd, const void *data, size_t len) {
  const char *cursor = data;
  while (len) {
    ssize_t written = write(fd, cursor, len);
    if (written < 0) {
      if (errno == EINTR)
        continue;
      return -1;
    }
    if (!written) {
      errno = EIO;
      return -1;
    }
    cursor += written;
    len -= (size_t)written;
  }
  return 0;
}

typedef struct {
  char *destination;
  char *temporary;
  int source_fd;
  int destination_fd;
  bool temporary_exists;
} ArchiveResources;

static int close_owned_fd(int *fd) {
  if (*fd < 0)
    return 0;
  int owned = *fd;
  *fd = -1;
  return close(owned);
}

static void archive_resources_cleanup(ArchiveResources *resources) {
  int saved = errno;
  (void)close_owned_fd(&resources->destination_fd);
  (void)close_owned_fd(&resources->source_fd);
  if (resources->temporary_exists)
    (void)unlink(resources->temporary);
  free(resources->temporary);
  free(resources->destination);
  memset(resources, 0, sizeof(*resources));
  resources->source_fd = resources->destination_fd = -1;
  errno = saved;
}

static int replace_file(const char *path, const void *data, size_t len,
                        mode_t mode) {
  size_t template_len = strlen(path) + sizeof(".tmp.XXXXXX");
  char *template = kual_xcalloc(template_len, 1U);
  snprintf(template, template_len, "%s.tmp.XXXXXX", path);
  int fd = mkstemp(template);
  if (fd < 0) {
    free(template);
    return -1;
  }
  int saved = 0;
  if (fchmod(fd, mode) != 0 || write_all(fd, data, len) != 0 || fsync(fd) != 0)
    saved = errno;
  if (close(fd) != 0 && !saved)
    saved = errno;
  if (!saved && rename(template, path) != 0)
    saved = errno;
  if (saved)
    unlink(template);
  free(template);
  if (saved) {
    errno = saved;
    return -1;
  }
  return 0;
}

int kual_set_sort_mode(const char *extensions_dir, const char *mode) {
  if (!extensions_dir) {
    errno = EINVAL;
    return -1;
  }
  if (!mode || (strcmp(mode, "ABC") && strcmp(mode, "123"))) {
    errno = EINVAL;
    return -1;
  }
  char *path = kual_join_path(extensions_dir, "KUAL.cfg");
  struct stat st;
  bool exists = stat(path, &st) == 0;
  if (!exists && errno != ENOENT) {
    free(path);
    return -1;
  }
  size_t input_len = 0;
  char *input = exists ? kual_read_file(path, &input_len) : NULL;
  if (exists && !input) {
    free(path);
    return -1;
  }

  Buffer output = {0};
  char assignment[48];
  int assignment_len =
      snprintf(assignment, sizeof(assignment), "KUAL_sort_mode=\"%s\"\n", mode);
  bool found = false;
  const char *cursor = input, *end = input ? input + input_len : NULL;
  while (cursor && cursor < end) {
    const char *line_end = memchr(cursor, '\n', (size_t)(end - cursor));
    size_t line_len =
        line_end ? (size_t)(line_end - cursor) + 1U : (size_t)(end - cursor);
    if (sort_assignment(cursor, line_len)) {
      if (buffer_append(&output, assignment, (size_t)assignment_len) != 0)
        goto fail;
      found = true;
    } else if (buffer_append(&output, cursor, line_len) != 0)
      goto fail;
    cursor += line_len;
  }
  if (!found) {
    if (!exists) {
      char header[128], date[64] = "unknown date";
      time_t now = time(NULL);
      struct tm local;
      if (localtime_r(&now, &local))
        strftime(date, sizeof(date), "%Y-%m-%d %H:%M:%S %z", &local);
      int header_len =
          snprintf(header, sizeof(header),
                   "# KUAL.cfg - created by KUAL Next on %s\n", date);
      if (buffer_append(&output, header, (size_t)header_len) != 0)
        goto fail;
    } else if (output.len && output.data[output.len - 1U] != '\n' &&
               buffer_append(&output, "\n", 1U) != 0)
      goto fail;
    if (buffer_append(&output, assignment, (size_t)assignment_len) != 0)
      goto fail;
  }
  if (replace_file(path, output.data, output.len,
                   exists ? st.st_mode & 07777 : 0644) != 0)
    goto fail;
  free(output.data);
  free(input);
  free(path);
  return 0;

fail: {
  int saved = errno;
  free(output.data);
  free(input);
  free(path);
  errno = saved;
  return -1;
}
}

int kual_archive_log(const char *source, const char *documents_dir, time_t when,
                     char **destination_out) {
  if (destination_out)
    *destination_out = NULL;
  if (!source || !documents_dir) {
    errno = EINVAL;
    return -1;
  }
  struct tm utc;
  char filename[64];
  if (!gmtime_r(&when, &utc) ||
      !strftime(filename, sizeof(filename), "KUAL-%Y-%m-%dT%H.%M+00.00.txt",
                &utc)) {
    errno = EINVAL;
    return -1;
  }
  ArchiveResources resources = {
      .destination = kual_join_path(documents_dir, filename),
      .temporary = kual_join_path(documents_dir, ".kual-next-log.XXXXXX"),
      .source_fd = -1,
      .destination_fd = -1,
  };
  int result = -1;
  resources.source_fd = open(source, O_RDONLY);
  if (resources.source_fd < 0)
    goto cleanup;
  struct stat st;
  if (fstat(resources.source_fd, &st) != 0)
    goto cleanup;
  resources.destination_fd = mkstemp(resources.temporary);
  if (resources.destination_fd < 0)
    goto cleanup;
  resources.temporary_exists = true;
  (void)fchmod(resources.destination_fd, st.st_mode & 07777);

  char buffer[16384];
  for (;;) {
    ssize_t count = read(resources.source_fd, buffer, sizeof(buffer));
    if (count < 0) {
      if (errno == EINTR)
        continue;
      goto cleanup;
    }
    if (!count)
      break;
    if (write_all(resources.destination_fd, buffer, (size_t)count) != 0)
      goto cleanup;
  }
  if (fsync(resources.destination_fd) != 0 ||
      close_owned_fd(&resources.destination_fd) != 0 ||
      close_owned_fd(&resources.source_fd) != 0)
    goto cleanup;
  if (rename(resources.temporary, resources.destination) != 0)
    goto cleanup;
  resources.temporary_exists = false;
  if (unlink(source) != 0)
    goto cleanup;
  if (destination_out) {
    *destination_out = resources.destination;
    resources.destination = NULL;
  }
  result = 0;

cleanup:
  archive_resources_cleanup(&resources);
  return result;
}

const char *kual_builtin_action_name(KualBuiltinAction action) {
  switch (action) {
  case KUAL_BUILTIN_SORT_ABC:
    return "sort-ABC";
  case KUAL_BUILTIN_SORT_123:
    return "sort-123";
  case KUAL_BUILTIN_SAVE_LOG:
    return "save-log";
  case KUAL_BUILTIN_QUIT:
    return "quit";
  default:
    return NULL;
  }
}
