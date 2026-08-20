#define _POSIX_C_SOURCE 200809L
#include "kual.h"
#include "fbink.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_INPUTS 16
#define MAX_NAV_DEPTH (KUAL_MAX_DEPTH + 1)

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
    FBInkState state;
    InputDevice inputs[MAX_INPUTS];
    size_t input_count;
    KualEntry *nav[MAX_NAV_DEPTH];
    size_t depth;
    size_t page;
    unsigned int header_h, footer_h, row_h, page_size;
    char status[256];
} UI;

static volatile sig_atomic_t stopping;
static void stop_handler(int sig) { (void)sig; stopping = 1; }

const char *kual_model_from_fbink_name(const char *name) {
    static const struct { const char *fbink, *kual; } models[] = {
        {"PaperWhite 6", "KindlePaperWhite6"}, {"PaperWhite 5", "KindlePaperWhite5"},
        {"PaperWhite 4", "KindlePaperWhite4"}, {"PaperWhite 3", "KindlePaperWhite3"},
        {"PaperWhite 2", "KindlePaperWhite2"}, {"PaperWhite", "KindlePaperWhite"},
        {"Basic 5", "KindleBasic5"}, {"Basic 4", "KindleBasic4"},
        {"Basic 3", "KindleBasic3"}, {"Basic 2", "KindleBasic2"}, {"Basic", "KindleBasic"},
        {"Oasis 3", "KindleOasis3"}, {"Oasis 2", "KindleOasis2"}, {"Oasis", "KindleOasis"},
        {"Scribe ColorSoft", "KindleScribeColorSoft"}, {"Scribe 3", "KindleScribe3"},
        {"Scribe 2", "KindleScribe2"}, {"Scribe", "KindleScribe"},
        {"ColorSoft", "KindleColorSoft"}, {"Voyage", "KindleVoyage"},
        {"Touch", "KindleTouch"}, {NULL, NULL}
    };
    for (size_t i = 0; models[i].fbink; i++) if (!strcmp(name, models[i].fbink)) return models[i].kual;
    return "Unknown";
}

char *kual_device_model_probe(void) {
    FBInkConfig cfg = {0}; cfg.is_quiet = true;
    int fd = fbink_open(); if (fd < 0) return NULL;
    if (fbink_init(fd, &cfg) != 0) { fbink_close(fd); return NULL; }
    FBInkState state = {0}; fbink_get_state(&cfg, &state);
    char *model = kual_xstrdup(kual_model_from_fbink_name(state.device_name));
    fbink_close(fd); return model;
}

static void ui_cleanup(UI *ui) {
    for (size_t i = 0; i < ui->input_count; i++) {
        int release = 0; ioctl(ui->inputs[i].fd, EVIOCGRAB, release); close(ui->inputs[i].fd);
    }
    ui->input_count = 0;
    if (ui->fbfd >= 0) { fbink_close(ui->fbfd); ui->fbfd = -1; }
}

static bool axis_info(int fd, unsigned int code, int *min, int *max) {
    struct input_absinfo info;
    if (ioctl(fd, EVIOCGABS(code), &info) != 0 || info.maximum <= info.minimum) return false;
    *min = info.minimum; *max = info.maximum; return true;
}

static int ui_inputs_open(UI *ui) {
    size_t count = 0;
    INPUT_DEVICE_TYPE_T wanted = INPUT_TOUCHSCREEN | INPUT_PAGINATION_BUTTONS | INPUT_HOME_BUTTON;
    FBInkInputDevice *devices = fbink_input_scan(wanted, INPUT_POWER_BUTTON, NO_RECAP, &count);
    if (!devices) return -1;
    for (size_t i = 0; i < count && ui->input_count < MAX_INPUTS; i++) {
        if (!devices[i].matched || devices[i].fd < 0) continue;
        InputDevice *input = &ui->inputs[ui->input_count++];
        memset(input, 0, sizeof(*input)); input->fd = devices[i].fd; input->type = devices[i].type;
        bool mt = axis_info(input->fd, ABS_MT_POSITION_X, &input->min_x, &input->max_x) &&
                  axis_info(input->fd, ABS_MT_POSITION_Y, &input->min_y, &input->max_y);
        if (!mt) {
            axis_info(input->fd, ABS_X, &input->min_x, &input->max_x);
            axis_info(input->fd, ABS_Y, &input->min_y, &input->max_y);
        }
        int grab = 1;
        if (ioctl(input->fd, EVIOCGRAB, grab) != 0) kual_log("cannot grab input fd %d: %s", input->fd, strerror(errno));
    }
    free(devices);
    return ui->input_count ? 0 : -1;
}

