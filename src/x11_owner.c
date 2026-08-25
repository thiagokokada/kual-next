#define _POSIX_C_SOURCE 200809L
#include "kual.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define X11_SETUP_TIMEOUT_MS 2000
#define X11_MAX_SETUP_SIZE (1024U * 1024U)
#define X11_WINDOW_NAME "L:A_N:application_PC:N_O:UDRL_ID:kual-next-owner"
#define X11_WINDOW_CLASS "kual-next\0KualNext\0"

enum {
  X11_CREATE_WINDOW = 1,
  X11_DESTROY_WINDOW = 4,
  X11_MAP_WINDOW = 8,
  X11_CHANGE_PROPERTY = 18,
  X11_GET_INPUT_FOCUS = 43,
  X11_QUERY_EXTENSION = 98,
  X11_EVENT_DESTROY_NOTIFY = 17,
  X11_EVENT_UNMAP_NOTIFY = 18,
  X11_EVENT_MAP_NOTIFY = 19,
  X11_EVENT_CONFIGURE_NOTIFY = 22,
  X11_ATOM_STRING = 31,
  X11_ATOM_WM_NAME = 39,
  X11_ATOM_WM_CLASS = 67,
  X11_COPY_FROM_PARENT = 0,
  X11_INPUT_OUTPUT = 1,
  X11_CW_BACK_PIXMAP = 1U << 0,
  X11_CW_EVENT_MASK = 1U << 11,
  X11_STRUCTURE_NOTIFY_MASK = 1U << 17,
  X11_SHAPE_RECTANGLES = 1,
  X11_SHAPE_SET = 0,
  X11_SHAPE_INPUT = 2,
  X11_UNSORTED = 0,
};

static uint16_t get16(const unsigned char *p) {
  return (uint16_t)p[0] | (uint16_t)((uint16_t)p[1] << 8U);
}

static uint32_t get32(const unsigned char *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8U) | ((uint32_t)p[2] << 16U) |
         ((uint32_t)p[3] << 24U);
}

static void put16(unsigned char *p, uint16_t value) {
  p[0] = (unsigned char)(value & 0xffU);
  p[1] = (unsigned char)(value >> 8U);
}

static void put32(unsigned char *p, uint32_t value) {
  p[0] = (unsigned char)(value & 0xffU);
  p[1] = (unsigned char)((value >> 8U) & 0xffU);
  p[2] = (unsigned char)((value >> 16U) & 0xffU);
  p[3] = (unsigned char)(value >> 24U);
}

static int wait_fd(int fd, short events, int timeout_ms) {
  struct pollfd pollfd = {fd, events, 0};
  int result;
  do {
    result = poll(&pollfd, 1, timeout_ms);
  } while (result < 0 && errno == EINTR);
  if (result <= 0) {
    if (result == 0)
      errno = ETIMEDOUT;
    return -1;
  }
  if (pollfd.revents & events)
    return 0;
  if (pollfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
    errno = EPIPE;
    return -1;
  }
  errno = EIO;
  return -1;
}

static int write_all(int fd, const void *buffer, size_t size) {
  const unsigned char *p = buffer;
  while (size) {
    ssize_t written = send(fd, p, size, MSG_NOSIGNAL);
    if (written < 0) {
      if (errno == EINTR)
        continue;
      return -1;
    }
    if (written == 0) {
      errno = EPIPE;
      return -1;
    }
    p += (size_t)written;
    size -= (size_t)written;
  }
  return 0;
}

static int read_all(int fd, void *buffer, size_t size) {
  unsigned char *p = buffer;
  while (size) {
    if (wait_fd(fd, POLLIN, X11_SETUP_TIMEOUT_MS) != 0)
      return -1;
    ssize_t got = read(fd, p, size);
    if (got < 0) {
      if (errno == EINTR)
        continue;
      return -1;
    }
    if (got == 0) {
      errno = EPIPE;
      return -1;
    }
    p += (size_t)got;
    size -= (size_t)got;
  }
  return 0;
}

