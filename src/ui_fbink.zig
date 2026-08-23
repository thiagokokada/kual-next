const std = @import("std");
const Io = std.Io;
const core = @import("core");
const ui_logic = @import("ui_logic");
const options = @import("build_options");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("fbink.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("linux/input.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
});

const page_rows = ui_logic.page_rows;
const max_inputs = 16;
const max_nav_depth = core.max_depth + 1;

fn errnoValue() c_int {
    return c.__errno_location().*;
}

fn transientReadError(value: c_int) bool {
    return value == c.EAGAIN or value == c.EINTR;
}

fn linuxReadIoctlRequest(comptime kind: u8, comptime number: u8, comptime Payload: type) c_int {
    const read_direction: u32 = 2;
    const direction_shift = 30;
    const size_shift = 16;
    const kind_shift = 8;
    const encoded = (read_direction << direction_shift) |
        (@as(u32, @sizeOf(Payload)) << size_shift) |
        (@as(u32, kind) << kind_shift) |
        number;
    return @bitCast(encoded);
}

fn evdevGetAbsoluteAxisRequest(comptime code: c_int) c_int {
    return linuxReadIoctlRequest('E', @intCast(0x40 + code), c.struct_input_absinfo);
}

pub fn modelFromFbinkName(name: []const u8) []const u8 {
    const models = [_]struct { fbink: []const u8, kual: []const u8 }{
        .{ .fbink = "PaperWhite 6", .kual = "KindlePaperWhite6" },
        .{ .fbink = "PaperWhite 5", .kual = "KindlePaperWhite5" },
        .{ .fbink = "PaperWhite 4", .kual = "KindlePaperWhite4" },
        .{ .fbink = "PaperWhite 3", .kual = "KindlePaperWhite3" },
        .{ .fbink = "PaperWhite 2", .kual = "KindlePaperWhite2" },
        .{ .fbink = "PaperWhite", .kual = "KindlePaperWhite" },
        .{ .fbink = "Basic 5", .kual = "KindleBasic5" },
        .{ .fbink = "Basic 4", .kual = "KindleBasic4" },
        .{ .fbink = "Basic 3", .kual = "KindleBasic3" },
        .{ .fbink = "Basic 2", .kual = "KindleBasic2" },
        .{ .fbink = "Basic", .kual = "KindleBasic" },
        .{ .fbink = "Oasis 3", .kual = "KindleOasis3" },
        .{ .fbink = "Oasis 2", .kual = "KindleOasis2" },
        .{ .fbink = "Oasis", .kual = "KindleOasis" },
        .{ .fbink = "Scribe ColorSoft", .kual = "KindleScribeColorSoft" },
        .{ .fbink = "Scribe 3", .kual = "KindleScribe3" },
        .{ .fbink = "Scribe 2", .kual = "KindleScribe2" },
        .{ .fbink = "Scribe", .kual = "KindleScribe" },
        .{ .fbink = "ColorSoft", .kual = "KindleColorSoft" },
        .{ .fbink = "Voyage", .kual = "KindleVoyage" },
        .{ .fbink = "Touch", .kual = "KindleTouch" },
    };
    for (models) |model| if (std.mem.eql(u8, name, model.fbink)) return model.kual;
    return "Unknown";
}

pub fn probeModel(allocator: std.mem.Allocator) ![]const u8 {
    var config: c.FBInkConfig = std.mem.zeroes(c.FBInkConfig);
    config.is_quiet = true;
    const fd = c.fbink_open();
    if (fd < 0) return error.FBInkOpenFailed;
    defer _ = c.fbink_close(fd);
    if (c.fbink_init(fd, &config) != 0) return error.FBInkInitFailed;
    var state: c.FBInkState = std.mem.zeroes(c.FBInkState);
    c.fbink_get_state(&config, &state);
    return allocator.dupe(u8, modelFromFbinkName(std.mem.sliceTo(&state.device_name, 0)));
}

const InputDevice = struct {
    fd: c_int = -1,
    min_x: c_int = 0,
    max_x: c_int = 1,
    min_y: c_int = 0,
    max_y: c_int = 1,
    x: c_int = 0,
    y: c_int = 0,
    start_x: c_int = 0,
    start_y: c_int = 0,
    down: bool = false,
    reported_down: bool = false,
    release_pending: bool = false,
    read_error_reported: bool = false,
};

const TapAction = enum { none, close, back, top, next, entry };
const TapResult = struct { action: TapAction = .none, entry: ?*core.Entry = null };