static int ui_init(UI *ui) {
    memset(ui, 0, sizeof(*ui)); ui->fbfd = -1;
    ui->draw_cfg.is_quiet = true; ui->draw_cfg.fontmult = 3;
    ui->draw_cfg.fontname = IBM; ui->draw_cfg.no_refresh = true;
    ui->draw_cfg.is_bgless = true; ui->draw_cfg.wfm_mode = WFM_GC16;
    ui->fbfd = fbink_open(); if (ui->fbfd < 0) return -1;
    if (fbink_init(ui->fbfd, &ui->draw_cfg) != 0) return -1;
    fbink_get_state(&ui->draw_cfg, &ui->state);
    unsigned int font_h = ui->state.font_h ? ui->state.font_h : 48;
    ui->header_h = font_h * 2; ui->footer_h = font_h * 2;
    unsigned int touch_h = (unsigned int)ui->state.screen_dpi * 8U / 25U;
    ui->row_h = font_h * 2 > touch_h ? font_h * 2 : touch_h;
    unsigned int available = ui->state.view_height > ui->header_h + ui->footer_h ?
        ui->state.view_height - ui->header_h - ui->footer_h : ui->row_h;
    ui->page_size = available / ui->row_h; if (!ui->page_size) ui->page_size = 1;
    if (ui_inputs_open(ui) != 0) return -1;
    return 0;
}

static char *display_text(const char *text, size_t max_chars) {
    if (!text) return kual_xstrdup("");
    size_t bytes = strlen(text), chars = 0, cut = 0;
    while (cut < bytes && chars < max_chars) {
        unsigned char c = (unsigned char)text[cut];
        size_t width = c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
        if (cut + width > bytes) break;
        cut += width;
        chars++;
    }
    bool truncated = cut < bytes;
    char *out = kual_xcalloc(cut + (truncated ? 4 : 1), 1);
    memcpy(out, text, cut); if (truncated) memcpy(out + cut, "...", 4);
    return out;
}

static void print_at(UI *ui, int x, int y, const char *text, bool centered) {
    FBInkConfig cfg = ui->draw_cfg; cfg.hoffset = (short)x; cfg.voffset = (short)y;
    cfg.is_centered = centered;
    (void)fbink_print(ui->fbfd, text, &cfg);
}

static KualEntry *current_menu(UI *ui) { return ui->nav[ui->depth]; }

static void ui_draw(UI *ui) {
    FBInkConfig clear = ui->draw_cfg; clear.bg_color = BG_WHITE; clear.is_bgless = false;
    clear.wfm_mode = WFM_GC16; clear.no_refresh = true;
    (void)fbink_cls(ui->fbfd, &clear, NULL, false);
    KualEntry *menu = current_menu(ui);
    char header[512];
    snprintf(header, sizeof(header), "%s  %s", ui->depth ? "< Back" : "X Close", menu->name);
    char *header_display = display_text(header, ui->state.max_cols > 2 ? ui->state.max_cols - 2 : 20);
    print_at(ui, (int)ui->state.font_w, 0, header_display, false); free(header_display);
    size_t first = ui->page * ui->page_size;
    for (size_t row = 0; row < ui->page_size && first + row < menu->child_count; row++) {
        KualEntry *entry = &menu->children[first + row];
        size_t max = ui->state.max_cols > 5 ? ui->state.max_cols - 5 : 20;
        char *name = display_text(entry->name, max);
        size_t n = strlen(name) + 5; char *line = kual_xcalloc(n, 1);
        snprintf(line, n, "%s%s", entry->child_count ? "> " : "  ", name);
        print_at(ui, (int)ui->state.font_w,
            (int)(ui->header_h + row * ui->row_h + (ui->row_h - ui->state.font_h) / 2), line, false);
        free(line); free(name);
    }
    size_t pages = (menu->child_count + ui->page_size - 1) / ui->page_size; if (!pages) pages = 1;
    char footer[512];
    if (*ui->status) snprintf(footer, sizeof(footer), "%s", ui->status);
    else snprintf(footer, sizeof(footer), "Prev       %zu/%zu       Next", ui->page + 1, pages);
    char *footer_display = display_text(footer, ui->state.max_cols > 2 ? ui->state.max_cols - 2 : 20);
    print_at(ui, 0, (int)(ui->state.view_height - ui->footer_h), footer_display, true); free(footer_display);
    FBInkConfig refresh = ui->draw_cfg; refresh.no_refresh = false; refresh.wfm_mode = WFM_GC16;
    (void)fbink_refresh(ui->fbfd, 0, 0, 0, 0, &refresh);
}