static int send_request(KualX11Owner *owner, const void *request, size_t size) {
  if (!owner->connected || size < 4U || size % 4U != 0U) {
    errno = EINVAL;
    return -1;
  }
  owner->sequence++;
  return write_all(owner->fd, request, size);
}

static int setup_connection(KualX11Owner *owner) {
  unsigned char request[12] = {'l', 0, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0};
  if (write_all(owner->fd, request, sizeof(request)) != 0)
    return -1;

  unsigned char prefix[8];
  if (read_all(owner->fd, prefix, sizeof(prefix)) != 0)
    return -1;
  size_t extra_size = (size_t)get16(prefix + 6U) * 4U;
  if (prefix[0] != 1U || extra_size < 72U || extra_size > X11_MAX_SETUP_SIZE) {
    errno = EPROTO;
    return -1;
  }
  unsigned char *extra = malloc(extra_size);
  if (!extra)
    return -1;
  if (read_all(owner->fd, extra, extra_size) != 0) {
    free(extra);
    return -1;
  }
  uint16_t vendor_len = get16(extra + 16U);
  uint8_t format_count = extra[21U];
  size_t screen_offset =
      32U + ((size_t)vendor_len + 3U) / 4U * 4U + (size_t)format_count * 8U;
  if (!extra[20U] || screen_offset > extra_size ||
      extra_size - screen_offset < 40U) {
    free(extra);
    errno = EPROTO;
    return -1;
  }
  const unsigned char *screen = extra + screen_offset;
  owner->resource_base = get32(extra + 4U);
  owner->resource_mask = get32(extra + 8U);
  owner->root = get32(screen);
  owner->width = get16(screen + 20U);
  owner->height = get16(screen + 22U);
  free(extra);
  if (!owner->resource_mask || !owner->root || !owner->width ||
      !owner->height) {
    errno = EPROTO;
    return -1;
  }
  uint32_t bit = owner->resource_mask & (~owner->resource_mask + 1U);
  owner->window = owner->resource_base | bit;
  return 0;
}

static int query_shape(KualX11Owner *owner) {
  static const char extension[] = "SHAPE";
  unsigned char request[16] = {0};
  request[0] = X11_QUERY_EXTENSION;
  put16(request + 2U, 4U);
  put16(request + 4U, (uint16_t)(sizeof(extension) - 1U));
  memcpy(request + 8U, extension, sizeof(extension) - 1U);
  if (send_request(owner, request, sizeof(request)) != 0)
    return -1;

  unsigned char reply[32];
  if (read_all(owner->fd, reply, sizeof(reply)) != 0)
    return -1;
  if (reply[0] != 1U || get16(reply + 2U) != owner->sequence || !reply[8U] ||
      !reply[9U]) {
    errno = ENOTSUP;
    return -1;
  }
  owner->shape_opcode = reply[9U];

  unsigned char version[4] = {owner->shape_opcode, 0, 1, 0};
  if (send_request(owner, version, sizeof(version)) != 0 ||
      read_all(owner->fd, reply, sizeof(reply)) != 0)
    return -1;
  uint16_t major = get16(reply + 8U);
  uint16_t minor = get16(reply + 10U);
  if (reply[0] != 1U || get16(reply + 2U) != owner->sequence || major < 1U ||
      (major == 1U && minor < 1U)) {
    errno = ENOTSUP;
    return -1;
  }
  return 0;
}

static int change_property(KualX11Owner *owner, uint32_t property,
                           const void *value, size_t size) {
  size_t padded = (size + 3U) & ~(size_t)3U;
  size_t request_size = 24U + padded;
  unsigned char *request = calloc(1, request_size);
  if (!request)
    return -1;
  request[0] = X11_CHANGE_PROPERTY;
  put16(request + 2U, (uint16_t)(request_size / 4U));
  put32(request + 4U, owner->window);
  put32(request + 8U, property);
  put32(request + 12U, X11_ATOM_STRING);
  request[16U] = 8U;
  put32(request + 20U, (uint32_t)size);
  memcpy(request + 24U, value, size);
  int result = send_request(owner, request, request_size);
  free(request);
  return result;
}