const UI = struct {
    allocator: std.mem.Allocator,
    io: Io,
    fbfd: c_int = -1,
    draw_config: c.FBInkConfig = std.mem.zeroes(c.FBInkConfig),
    text_config: c.FBInkOTConfig = std.mem.zeroes(c.FBInkOTConfig),
    symbol_config: c.FBInkOTConfig = std.mem.zeroes(c.FBInkOTConfig),
    text_ready: bool = false,
    symbols_ready: bool = false,
    state: c.FBInkState = std.mem.zeroes(c.FBInkState),
    inputs: [max_inputs]InputDevice = [_]InputDevice{.{}} ** max_inputs,
    input_count: usize = 0,
    power_child: ?std.process.Child = null,
    power_file: ?Io.File = null,
    power_buffer: [512]u8 = std.mem.zeroes([512]u8),
    power_buffer_length: usize = 0,
    screen_saver_active: bool = false,
    resume_redraw_pending: bool = false,
    resume_redraw_at_ns: i96 = 0,
    nav: [max_nav_depth]?*core.Entry = [_]?*core.Entry{null} ** max_nav_depth,
    depth: usize = 0,
    page: usize = 0,
    top_height: u32 = 0,
    status_height: u32 = 0,
    side_width: u32 = 0,
    gap: u32 = 0,
    chrome_text_size: u32 = 0,
    list_y: u32 = 0,
    list_height: u32 = 0,
    button_x: u32 = 0,
    button_width: u32 = 0,
    button_height: u32 = 0,
    status: [256]u8 = std.mem.zeroes([256]u8),
    breadcrumb_status: [256]u8 = std.mem.zeroes([256]u8),
    render_error_reported: bool = false,

    fn init(allocator: std.mem.Allocator, io: Io, root: *core.Entry) !UI {
        var ui: UI = .{ .allocator = allocator, .io = io };
        ui.nav[0] = root;
        ui.draw_config.is_quiet = true;
        ui.draw_config.fontmult = 3;
        ui.draw_config.fontname = c.IBM;
        ui.draw_config.no_refresh = true;
        ui.draw_config.is_bgless = true;
        ui.draw_config.wfm_mode = c.WFM_GC16;
        ui.fbfd = c.fbink_open();
        if (ui.fbfd < 0) return error.FBInkOpenFailed;
        errdefer ui.cleanup();
        if (c.fbink_init(ui.fbfd, &ui.draw_config) != 0) return error.FBInkInitFailed;
        c.fbink_get_state(&ui.draw_config, &ui.state);
        const text_font = "/mnt/us/kual-next/fonts/NotoSans.ttf";
        if (c.access(text_font, c.R_OK) != 0)
            core.log(io, allocator, "cannot read UI font {s}: errno {d}; using FBInk fallback font", .{ text_font, errnoValue() })
        else if (c.fbink_add_ot_font_v2(text_font, c.FNT_REGULAR, &ui.text_config) != 0)
            core.log(io, allocator, "FBInk could not load UI font {s}; using fallback font", .{text_font})
        else
            ui.text_ready = true;
        const symbol_font = "/mnt/us/kual-next/fonts/NotoSansSymbols2-Regular.otf";
        if (c.access(symbol_font, c.R_OK) != 0)
            core.log(io, allocator, "cannot read symbol font {s}: errno {d}; using text indicators", .{ symbol_font, errnoValue() })
        else if (c.fbink_add_ot_font_v2(symbol_font, c.FNT_REGULAR, &ui.symbol_config) != 0)
            core.log(io, allocator, "FBInk could not load symbol font {s}; using text indicators", .{symbol_font})
        else
            ui.symbols_ready = true;
        ui.layout();
        try ui.openInputs();
        ui.openPowerEvents() catch |err| core.log(io, allocator, "cannot monitor Kindle screen-saver events: {s}", .{@errorName(err)});
        return ui;
    }

    fn cleanup(self: *UI) void {
        self.closePowerEvents();
        for (self.inputs[0..self.input_count]) |input| {
            const release: c_int = 0;
            if (c.ioctl(input.fd, c.EVIOCGRAB, release) != 0)
                core.log(self.io, self.allocator, "cannot release input device fd {d}: errno {d}", .{ input.fd, errnoValue() });
            if (c.close(input.fd) != 0)
                core.log(self.io, self.allocator, "cannot close input device fd {d}: errno {d}", .{ input.fd, errnoValue() });
        }
        self.input_count = 0;
        if (self.text_ready) _ = c.fbink_free_ot_fonts_v2(&self.text_config);
        if (self.symbols_ready) _ = c.fbink_free_ot_fonts_v2(&self.symbol_config);
        self.text_ready = false;
        self.symbols_ready = false;
        if (self.fbfd >= 0) _ = c.fbink_close(self.fbfd);
        self.fbfd = -1;
    }

    fn layout(self: *UI) void {
        const value = ui_logic.calculateLayout(self.state.view_width, self.state.view_height);
        self.gap = value.gap;
        self.top_height = value.top_height;
        self.status_height = value.status_height;
        self.chrome_text_size = value.chrome_text_size;
        self.list_y = value.list_y;
        self.list_height = value.list_height;
        self.side_width = value.side_width;
        self.button_x = value.button_x;
        self.button_width = value.button_width;
        self.button_height = value.button_height;
    }

    fn reinit(self: *UI) !void {
        if (c.fbink_reinit(self.fbfd, &self.draw_config) < 0) return error.FBInkReinitFailed;
        c.fbink_get_state(&self.draw_config, &self.state);
        self.layout();
    }

    fn axisInfo(fd: c_int, comptime code: c_int, minimum: *c_int, maximum: *c_int) bool {
        var info: c.struct_input_absinfo = undefined;
        if (c.ioctl(fd, evdevGetAbsoluteAxisRequest(code), &info) != 0 or info.maximum <= info.minimum) return false;
        minimum.* = info.minimum;
        maximum.* = info.maximum;
        return true;
    }

    fn openInputs(self: *UI) !void {
        var count: usize = 0;
        const wanted = c.INPUT_TOUCHSCREEN | c.INPUT_PAGINATION_BUTTONS | c.INPUT_HOME_BUTTON;
        const devices = c.fbink_input_scan(wanted, c.INPUT_POWER_BUTTON, c.NO_RECAP, &count) orelse return error.InputScanFailed;
        defer c.free(devices);
        var i: usize = 0;
        while (i < count and self.input_count < max_inputs) : (i += 1) {
            if (!devices[i].matched or devices[i].fd < 0) continue;
            var input: InputDevice = .{ .fd = devices[i].fd };
            const mt = axisInfo(input.fd, c.ABS_MT_POSITION_X, &input.min_x, &input.max_x) and
                axisInfo(input.fd, c.ABS_MT_POSITION_Y, &input.min_y, &input.max_y);
            if (!mt) {
                const legacy = axisInfo(input.fd, c.ABS_X, &input.min_x, &input.max_x) and
                    axisInfo(input.fd, c.ABS_Y, &input.min_y, &input.max_y);
                if (!legacy and devices[i].type & c.INPUT_TOUCHSCREEN != 0)
                    core.log(self.io, self.allocator, "input device fd {d} has no usable touch axes", .{input.fd});
            }
            const grab: c_int = 1;
            if (c.ioctl(input.fd, c.EVIOCGRAB, grab) != 0)
                core.log(self.io, self.allocator, "cannot grab input device fd {d}: errno {d}", .{ input.fd, errnoValue() });
            const flags = c.fcntl(input.fd, c.F_GETFL);
            if (flags < 0)
                core.log(self.io, self.allocator, "cannot read input flags for fd {d}: errno {d}", .{ input.fd, errnoValue() })
            else if (c.fcntl(input.fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0)
                core.log(self.io, self.allocator, "cannot make input fd {d} nonblocking: errno {d}", .{ input.fd, errnoValue() });
            self.inputs[self.input_count] = input;
            self.input_count += 1;
        }
        if (i < count)
            core.log(self.io, self.allocator, "input scan found {d} devices; only the first {d} are supported", .{ count, max_inputs });
        if (self.input_count == 0) return error.NoInputDevices;
    }

    fn grabInputs(self: *UI, grab: bool) bool {
        const value: c_int = if (grab) 1 else 0;
        var success = true;
        for (self.inputs[0..self.input_count]) |input| {
            if (c.ioctl(input.fd, c.EVIOCGRAB, value) != 0) {
                success = false;
                core.log(self.io, self.allocator, "cannot {s} input device fd {d}: errno {d}", .{ if (grab) "grab" else "release", input.fd, errnoValue() });
            }
        }
        return success;
    }

    fn discardInput(input: *InputDevice) void {
        var events: [32]c.struct_input_event = undefined;
        while (c.read(input.fd, &events, @sizeOf(@TypeOf(events))) > 0) {}
        input.down = false;
        input.reported_down = false;
        input.release_pending = false;
    }

    fn openPowerEvents(self: *UI) !void {
        const child = try std.process.spawn(self.io, .{
            .argv = &.{
                "/usr/bin/lipc-wait-event",
                "-m",
                "-s",
                "0",
                "com.lab126.powerd",
                "goingToScreenSaver,outOfScreenSaver,exitingScreenSaver",
            },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        const output = child.stdout.?;
        const flags = c.fcntl(output.handle, c.F_GETFL);
        if (flags < 0)
            core.log(self.io, self.allocator, "cannot read screen-saver monitor flags: errno {d}", .{errnoValue()})
        else if (c.fcntl(output.handle, c.F_SETFL, flags | c.O_NONBLOCK) < 0)
            core.log(self.io, self.allocator, "cannot make screen-saver monitor nonblocking: errno {d}", .{errnoValue()});
        self.power_file = output;
        self.power_child = child;
    }

    fn closePowerEvents(self: *UI) void {
        if (self.power_file) |file| file.close(self.io);
        self.power_file = null;
        if (self.power_child) |*child| {
            child.stdout = null;
            child.kill(self.io);
        }
        self.power_child = null;
        self.power_buffer_length = 0;
    }

    fn scheduleResumeRedraw(self: *UI, delay_ms: i64) void {
        self.resume_redraw_at_ns = Io.Clock.awake.now(self.io).nanoseconds + delay_ms * std.time.ns_per_ms;
        self.resume_redraw_pending = true;
    }

    fn resumeTimeout(self: *UI) c_int {
        if (!self.resume_redraw_pending) return -1;
        const remaining = self.resume_redraw_at_ns - Io.Clock.awake.now(self.io).nanoseconds;
        if (remaining <= 0) return 0;
        return @intCast(@min(std.math.maxInt(c_int), @divFloor(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
    }

    fn redrawAfterResume(self: *UI, statusbar_owned: bool) void {
        if (statusbar_owned) serviceCommand(self.io, self.allocator, "/sbin/stop");
        self.reinit() catch |err| core.log(self.io, self.allocator, "FBInk reinit after unlock failed: {s}", .{@errorName(err)});
        self.draw();
    }

    fn finishResumeRedraw(self: *UI, statusbar_owned: bool) void {
        self.resume_redraw_pending = false;
        self.redrawAfterResume(statusbar_owned);
        for (self.inputs[0..self.input_count]) |*input| discardInput(input);
        if (self.grabInputs(true))
            self.screen_saver_active = false
        else
            self.scheduleResumeRedraw(1000);
    }

    fn handlePowerEvent(self: *UI, line: []const u8, statusbar_owned: bool) void {
        if (std.mem.startsWith(u8, line, "goingToScreenSaver")) {
            if (!self.screen_saver_active) _ = self.grabInputs(false);
            self.screen_saver_active = true;
            self.resume_redraw_pending = false;
        } else if (std.mem.startsWith(u8, line, "outOfScreenSaver")) {
            self.screen_saver_active = true;
        } else if (core.powerEventIsUnlock(line, self.screen_saver_active)) {
            self.redrawAfterResume(statusbar_owned);
            self.scheduleResumeRedraw(3000);
        }
    }

    fn readPowerEvents(self: *UI, statusbar_owned: bool) void {
        const file = self.power_file orelse return;
        var chunk: [256]u8 = undefined;
        const got = c.read(file.handle, &chunk, chunk.len);
        if (got == 0) {
            core.log(self.io, self.allocator, "Kindle screen-saver event monitor exited", .{});
            self.closePowerEvents();
            return;
        }
        if (got < 0) {
            const read_errno = errnoValue();
            if (!transientReadError(read_errno)) {
                core.log(self.io, self.allocator, "cannot read Kindle screen-saver events: errno {d}; monitor disabled", .{read_errno});
                self.closePowerEvents();
            }
            return;
        }
        const count: usize = @intCast(got);
        if (count > self.power_buffer.len - self.power_buffer_length - 1) {
            core.log(self.io, self.allocator, "Kindle screen-saver event exceeded the {d}-byte buffer; event discarded", .{self.power_buffer.len});
            self.power_buffer_length = 0;
            return;
        }
        @memcpy(self.power_buffer[self.power_buffer_length..][0..count], chunk[0..count]);
        self.power_buffer_length += count;
        while (std.mem.indexOfScalar(u8, self.power_buffer[0..self.power_buffer_length], '\n')) |newline| {
            self.handlePowerEvent(self.power_buffer[0..newline], statusbar_owned);
            const consumed = newline + 1;
            std.mem.copyForwards(u8, self.power_buffer[0 .. self.power_buffer_length - consumed], self.power_buffer[consumed..self.power_buffer_length]);
            self.power_buffer_length -= consumed;
        }
    }

    fn currentMenu(self: *UI) *core.Entry {
        return self.nav[self.depth].?;
    }

    fn renderFailure(self: *UI, operation: []const u8, code: c_int) void {
        if (self.render_error_reported) return;
        self.render_error_reported = true;
        core.log(self.io, self.allocator, "FBInk render failed during {s}: code {d}", .{ operation, code });
    }

    fn renderAllocationFailure(self: *UI, operation: []const u8, err: anyerror) void {
        if (self.render_error_reported) return;
        self.render_error_reported = true;
        core.log(self.io, self.allocator, "cannot allocate {s} while rendering: {s}", .{ operation, @errorName(err) });
    }

    fn drawLine(self: *UI, x: u32, y: u32, width: u32, height: u32, gray: u8) void {
        if (width == 0 or height == 0) return;
        var rect: c.FBInkRect = .{ .left = @intCast(x), .top = @intCast(y), .width = @intCast(width), .height = @intCast(height) };
        const result = c.fbink_fill_rect_gray(self.fbfd, &self.draw_config, &rect, false, gray);
        if (result < 0) self.renderFailure("rectangle", result);
    }

    fn roundedOutline(self: *UI, x: u32, y: u32, width: u32, height: u32, radius_arg: u32, gray: u8) void {
        if (width < 2 or height < 2) return;
        var radius = @min(radius_arg, @min(width / 2 - 1, height / 2 - 1));
        radius = @max(radius, 1);
        self.drawLine(x + radius, y, width - 2 * radius, 1, gray);
        self.drawLine(x + radius, y + height - 1, width - 2 * radius, 1, gray);
        self.drawLine(x, y + radius, 1, height - 2 * radius, gray);
        self.drawLine(x + width - 1, y + radius, 1, height - 2 * radius, gray);
        const cx1: i32 = @intCast(x + radius);
        const cx2: i32 = @intCast(x + width - radius - 1);
        const cy1: i32 = @intCast(y + radius);
        const cy2: i32 = @intCast(y + height - radius - 1);
        var px: i32 = @intCast(radius);
        var py: i32 = 0;
        var decision: i32 = 1 - px;
        while (px >= py) {
            const points = [_]struct { x: i32, y: i32 }{
                .{ .x = cx1 - px, .y = cy1 - py }, .{ .x = cx1 - py, .y = cy1 - px },
                .{ .x = cx2 + px, .y = cy1 - py }, .{ .x = cx2 + py, .y = cy1 - px },
                .{ .x = cx1 - px, .y = cy2 + py }, .{ .x = cx1 - py, .y = cy2 + px },
                .{ .x = cx2 + px, .y = cy2 + py }, .{ .x = cx2 + py, .y = cy2 + px },
            };
            for (points) |point| {
                const result = c.fbink_put_pixel_gray(self.fbfd, @intCast(point.x), @intCast(point.y), gray);
                if (result < 0) self.renderFailure("pixel", result);
            }
            py += 1;
            if (decision < 0)
                decision += 2 * py + 1
            else {
                px -= 1;
                decision += 2 * (py - px) + 1;
            }
        }
    }

    fn drawTriangle(self: *UI, center_x: u32, center_y: u32, points_up: bool, gray: u8) void {
        const half = @max(8, self.side_width / 11);
        for (0..half + 1) |raw_offset| {
            const offset: u32 = @intCast(raw_offset);
            const span = half - offset;
            if (points_up)
                self.drawLine(center_x - span, center_y + half / 2 - offset, span * 2 + 1, 1, gray)
            else
                self.drawLine(center_x - half / 2 + offset, center_y - span, 1, span * 2 + 1, gray);
        }
    }

    fn printAreaWithFont(self: *UI, text: []const u8, x: u32, y: u32, width: u32, height: u32, size: u32, centered: bool, font: ?*const c.FBInkOTConfig) void {
        const text_z = self.allocator.dupeZ(u8, text) catch |err| {
            self.renderAllocationFailure("text", err);
            return;
        };
        defer self.allocator.free(text_z);
        if (font) |selected| {
            var config = selected.*;
            config.margins.left = @intCast(x);
            config.margins.right = @intCast(self.state.view_width - x - width);
            config.margins.top = @intCast(y);
            config.margins.bottom = @intCast(self.state.view_height - y - height);
            config.size_px = @intCast(size);
            config.is_centered = centered;
            var fb_draw = self.draw_config;
            fb_draw.halign = if (centered) c.CENTER else c.NONE;
            fb_draw.valign = c.CENTER;
            fb_draw.is_centered = centered;
            fb_draw.is_bgless = true;
            const result = c.fbink_print_ot(self.fbfd, text_z.ptr, &config, &fb_draw, null);
            if (result < 0) self.renderFailure("OpenType text", result);
        } else {
            var fb_draw = self.draw_config;
            fb_draw.hoffset = @intCast(if (centered) x + width / 2 else x);
            fb_draw.voffset = @intCast(y + (height -| self.state.font_h) / 2);
            fb_draw.is_centered = centered;
            const result = c.fbink_print(self.fbfd, text_z.ptr, &fb_draw);
            if (result < 0) self.renderFailure("fallback text", result);
        }
    }

    fn printArea(self: *UI, text: []const u8, x: u32, y: u32, width: u32, height: u32, size: u32, centered: bool) void {
        self.printAreaWithFont(text, x, y, width, height, size, centered, if (self.text_ready) &self.text_config else null);
    }

    fn measureText(self: *UI, text: []const u8, size: u32, font: *const c.FBInkOTConfig) u32 {
        const text_z = self.allocator.dupeZ(u8, text) catch |err| {
            self.renderAllocationFailure("text measurement", err);
            return 0;
        };
        defer self.allocator.free(text_z);
        var config = font.*;
        config.margins = std.mem.zeroes(@TypeOf(config.margins));
        config.size_px = @intCast(size);
        config.compute_only = true;
        config.no_truncation = false;
        config.is_centered = false;
        var fb_draw = self.draw_config;
        fb_draw.halign = c.NONE;
        fb_draw.valign = c.NONE;
        fb_draw.is_centered = false;
        fb_draw.no_refresh = true;
        var fit: c.FBInkOTFit = std.mem.zeroes(c.FBInkOTFit);
        const result = c.fbink_print_ot(self.fbfd, text_z.ptr, &config, &fb_draw, &fit);
        if (result < 0) {
            self.renderFailure("text measurement", result);
            return 0;
        }
        return fit.bbox.width;
    }

    fn drawEntry(self: *UI, entry: *const core.Entry, x: u32, y: u32, width: u32, height: u32, size: u32) void {
        const label = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ entry.name, if (entry.collated) "+" else "" }) catch |err| {
            self.renderAllocationFailure("entry label", err);
            return;
        };
        defer self.allocator.free(label);
        if (!self.text_ready or !self.symbols_ready) {
            const fallback = std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ if (entry.checked) "[x] " else "", label, if (entry.children.items.len > 0) " v" else "" }) catch |err| {
                self.renderAllocationFailure("fallback entry label", err);
                return;
            };
            defer self.allocator.free(fallback);
            self.printArea(fallback, x, y, width, height, size, true);
            return;
        }
        const check_width = if (entry.checked) self.measureText("✓", size, &self.symbol_config) else 0;
        const text_width = self.measureText(label, size, &self.text_config);
        const down_width = if (entry.children.items.len > 0) self.measureText("▽", size, &self.symbol_config) else 0;
        const spacing = @max(4, size / 4);
        const left_width = if (check_width > 0) check_width + spacing else 0;
        const right_width = if (down_width > 0) spacing + down_width else 0;
        if (left_width + text_width + right_width <= width) {
            var cursor = x + (width - left_width - text_width - right_width) / 2;
            if (check_width > 0) {
                self.printAreaWithFont("✓", cursor, y, check_width + 1, height, size, false, &self.symbol_config);
                cursor += left_width;
            }
            self.printAreaWithFont(label, cursor, y, text_width + 1, height, size, false, &self.text_config);
            cursor += text_width;
            if (down_width > 0) self.printAreaWithFont("▽", cursor + spacing, y, down_width + 1, height, size, false, &self.symbol_config);
        } else {
            if (check_width > 0) self.printAreaWithFont("✓", x, y, left_width, height, size, true, &self.symbol_config);
            self.printArea(label, x + left_width, y, width -| left_width -| right_width, height, size, true);
            if (down_width > 0) self.printAreaWithFont("▽", x + width - right_width, y, right_width, height, size, true, &self.symbol_config);
        }
    }

    fn breadcrumb(self: *UI) ![]u8 {
        var result: std.ArrayList(u8) = .empty;
        const indicator = core.privilegeIndicator(c.geteuid() == 0);
        try result.appendSlice(self.allocator, indicator);
        try result.appendSlice(self.allocator, " • ");
        const status = std.mem.sliceTo(&self.breadcrumb_status, 0);
        if (status.len > 0) {
            try result.appendSlice(self.allocator, status);
            try result.appendSlice(self.allocator, " | ");
        }
        try result.append(self.allocator, '/');
        for (self.nav[1 .. self.depth + 1]) |entry| {
            try result.appendSlice(self.allocator, " • ");
            try result.appendSlice(self.allocator, entry.?.name);
        }
        return result.toOwnedSlice(self.allocator);
    }

    fn draw(self: *UI) void {
        self.render_error_reported = false;
        var clear = self.draw_config;
        clear.bg_color = c.BG_WHITE;
        clear.is_bgless = false;
        clear.wfm_mode = c.WFM_GC16;
        clear.no_refresh = true;
        const clear_result = c.fbink_cls(self.fbfd, &clear, null, false);
        if (clear_result < 0) self.renderFailure("screen clear", clear_result);
        const menu = self.currentMenu();
        const outer_x = self.gap / 2;
        const right_x = self.state.view_width - outer_x - self.side_width;
        const total = menu.children.items.len + 1;
        const first = self.page * page_rows;
        const pages = (total + page_rows - 1) / page_rows;
        const radius = @max(8, self.state.view_width / 85);
        self.roundedOutline(outer_x, self.list_y, self.side_width, self.list_height, radius, if (self.depth > 0) 55 else 170);
        self.roundedOutline(right_x, self.list_y, self.side_width, self.list_height, radius, if (pages > 1) 55 else 170);
        const trail = self.breadcrumb() catch |err| trail: {
            self.renderAllocationFailure("breadcrumb", err);
            break :trail "";
        };
        defer if (trail.len > 0) self.allocator.free(trail);
        self.printArea(trail, outer_x, 0, self.state.view_width - 2 * outer_x, self.top_height, self.chrome_text_size, false);
        const final_page = self.page + 1 == pages;
        for (0..page_rows) |row| {
            const index = first + row;
            const special = final_page and row == page_rows - 1;
            if (index >= menu.children.items.len and !special) continue;
            const y = self.list_y + @as(u32, @intCast(row)) * (self.button_height + self.gap);
            self.roundedOutline(self.button_x, y, self.button_width, self.button_height, radius, 55);
            if (special)
                self.printArea(if (self.depth > 0) "/" else "× Quit", self.button_x + self.gap, y, self.button_width - 2 * self.gap, self.button_height, self.state.view_width / 30, true)
            else
                self.drawEntry(&menu.children.items[index], self.button_x + self.gap, y, self.button_width - 2 * self.gap, self.button_height, self.state.view_width / 30);
        }
        self.drawTriangle(outer_x + self.side_width / 2, self.list_y + self.list_height / 2, true, if (self.depth > 0) 0 else 165);
        self.drawTriangle(right_x + self.side_width / 2, self.list_y + self.list_height / 2, false, if (pages > 1) 0 else 165);
        const status = std.mem.sliceTo(&self.status, 0);
        const footer = if (status.len > 0) self.allocator.dupe(u8, status) catch |err| {
            self.renderAllocationFailure("status text", err);
            return;
        } else std.fmt.allocPrint(self.allocator, "Entries {d} - {d} of {d} • KUAL Next {s} • {s}", .{
            first + 1,
            @min(first + page_rows, total),
            total,
            options.version,
            std.mem.sliceTo(&self.state.device_name, 0),
        }) catch |err| {
            self.renderAllocationFailure("footer text", err);
            return;
        };
        defer self.allocator.free(footer);
        self.printArea(footer, outer_x, self.state.view_height - self.status_height, self.state.view_width - 2 * outer_x, self.status_height, self.chrome_text_size, false);
        var refresh = self.draw_config;
        refresh.no_refresh = false;
        refresh.wfm_mode = c.WFM_GC16;
        const refresh_result = c.fbink_refresh(self.fbfd, 0, 0, 0, 0, &refresh);
        if (refresh_result < 0) {
            self.renderFailure("full refresh", refresh_result);
        } else {
            const wait_result = c.fbink_wait_for_complete(self.fbfd, c.LAST_MARKER);
            if (wait_result < 0) self.renderFailure("refresh wait", wait_result);
        }
    }

    fn transformTouch(self: *UI, input: *InputDevice, raw_x: c_int, raw_y: c_int) struct { x: c_int, y: c_int } {
        var nx = if (input.max_x > input.min_x) @as(f64, @floatFromInt(raw_x - input.min_x)) / @as(f64, @floatFromInt(input.max_x - input.min_x)) else 0;
        var ny = if (input.max_y > input.min_y) @as(f64, @floatFromInt(raw_y - input.min_y)) / @as(f64, @floatFromInt(input.max_y - input.min_y)) else 0;
        nx = std.math.clamp(nx, 0, 1);
        ny = std.math.clamp(ny, 0, 1);
        const raw_landscape = input.max_x - input.min_x > input.max_y - input.min_y;
        const view_landscape = self.state.view_width > self.state.view_height;
        var swap = self.state.touch_swap_axes != (raw_landscape != view_landscape);
        var mirror_x = self.state.touch_mirror_x;
        var mirror_y = self.state.touch_mirror_y;
        var rotation = if (self.state.current_rota < 4) self.state.rotation_map[self.state.current_rota] else c.FB_ROTATE_UR;
        if (rotation > 3) rotation = if (self.state.current_rota < 4) self.state.current_rota else c.FB_ROTATE_UR;
        if (rotation == c.FB_ROTATE_CW) {
            swap = !swap;
            mirror_y = !mirror_y;
        } else if (rotation == c.FB_ROTATE_UD) {
            mirror_x = !mirror_x;
            mirror_y = !mirror_y;
        } else if (rotation == c.FB_ROTATE_CCW) {
            swap = !swap;
            mirror_x = !mirror_x;
        }
        var tx = if (swap) ny else nx;
        var ty = if (swap) nx else ny;
        if (mirror_x) tx = 1 - tx;
        if (mirror_y) ty = 1 - ty;
        return .{
            .x = @intFromFloat(tx * @as(f64, @floatFromInt(self.state.view_width - 1))),
            .y = @intFromFloat(ty * @as(f64, @floatFromInt(self.state.view_height - 1))),
        };
    }

    fn mapTap(self: *UI, x: c_int, y: c_int) TapResult {
        const menu = self.currentMenu();
        const layout_value: ui_logic.Layout = .{
            .top_height = self.top_height,
            .status_height = self.status_height,
            .side_width = self.side_width,
            .gap = self.gap,
            .chrome_text_size = self.chrome_text_size,
            .list_y = self.list_y,
            .list_height = self.list_height,
            .button_x = self.button_x,
            .button_width = self.button_width,
            .button_height = self.button_height,
        };
        return switch (ui_logic.mapTap(layout_value, self.depth, self.page, menu.children.items.len, x, y)) {
            .none => .{},
            .close => .{ .action = .close },
            .back => .{ .action = .back },
            .top => .{ .action = .top },
            .next => .{ .action = .next },
            .entry => |index| .{ .action = .entry, .entry = &menu.children.items[index] },
        };
    }

    fn processInput(self: *UI, input: *InputDevice) TapResult {
        var events: [32]c.struct_input_event = undefined;
        const bytes = std.mem.asBytes(&events);
        const got = c.read(input.fd, bytes.ptr, bytes.len);
        if (got <= 0) {
            const read_errno = if (got < 0) errnoValue() else 0;
            if (!input.read_error_reported and (got == 0 or !transientReadError(read_errno))) {
                if (got == 0)
                    core.log(self.io, self.allocator, "input device fd {d} reached end of file", .{input.fd})
                else
                    core.log(self.io, self.allocator, "cannot read input device fd {d}: errno {d}", .{ input.fd, read_errno });
                input.read_error_reported = true;
            }
            return .{};
        }
        input.read_error_reported = false;
        var result: TapResult = .{};
        const count: usize = @intCast(@divFloor(got, @sizeOf(c.struct_input_event)));
        for (events[0..count]) |event| {
            if (event.type == c.EV_KEY and event.value == 0) {
                if (event.code == c.KEY_HOME or event.code == c.KEY_MENU) result.action = .close else if (event.code == c.KEY_PAGEUP or event.code == c.KEY_F23) result.action = .back else if (event.code == c.KEY_PAGEDOWN or event.code == c.KEY_YEN) result.action = .next else if (event.code == c.BTN_TOUCH) {
                    input.down = false;
                    input.release_pending = true;
                }
            } else if (event.type == c.EV_KEY and event.code == c.BTN_TOUCH and event.value > 0) input.down = true else if (event.type == c.EV_ABS) {
                if (event.code == c.ABS_X or event.code == c.ABS_MT_POSITION_X) input.x = event.value else if (event.code == c.ABS_Y or event.code == c.ABS_MT_POSITION_Y) input.y = event.value else if (event.code == c.ABS_MT_TRACKING_ID) {
                    if (event.value < 0) {
                        input.down = false;
                        input.release_pending = true;
                    } else input.down = true;
                }
            } else if (event.type == c.EV_SYN and event.code == c.SYN_REPORT) {
                const point = self.transformTouch(input, input.x, input.y);
                if (input.down and !input.reported_down) {
                    input.start_x = point.x;
                    input.start_y = point.y;
                    input.reported_down = true;
                }
                if (input.release_pending) {
                    const dx = point.x - input.start_x;
                    const dy = point.y - input.start_y;
                    input.release_pending = false;
                    input.reported_down = false;
                    const threshold: c_int = @intCast(self.state.screen_dpi / 12);
                    if (dx * dx + dy * dy <= threshold * threshold) {
                        result = self.mapTap(point.x, point.y);
                        if (result.action != .none and point.x >= self.button_x and point.x < self.button_x + self.button_width and point.y >= self.list_y and point.y < self.list_y + self.list_height) {
                            const row: u32 = @intCast(@divFloor(point.y - @as(c_int, @intCast(self.list_y)), @as(c_int, @intCast(self.button_height + self.gap))));
                            self.tapFeedback(self.list_y + row * (self.button_height + self.gap));
                        }
                    }
                }
            }
        }
        return result;
    }

    fn tapFeedback(self: *UI, y: u32) void {
        var rect: c.FBInkRect = .{ .left = @intCast(self.button_x), .top = @intCast(y), .width = @intCast(self.button_width), .height = @intCast(self.button_height) };
        const invert_result = c.fbink_invert_rect(self.fbfd, &rect, false);
        if (invert_result < 0)
            core.log(self.io, self.allocator, "FBInk tap feedback invert failed: code {d}", .{invert_result});
        var config = self.draw_config;
        config.wfm_mode = c.WFM_DU;
        config.no_refresh = false;
        const refresh_result = c.fbink_refresh_rect(self.fbfd, &rect, &config);
        if (refresh_result < 0)
            core.log(self.io, self.allocator, "FBInk tap feedback refresh failed: code {d}", .{refresh_result});
    }
};

var stopping: c.sig_atomic_t = 0;
fn stopHandler(_: c_int) callconv(.c) void {
    stopping = 1;
}

fn serviceCommand(io: Io, allocator: std.mem.Allocator, path: []const u8) void {
    var child = std.process.spawn(io, .{ .argv = &.{ path, "statusbar" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err| {
        core.log(io, allocator, "cannot run {s} statusbar: {s}", .{ path, @errorName(err) });
        return;
    };
    const term = child.wait(io) catch |err| {
        core.log(io, allocator, "cannot wait for {s} statusbar: {s}", .{ path, @errorName(err) });
        return;
    };
    switch (term) {
        .exited => |code| if (code != 0) core.log(io, allocator, "{s} statusbar exited with status {d}", .{ path, code }),
        .signal => |signal| core.log(io, allocator, "{s} statusbar terminated by signal {d}", .{ path, @intFromEnum(signal) }),
        .stopped => |signal| core.log(io, allocator, "{s} statusbar stopped by signal {d}", .{ path, @intFromEnum(signal) }),
        .unknown => |status| core.log(io, allocator, "{s} statusbar returned unknown status {d}", .{ path, status }),
    }
}

fn openLog(io: Io) !Io.File {
    const cwd = Io.Dir.cwd();
    const file = cwd.openFile(io, core.default_log, .{ .mode = .write_only }) catch
        try cwd.createFile(io, core.default_log, .{ .truncate = false, .permissions = .fromMode(0o644) });
    errdefer file.close(io);
    const length = try file.length(io);
    var reader = file.readerStreaming(io, &.{});
    try reader.seekTo(length);
    return file;
}

fn actionCommand(allocator: std.mem.Allocator, entry: *const core.Entry) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ entry.action.?, if (entry.params != null and entry.params.?.len > 0) " " else "", entry.params orelse "" });
}

fn setStatus(ui: *UI, text: []const u8) void {
    @memset(&ui.status, 0);
    @memcpy(ui.status[0..@min(text.len, ui.status.len - 1)], text[0..@min(text.len, ui.status.len - 1)]);
}

fn showCurrentDate(ui: *UI) void {
    const now: u64 = @intCast(@max(0, @divFloor(Io.Clock.real.now(ui.io).nanoseconds, std.time.ns_per_s)));
    const date = core.formatDisplayDate(ui.allocator, now) catch |err| {
        core.log(ui.io, ui.allocator, "cannot format current date: {s}", .{@errorName(err)});
        return;
    };
    defer ui.allocator.free(date);
    setStatus(ui, date);
}

fn notifyDocumentIndexer(ui: *UI) void {
    const log_file: ?Io.File = openLog(ui.io) catch |err| log: {
        core.log(ui.io, ui.allocator, "cannot open action log for document index notification: {s}", .{@errorName(err)});
        break :log null;
    };
    defer if (log_file) |file| file.close(ui.io);
    _ = std.process.spawn(ui.io, .{
        .argv = &.{ "dbus-send", "--system", "/default", "com.lab126.powerd.resuming", "int32:1" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = if (log_file) |file| .{ .file = file } else .ignore,
    }) catch |err| {
        setStatus(ui, "Log saved; index notification failed");
        core.log(ui.io, ui.allocator, "cannot launch dbus-send: {s}", .{@errorName(err)});
    };
}

fn internalMessage(ui: *UI, entry: *const core.Entry) void {
    const message = entry.internal orelse return;
    const destination = if (entry.internal_kind == .breadcrumb) &ui.breadcrumb_status else if (entry.internal_kind == .status) &ui.status else return;
    @memset(destination, 0);
    @memcpy(destination[0..@min(message.len, destination.len - 1)], message[0..@min(message.len, destination.len - 1)]);
}

fn spawnAction(ui: *UI, entry: *core.Entry) !void {
    const command = try actionCommand(ui.allocator, entry);
    defer ui.allocator.free(command);
    const log_file: ?Io.File = openLog(ui.io) catch |err| log: {
        core.log(ui.io, ui.allocator, "cannot open action log for '{s}': {s}", .{ entry.name, @errorName(err) });
        break :log null;
    };
    defer if (log_file) |file| file.close(ui.io);
    _ = try std.process.spawn(ui.io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .cwd = .{ .path = entry.working_dir },
        .stderr = if (log_file) |file| .{ .file = file } else .ignore,
    });
    if (entry.show_status) setStatus(ui, command);
    if (entry.checked_after) entry.checked = true;
}

fn execAndExit(ui: *UI, entry: *const core.Entry) u8 {
    const command = actionCommand(ui.allocator, entry) catch |err| {
        core.log(ui.io, ui.allocator, "cannot build command for '{s}': {s}", .{ entry.name, @errorName(err) });
        return 127;
    };
    const log_file: ?Io.File = openLog(ui.io) catch |err| log: {
        core.log(ui.io, ui.allocator, "cannot open action log for '{s}': {s}", .{ entry.name, @errorName(err) });
        break :log null;
    };
    if (log_file) |file| {
        if (c.dup2(file.handle, c.STDERR_FILENO) < 0) core.log(ui.io, ui.allocator, "cannot redirect action stderr", .{});
        file.close(ui.io);
    }
    std.process.setCurrentPath(ui.io, entry.working_dir) catch |err| {
        core.log(ui.io, ui.allocator, "cannot chdir to {s}: {s}", .{ entry.working_dir, @errorName(err) });
        return 126;
    };
    const replace_error = std.process.replace(ui.io, .{ .argv = &.{ "/bin/sh", "-c", command } });
    core.log(ui.io, ui.allocator, "cannot execute '{s}': {s}", .{ command, @errorName(replace_error) });
    return 127;
}

fn reloadMenu(ui: *UI, menu: *core.Menu, errors: *core.Errors) !void {
    const allocator = menu.backing_allocator;
    const extensions = try allocator.dupe(u8, menu.extensions_dir);
    defer allocator.free(extensions);
    const model = try allocator.dupe(u8, menu.model);
    defer allocator.free(model);
    const io = menu.io;
    menu.deinit();
    errors.deinit();
    errors.* = core.Errors.init(allocator);
    menu.* = try core.Menu.init(allocator, io, extensions, model);
    menu.load(errors) catch |err| if (err != error.EmptyMenu) return err;
    for (errors.items.items) |item|
        core.log(io, ui.allocator, "menu error in {s}: {s}", .{ item.source, item.message });
    ui.depth = 0;
    ui.page = 0;
    @memset(&ui.status, 0);
    @memset(&ui.breadcrumb_status, 0);
    ui.nav = [_]?*core.Entry{null} ** max_nav_depth;
    ui.nav[0] = &menu.root;
}

fn handleTap(ui: *UI, menu: *core.Menu, errors: *core.Errors, tap: TapResult, statusbar_restore_pending: *bool) !?u8 {
    const current = ui.currentMenu();
    const pages = @max(1, (current.children.items.len + 1 + page_rows - 1) / page_rows);
    switch (tap.action) {
        .none => return null,
        .close => return 0,
        .back => {
            if (ui.depth > 0) ui.depth -= 1;
            ui.page = 0;
            @memset(&ui.status, 0);
            @memset(&ui.breadcrumb_status, 0);
        },
        .top => {
            ui.depth = 0;
            ui.page = 0;
            @memset(&ui.status, 0);
            @memset(&ui.breadcrumb_status, 0);
        },
        .next => {
            ui.page = (ui.page + 1) % pages;
            @memset(&ui.breadcrumb_status, 0);
        },
        .entry => {
            const entry = tap.entry.?;
            if (entry.children.items.len > 0) {
                if (ui.depth + 1 < max_nav_depth) {
                    ui.depth += 1;
                    ui.nav[ui.depth] = entry;
                }
                ui.page = 0;
                @memset(&ui.status, 0);
                @memset(&ui.breadcrumb_status, 0);
            } else {
                internalMessage(ui, entry);
                if (entry.builtin_action == .quit) return 0;
                if (entry.builtin_action == .sort_abc or entry.builtin_action == .sort_123) {
                    const mode = if (entry.builtin_action == .sort_abc) "ABC" else "123";
                    core.setSortMode(ui.allocator, ui.io, menu.extensions_dir, mode) catch |err| {
                        setStatus(ui, @errorName(err));
                        core.log(ui.io, ui.allocator, "cannot set sort mode to {s}: {s}", .{ mode, @errorName(err) });
                        return null;
                    };
                    reloadMenu(ui, menu, errors) catch |err| {
                        setStatus(ui, @errorName(err));
                        core.log(ui.io, ui.allocator, "cannot reload menus after changing sort mode: {s}", .{@errorName(err)});
                        return null;
                    };
                } else if (entry.builtin_action == .save_log) {
                    const destination = core.archiveLog(ui.allocator, ui.io, core.default_log, core.default_documents, @intCast(@max(0, @divFloor(Io.Clock.real.now(ui.io).nanoseconds, std.time.ns_per_s)))) catch |err| {
                        setStatus(ui, @errorName(err));
                        core.log(ui.io, ui.allocator, "cannot archive log to {s}: {s}", .{ core.default_documents, @errorName(err) });
                        return null;
                    };
                    ui.allocator.free(destination);
                    entry.checked = entry.checked_after;
                    showCurrentDate(ui);
                    notifyDocumentIndexer(ui);
                } else if (entry.action != null) {
                    if (entry.exit_menu) {
                        ui.cleanup();
                        if (statusbar_restore_pending.*) {
                            serviceCommand(ui.io, ui.allocator, "/sbin/start");
                            statusbar_restore_pending.* = false;
                        }
                        return execAndExit(ui, entry);
                    }
                    spawnAction(ui, entry) catch |err| {
                        setStatus(ui, @errorName(err));
                        core.log(ui.io, ui.allocator, "cannot launch action '{s}' from {s}: {s}", .{ entry.name, entry.working_dir, @errorName(err) });
                        return null;
                    };
                    if (entry.show_date) showCurrentDate(ui);
                    if (entry.refresh_after) {
                        Io.sleep(ui.io, .fromMilliseconds(250), .awake) catch {};
                        reloadMenu(ui, menu, errors) catch |err| {
                            setStatus(ui, @errorName(err));
                            core.log(ui.io, ui.allocator, "cannot reload menus after action '{s}': {s}", .{ entry.name, @errorName(err) });
                            return null;
                        };
                        Io.sleep(ui.io, .fromMilliseconds(750), .awake) catch {};
                    }
                }
            }
        },
    }
    ui.draw();
    return null;
}

pub fn run(allocator: std.mem.Allocator, io: Io, menu: *core.Menu, errors: *core.Errors, statusbar_owned: bool) !u8 {
    var ui = UI.init(allocator, io, &menu.root) catch |err| {
        core.log(io, allocator, "failed to initialize FBInk or input: {s}", .{@errorName(err)});
        return 1;
    };
    defer ui.cleanup();
    var statusbar_restore_pending = statusbar_owned;
    defer if (statusbar_restore_pending) serviceCommand(io, allocator, "/sbin/start");
    _ = c.signal(c.SIGTERM, stopHandler);
    _ = c.signal(c.SIGINT, stopHandler);
    _ = c.signal(c.SIGQUIT, stopHandler);
    Io.sleep(io, .fromMilliseconds(500), .awake) catch {};
    ui.reinit() catch |err| core.log(io, allocator, "FBInk reinit before first draw failed: {s}", .{@errorName(err)});
    ui.draw();
    while (stopping == 0) {
        var fds: [max_inputs + 1]c.struct_pollfd = undefined;
        const monitor_power = ui.power_file != null;
        const input_offset: usize = if (monitor_power) 1 else 0;
        if (monitor_power) fds[0] = .{ .fd = ui.power_file.?.handle, .events = c.POLLIN, .revents = 0 };
        for (ui.inputs[0..ui.input_count], 0..) |input, i| fds[input_offset + i] = .{ .fd = input.fd, .events = c.POLLIN, .revents = 0 };
        const ready = c.poll(&fds, @intCast(input_offset + ui.input_count), ui.resumeTimeout());
        if (ready < 0) {
            const poll_errno = errnoValue();
            if (poll_errno == c.EINTR) continue;
            core.log(io, allocator, "input poll failed: errno {d}", .{poll_errno});
            return 1;
        }
        if (monitor_power and fds[0].revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0)
            ui.readPowerEvents(statusbar_owned);
        var i: usize = 0;
        while (i < ui.input_count) : (i += 1) if (fds[input_offset + i].revents & c.POLLIN != 0) {
            if (ui.screen_saver_active) {
                UI.discardInput(&ui.inputs[i]);
                continue;
            }
            const tap = ui.processInput(&ui.inputs[i]);
            if (try handleTap(&ui, menu, errors, tap, &statusbar_restore_pending)) |result| return result;
        };
        if (ui.resume_redraw_pending and ui.resumeTimeout() == 0)
            ui.finishResumeRedraw(statusbar_owned);
        while (c.waitpid(-1, null, c.WNOHANG) > 0) {}
    }
    return 0;
}

test "FBInk names map to KUAL model identifiers" {
    try std.testing.expectEqualStrings("KindlePaperWhite5", modelFromFbinkName("PaperWhite 5"));
    try std.testing.expectEqualStrings("Unknown", modelFromFbinkName("Future Kindle"));
}