static void tap_feedback(UI *ui, unsigned int y) {
    FBInkRect rect = {0, (unsigned short)y, (unsigned short)ui->state.view_width, (unsigned short)ui->row_h};
    (void)fbink_invert_rect(ui->fbfd, &rect, false);
    FBInkConfig cfg = ui->draw_cfg; cfg.wfm_mode = WFM_DU; cfg.no_refresh = false;
    (void)fbink_refresh_rect(ui->fbfd, &rect, &cfg);
}

static void transform_touch(UI *ui, InputDevice *input, int raw_x, int raw_y, int *x, int *y) {
    double nx = input->max_x > input->min_x ? (double)(raw_x - input->min_x) / (input->max_x - input->min_x) : 0;
    double ny = input->max_y > input->min_y ? (double)(raw_y - input->min_y) / (input->max_y - input->min_y) : 0;
    if (nx < 0) nx = 0;
    if (nx > 1) nx = 1;
    if (ny < 0) ny = 0;
    if (ny > 1) ny = 1;
    bool raw_landscape = (input->max_x - input->min_x) > (input->max_y - input->min_y);
    bool view_landscape = ui->state.view_width > ui->state.view_height;
    bool swap = ui->state.touch_swap_axes ^ (raw_landscape != view_landscape);
    bool mirror_x = ui->state.touch_mirror_x, mirror_y = ui->state.touch_mirror_y;
    uint8_t rotation = ui->state.current_rota < 4 ? ui->state.rotation_map[ui->state.current_rota] : FB_ROTATE_UR;
    if (rotation > 3) rotation = ui->state.current_rota < 4 ? ui->state.current_rota : FB_ROTATE_UR;
    if (rotation == FB_ROTATE_CW) { swap = !swap; mirror_y = !mirror_y; }
    else if (rotation == FB_ROTATE_UD) { mirror_x = !mirror_x; mirror_y = !mirror_y; }
    else if (rotation == FB_ROTATE_CCW) { swap = !swap; mirror_x = !mirror_x; }
    double tx = swap ? ny : nx, ty = swap ? nx : ny;
    if (mirror_x) tx = 1.0 - tx;
    if (mirror_y) ty = 1.0 - ty;
    *x = (int)(tx * (ui->state.view_width - 1)); *y = (int)(ty * (ui->state.view_height - 1));
}

enum tap_action { TAP_NONE, TAP_CLOSE, TAP_BACK, TAP_PREV, TAP_NEXT, TAP_ENTRY };
typedef struct { enum tap_action action; KualEntry *entry; } TapResult;

static TapResult map_tap(UI *ui, int x, int y) {
    (void)x; KualEntry *menu = current_menu(ui);
    if (y < (int)ui->header_h) return (TapResult){ui->depth ? TAP_BACK : TAP_CLOSE, NULL};
    if (y >= (int)(ui->state.view_height - ui->footer_h)) {
        return (TapResult){x < (int)ui->state.view_width / 2 ? TAP_PREV : TAP_NEXT, NULL};
    }
    size_t row = (size_t)(y - (int)ui->header_h) / ui->row_h;
    size_t index = ui->page * ui->page_size + row;
    if (row < ui->page_size && index < menu->child_count)
        return (TapResult){TAP_ENTRY, &menu->children[index]};
    return (TapResult){TAP_NONE, NULL};
}