static int create_window(KualX11Owner *owner) {
  unsigned char create[40] = {0};
  create[0] = X11_CREATE_WINDOW;
  create[1] = X11_COPY_FROM_PARENT;
  put16(create + 2U, 10U);
  put32(create + 4U, owner->window);
  put32(create + 8U, owner->root);
  put16(create + 16U, owner->width);
  put16(create + 18U, owner->height);
  put16(create + 22U, X11_INPUT_OUTPUT);
  put32(create + 24U, X11_COPY_FROM_PARENT);
  put32(create + 28U, X11_CW_BACK_PIXMAP | X11_CW_EVENT_MASK);
  put32(create + 32U, 0U);
  put32(create + 36U, X11_STRUCTURE_NOTIFY_MASK);
  if (send_request(owner, create, sizeof(create)) != 0)
    return -1;
  owner->window_created = true;
  if (change_property(owner, X11_ATOM_WM_NAME, X11_WINDOW_NAME,
                      sizeof(X11_WINDOW_NAME) - 1U) != 0 ||
      change_property(owner, X11_ATOM_WM_CLASS, X11_WINDOW_CLASS,
                      sizeof(X11_WINDOW_CLASS) - 1U) != 0)
    return -1;

  unsigned char shape[16] = {0};
  shape[0] = owner->shape_opcode;
  shape[1] = X11_SHAPE_RECTANGLES;
  put16(shape + 2U, 4U);
  shape[4U] = X11_SHAPE_SET;
  shape[5U] = X11_SHAPE_INPUT;
  shape[6U] = X11_UNSORTED;
  put32(shape + 8U, owner->window);
  if (send_request(owner, shape, sizeof(shape)) != 0)
    return -1;

  unsigned char map[8] = {X11_MAP_WINDOW, 0, 2, 0, 0, 0, 0, 0};
  put32(map + 4U, owner->window);
  if (send_request(owner, map, sizeof(map)) != 0)
    return -1;

  unsigned char focus[4] = {X11_GET_INPUT_FOCUS, 0, 1, 0};
  if (send_request(owner, focus, sizeof(focus)) != 0)
    return -1;
  uint16_t focus_sequence = owner->sequence;
  for (;;) {
    unsigned char message[32];
    if (read_all(owner->fd, message, sizeof(message)) != 0)
      return -1;
    uint8_t type = message[0] & 0x7fU;
    if (message[0] == 0U) {
      errno = EPROTO;
      return -1;
    }
    if (message[0] == 1U && get16(message + 2U) == focus_sequence)
      break;
    if (type == X11_EVENT_MAP_NOTIFY && get32(message + 8U) == owner->window)
      owner->mapped = true;
  }
  return 0;
}

void kual_x11_owner_init(KualX11Owner *owner) {
  memset(owner, 0, sizeof(*owner));
  owner->fd = -1;
}

int kual_x11_owner_open_fd(KualX11Owner *owner, int fd) {
  kual_x11_owner_init(owner);
  owner->fd = fd;
  owner->connected = true;
  int flags = fcntl(fd, F_GETFD);
  if (flags >= 0)
    (void)fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
  if (setup_connection(owner) != 0 || query_shape(owner) != 0 ||
      create_window(owner) != 0) {
    int saved = errno;
    kual_x11_owner_close(owner);
    errno = saved;
    return -1;
  }
  flags = fcntl(fd, F_GETFL);
  if (flags >= 0)
    (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
  return 0;
}

int kual_x11_owner_open(KualX11Owner *owner, const char *socket_path) {
  if (!socket_path || !*socket_path) {
    errno = EINVAL;
    return -1;
  }
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0)
    return -1;
  struct sockaddr_un address = {0};
  address.sun_family = AF_UNIX;
  size_t length = strlen(socket_path);
  if (length >= sizeof(address.sun_path)) {
    close(fd);
    errno = ENAMETOOLONG;
    return -1;
  }
  memcpy(address.sun_path, socket_path, length + 1U);
  if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
  }
  return kual_x11_owner_open_fd(owner, fd);
}

