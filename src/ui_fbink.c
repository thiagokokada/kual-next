#define _POSIX_C_SOURCE 200809L
#include "fbink.h"
#include "kual.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_INPUTS 16
#define MAX_NAV_DEPTH (KUAL_MAX_DEPTH + 1)
#define KUAL_PAGE_ROWS 10U

typedef struct {
  int fd;
  INPUT_DEVICE_TYPE_T type;
  int min_x, max_x, min_y, max_y;
  int x, y, start_x, start_y;
  bool down, reported_down, release_pending;
} InputDevice;

typedef struct {
  int fbfd;
  FBInkConfig draw_cfg;
  FBInkOTConfig text_cfg;
  FBInkOTConfig symbol_cfg;
  FBInkOTConfig music_symbol_cfg;
  bool opentype_ready;
  bool symbols_ready;
  bool music_symbols_ready;
  FBInkState state;
  InputDevice inputs[MAX_INPUTS];
  size_t input_count;
  int power_fd;
  pid_t power_pid;
  char power_buffer[512];
  size_t power_buffer_len;
  bool screen_saver_active;
  bool resume_redraw_pending;
  struct timespec resume_redraw_at;
  KualEntry *nav[MAX_NAV_DEPTH];
  size_t depth;
  size_t page;
  unsigned int top_h, status_h, side_w, gap;
  unsigned int list_y, list_h, button_x, button_w, button_h;
  char status[256];
  char breadcrumb_status[256];
} UI;

static volatile sig_atomic_t stopping;
static void stop_handler(int sig) {
  (void)sig;
  stopping = 1;
}

static void power_events_close(UI *ui);

static bool statusbar_owned(void) {
  const char *value = getenv("KUAL_NEXT_STATUSBAR_STOPPED");
  return value && !strcmp(value, "1");
}

