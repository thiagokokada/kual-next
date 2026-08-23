const std = @import("std");
const Io = std.Io;
const core = @import("core");
const options = @import("build_options");
const ui = if (options.host) void else @import("ui");

fn usage(writer: *Io.Writer) !void {
    try writer.writeAll(
        "Usage: kual-next [--extensions PATH] [--model NAME] [--validate] [--version]\n" ++
            "  --validate  parse menus and print the resulting tree without opening FBInk\n",
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (!options.host and args.len == 2 and std.mem.eql(u8, args[1], ui.power_event_monitor_argument))
        std.process.exit(ui.runPowerEventMonitor(allocator, init.io));
    var extensions: []const u8 = core.default_extensions;
    var model_arg: ?[]const u8 = null;
    var validate = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--extensions") and i + 1 < args.len) {
            i += 1;
            extensions = args[i];
        } else if (std.mem.eql(u8, arg, "--model") and i + 1 < args.len) {
            i += 1;
            model_arg = args[i];
        } else if (std.mem.eql(u8, arg, "--validate")) {
            validate = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            var buffer: [256]u8 = undefined;
            var output: Io.File.Writer = .init(.stdout(), init.io, &buffer);
            try output.interface.print("kual-next {s}\n", .{options.version});
            try output.interface.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--help")) {
            var buffer: [1024]u8 = undefined;
            var output: Io.File.Writer = .init(.stdout(), init.io, &buffer);
            try usage(&output.interface);
            try output.interface.flush();
            return;
        } else {
            var buffer: [1024]u8 = undefined;
            var output: Io.File.Writer = .init(.stderr(), init.io, &buffer);
            try usage(&output.interface);
            try output.interface.flush();
            std.process.exit(2);
        }
    }
    const environment = init.minimal.environ;
    const env_model = environment.getPosix("KUAL_MODEL");
    const probed_model = if (!options.host and model_arg == null and (env_model == null or env_model.?.len == 0))
        ui.probeModel(allocator) catch |err| result: {
            core.log(init.io, allocator, "cannot detect Kindle model with FBInk: {s}", .{@errorName(err)});
            break :result null;
        }
    else
        null;
    const model = model_arg orelse (if (env_model != null and env_model.?.len > 0) env_model.? else probed_model orelse "Unknown");
    var errors = core.Errors.init(allocator);
    defer errors.deinit();
    var menu = try core.Menu.init(allocator, init.io, extensions, model);
    defer menu.deinit();
    menu.load(&errors) catch |err| switch (err) {
        error.EmptyMenu => {},
        else => {
            if (!options.host) core.log(init.io, allocator, "cannot load extension menus: {s}", .{@errorName(err)});
            return err;
        },
    };
    if (validate) {
        var stdout_buffer: [4096]u8 = undefined;
        var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
        try core.printMenu(&menu, options.version, &stdout.interface);
        try stdout.interface.flush();
        var stderr_buffer: [4096]u8 = undefined;
        var stderr: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
        for (errors.items.items) |item| try stderr.interface.print("{s}: {s}\n", .{ item.source, item.message });
        try stderr.interface.flush();
        if (errors.items.items.len > 0 or menu.root.children.items.len == 0) std.process.exit(1);
        return;
    }
    if (options.host) {
        var buffer: [256]u8 = undefined;
        var stderr: Io.File.Writer = .init(.stderr(), init.io, &buffer);
        try stderr.interface.writeAll("kual-next: this host build only supports --validate\n");
        try stderr.interface.flush();
        std.process.exit(2);
    }
    for (errors.items.items) |item|
        core.log(init.io, allocator, "menu error in {s}: {s}", .{ item.source, item.message });
    const statusbar_owned = if (environment.getPosix("KUAL_NEXT_STATUSBAR_STOPPED")) |value| std.mem.eql(u8, value, "1") else false;
    std.process.exit(try ui.run(allocator, init.io, &menu, &errors, statusbar_owned));
}