static char *action_command(const KualEntry *entry) {
    size_t n = strlen(entry->action) + (entry->params ? strlen(entry->params) : 0) + 2;
    char *command = kual_xcalloc(n, 1);
    snprintf(command, n, "%s%s%s", entry->action, entry->params && *entry->params ? " " : "", entry->params ? entry->params : "");
    return command;
}

static void internal_message(UI *ui, const KualEntry *entry) {
    if (!entry->internal) return;
    const char *message = entry->internal;
    if (!strncmp(message, "breadcrumb ", 11)) message += 11;
    else if (!strncmp(message, "status ", 7)) message += 7;
    snprintf(ui->status, sizeof(ui->status), "%s", message);
}

static int run_background(UI *ui, KualEntry *entry) {
    char *command = action_command(entry);
    pid_t pid = fork();
    if (pid == 0) {
        if (chdir(entry->working_dir) != 0) _exit(126);
        execl("/bin/sh", "sh", "-c", command, (char *)NULL); _exit(127);
    }
    if (pid < 0) { snprintf(ui->status, sizeof(ui->status), "Launch failed: %s", strerror(errno)); free(command); return -1; }
    if (entry->show_status && !entry->internal) snprintf(ui->status, sizeof(ui->status), "%s", command);
    free(command);
    if (entry->checked_after && strncmp(entry->name, "[x] ", 4)) {
        size_t n = strlen(entry->name) + 5; char *checked = kual_xcalloc(n, 1);
        snprintf(checked, n, "[x] %s", entry->name); free(entry->name); entry->name = checked;
    }
    if (entry->show_date) {
        time_t now = time(NULL); struct tm local; localtime_r(&now, &local);
        strftime(ui->status, sizeof(ui->status), "%Y-%m-%d %H:%M:%S", &local);
    }
    return 0;
}

static int exec_and_exit(UI *ui, KualEntry *entry) {
    char *command = action_command(entry), *cwd = kual_xstrdup(entry->working_dir);
    ui_cleanup(ui);
    if (chdir(cwd) != 0) { kual_log("cannot chdir to %s: %s", cwd, strerror(errno)); free(cwd); free(command); return 126; }
    free(cwd); execl("/bin/sh", "sh", "-c", command, (char *)NULL);
    kual_log("cannot execute '%s': %s", command, strerror(errno)); free(command); return 127;
}

static void sleep_ms(long ms) {
    struct timespec delay = {ms / 1000, (ms % 1000) * 1000000L};
    while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {}
}

static void reload_menu(UI *ui, KualMenu *menu, KualErrors *errors) {
    char *root = kual_xstrdup(menu->extensions_dir), *model = kual_xstrdup(menu->model);
    kual_menu_free(menu); kual_errors_free(errors);
    kual_menu_init(menu, root, model); free(root); free(model);
    kual_menu_load(menu, errors); kual_menu_add_errors(menu, errors);
    ui->depth = ui->page = 0; ui->nav[0] = &menu->root;
}

static int handle_tap(UI *ui, KualMenu *menu, KualErrors *errors, TapResult tap) {
    KualEntry *current = current_menu(ui);
    size_t pages = (current->child_count + ui->page_size - 1) / ui->page_size; if (!pages) pages = 1;
    if (tap.action == TAP_CLOSE) return 1;
    if (tap.action == TAP_BACK) { if (ui->depth) ui->depth--; ui->page = 0; *ui->status = '\0'; }
    else if (tap.action == TAP_PREV) { if (ui->page) ui->page--; }
    else if (tap.action == TAP_NEXT) { if (ui->page + 1 < pages) ui->page++; }
    else if (tap.action == TAP_ENTRY && tap.entry) {
        if (tap.entry->child_count) {
            if (ui->depth + 1 < MAX_NAV_DEPTH) ui->nav[++ui->depth] = tap.entry;
            ui->page = 0; *ui->status = '\0';
        } else {
            internal_message(ui, tap.entry);
            if (tap.entry->action) {
                if (tap.entry->exit_menu) return exec_and_exit(ui, tap.entry) + 2;
                run_background(ui, tap.entry);
            }
            if (tap.entry->refresh_after) { sleep_ms(250); reload_menu(ui, menu, errors); sleep_ms(750); }
        }
    }
    while (waitpid(-1, NULL, WNOHANG) > 0) {}
    ui_draw(ui); return 0;
}