static int service_command(const char *path) {
  pid_t pid = fork();
  if (pid == 0) {
    int nullfd = open("/dev/null", O_RDWR);
    if (nullfd >= 0) {
      dup2(nullfd, STDOUT_FILENO);
      dup2(nullfd, STDERR_FILENO);
      if (nullfd > STDERR_FILENO)
        close(nullfd);
    }
    execl(path, path, "statusbar", (char *)NULL);
    _exit(127);
  }
  if (pid < 0)
    return -1;
  int status;
  while (waitpid(pid, &status, 0) < 0)
    if (errno != EINTR)
      return -1;
  return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static bool statusbar_is_running(void) {
  int pipefd[2];
  if (pipe(pipefd) != 0)
    return false;
  pid_t pid = fork();
  if (pid == 0) {
    close(pipefd[0]);
    dup2(pipefd[1], STDOUT_FILENO);
    int nullfd = open("/dev/null", O_WRONLY);
    if (nullfd >= 0) {
      dup2(nullfd, STDERR_FILENO);
      if (nullfd > STDERR_FILENO && nullfd != pipefd[1])
        close(nullfd);
    }
    if (pipefd[1] != STDOUT_FILENO)
      close(pipefd[1]);
    execl("/sbin/status", "/sbin/status", "statusbar", (char *)NULL);
    _exit(127);
  }
  close(pipefd[1]);
  if (pid < 0) {
    close(pipefd[0]);
    return false;
  }
  char output[128];
  size_t used = 0;
  ssize_t got;
  while (used + 1U < sizeof(output) &&
         (got = read(pipefd[0], output + used, sizeof(output) - used - 1U)) > 0)
    used += (size_t)got;
  close(pipefd[0]);
  while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {
  }
  output[used] = '\0';
  return strstr(output, "start/running") != NULL;
}

static void statusbar_restore_if_owned(void) {
  if (!statusbar_owned())
    return;
  if (!statusbar_is_running() && service_command("/sbin/start") != 0)
    kual_log("failed to restore Kindle statusbar before action");
  unsetenv("KUAL_NEXT_STATUSBAR_STOPPED");
}

static void statusbar_hide_if_owned(void) {
  if (!statusbar_owned())
    return;
  if (statusbar_is_running() && service_command("/sbin/stop") != 0)
    kual_log("failed to stop Kindle statusbar after resume");
}

const char *kual_model_from_fbink_name(const char *name) {
  static const struct {
    const char *fbink, *kual;
  } models[] = {{"PaperWhite 6", "KindlePaperWhite6"},
                {"PaperWhite 5", "KindlePaperWhite5"},
                {"PaperWhite 4", "KindlePaperWhite4"},
                {"PaperWhite 3", "KindlePaperWhite3"},
                {"PaperWhite 2", "KindlePaperWhite2"},
                {"PaperWhite", "KindlePaperWhite"},
                {"Basic 5", "KindleBasic5"},
                {"Basic 4", "KindleBasic4"},
                {"Basic 3", "KindleBasic3"},
                {"Basic 2", "KindleBasic2"},
                {"Basic", "KindleBasic"},
                {"Oasis 3", "KindleOasis3"},
                {"Oasis 2", "KindleOasis2"},
                {"Oasis", "KindleOasis"},
                {"Scribe ColorSoft", "KindleScribeColorSoft"},
                {"Scribe 3", "KindleScribe3"},
                {"Scribe 2", "KindleScribe2"},
                {"Scribe", "KindleScribe"},
                {"ColorSoft", "KindleColorSoft"},
                {"Voyage", "KindleVoyage"},
                {"Touch", "KindleTouch"},
                {NULL, NULL}};
  for (size_t i = 0; models[i].fbink; i++)
    if (!strcmp(name, models[i].fbink))
      return models[i].kual;
  return "Unknown";
}

char *kual_device_model_probe(void) {
  FBInkConfig cfg = {0};
  cfg.is_quiet = true;
  int fd = fbink_open();
  if (fd < 0)
    return NULL;
  if (fbink_init(fd, &cfg) != 0) {
    fbink_close(fd);
    return NULL;
  }
  FBInkState state = {0};
  fbink_get_state(&cfg, &state);
  char *model = kual_xstrdup(kual_model_from_fbink_name(state.device_name));
  fbink_close(fd);
  return model;
}

static void ui_cleanup(UI *ui) {
  power_events_close(ui);
  for (size_t i = 0; i < ui->input_count; i++) {
    int release = 0;
    ioctl(ui->inputs[i].fd, EVIOCGRAB, release);
    close(ui->inputs[i].fd);
  }
  ui->input_count = 0;
  if (ui->opentype_ready) {
    (void)fbink_free_ot_fonts_v2(&ui->text_cfg);
    ui->opentype_ready = false;
  }
  if (ui->symbols_ready) {
    (void)fbink_free_ot_fonts_v2(&ui->symbol_cfg);
    ui->symbols_ready = false;
  }
  if (ui->music_symbols_ready) {
    (void)fbink_free_ot_fonts_v2(&ui->music_symbol_cfg);
    ui->music_symbols_ready = false;
  }
  if (ui->fbfd >= 0) {
    fbink_close(ui->fbfd);
    ui->fbfd = -1;
  }
}

static bool axis_info(int fd, unsigned int code, int *min, int *max) {
  struct input_absinfo info;
  if (ioctl(fd, EVIOCGABS(code), &info) != 0 || info.maximum <= info.minimum)
    return false;
  *min = info.minimum;
  *max = info.maximum;
  return true;
}

static int ui_inputs_open(UI *ui) {
  size_t count = 0;
  INPUT_DEVICE_TYPE_T wanted =
      INPUT_TOUCHSCREEN | INPUT_PAGINATION_BUTTONS | INPUT_HOME_BUTTON;
  FBInkInputDevice *devices =
      fbink_input_scan(wanted, INPUT_POWER_BUTTON, NO_RECAP, &count);
  if (!devices)
    return -1;
  for (size_t i = 0; i < count && ui->input_count < MAX_INPUTS; i++) {
    if (!devices[i].matched || devices[i].fd < 0)
      continue;
    InputDevice *input = &ui->inputs[ui->input_count++];
    memset(input, 0, sizeof(*input));
    input->fd = devices[i].fd;
    input->type = devices[i].type;
    bool mt =
        axis_info(input->fd, ABS_MT_POSITION_X, &input->min_x, &input->max_x) &&
        axis_info(input->fd, ABS_MT_POSITION_Y, &input->min_y, &input->max_y);
    if (!mt) {
      axis_info(input->fd, ABS_X, &input->min_x, &input->max_x);
      axis_info(input->fd, ABS_Y, &input->min_y, &input->max_y);
    }
    int grab = 1;
    if (ioctl(input->fd, EVIOCGRAB, grab) != 0)
      kual_log("cannot grab input fd %d: %s", input->fd, strerror(errno));
  }
  free(devices);
  return ui->input_count ? 0 : -1;
}

static bool ui_inputs_grab(UI *ui, bool grab) {
  int value = grab ? 1 : 0;
  bool success = true;
  for (size_t i = 0; i < ui->input_count; i++) {
    if (ioctl(ui->inputs[i].fd, EVIOCGRAB, value) != 0) {
      success = false;
      kual_log("cannot %s input fd %d: %s", grab ? "grab" : "release",
               ui->inputs[i].fd, strerror(errno));
    }
  }
  return success;
}

static void input_discard(InputDevice *input) {
  struct input_event events[32];
  while (read(input->fd, events, sizeof(events)) > 0) {
  }
  input->down = input->reported_down = input->release_pending = false;
}

static int power_events_open(UI *ui) {
  int pipefd[2];
  if (pipe(pipefd) != 0)
    return -1;
  for (size_t i = 0; i < 2; i++) {
    int flags = fcntl(pipefd[i], F_GETFL);
    if (flags >= 0)
      fcntl(pipefd[i], F_SETFL, flags | O_NONBLOCK);
    flags = fcntl(pipefd[i], F_GETFD);
    if (flags >= 0)
      fcntl(pipefd[i], F_SETFD, flags | FD_CLOEXEC);
  }
  pid_t pid = fork();
  if (pid == 0) {
    close(pipefd[0]);
    if (ui->fbfd >= 0)
      close(ui->fbfd);
    for (size_t i = 0; i < ui->input_count; i++)
      close(ui->inputs[i].fd);
    prctl(PR_SET_PDEATHSIG, SIGTERM);
    if (getppid() == 1)
      _exit(1);
    dup2(pipefd[1], STDOUT_FILENO);
    int nullfd = open("/dev/null", O_WRONLY);
    if (nullfd >= 0) {
      dup2(nullfd, STDERR_FILENO);
      if (nullfd > STDERR_FILENO && nullfd != pipefd[1])
        close(nullfd);
    }
    if (pipefd[1] != STDOUT_FILENO)
      close(pipefd[1]);
    execl("/usr/bin/lipc-wait-event", "lipc-wait-event", "-m", "-s", "0",
          "com.lab126.powerd",
          "goingToScreenSaver,outOfScreenSaver,exitingScreenSaver",
          (char *)NULL);
    _exit(127);
  }
  close(pipefd[1]);
  if (pid < 0) {
    close(pipefd[0]);
    return -1;
  }
  ui->power_fd = pipefd[0];
  ui->power_pid = pid;
  return 0;
}

static void power_events_close(UI *ui) {
  if (ui->power_fd >= 0) {
    close(ui->power_fd);
    ui->power_fd = -1;
  }
  if (ui->power_pid > 0) {
    kill(ui->power_pid, SIGINT);
    while (waitpid(ui->power_pid, NULL, 0) < 0 && errno == EINTR) {
    }
    ui->power_pid = 0;
  }
  ui->power_buffer_len = 0;
}

static void ui_layout(UI *ui) {
  unsigned int width = ui->state.view_width, height = ui->state.view_height;
  ui->gap = width / 190U;
  if (ui->gap < 4U)
    ui->gap = 4U;
  ui->top_h = height / 25U;
  if (ui->top_h < 28U)
    ui->top_h = 28U;
  ui->status_h = height / 25U;
  if (ui->status_h < 28U)
    ui->status_h = 28U;
  ui->list_y = ui->top_h;
  ui->list_h = height - ui->top_h - ui->status_h;
  ui->side_w = width * 13U / 100U;
  ui->button_x = ui->gap / 2U + ui->side_w + ui->gap;
  ui->button_w = width - 2U * ui->button_x;
  ui->button_h =
      (ui->list_h - (KUAL_PAGE_ROWS - 1U) * ui->gap) / KUAL_PAGE_ROWS;
  ui->list_h = KUAL_PAGE_ROWS * ui->button_h + (KUAL_PAGE_ROWS - 1U) * ui->gap;
}

static int ui_init(UI *ui) {
  memset(ui, 0, sizeof(*ui));
  ui->fbfd = ui->power_fd = -1;
  ui->draw_cfg.is_quiet = true;
  ui->draw_cfg.fontmult = 3;
  ui->draw_cfg.fontname = IBM;
  ui->draw_cfg.no_refresh = true;
  ui->draw_cfg.is_bgless = true;
  ui->draw_cfg.wfm_mode = WFM_GC16;
  ui->fbfd = fbink_open();
  if (ui->fbfd < 0)
    return -1;
  if (fbink_init(ui->fbfd, &ui->draw_cfg) != 0)
    return -1;
  fbink_get_state(&ui->draw_cfg, &ui->state);
  const char *font = "/mnt/us/kual-next/fonts/NotoSans.ttf";
  if (access(font, R_OK) == 0 &&
      fbink_add_ot_font_v2(font, FNT_REGULAR, &ui->text_cfg) == 0)
    ui->opentype_ready = true;
  const char *symbols = "/mnt/us/kual-next/fonts/NotoSansSymbols2-Regular.otf";
  if (access(symbols, R_OK) == 0 &&
      fbink_add_ot_font_v2(symbols, FNT_REGULAR, &ui->symbol_cfg) == 0)
    ui->symbols_ready = true;
  const char *music_symbols = "/mnt/us/kual-next/fonts/NotoSansSymbols.ttf";
  if (access(music_symbols, R_OK) == 0 &&
      fbink_add_ot_font_v2(music_symbols, FNT_REGULAR, &ui->music_symbol_cfg) ==
          0)
    ui->music_symbols_ready = true;
  ui_layout(ui);
  if (ui_inputs_open(ui) != 0)
    return -1;
  if (power_events_open(ui) != 0)
    kual_log("cannot monitor Kindle screen-saver events: %s", strerror(errno));
  return 0;
}

static char *display_text(const char *text, size_t max_chars) {
  if (!text)
    return kual_xstrdup("");
  size_t bytes = strlen(text), chars = 0, cut = 0;
  while (cut < bytes && chars < max_chars) {
    unsigned char c = (unsigned char)text[cut];
    size_t width = c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
    if (cut + width > bytes)
      break;
    cut += width;
    chars++;
  }
  bool truncated = cut < bytes;
  char *out = kual_xcalloc(cut + (truncated ? 4 : 1), 1);
  memcpy(out, text, cut);
  if (truncated)
    memcpy(out + cut, "...", 4);
  return out;
}

static void print_at(UI *ui, int x, int y, const char *text, bool centered) {
  FBInkConfig cfg = ui->draw_cfg;
  cfg.hoffset = (short)x;
  cfg.voffset = (short)y;
  cfg.is_centered = centered;
  (void)fbink_print(ui->fbfd, text, &cfg);
}

static KualEntry *current_menu(UI *ui) { return ui->nav[ui->depth]; }

static void print_area_font(UI *ui, const char *text, unsigned int x,
                            unsigned int y, unsigned int width,
                            unsigned int height, unsigned int size,
                            bool centered, const FBInkOTConfig *font) {
  if (font) {
    FBInkOTConfig cfg = *font;
    cfg.margins.left = (short)x;
    cfg.margins.right = (short)(ui->state.view_width - x - width);
    cfg.margins.top = (short)y;
    cfg.margins.bottom = (short)(ui->state.view_height - y - height);
    cfg.size_px = (unsigned short)size;
    cfg.is_centered = centered;
    FBInkConfig draw = ui->draw_cfg;
    draw.halign = centered ? CENTER : NONE;
    draw.valign = CENTER;
    draw.is_centered = centered;
    draw.is_bgless = true;
    (void)fbink_print_ot(ui->fbfd, text, &cfg, &draw, NULL);
    return;
  }
  size_t columns = ui->state.font_w ? width / ui->state.font_w : 20U;
  char *fallback = display_text(text, columns ? columns : 1U);
  print_at(
      ui, centered ? (int)(x + width / 2U) : (int)x,
      (int)(y + (height > ui->state.font_h ? (height - ui->state.font_h) / 2U
                                           : 0U)),
      fallback, centered);
  free(fallback);
}

static void print_area(UI *ui, const char *text, unsigned int x, unsigned int y,
                       unsigned int width, unsigned int height,
                       unsigned int size, bool centered) {
  print_area_font(ui, text, x, y, width, height, size, centered,
                  ui->opentype_ready ? &ui->text_cfg : NULL);
}

static unsigned int measure_text(UI *ui, const char *text, unsigned int size,
                                 const FBInkOTConfig *font) {
  if (!font || !text || !*text)
    return 0U;
  FBInkOTConfig cfg = *font;
  cfg.margins.left = cfg.margins.top = 0;
  cfg.margins.right = cfg.margins.bottom = 0;
  cfg.size_px = (unsigned short)size;
  cfg.compute_only = true;
  cfg.no_truncation = false;
  cfg.is_centered = false;
  FBInkConfig draw = ui->draw_cfg;
  draw.halign = NONE;
  draw.valign = NONE;
  draw.is_centered = false;
  draw.no_refresh = true;
  FBInkOTFit fit = {0};
  if (fbink_print_ot(ui->fbfd, text, &cfg, &draw, &fit) < 0)
    return 0U;
  return fit.bbox.width;
}

static void print_entry_label(UI *ui, const KualEntry *entry, unsigned int x,
                              unsigned int y, unsigned int width,
                              unsigned int height, unsigned int size) {
  size_t label_size = strlen(entry->name) + (entry->collated ? 2U : 1U);
  char *label = kual_xcalloc(label_size, 1U);
  snprintf(label, label_size, "%s%s", entry->name, entry->collated ? "+" : "");
  if (!ui->opentype_ready || !ui->symbols_ready) {
    char fallback[768];
    snprintf(fallback, sizeof(fallback), "%s%s%s", entry->checked ? "[x] " : "",
             label, entry->child_count ? " v" : "");
    print_area(ui, fallback, x, y, width, height, size, true);
    free(label);
    return;
  }

  unsigned int check_w =
      entry->checked ? measure_text(ui, "✓", size, &ui->symbol_cfg) : 0U;
  unsigned int text_w = measure_text(ui, label, size, &ui->text_cfg);
  unsigned int down_w =
      entry->child_count ? measure_text(ui, "▽", size, &ui->symbol_cfg) : 0U;
  unsigned int spacing = size / 4U;
  if (spacing < 4U)
    spacing = 4U;
  unsigned int left_w = check_w ? check_w + spacing : 0U;
  unsigned int right_w = down_w ? spacing + down_w : 0U;
  unsigned int total = left_w + text_w + right_w;

  if (text_w && total <= width) {
    unsigned int cursor = x + (width - total) / 2U;
    if (check_w) {
      print_area_font(ui, "✓", cursor, y, check_w + 1U, height, size, false,
                      &ui->symbol_cfg);
      cursor += left_w;
    }
    print_area_font(ui, label, cursor, y, text_w + 1U, height, size, false,
                    &ui->text_cfg);
    cursor += text_w;
    if (down_w)
      print_area_font(ui, "▽", cursor + spacing, y, down_w + 1U, height, size,
                      false, &ui->symbol_cfg);
    free(label);
    return;
  }

  if (left_w + right_w >= width) {
    print_area(ui, label, x, y, width, height, size, true);
    free(label);
    return;
  }
  if (check_w)
    print_area_font(ui, "✓", x, y, left_w, height, size, true, &ui->symbol_cfg);
  print_area(ui, label, x + left_w, y, width - left_w - right_w, height, size,
             true);
  if (down_w)
    print_area_font(ui, "▽", x + width - right_w, y, right_w, height, size,
                    true, &ui->symbol_cfg);
  free(label);
}

static void line_gray(UI *ui, unsigned int x, unsigned int y,
                      unsigned int width, unsigned int height, uint8_t gray) {
  if (!width || !height)
    return;
  FBInkRect rect = {(unsigned short)x, (unsigned short)y, (unsigned short)width,
                    (unsigned short)height};
  (void)fbink_fill_rect_gray(ui->fbfd, &ui->draw_cfg, &rect, false, gray);
}

static void rounded_outline(UI *ui, unsigned int x, unsigned int y,
                            unsigned int width, unsigned int height,
                            unsigned int radius, unsigned int thickness,
                            uint8_t gray) {
  if (width < 2U || height < 2U)
    return;
  if (radius * 2U >= width)
    radius = width / 2U - 1U;
  if (radius * 2U >= height)
    radius = height / 2U - 1U;
  for (unsigned int inset = 0; inset < thickness; inset++) {
    unsigned int xi = x + inset, yi = y + inset;
    unsigned int wi = width - inset * 2U, hi = height - inset * 2U;
    unsigned int ri = radius > inset ? radius - inset : 1U;
    line_gray(ui, xi + ri, yi, wi - 2U * ri, 1U, gray);
    line_gray(ui, xi + ri, yi + hi - 1U, wi - 2U * ri, 1U, gray);
    line_gray(ui, xi, yi + ri, 1U, hi - 2U * ri, gray);
    line_gray(ui, xi + wi - 1U, yi + ri, 1U, hi - 2U * ri, gray);
    int cx1 = (int)(xi + ri), cx2 = (int)(xi + wi - ri - 1U);
    int cy1 = (int)(yi + ri), cy2 = (int)(yi + hi - ri - 1U);
    int px = (int)ri, py = 0, decision = 1 - (int)ri;
    while (px >= py) {
      (void)fbink_put_pixel_gray(ui->fbfd, (uint16_t)(cx1 - px),
                                 (uint16_t)(cy1 - py), gray);
      (void)fbink_put_pixel_gray(ui->fbfd, (uint16_t)(cx1 - py),
                                 (uint16_t)(cy1 - px), gray);
      (void)fbink_put_pixel_gray(ui->fbfd, (uint16_t)(cx2 + px),
                                 (uint16_t)(cy1 - py), gray);
      (void)fbink_put_pixel_gray(ui->fbfd, (uint16_t)(cx2 + py),
                                 (uint16_t)(cy1 - px), gray);
      (void)fbink_put_pixel_gray(ui->fbfd, (uint16_t)(cx1 - px),
                                 (uint16_t)(cy2 + py), gray);
      (void)fbink_put_pixel_gray(ui->fbfd, (uint16_t)(cx1 - py),
                                 (uint16_t)(cy2 + px), gray);
      (void)fbink_put_pixel_gray(ui->fbfd, (uint16_t)(cx2 + px),
                                 (uint16_t)(cy2 + py), gray);
      (void)fbink_put_pixel_gray(ui->fbfd, (uint16_t)(cx2 + py),
                                 (uint16_t)(cy2 + px), gray);
      py++;
      if (decision < 0)
        decision += 2 * py + 1;
      else {
        px--;
        decision += 2 * (py - px) + 1;
      }
    }
  }
}

static void draw_triangle(UI *ui, unsigned int center_x, unsigned int center_y,
                          bool points_up, uint8_t gray) {
  unsigned int half = ui->side_w / 11U;
  if (half < 8U)
    half = 8U;
  for (unsigned int offset = 0; offset <= half; offset++) {
    unsigned int span = half - offset;
    if (points_up) {
      unsigned int y = center_y + half / 2U - offset;
      line_gray(ui, center_x - span, y, span * 2U + 1U, 1U, gray);
    } else {
      unsigned int x = center_x - half / 2U + offset;
      line_gray(ui, x, center_y - span, 1U, span * 2U + 1U, gray);
    }
  }
}

static void breadcrumb(UI *ui, char *buffer, size_t size) {
  snprintf(buffer, size, "%s • %s%s/", kual_privilege_indicator(geteuid() == 0),
           ui->breadcrumb_status, *ui->breadcrumb_status ? " | " : "");
  for (size_t i = 1; i <= ui->depth; i++) {
    size_t used = strlen(buffer);
    if (used + 5U >= size)
      break;
    snprintf(buffer + used, size - used, " • %s", ui->nav[i]->name);
  }
}

static void ui_draw(UI *ui) {
  FBInkConfig clear = ui->draw_cfg;
  clear.bg_color = BG_WHITE;
  clear.is_bgless = false;
  clear.wfm_mode = WFM_GC16;
  clear.no_refresh = true;
  (void)fbink_cls(ui->fbfd, &clear, NULL, false);
  KualEntry *menu = current_menu(ui);
  unsigned int outer_x = ui->gap / 2U;
  unsigned int right_x = ui->state.view_width - outer_x - ui->side_w;
  unsigned int radius = ui->state.view_width / 85U;
  if (radius < 8U)
    radius = 8U;
  rounded_outline(ui, outer_x, ui->list_y, ui->side_w, ui->list_h, radius, 1U,
                  170U);
  rounded_outline(ui, right_x, ui->list_y, ui->side_w, ui->list_h, radius, 1U,
                  170U);

  char trail[768];
  breadcrumb(ui, trail, sizeof(trail));
  print_area(ui, trail, outer_x, 0U, ui->state.view_width - 2U * outer_x,
             ui->top_h, ui->state.view_width / 43U, false);

  size_t total = menu->child_count + 1U;
  size_t first = ui->page * KUAL_PAGE_ROWS;
  size_t pages = (total + KUAL_PAGE_ROWS - 1U) / KUAL_PAGE_ROWS;
  bool final_page = ui->page + 1U == pages;
  for (size_t row = 0; row < KUAL_PAGE_ROWS; row++) {
    size_t index = first + row;
    bool special = final_page && row == KUAL_PAGE_ROWS - 1U;
    if (index >= menu->child_count && !special)
      continue;
    unsigned int y = ui->list_y + (unsigned int)row * (ui->button_h + ui->gap);
    rounded_outline(ui, ui->button_x, y, ui->button_w, ui->button_h, radius, 1U,
                    55U);
    if (special) {
      const char *label = ui->depth ? "/" : "× Quit";
      print_area(ui, label, ui->button_x + ui->gap, y,
                 ui->button_w - 2U * ui->gap, ui->button_h,
                 ui->state.view_width / 30U, true);
    } else {
      KualEntry *entry = &menu->children[index];
      print_entry_label(ui, entry, ui->button_x + ui->gap, y,
                        ui->button_w - 2U * ui->gap, ui->button_h,
                        ui->state.view_width / 30U);
    }
  }

  draw_triangle(ui, outer_x + ui->side_w / 2U, ui->list_y + ui->list_h / 2U,
                true, ui->depth ? 80U : 165U);
  draw_triangle(ui, right_x + ui->side_w / 2U, ui->list_y + ui->list_h / 2U,
                false, pages > 1U ? 80U : 165U);

  char footer[512];
  if (*ui->status)
    snprintf(footer, sizeof(footer), "%s", ui->status);
  else {
    size_t end = first + KUAL_PAGE_ROWS;
    if (end > total)
      end = total;
    snprintf(footer, sizeof(footer),
             "Entries %zu - %zu of %zu • KUAL Next %s • %s", first + 1U, end,
             total, KUAL_NEXT_VERSION, ui->state.device_name);
  }
  print_area(ui, footer, outer_x, ui->state.view_height - ui->status_h,
             ui->state.view_width - 2U * outer_x, ui->status_h,
             ui->state.view_width / 45U, false);
  FBInkConfig refresh = ui->draw_cfg;
  refresh.no_refresh = false;
  refresh.wfm_mode = WFM_GC16;
  (void)fbink_refresh(ui->fbfd, 0, 0, 0, 0, &refresh);
}

static void ui_redraw_after_resume(UI *ui) {
  statusbar_hide_if_owned();
  int result = fbink_reinit(ui->fbfd, &ui->draw_cfg);
  if (result < 0)
    kual_log("FBInk reinit after unlock failed: %d", result);
  fbink_get_state(&ui->draw_cfg, &ui->state);
  ui_layout(ui);
  ui_draw(ui);
}

static void schedule_resume_redraw(UI *ui, long delay_ms) {
  clock_gettime(CLOCK_MONOTONIC, &ui->resume_redraw_at);
  ui->resume_redraw_at.tv_sec += delay_ms / 1000L;
  ui->resume_redraw_at.tv_nsec += (delay_ms % 1000L) * 1000000L;
  if (ui->resume_redraw_at.tv_nsec >= 1000000000L) {
    ui->resume_redraw_at.tv_sec++;
    ui->resume_redraw_at.tv_nsec -= 1000000000L;
  }
  ui->resume_redraw_pending = true;
}

static int resume_redraw_timeout(const UI *ui) {
  if (!ui->resume_redraw_pending)
    return -1;
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  long seconds = ui->resume_redraw_at.tv_sec - now.tv_sec;
  long nanoseconds = ui->resume_redraw_at.tv_nsec - now.tv_nsec;
  long milliseconds = seconds * 1000L + nanoseconds / 1000000L;
  if (nanoseconds > 0 && nanoseconds % 1000000L)
    milliseconds++;
  return milliseconds > 0 ? (int)milliseconds : 0;
}

static void finish_resume_redraw(UI *ui) {
  ui->resume_redraw_pending = false;
  ui_redraw_after_resume(ui);
  for (size_t i = 0; i < ui->input_count; i++)
    input_discard(&ui->inputs[i]);
  if (ui_inputs_grab(ui, true))
    ui->screen_saver_active = false;
  else
    schedule_resume_redraw(ui, 1000L);
}

static void handle_power_event(UI *ui, const char *line) {
  if (!strncmp(line, "goingToScreenSaver", 18)) {
    if (!ui->screen_saver_active)
      ui_inputs_grab(ui, false);
    ui->screen_saver_active = true;
    ui->resume_redraw_pending = false;
  } else if (!strncmp(line, "outOfScreenSaver", 16)) {
    ui->screen_saver_active = true;
  } else if (!strncmp(line, "exitingScreenSaver", 18)) {
    ui_redraw_after_resume(ui);
    schedule_resume_redraw(ui, 3000L);
  }
}

static void power_events_read(UI *ui) {
  char chunk[256];
  ssize_t got;
  while ((got = read(ui->power_fd, chunk, sizeof(chunk))) > 0) {
    size_t count = (size_t)got;
    if (count > sizeof(ui->power_buffer) - ui->power_buffer_len - 1U) {
      kual_log("discarding oversized Kindle power event");
      ui->power_buffer_len = 0;
      continue;
    }
    memcpy(ui->power_buffer + ui->power_buffer_len, chunk, count);
    ui->power_buffer_len += count;
    ui->power_buffer[ui->power_buffer_len] = '\0';
    char *line;
    while ((line = memchr(ui->power_buffer, '\n', ui->power_buffer_len)) !=
           NULL) {
      size_t length = (size_t)(line - ui->power_buffer);
      ui->power_buffer[length] = '\0';
      handle_power_event(ui, ui->power_buffer);
      size_t consumed = length + 1U;
      memmove(ui->power_buffer, ui->power_buffer + consumed,
              ui->power_buffer_len - consumed);
      ui->power_buffer_len -= consumed;
      ui->power_buffer[ui->power_buffer_len] = '\0';
    }
  }
  if (got == 0) {
    kual_log("Kindle screen-saver event monitor exited");
    power_events_close(ui);
  } else if (got < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
    kual_log("cannot read Kindle screen-saver events: %s", strerror(errno));
    power_events_close(ui);
  }
}

static void tap_feedback(UI *ui, unsigned int y) {
  FBInkRect rect = {(unsigned short)ui->button_x, (unsigned short)y,
                    (unsigned short)ui->button_w, (unsigned short)ui->button_h};
  (void)fbink_invert_rect(ui->fbfd, &rect, false);
  FBInkConfig cfg = ui->draw_cfg;
  cfg.wfm_mode = WFM_DU;
  cfg.no_refresh = false;
  (void)fbink_refresh_rect(ui->fbfd, &rect, &cfg);
}

static void transform_touch(UI *ui, InputDevice *input, int raw_x, int raw_y,
                            int *x, int *y) {
  double nx = input->max_x > input->min_x ? (double)(raw_x - input->min_x) /
                                                (input->max_x - input->min_x)
                                          : 0;
  double ny = input->max_y > input->min_y ? (double)(raw_y - input->min_y) /
                                                (input->max_y - input->min_y)
                                          : 0;
  if (nx < 0)
    nx = 0;
  if (nx > 1)
    nx = 1;
  if (ny < 0)
    ny = 0;
  if (ny > 1)
    ny = 1;
  bool raw_landscape =
      (input->max_x - input->min_x) > (input->max_y - input->min_y);
  bool view_landscape = ui->state.view_width > ui->state.view_height;
  bool swap = ui->state.touch_swap_axes ^ (raw_landscape != view_landscape);
  bool mirror_x = ui->state.touch_mirror_x, mirror_y = ui->state.touch_mirror_y;
  uint8_t rotation = ui->state.current_rota < 4
                         ? ui->state.rotation_map[ui->state.current_rota]
                         : FB_ROTATE_UR;
  if (rotation > 3)
    rotation =
        ui->state.current_rota < 4 ? ui->state.current_rota : FB_ROTATE_UR;
  if (rotation == FB_ROTATE_CW) {
    swap = !swap;
    mirror_y = !mirror_y;
  } else if (rotation == FB_ROTATE_UD) {
    mirror_x = !mirror_x;
    mirror_y = !mirror_y;
  } else if (rotation == FB_ROTATE_CCW) {
    swap = !swap;
    mirror_x = !mirror_x;
  }
  double tx = swap ? ny : nx, ty = swap ? nx : ny;
  if (mirror_x)
    tx = 1.0 - tx;
  if (mirror_y)
    ty = 1.0 - ty;
  *x = (int)(tx * (ui->state.view_width - 1));
  *y = (int)(ty * (ui->state.view_height - 1));
}

enum tap_action { TAP_NONE, TAP_CLOSE, TAP_BACK, TAP_TOP, TAP_NEXT, TAP_ENTRY };
typedef struct {
  enum tap_action action;
  KualEntry *entry;
} TapResult;

static TapResult map_tap(UI *ui, int x, int y) {
  KualEntry *menu = current_menu(ui);
  if (y < (int)ui->list_y || y >= (int)(ui->list_y + ui->list_h))
    return (TapResult){TAP_NONE, NULL};
  if (x < (int)ui->button_x)
    return (TapResult){ui->depth ? TAP_BACK : TAP_NONE, NULL};
  if (x >= (int)(ui->button_x + ui->button_w))
    return (TapResult){TAP_NEXT, NULL};
  size_t row = (size_t)(y - (int)ui->list_y) / (ui->button_h + ui->gap);
  unsigned int row_y =
      ui->list_y + (unsigned int)row * (ui->button_h + ui->gap);
  if (row >= KUAL_PAGE_ROWS || y >= (int)(row_y + ui->button_h))
    return (TapResult){TAP_NONE, NULL};
  size_t index = ui->page * KUAL_PAGE_ROWS + row;
  if (index < menu->child_count)
    return (TapResult){TAP_ENTRY, &menu->children[index]};
  size_t pages =
      (menu->child_count + 1U + KUAL_PAGE_ROWS - 1U) / KUAL_PAGE_ROWS;
  if (ui->page + 1U == pages && row == KUAL_PAGE_ROWS - 1U)
    return (TapResult){ui->depth ? TAP_TOP : TAP_CLOSE, NULL};
  return (TapResult){TAP_NONE, NULL};
}

static char *action_command(const KualEntry *entry) {
  size_t n =
      strlen(entry->action) + (entry->params ? strlen(entry->params) : 0) + 2;
  char *command = kual_xcalloc(n, 1);
  snprintf(command, n, "%s%s%s", entry->action,
           entry->params && *entry->params ? " " : "",
           entry->params ? entry->params : "");
  return command;
}

static void internal_message(UI *ui, const KualEntry *entry) {
  if (entry->internal_kind == KUAL_INTERNAL_BREADCRUMB)
    snprintf(ui->breadcrumb_status, sizeof(ui->breadcrumb_status), "%s",
             entry->internal);
  else if (entry->internal_kind == KUAL_INTERNAL_STATUS)
    snprintf(ui->status, sizeof(ui->status), "%s", entry->internal);
}

static int run_background(UI *ui, KualEntry *entry) {
  char *command = action_command(entry);
  pid_t pid = fork();
  if (pid == 0) {
    (void)kual_redirect_stderr(KUAL_DEFAULT_LOG);
    if (chdir(entry->working_dir) != 0) {
      dprintf(STDERR_FILENO, "cannot chdir to %s: %s\n", entry->working_dir,
              strerror(errno));
      _exit(126);
    }
    execl("/bin/sh", "sh", "-c", command, (char *)NULL);
    dprintf(STDERR_FILENO, "cannot execute '%s': %s\n", command,
            strerror(errno));
    _exit(127);
  }
  if (pid < 0) {
    snprintf(ui->status, sizeof(ui->status), "Launch failed: %s",
             strerror(errno));
    free(command);
    return -1;
  }
  if (entry->show_status && entry->internal_kind != KUAL_INTERNAL_STATUS)
    snprintf(ui->status, sizeof(ui->status), "%s", command);
  free(command);
  if (entry->checked_after)
    entry->checked = true;
  if (entry->show_date) {
    time_t now = time(NULL);
    struct tm local;
    localtime_r(&now, &local);
    strftime(ui->status, sizeof(ui->status), "%Y-%m-%d %H:%M:%S", &local);
  }
  return 0;
}

static int exec_and_exit(UI *ui, KualEntry *entry) {
  char *command = action_command(entry),
       *cwd = kual_xstrdup(entry->working_dir);
  ui_cleanup(ui);
  statusbar_restore_if_owned();
  (void)kual_redirect_stderr(KUAL_DEFAULT_LOG);
  if (chdir(cwd) != 0) {
    dprintf(STDERR_FILENO, "cannot chdir to %s: %s\n", cwd, strerror(errno));
    free(cwd);
    free(command);
    return 126;
  }
  free(cwd);
  execl("/bin/sh", "sh", "-c", command, (char *)NULL);
  dprintf(STDERR_FILENO, "cannot execute '%s': %s\n", command, strerror(errno));
  free(command);
  return 127;
}

static void sleep_ms(long ms) {
  struct timespec delay = {ms / 1000, (ms % 1000) * 1000000L};
  while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {
  }
}

static void reload_menu(UI *ui, KualMenu *menu, KualErrors *errors) {
  char *root = kual_xstrdup(menu->extensions_dir),
       *model = kual_xstrdup(menu->model);
  kual_menu_free(menu);
  kual_errors_free(errors);
  kual_menu_init(menu, root, model);
  free(root);
  free(model);
  kual_menu_load(menu, errors);
  kual_menu_add_errors(menu, errors);
  ui->depth = ui->page = 0;
  *ui->breadcrumb_status = '\0';
  ui->nav[0] = &menu->root;
}

static int handle_tap(UI *ui, KualMenu *menu, KualErrors *errors,
                      TapResult tap) {
  KualEntry *current = current_menu(ui);
  size_t pages =
      (current->child_count + 1U + KUAL_PAGE_ROWS - 1U) / KUAL_PAGE_ROWS;
  if (!pages)
    pages = 1;
  if (tap.action == TAP_CLOSE)
    return 1;
  if (tap.action == TAP_BACK) {
    if (ui->depth)
      ui->depth--;
    ui->page = 0;
    *ui->status = '\0';
    *ui->breadcrumb_status = '\0';
  } else if (tap.action == TAP_TOP) {
    ui->depth = ui->page = 0;
    *ui->status = '\0';
    *ui->breadcrumb_status = '\0';
  } else if (tap.action == TAP_NEXT) {
    ui->page = (ui->page + 1U) % pages;
    *ui->breadcrumb_status = '\0';
  } else if (tap.action == TAP_ENTRY && tap.entry) {
    if (tap.entry->child_count) {
      if (ui->depth + 1 < MAX_NAV_DEPTH)
        ui->nav[++ui->depth] = tap.entry;
      ui->page = 0;
      *ui->status = '\0';
      *ui->breadcrumb_status = '\0';
    } else {
      internal_message(ui, tap.entry);
      if (tap.entry->action) {
        if (tap.entry->exit_menu)
          return exec_and_exit(ui, tap.entry) + 2;
        run_background(ui, tap.entry);
      }
      if (tap.entry->refresh_after) {
        sleep_ms(250);
        reload_menu(ui, menu, errors);
        sleep_ms(750);
      }
    }
  }
  while (waitpid(-1, NULL, WNOHANG) > 0) {
  }
  ui_draw(ui);
  return 0;
}

static TapResult process_input(UI *ui, InputDevice *input) {
  struct input_event events[32];
  ssize_t got;
  TapResult result = {TAP_NONE, NULL};
  while ((got = read(input->fd, events, sizeof(events))) > 0) {
    size_t count = (size_t)got / sizeof(events[0]);
    for (size_t i = 0; i < count; i++) {
      struct input_event *ev = &events[i];
      if (ev->type == EV_KEY && ev->value == 0) {
        if (ev->code == KEY_HOME || ev->code == KEY_MENU)
          result.action = TAP_CLOSE;
        else if (ev->code == KEY_PAGEUP || ev->code == KEY_F23)
          result.action = TAP_BACK;
        else if (ev->code == KEY_PAGEDOWN || ev->code == KEY_YEN)
          result.action = TAP_NEXT;
        else if (ev->code == BTN_TOUCH) {
          input->down = false;
          input->release_pending = true;
        }
      } else if (ev->type == EV_KEY && ev->code == BTN_TOUCH && ev->value > 0)
        input->down = true;
      else if (ev->type == EV_ABS) {
        if (ev->code == ABS_X || ev->code == ABS_MT_POSITION_X)
          input->x = ev->value;
        else if (ev->code == ABS_Y || ev->code == ABS_MT_POSITION_Y)
          input->y = ev->value;
        else if (ev->code == ABS_MT_TRACKING_ID) {
          if (ev->value < 0) {
            input->down = false;
            input->release_pending = true;
          } else
            input->down = true;
        }
      } else if (ev->type == EV_SYN && ev->code == SYN_REPORT) {
        int x, y;
        transform_touch(ui, input, input->x, input->y, &x, &y);
        if (input->down && !input->reported_down) {
          input->start_x = x;
          input->start_y = y;
          input->reported_down = true;
        }
        if (input->release_pending) {
          int dx = x - input->start_x, dy = y - input->start_y;
          input->release_pending = input->reported_down = false;
          int threshold = (int)ui->state.screen_dpi / 12;
          if (dx * dx + dy * dy <= threshold * threshold) {
            result = map_tap(ui, x, y);
            if (x >= (int)ui->button_x &&
                x < (int)(ui->button_x + ui->button_w) &&
                y >= (int)ui->list_y && y < (int)(ui->list_y + ui->list_h) &&
                result.action != TAP_NONE) {
              unsigned int row = (unsigned int)(y - (int)ui->list_y) /
                                 (ui->button_h + ui->gap);
              tap_feedback(ui, ui->list_y + row * (ui->button_h + ui->gap));
            }
          }
        }
      }
    }
  }
  return result;
}

int kual_ui_run(KualMenu *menu, KualErrors *errors) {
  UI ui;
  if (ui_init(&ui) != 0) {
    ui_cleanup(&ui);
    kual_log("failed to initialize FBInk or input");
    return 1;
  }
  struct sigaction action = {0};
  action.sa_handler = stop_handler;
  sigemptyset(&action.sa_mask);
  sigaction(SIGTERM, &action, NULL);
  sigaction(SIGINT, &action, NULL);
  sigaction(SIGQUIT, &action, NULL);
  ui.nav[0] = &menu->root;
  ui_draw(&ui);
  while (!stopping) {
    struct pollfd fds[MAX_INPUTS + 1U];
    bool monitor_power = ui.power_fd >= 0;
    size_t input_offset = monitor_power ? 1U : 0U;
    if (monitor_power)
      fds[0] = (struct pollfd){ui.power_fd, POLLIN, 0};
    for (size_t i = 0; i < ui.input_count; i++)
      fds[input_offset + i] = (struct pollfd){ui.inputs[i].fd, POLLIN, 0};
    int ready =
        poll(fds, input_offset + ui.input_count, resume_redraw_timeout(&ui));
    if (ready < 0) {
      if (errno == EINTR)
        continue;
      break;
    }
    if (monitor_power && fds[0].revents & (POLLIN | POLLHUP | POLLERR))
      power_events_read(&ui);
    for (size_t i = 0; i < ui.input_count; i++)
      if (fds[input_offset + i].revents & POLLIN) {
        if (ui.screen_saver_active) {
          input_discard(&ui.inputs[i]);
          continue;
        }
        TapResult tap = process_input(&ui, &ui.inputs[i]);
        if (tap.action != TAP_NONE) {
          int result = handle_tap(&ui, menu, errors, tap);
          if (result == 1) {
            ui_cleanup(&ui);
            return 0;
          }
          if (result >= 2)
            return result - 2;
        }
      }
    if (ui.resume_redraw_pending && resume_redraw_timeout(&ui) == 0)
      finish_resume_redraw(&ui);
  }
  ui_cleanup(&ui);
  return 0;
}