static int process_messages(KualX11Owner *owner, bool *geometry_changed) {
  size_t consumed = 0;
  while (owner->buffer_len - consumed >= 32U) {
    unsigned char *message = owner->buffer + consumed;
    uint8_t type = message[0] & 0x7fU;
    size_t message_size = 32U;
    if (message[0] == 1U)
      message_size += (size_t)get32(message + 4U) * 4U;
    if (message_size > KUAL_X11_BUFFER_SIZE) {
      errno = EOVERFLOW;
      return -1;
    }
    if (owner->buffer_len - consumed < message_size)
      break;
    if (message[0] == 0U) {
      errno = EPROTO;
      return -1;
    }
    uint32_t window = get32(message + 8U);
    if (window == owner->window) {
      if (type == X11_EVENT_MAP_NOTIFY)
        owner->mapped = true;
      else if (type == X11_EVENT_UNMAP_NOTIFY ||
               type == X11_EVENT_DESTROY_NOTIFY) {
        errno = EPIPE;
        return -1;
      } else if (type == X11_EVENT_CONFIGURE_NOTIFY) {
        uint16_t width = get16(message + 20U);
        uint16_t height = get16(message + 22U);
        if (width && height &&
            (width != owner->width || height != owner->height)) {
          owner->width = width;
          owner->height = height;
          *geometry_changed = true;
        }
      }
    }
    consumed += message_size;
  }
  if (consumed) {
    memmove(owner->buffer, owner->buffer + consumed,
            owner->buffer_len - consumed);
    owner->buffer_len -= consumed;
  }
  return 0;
}

int kual_x11_owner_read(KualX11Owner *owner, bool *geometry_changed) {
  if (!owner->connected || owner->fd < 0 || !geometry_changed) {
    errno = EINVAL;
    return -1;
  }
  *geometry_changed = false;
  for (;;) {
    if (owner->buffer_len == sizeof(owner->buffer)) {
      errno = EOVERFLOW;
      return -1;
    }
    ssize_t got = read(owner->fd, owner->buffer + owner->buffer_len,
                       sizeof(owner->buffer) - owner->buffer_len);
    if (got > 0) {
      owner->buffer_len += (size_t)got;
      if (process_messages(owner, geometry_changed) != 0)
        return -1;
      continue;
    }
    if (got == 0) {
      errno = EPIPE;
      return -1;
    }
    if (errno == EINTR)
      continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK)
      return process_messages(owner, geometry_changed);
    return -1;
  }
}

int kual_x11_owner_wait_mapped(KualX11Owner *owner, int timeout_ms) {
  if (!owner->connected)
    return -1;
  if (owner->mapped)
    return 0;
  if (wait_fd(owner->fd, POLLIN, timeout_ms) != 0)
    return errno == ETIMEDOUT ? 1 : -1;
  bool geometry_changed = false;
  if (kual_x11_owner_read(owner, &geometry_changed) != 0)
    return -1;
  return owner->mapped ? 0 : 1;
}

void kual_x11_owner_close(KualX11Owner *owner) {
  if (!owner)
    return;
  if (owner->fd >= 0) {
    if (owner->connected && owner->window_created) {
      unsigned char destroy[8] = {X11_DESTROY_WINDOW, 0, 2, 0, 0, 0, 0, 0};
      put32(destroy + 4U, owner->window);
      (void)send_request(owner, destroy, sizeof(destroy));
    }
    close(owner->fd);
  }
  kual_x11_owner_init(owner);
}