static TapResult process_input(UI *ui, InputDevice *input) {
    struct input_event events[32]; ssize_t got;
    TapResult result = {TAP_NONE, NULL};
    while ((got = read(input->fd, events, sizeof(events))) > 0) {
        size_t count = (size_t)got / sizeof(events[0]);
        for (size_t i = 0; i < count; i++) {
            struct input_event *ev = &events[i];
            if (ev->type == EV_KEY && ev->value == 0) {
                if (ev->code == KEY_HOME || ev->code == KEY_MENU) result.action = TAP_CLOSE;
                else if (ev->code == KEY_PAGEUP || ev->code == KEY_F23) result.action = TAP_PREV;
                else if (ev->code == KEY_PAGEDOWN || ev->code == KEY_YEN) result.action = TAP_NEXT;
                else if (ev->code == BTN_TOUCH) { input->down = false; input->release_pending = true; }
            } else if (ev->type == EV_KEY && ev->code == BTN_TOUCH && ev->value > 0) input->down = true;
            else if (ev->type == EV_ABS) {
                if (ev->code == ABS_X || ev->code == ABS_MT_POSITION_X) input->x = ev->value;
                else if (ev->code == ABS_Y || ev->code == ABS_MT_POSITION_Y) input->y = ev->value;
                else if (ev->code == ABS_MT_TRACKING_ID) {
                    if (ev->value < 0) { input->down = false; input->release_pending = true; }
                    else input->down = true;
                }
            } else if (ev->type == EV_SYN && ev->code == SYN_REPORT) {
                int x, y; transform_touch(ui, input, input->x, input->y, &x, &y);
                if (input->down && !input->reported_down) {
                    input->start_x = x; input->start_y = y; input->reported_down = true;
                }
                if (input->release_pending) {
                    int dx = x - input->start_x, dy = y - input->start_y;
                    input->release_pending = input->reported_down = false;
                    int threshold = (int)ui->state.screen_dpi / 12;
                    if (dx * dx + dy * dy <= threshold * threshold) {
                        result = map_tap(ui, x, y);
                        if (result.action == TAP_ENTRY) tap_feedback(ui, ui->header_h +
                            ((unsigned int)(y - (int)ui->header_h) / ui->row_h) * ui->row_h);
                    }
                }
            }
        }
    }
    return result;
}

int kual_ui_run(KualMenu *menu, KualErrors *errors) {
    UI ui;
    if (ui_init(&ui) != 0) { ui_cleanup(&ui); kual_log("failed to initialize FBInk or input"); return 1; }
    struct sigaction action = {0}; action.sa_handler = stop_handler; sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL); sigaction(SIGINT, &action, NULL); sigaction(SIGQUIT, &action, NULL);
    ui.nav[0] = &menu->root; ui_draw(&ui);
    while (!stopping) {
        struct pollfd fds[MAX_INPUTS];
        for (size_t i = 0; i < ui.input_count; i++) fds[i] = (struct pollfd){ui.inputs[i].fd, POLLIN, 0};
        int ready = poll(fds, ui.input_count, -1);
        if (ready < 0) { if (errno == EINTR) continue; break; }
        for (size_t i = 0; i < ui.input_count; i++) if (fds[i].revents & POLLIN) {
            TapResult tap = process_input(&ui, &ui.inputs[i]);
            if (tap.action != TAP_NONE) {
                int result = handle_tap(&ui, menu, errors, tap);
                if (result == 1) { ui_cleanup(&ui); return 0; }
                if (result >= 2) return result - 2;
            }
        }
    }
    ui_cleanup(&ui); return 0;
}
