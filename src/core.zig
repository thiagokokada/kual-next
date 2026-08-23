const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const posix_regex = @import("regex.zig");
const xml_parser = @import("xml");

pub const default_extensions = "/mnt/us/extensions";
pub const default_log = "/var/tmp/kual-next.log";
pub const default_documents = "/mnt/us/documents";
pub const max_depth = 10;

pub const InternalKind = enum { none, breadcrumb, status };
pub const BuiltinAction = enum { none, sort_abc, sort_123, save_log, quit };

pub const Entry = struct {
    name: []const u8 = "",
    action: ?[]const u8 = null,
    params: ?[]const u8 = null,
    condition: ?[]const u8 = null,
    internal: ?[]const u8 = null,
    internal_kind: InternalKind = .none,
    builtin_action: BuiltinAction = .none,
    working_dir: []const u8 = "",
    extension_id: []const u8 = "",
    source: []const u8 = "",
    priority: i32 = 0,
    order: usize = 0,
    exit_menu: bool = true,
    checked_after: bool = false,
    checked: bool = false,
    refresh_after: bool = false,
    show_status: bool = true,
    show_date: bool = false,
    hidden: bool = false,
    collated: bool = false,
    children: std.ArrayList(Entry) = .empty,
};

pub const ErrorItem = struct { source: []const u8, message: []const u8 };

pub const Errors = struct {
    allocator: Allocator,
    items: std.ArrayList(ErrorItem) = .empty,

    pub fn init(allocator: Allocator) Errors {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Errors) void {
        for (self.items.items) |item| {
            self.allocator.free(item.source);
            self.allocator.free(item.message);
        }
        self.items.deinit(self.allocator);
    }

    pub fn add(self: *Errors, source: []const u8, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(self.allocator, .{
            .source = try self.allocator.dupe(u8, source),
            .message = try std.fmt.allocPrint(self.allocator, fmt, args),
        });
    }
};

const Option = struct { key: []const u8, value: []const u8 };

pub const Config = struct {
    items: std.ArrayList(Option) = .empty,

    pub fn get(self: *const Config, key: []const u8) ?[]const u8 {
        var i = self.items.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.items.items[i].key, key)) return self.items.items[i].value;
        }
        return null;
    }

    pub fn set(self: *Config, allocator: Allocator, key: []const u8, value: []const u8) !void {
        for (self.items.items) |*item| {
            if (std.mem.eql(u8, item.key, key)) {
                item.value = try allocator.dupe(u8, value);
                return;
            }
        }
        try self.items.append(allocator, .{
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
        });
    }
};

pub const Menu = struct {
    backing_allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    io: Io,
    root: Entry,
    config: Config = .{},
    extension_aliases: std.ArrayList([]const u8) = .empty,
    extension_id_count: usize = 0,
    extensions_dir: []const u8,
    model: []const u8,
    next_order: usize = 1,

    pub fn init(backing_allocator: Allocator, io: Io, extensions_dir: []const u8, model: []const u8) !Menu {
        const actual_model = if (model.len == 0) "Unknown" else model;
        var menu: Menu = .{
            .backing_allocator = backing_allocator,
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .io = io,
            .root = .{ .name = "KUAL Next" },
            .extensions_dir = "",
            .model = "",
        };
        errdefer menu.deinit();
        const allocator = menu.arenaAllocator();
        menu.extensions_dir = try allocator.dupe(u8, extensions_dir);
        menu.model = try allocator.dupe(u8, actual_model);
        try menu.config.set(allocator, "model", menu.model);
        return menu;
    }

    pub fn deinit(self: *Menu) void {
        self.arena.deinit();
    }

    fn arenaAllocator(self: *Menu) Allocator {
        return self.arena.allocator();
    }

    fn addAlias(self: *Menu, id: []const u8) !void {
        if (id.len == 0) return;
        for (self.extension_aliases.items) |alias| if (std.mem.eql(u8, alias, id)) return;
        try self.extension_aliases.append(self.arenaAllocator(), try self.arenaAllocator().dupe(u8, id));
    }

    pub fn load(self: *Menu, errors: *Errors) !void {
        const allocator = self.arenaAllocator();
        const config_path = try join(allocator, self.extensions_dir, "KUAL.cfg");
        try loadConfig(self, config_path, errors);

        var search_depth: usize = 2;
        if (self.config.get("search_depth")) |value| {
            const parsed = std.fmt.parseInt(usize, value, 10) catch 0;
            if (parsed >= 1 and parsed <= max_depth) search_depth = parsed;
        }
        const follow = if (self.config.get("nofollow")) |v| !asciiEqlIgnoreCase(v, "true") else true;
        var files: std.ArrayList(ExtensionFile) = .empty;
        var seen: std.ArrayList(DirectoryKey) = .empty;
        try discoverDir(self, self.extensions_dir, 0, search_depth, follow, self.config.get("search_exclude_paths"), &files, &seen, errors);

        for (files.items) |file| try self.parseExtension(file, errors);
        try pruneEntries(self, &self.root, errors);
        if (self.config.get("collate") == null or !asciiEqlIgnoreCase(self.config.get("collate").?, "false"))
            try collateEntries(self, &self.root);
        const mode = self.config.get("sort_mode") orelse "ABC";
        if (asciiEqlIgnoreCase(mode, "123"))
            sortEntries(&self.root, .priority, true)
        else if (asciiEqlIgnoreCase(mode, "ABC!"))
            sortEntries(&self.root, .alphabetic, true)
        else if (asciiEqlIgnoreCase(mode, "ABC"))
            sortEntries(&self.root, .alphabetic, false);
        try self.buildKualMenu(errors);
        if (self.root.children.items.len == 0) return error.EmptyMenu;
    }

    fn parseExtension(self: *Menu, file: ExtensionFile, errors: *Errors) !void {
        const allocator = self.arenaAllocator();
        const cwd = dirname(file.path);
        var loaded = false;
        for (file.menus.items) |name| {
            const path = try join(allocator, cwd, name);
            loaded = (try self.parseJsonMenu(path, cwd, file.id, errors)) or loaded;
        }
        if (file.menus.items.len == 0)
            try errors.add(file.path, "no readable JSON menu declaration", .{});
        if (loaded) {
            // Conditions are pruned only after every extension is parsed, so
            // aliases registered here remain independent of directory order.
            try self.addAlias(std.fs.path.basename(cwd));
            try self.addAlias(file.id);
            self.extension_id_count += 1;
        }
    }

    fn parseJsonMenu(self: *Menu, path: []const u8, cwd: []const u8, id: []const u8, errors: *Errors) !bool {
        const allocator = self.arenaAllocator();
        const data = Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(4 * 1024 * 1024 + 1)) catch |err| {
            try errors.add(path, "cannot read JSON menu: {s}", .{@errorName(err)});
            return false;
        };
        const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, data, .{}) catch |err| {
            try errors.add(path, "invalid JSON menu ({s})", .{@errorName(err)});
            return false;
        };
        if (value != .object) {
            try errors.add(path, "invalid JSON menu (top level is not an object)", .{});
            return false;
        }
        const items = value.object.get("items") orelse {
            try errors.add(path, "top-level items array is missing", .{});
            return false;
        };
        if (items != .array) {
            try errors.add(path, "top-level items array is missing", .{});
            return false;
        }
        for (items.array.items) |item| try self.parseItem(&self.root, item, 0, cwd, id, path, errors);
        return true;
    }

    fn parseItem(self: *Menu, parent: *Entry, value: std.json.Value, depth: usize, cwd: []const u8, id: []const u8, source: []const u8, errors: *Errors) !void {
        if (value != .object) return;
        if (depth >= max_depth) {
            try errors.add(source, "menu exceeds {d} levels", .{max_depth});
            return;
        }
        const allocator = self.arenaAllocator();
        const object = value.object;
        const items = object.get("items");
        var entry: Entry = .{
            .name = jsonString(object.get("name")) orelse "",
            .action = jsonString(object.get("action")),
            .params = jsonString(object.get("params")),
            .condition = jsonString(object.get("if")),
            .internal = jsonString(object.get("internal")),
            .priority = jsonInt(object.get("priority"), 0),
            .exit_menu = jsonBool(object.get("exitmenu"), true),
            .checked_after = jsonBool(object.get("checked"), false),
            .refresh_after = jsonBool(object.get("refresh"), false),
            .show_status = jsonBool(object.get("status"), true),
            .show_date = jsonBool(object.get("date"), false),
            .hidden = jsonBool(object.get("hidden"), false),
            .working_dir = cwd,
            .extension_id = id,
            .source = source,
            .order = self.next_order,
        };
        self.next_order += 1;
        parseInternal(&entry, items != null);
        if (entry.name.len == 0 or (entry.action == null and items == null)) {
            try errors.add(source, "menu entry is missing name or action/items", .{});
            return;
        }
        if (items) |children| if (children == .array) {
            for (children.array.items) |child| try self.parseItem(&entry, child, depth + 1, cwd, id, source, errors);
        };
        try parent.children.append(allocator, entry);
    }

    fn buildKualMenu(self: *Menu, errors: *Errors) !void {
        const allocator = self.arenaAllocator();
        const show = self.config.get("show_KUAL_buttons");
        if (show != null and std.mem.eql(u8, show.?, "0") and errors.items.items.len == 0) return;
        var menu: Entry = .{
            .name = if (errors.items.items.len > 0)
                try std.fmt.allocPrint(allocator, "KUAL ● {d}", .{errors.items.items.len})
            else
                "KUAL",
            .priority = std.math.minInt(i32),
            .order = 0,
        };
        for (errors.items.items) |item| {
            try menu.children.append(allocator, .{
                .name = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ std.fs.path.basename(item.source), item.message }),
                .internal = item.message,
                .internal_kind = .breadcrumb,
                .working_dir = "/var/tmp",
                .exit_menu = false,
                .show_status = false,
                .priority = -1000,
                .order = self.next_order,
            });
            self.next_order += 1;
        }
        if (show == null or !std.mem.eql(u8, show.?, "0")) {
            const buttons = if (show != null and show.?.len > 0) show.? else "2 3 99";
            const mode = self.config.get("sort_mode") orelse "ABC";
            const is_abc = asciiEqlIgnoreCase(mode, "ABC") or asciiEqlIgnoreCase(mode, "ABC!");
            var tokens = std.mem.tokenizeAny(u8, buttons, " \t\r\n");
            while (tokens.next()) |token| {
                if (std.mem.eql(u8, token, "2")) {
                    try menu.children.append(allocator, .{
                        .name = if (is_abc) "Sort menu 123" else "Sort menu ABC",
                        .builtin_action = if (is_abc) .sort_123 else .sort_abc,
                        .working_dir = "/var/tmp",
                        .priority = 2,
                        .exit_menu = false,
                        .checked_after = true,
                        .refresh_after = true,
                        .show_status = false,
                        .order = self.next_order,
                    });
                    self.next_order += 1;
                } else if (std.mem.eql(u8, token, "3") and fileNonEmpty(self.io, default_log)) {
                    try menu.children.append(allocator, .{
                        .name = "Save and reset KUAL log",
                        .builtin_action = .save_log,
                        .working_dir = "/var/tmp",
                        .condition = "\"/var/tmp/kual-next.log\" -z!",
                        .priority = 3,
                        .exit_menu = false,
                        .checked_after = true,
                        .show_status = false,
                        .show_date = true,
                        .order = self.next_order,
                    });
                    self.next_order += 1;
                } else if (std.mem.eql(u8, token, "99")) {
                    try menu.children.append(allocator, .{
                        .name = "× Quit",
                        .builtin_action = .quit,
                        .working_dir = "/var/tmp",
                        .priority = 99,
                        .order = self.next_order,
                    });
                    self.next_order += 1;
                }
            }
        }
        if (menu.children.items.len == 0) return;
        const mode = self.config.get("sort_mode") orelse "ABC";
        if (asciiEqlIgnoreCase(mode, "123"))
            sortEntries(&menu, .priority, true)
        else if (asciiEqlIgnoreCase(mode, "ABC!"))
            sortEntries(&menu, .alphabetic, true);
        try self.root.children.insert(allocator, 0, menu);
    }
};

fn loadConfig(menu: *Menu, path: []const u8, errors: *Errors) !void {
    const data = Io.Dir.cwd().readFileAlloc(menu.io, path, menu.arenaAllocator(), .limited(4 * 1024 * 1024 + 1)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            try errors.add(path, "failed reading configuration: {s}", .{@errorName(err)});
            return;
        },
    };
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        var key = std.mem.trim(u8, line[0..eq], " \t\r");
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        if (!std.mem.startsWith(u8, key, "KUAL_") or key.len == 5) continue;
        key = key[5..];
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\'')))
            value = value[1 .. value.len - 1];
        try menu.config.set(menu.arenaAllocator(), key, value);
    }
}

const ExtensionFile = struct {
    path: []const u8,
    id: []const u8 = "",
    menus: std.ArrayList([]const u8) = .empty,
    is_extension: bool = false,
};

const DirectoryKey = struct {
    device_major: u32,
    device_minor: u32,
    inode: u64,
};

fn directoryKey(dir: Io.Dir) !DirectoryKey {
    const linux = std.os.linux;
    var statx = std.mem.zeroes(linux.Statx);
    while (true) {
        switch (linux.errno(linux.statx(dir.handle, "", linux.AT.EMPTY_PATH, .BASIC_STATS, &statx))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.DirectoryIdentityUnavailable,
        }
    }
    if (!statx.mask.INO) return error.DirectoryIdentityUnavailable;
    return .{
        .device_major = statx.dev_major,
        .device_minor = statx.dev_minor,
        .inode = statx.ino,
    };
}

fn discoverDir(menu: *Menu, path: []const u8, depth: usize, limit: usize, follow: bool, exclude: ?[]const u8, files: *std.ArrayList(ExtensionFile), seen: *std.ArrayList(DirectoryKey), errors: *Errors) !void {
    const allocator = menu.arenaAllocator();
    const stat = Io.Dir.cwd().statFile(menu.io, path, .{ .follow_symlinks = follow }) catch |err| {
        if (depth == 0 or err != error.FileNotFound)
            try errors.add(path, "cannot inspect directory: {s}", .{@errorName(err)});
        return;
    };
    if (stat.kind != .directory) return;
    const dir = Io.Dir.cwd().openDir(menu.io, path, .{ .iterate = true }) catch |err| {
        try errors.add(path, "cannot open directory: {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(menu.io);
    const key = directoryKey(dir) catch |err| {
        try errors.add(path, "cannot identify directory: {s}", .{@errorName(err)});
        return;
    };
    for (seen.items) |visited| if (std.meta.eql(visited, key)) return;
    try seen.append(allocator, key);
    var iterator = dir.iterateAssumeFirstIteration();
    while (try iterator.next(menu.io)) |entry| {
        const child = try join(allocator, path, entry.name);
        if (excludedPath(menu.extensions_dir, child, exclude)) continue;
        const child_stat = Io.Dir.cwd().statFile(menu.io, child, .{ .follow_symlinks = follow }) catch |err| {
            if (err != error.FileNotFound)
                try errors.add(child, "cannot inspect path: {s}", .{@errorName(err)});
            continue;
        };
        if (child_stat.kind == .directory and depth < limit) {
            try discoverDir(menu, child, depth + 1, limit, follow, exclude, files, seen, errors);
        } else if (child_stat.kind == .file and std.mem.eql(u8, entry.name, "config.xml")) {
            const xml = Io.Dir.cwd().readFileAlloc(menu.io, child, allocator, .limited(4 * 1024 * 1024 + 1)) catch |err| {
                try errors.add(child, "cannot read config.xml: {s}", .{@errorName(err)});
                continue;
            };
            var file: ExtensionFile = .{ .path = child };
            parseExtensionXml(allocator, xml, &file) catch |err| {
                try errors.add(child, "{s}", .{xmlErrorName(err)});
                continue;
            };
            if (!file.is_extension) {
                try errors.add(child, "not a KUAL extension config", .{});
                continue;
            }
            try files.append(allocator, file);
        }
    }
}

const XmlError = error{ InvalidEntity, MismatchedClose, UnexpectedEof, InvalidSyntax };

fn xmlErrorName(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidEntity => "invalid entity reference",
        error.MismatchedClose => "mismatched closing element",
        error.UnexpectedEof => "unexpected end of file",
        else => "invalid XML syntax",
    };
}

fn zigXmlError(code: xml_parser.Reader.ErrorCode) XmlError {
    return switch (code) {
        .entity_reference_undefined, .entity_reference_unclosed, .character_reference_malformed, .character_reference_unclosed, .doctype_unsupported => error.InvalidEntity,
        .element_end_mismatched => error.MismatchedClose,
        .unexpected_eof, .element_end_unclosed, .comment_unclosed, .pi_unclosed, .cdata_unclosed, .missing_end_quote => error.UnexpectedEof,
        else => error.InvalidSyntax,
    };
}

fn appendXmlContent(allocator: Allocator, destination: *std.ArrayList(u8), reader: *xml_parser.Reader, node: xml_parser.Reader.Node) !void {
    switch (node) {
        .text => try destination.appendSlice(allocator, try reader.text()),
        .cdata => try destination.appendSlice(allocator, try reader.cdata()),
        .entity_reference => {
            const name = reader.entityReferenceName();
            const value = xml_parser.predefined_entities.get(name) orelse return error.InvalidEntity;
            try destination.appendSlice(allocator, value);
        },
        .character_reference => {
            var encoded: [4]u8 = undefined;
            const length = try std.unicode.utf8Encode(reader.characterReferenceChar(), &encoded);
            try destination.appendSlice(allocator, encoded[0..length]);
        },
        else => {},
    }
}

fn parseExtensionXml(allocator: Allocator, xml: []const u8, file: *ExtensionFile) !void {
    var static_reader: xml_parser.Reader.Static = .init(allocator, xml, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const reader = &static_reader.interface;
    var id: std.ArrayList(u8) = .empty;
    var menu: std.ArrayList(u8) = .empty;
    var depth: i32 = 0;
    var extension_depth: i32 = -1;
    var id_depth: i32 = -1;
    var menu_depth: i32 = -1;
    var menu_is_json = false;
    while (true) {
        const node = reader.read() catch |err| switch (err) {
            error.MalformedXml => return zigXmlError(reader.errorCode()),
            error.ReadFailed => return error.InvalidSyntax,
            error.OutOfMemory => return err,
        };
        switch (node) {
            .element_start => {
                depth += 1;
                const elem = reader.elementName();
                if (extension_depth < 0 and std.mem.eql(u8, elem, "extension")) {
                    extension_depth = depth;
                    file.is_extension = true;
                } else if (extension_depth >= 0 and id_depth < 0 and file.id.len == 0 and std.mem.eql(u8, elem, "id")) {
                    id_depth = depth;
                    id.clearRetainingCapacity();
                } else if (extension_depth >= 0 and menu_depth < 0 and std.mem.eql(u8, elem, "menu")) {
                    menu_depth = depth;
                    menu_is_json = false;
                    menu.clearRetainingCapacity();
                    if (reader.attributeIndex("type")) |index| {
                        const value = try reader.attributeValue(index);
                        menu_is_json = std.mem.eql(u8, std.mem.trim(u8, value, " \t\r\n"), "json");
                    }
                }
            },
            .text, .cdata, .entity_reference, .character_reference => {
                if (depth == id_depth) try appendXmlContent(allocator, &id, reader, node);
                if (depth == menu_depth) try appendXmlContent(allocator, &menu, reader, node);
            },
            .element_end => {
                if (depth == id_depth) {
                    file.id = try allocator.dupe(u8, std.mem.trim(u8, id.items, " \t\r\n"));
                    id_depth = -1;
                }
                if (depth == menu_depth) {
                    const name = std.mem.trim(u8, menu.items, " \t\r\n");
                    if (menu_is_json and name.len > 0) try file.menus.append(allocator, try allocator.dupe(u8, name));
                    menu_depth = -1;
                    menu_is_json = false;
                }
                if (depth == extension_depth) extension_depth = -1;
                depth -= 1;
            },
            .eof => break,
            else => {},
        }
    }
}

fn parseInternal(entry: *Entry, submenu: bool) void {
    const raw = entry.internal orelse return;
    var kind: InternalKind = .none;
    var message: ?[]const u8 = null;
    if (std.mem.eql(u8, raw, "breadcrumb")) {
        kind = .breadcrumb;
        message = "";
    } else if (std.mem.startsWith(u8, raw, "breadcrumb ")) {
        kind = .breadcrumb;
        message = raw[11..];
    } else if (std.mem.eql(u8, raw, "status")) {
        kind = .status;
        message = "";
    } else if (std.mem.startsWith(u8, raw, "status ")) {
        kind = .status;
        message = raw[7..];
    }
    entry.internal_kind = if (submenu) .none else kind;
    entry.internal = if (submenu) null else message;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const actual = value orelse return null;
    return if (actual == .string) actual.string else null;
}

fn jsonBool(value: ?std.json.Value, fallback: bool) bool {
    const actual = value orelse return fallback;
    return switch (actual) {
        .bool => |v| v,
        .integer => |v| if (v == 1) true else if (v == 0) false else fallback,
        .string => |v| if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) true else if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) false else fallback,
        else => fallback,
    };
}

fn jsonInt(value: ?std.json.Value, fallback: i32) i32 {
    const actual = value orelse return fallback;
    return switch (actual) {
        .integer => |v| if (v >= std.math.minInt(i32) and v <= std.math.maxInt(i32)) @intCast(v) else fallback,
        .string => |v| std.fmt.parseInt(i32, v, 10) catch fallback,
        else => fallback,
    };
}

pub fn conditionEval(menu: *Menu, expr: ?[]const u8, working_dir: []const u8, error_out: *?[]const u8) !bool {
    error_out.* = null;
    const expression = expr orelse return true;
    if (expression.len == 0) return true;
    const allocator = menu.arenaAllocator();
    var stack: std.ArrayList([]const u8) = .empty;
    var cursor: usize = 0;
    while (try nextToken(allocator, expression, &cursor, error_out)) |token| {
        const unary = isUnary(token);
        const binary = isBinary(token);
        if (!unary and !binary) {
            if (stack.items.len == 64) {
                error_out.* = "condition stack overflow";
                return true;
            }
            try stack.append(allocator, token);
            continue;
        }
        if (unary) {
            if (stack.items.len < 1) {
                error_out.* = try std.fmt.allocPrint(allocator, "stack underflow at {s}", .{token});
                return true;
            }
            const x = stack.pop().?;
            var result = false;
            if (std.mem.eql(u8, token, "!")) result = !truth(x) else if (std.mem.eql(u8, token, "-ext")) {
                for (menu.extension_aliases.items) |alias| if (std.mem.eql(u8, alias, x)) {
                    result = true;
                    break;
                };
            } else if (std.mem.eql(u8, token, "-m")) result = std.mem.eql(u8, menu.model, x) else {
                const path = try conditionPath(allocator, working_dir, x);
                const stat = Io.Dir.cwd().statFile(menu.io, path, .{}) catch null;
                if (std.mem.eql(u8, token, "-e")) result = stat != null else if (std.mem.eql(u8, token, "-f")) result = stat != null and stat.?.kind == .file else result = stat != null and stat.?.kind == .file and stat.?.size > 0;
            }
            try stack.append(allocator, if (result) "1" else "0");
            continue;
        }
        if (stack.items.len < 2) {
            error_out.* = try std.fmt.allocPrint(allocator, "stack underflow at {s}", .{token});
            return true;
        }
        const x = stack.pop().?;
        const y = stack.pop().?;
        var result = false;
        if (std.mem.eql(u8, token, "&&")) result = truth(y) and truth(x) else if (std.mem.eql(u8, token, "||")) result = truth(y) or truth(x) else if (std.mem.eql(u8, token, "-o")) {
            result = if (menu.config.get(y)) |configured| std.mem.eql(u8, configured, x) else false;
        } else {
            const path = try conditionPath(allocator, working_dir, y);
            const invert = std.mem.indexOfScalar(u8, token, '!') != null;
            const matched = grepFile(menu, x, path, invert) catch |err| missing: {
                if (err == error.FileNotFound and std.mem.startsWith(u8, token, "-gg")) break :missing false;
                error_out.* = switch (err) {
                    error.InvalidRegex => try std.fmt.allocPrint(allocator, "invalid regular expression: {s}", .{x}),
                    else => try std.fmt.allocPrint(allocator, "condition file not found: {s}", .{path}),
                };
                return true;
            };
            result = matched;
        }
        try stack.append(allocator, if (result) "1" else "0");
    }
    if (error_out.* != null) return true;
    if (stack.items.len != 1) {
        error_out.* = try std.fmt.allocPrint(allocator, "condition leaves {d} values on stack", .{stack.items.len});
        return true;
    }
    return truth(stack.items[0]);
}

fn nextToken(allocator: Allocator, input: []const u8, cursor: *usize, error_out: *?[]const u8) !?[]const u8 {
    while (cursor.* < input.len and std.ascii.isWhitespace(input[cursor.*])) cursor.* += 1;
    if (cursor.* == input.len) return null;
    const operators = [_][]const u8{ "-ext", "-gg!", "-gg", "-g!", "-g", "-z!", "-e", "-f", "-m", "-o", "&&", "||", "!" };
    if (input[cursor.*] != '"') for (operators) |op| {
        if (std.mem.startsWith(u8, input[cursor.*..], op)) {
            cursor.* += op.len;
            return op;
        }
    };
    var output: std.ArrayList(u8) = .empty;
    if (input[cursor.*] == '"') {
        cursor.* += 1;
        while (cursor.* < input.len and input[cursor.*] != '"') {
            var byte = input[cursor.*];
            cursor.* += 1;
            if (byte == '\\' and cursor.* < input.len) {
                byte = input[cursor.*];
                cursor.* += 1;
                byte = switch (byte) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => byte,
                };
            }
            try output.append(allocator, byte);
        }
        if (cursor.* == input.len) {
            error_out.* = "unterminated quoted token";
            return null;
        }
        cursor.* += 1;
    } else {
        while (cursor.* < input.len and !std.ascii.isWhitespace(input[cursor.*])) : (cursor.* += 1) try output.append(allocator, input[cursor.*]);
    }
    return try output.toOwnedSlice(allocator);
}

fn isUnary(token: []const u8) bool {
    return std.mem.eql(u8, token, "!") or std.mem.eql(u8, token, "-e") or std.mem.eql(u8, token, "-f") or std.mem.eql(u8, token, "-z!") or std.mem.eql(u8, token, "-ext") or std.mem.eql(u8, token, "-m");
}
fn isBinary(token: []const u8) bool {
    return std.mem.eql(u8, token, "&&") or std.mem.eql(u8, token, "||") or std.mem.eql(u8, token, "-o") or std.mem.eql(u8, token, "-g") or std.mem.eql(u8, token, "-g!") or std.mem.eql(u8, token, "-gg") or std.mem.eql(u8, token, "-gg!");
}
fn truth(value: []const u8) bool {
    return value.len > 0 and !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false");
}
fn conditionPath(allocator: Allocator, cwd: []const u8, value: []const u8) ![]const u8 {
    return if (std.fs.path.isAbsolute(value)) allocator.dupe(u8, value) else join(allocator, cwd, value);
}

fn grepFile(menu: *Menu, pattern: []const u8, path: []const u8, invert: bool) !bool {
    const allocator = menu.arenaAllocator();
    var expression: posix_regex.Regex = .{};
    expression.compile(allocator, pattern) catch return error.InvalidRegex;
    defer expression.deinit();
    const data = Io.Dir.cwd().readFileAlloc(menu.io, path, allocator, .limited(4 * 1024 * 1024 + 1)) catch return error.FileNotFound;
    var lines = std.mem.splitScalar(u8, data, '\n');
    var found = false;
    while (lines.next()) |line| {
        if (try expression.matches(allocator, line)) {
            found = true;
            break;
        }
    }
    return if (invert) !found else found;
}

fn pruneEntries(menu: *Menu, parent: *Entry, errors: *Errors) !void {
    var output: usize = 0;
    for (parent.children.items) |*entry| {
        var condition_error: ?[]const u8 = null;
        const keep = !entry.hidden and try conditionEval(menu, entry.condition, entry.working_dir, &condition_error);
        if (condition_error) |message| try errors.add(entry.source, "condition for '{s}': {s}", .{ entry.name, message });
        if (!keep) continue;
        try pruneEntries(menu, entry, errors);
        parent.children.items[output] = entry.*;
        output += 1;
    }
    parent.children.items.len = output;
}

const SortMode = enum { alphabetic, priority };
var active_sort_mode: SortMode = .alphabetic;
fn sortEntries(parent: *Entry, mode: SortMode, recursive: bool) void {
    active_sort_mode = mode;
    std.sort.block(Entry, parent.children.items, {}, entryLessThan);
    if (recursive) for (parent.children.items) |*child| sortEntries(child, mode, true);
}
fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    const cmp: std.math.Order = if (active_sort_mode == .priority) std.math.order(a.priority, b.priority) else asciiOrderIgnoreCase(a.name, b.name);
    return if (cmp == .eq) a.order < b.order else cmp == .lt;
}

fn collateEntries(menu: *Menu, parent: *Entry) !void {
    var i: usize = 0;
    while (i < parent.children.items.len) : (i += 1) {
        var a = &parent.children.items[i];
        if (a.children.items.len == 0) continue;
        var j = i + 1;
        while (j < parent.children.items.len) {
            const b = &parent.children.items[j];
            if (b.children.items.len > 0 and std.mem.eql(u8, a.name, b.name)) {
                a.collated = true;
                try a.children.appendSlice(menu.arenaAllocator(), b.children.items);
                _ = parent.children.orderedRemove(j);
                a = &parent.children.items[i];
            } else j += 1;
        }
        try collateEntries(menu, a);
    }
}

pub fn builtinActionName(action: BuiltinAction) ?[]const u8 {
    return switch (action) {
        .sort_abc => "sort-ABC",
        .sort_123 => "sort-123",
        .save_log => "save-log",
        .quit => "quit",
        else => null,
    };
}

pub fn printMenu(menu: *const Menu, version: []const u8, writer: *Io.Writer) !void {
    try writer.print("KUAL Next {s}; model={s}; extensions={d}; entries={d}\n", .{ version, menu.model, menu.extension_id_count, menu.root.children.items.len });
    for (menu.root.children.items) |*entry| try printEntry(entry, writer, 0);
}
fn printEntry(entry: *const Entry, writer: *Io.Writer, depth: usize) !void {
    for (0..depth) |_| try writer.writeAll("  ");
    try writer.print("{s}{s}{s}", .{ if (entry.children.items.len > 0) "> " else "- ", entry.name, if (entry.collated) "+" else "" });
    if (entry.action) |action| try writer.print(" => {s}{s}{s}", .{ action, if (entry.params != null and entry.params.?.len > 0) " " else "", entry.params orelse "" }) else if (builtinActionName(entry.builtin_action)) |name| try writer.print(" => [internal:{s}]", .{name});
    try writer.writeByte('\n');
    for (entry.children.items) |*child| try printEntry(child, writer, depth + 1);
}

fn excludedPath(root: []const u8, path: []const u8, configured: ?[]const u8) bool {
    const list = if (configured == null or configured.?.len == 0) "system" else configured.?;
    var rel = path[root.len..];
    if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
    var parts = std.mem.splitScalar(u8, list, ';');
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t\r\n");
        if (part.len > 0 and std.mem.startsWith(u8, rel, part) and (rel.len == part.len or rel[part.len] == '/')) return true;
    }
    return false;
}
fn fileNonEmpty(io: Io, path: []const u8) bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file and stat.size > 0;
}
fn join(allocator: Allocator, a: []const u8, b: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(b)) return allocator.dupe(u8, b);
    return std.fs.path.join(allocator, &.{ a, b });
}
fn dirname(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}
fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return asciiOrderIgnoreCase(a, b) == .eq;
}
fn asciiOrderIgnoreCase(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx < ly) return .lt;
        if (lx > ly) return .gt;
    }
    return std.math.order(a.len, b.len);
}

test "JSON compatibility helpers accept KUAL string booleans" {
    try std.testing.expect(jsonBool(.{ .string = "1" }, false));
    try std.testing.expect(!jsonBool(.{ .string = "false" }, true));
    try std.testing.expectEqual(@as(i32, 7), jsonInt(.{ .string = "7" }, 0));
}

test "power event unlock semantics" {
    try std.testing.expect(powerEventIsUnlock("exitingScreenSaver", true));
    try std.testing.expect(!powerEventIsUnlock("outOfScreenSaver", true));
    try std.testing.expect(!powerEventIsUnlock("exitingScreenSaver", false));
}

test "directory identity includes the containing device" {
    const first: DirectoryKey = .{ .device_major = 1, .device_minor = 2, .inode = 42 };
    const same: DirectoryKey = .{ .device_major = 1, .device_minor = 2, .inode = 42 };
    const other_device: DirectoryKey = .{ .device_major = 1, .device_minor = 3, .inode = 42 };
    try std.testing.expect(std.meta.eql(first, same));
    try std.testing.expect(!std.meta.eql(first, other_device));
}

test "conditions preserve KUAL grep error semantics" {
    const allocator = std.testing.allocator;
    var menu = try Menu.init(allocator, std.testing.io, ".", "Unknown");
    defer menu.deinit();
    var condition_error: ?[]const u8 = null;
    try std.testing.expect(!try conditionEval(&menu, "\"definitely-missing\" \"pattern\" -gg", ".", &condition_error));
    try std.testing.expect(condition_error == null);
    try std.testing.expect(try conditionEval(&menu, "\"definitely-missing\" \"pattern\" -g", ".", &condition_error));
    try std.testing.expect(condition_error != null);
    try std.testing.expect(try conditionEval(&menu, "\"/dev/null\" \"[\" -g", ".", &condition_error));
    try std.testing.expect(condition_error != null and std.mem.startsWith(u8, condition_error.?, "invalid regular expression"));
}

test "sort mode update and log archival use Zig filesystem APIs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const config_path = try std.fs.path.join(allocator, &.{ root, "KUAL.cfg" });
    defer allocator.free(config_path);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = config_path,
        .data = "# preserved\n  KUAL_sort_mode = \"ABC!\"\n",
        .flags = .{ .permissions = .fromMode(0o600) },
    });
    try setSortMode(allocator, io, root, "123");
    const updated = try Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(4096));
    defer allocator.free(updated);
    try std.testing.expectEqualStrings("# preserved\nKUAL_sort_mode=\"123\"\n", updated);
    const updated_stat = try Io.Dir.cwd().statFile(io, config_path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), updated_stat.permissions.toMode() & 0o777);

    const documents = try std.fs.path.join(allocator, &.{ root, "documents" });
    defer allocator.free(documents);
    try Io.Dir.cwd().createDir(io, documents, .default_dir);
    const source = try std.fs.path.join(allocator, &.{ root, "kual-next.log" });
    defer allocator.free(source);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = "log entry\n", .flags = .{ .permissions = .fromMode(0o600) } });
    const archived = try archiveLog(allocator, io, source, documents, 0);
    defer allocator.free(archived);
    try std.testing.expectEqualStrings("KUAL-1970-01-01T00.00+00.00.txt", std.fs.path.basename(archived));
    const archived_text = try Io.Dir.cwd().readFileAlloc(io, archived, allocator, .limited(4096));
    defer allocator.free(archived_text);
    try std.testing.expectEqualStrings("log entry\n", archived_text);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, source, .{}));

    const recovery_source = try std.fs.path.join(allocator, &.{ root, "recovery.log" });
    defer allocator.free(recovery_source);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = recovery_source, .data = "keep me\n" });
    const missing_documents = try std.fs.path.join(allocator, &.{ root, "missing", "documents" });
    defer allocator.free(missing_documents);
    try std.testing.expectError(error.FileNotFound, archiveLog(allocator, io, recovery_source, missing_documents, 0));
    const recovery_text = try Io.Dir.cwd().readFileAlloc(io, recovery_source, allocator, .limited(4096));
    defer allocator.free(recovery_text);
    try std.testing.expectEqualStrings("keep me\n", recovery_text);
}

pub fn powerEventIsUnlock(event: []const u8, screen_saver_active: bool) bool {
    return screen_saver_active and std.mem.startsWith(u8, event, "exitingScreenSaver");
}

pub fn privilegeIndicator(is_root: bool) []const u8 {
    return if (is_root) "#" else "%";
}

fn openAppendFile(path: []const u8) !Io.File {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    }, 0o644);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

pub fn log(io: Io, allocator: Allocator, comptime fmt: []const u8, args: anytype) void {
    const message = std.fmt.allocPrint(allocator, fmt ++ "\n", args) catch return;
    defer allocator.free(message);
    var file = openAppendFile(default_log) catch {
        Io.File.stderr().writeStreamingAll(io, message) catch {};
        return;
    };
    defer file.close(io);
    file.writeStreamingAll(io, message) catch
        Io.File.stderr().writeStreamingAll(io, message) catch {};
}

test "append files do not overwrite writes from another descriptor" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "append.log" });
    defer allocator.free(path);

    var first = try openAppendFile(path);
    defer first.close(io);
    var second = try openAppendFile(path);
    defer second.close(io);
    try first.writeStreamingAll(io, "first\n");
    try second.writeStreamingAll(io, "second\n");
    try first.writeStreamingAll(io, "third\n");

    const contents = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024));
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("first\nsecond\nthird\n", contents);
}

pub fn setSortMode(allocator: Allocator, io: Io, extensions_dir: []const u8, mode: []const u8) !void {
    if (!std.mem.eql(u8, mode, "ABC") and !std.mem.eql(u8, mode, "123")) return error.InvalidMode;
    const path = try join(allocator, extensions_dir, "KUAL.cfg");
    defer allocator.free(path);
    const cwd = Io.Dir.cwd();
    const existing_stat = cwd.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const exists = existing_stat != null;
    const input = if (exists)
        try cwd.readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024 + 1))
    else
        "";
    defer if (exists) allocator.free(input);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const assignment = try std.fmt.allocPrint(allocator, "KUAL_sort_mode=\"{s}\"\n", .{mode});
    defer allocator.free(assignment);
    var found = false;
    var cursor: usize = 0;
    while (cursor < input.len) {
        const newline = std.mem.indexOfScalarPos(u8, input, cursor, '\n');
        const end = if (newline) |index| index + 1 else input.len;
        const line = input[cursor..end];
        const trimmed = std.mem.trimStart(u8, line, " \t\r");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=');
        if (eq != null and std.mem.eql(u8, std.mem.trimEnd(u8, trimmed[0..eq.?], " \t\r"), "KUAL_sort_mode")) {
            try output.appendSlice(allocator, assignment);
            found = true;
        } else try output.appendSlice(allocator, line);
        cursor = end;
    }
    if (!found) {
        if (!exists) {
            const now = realSeconds(io);
            const date = try formatUtc(allocator, now, .config);
            defer allocator.free(date);
            try output.appendSlice(allocator, "# KUAL.cfg - created by KUAL Next on ");
            try output.appendSlice(allocator, date);
            try output.append(allocator, '\n');
        } else if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') try output.append(allocator, '\n');
        try output.appendSlice(allocator, assignment);
    }
    const permissions: Io.File.Permissions = if (existing_stat) |stat| stat.permissions else .fromMode(0o644);
    var atomic = try cwd.createFileAtomic(io, path, .{ .permissions = permissions, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, output.items);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

pub fn archiveLog(allocator: Allocator, io: Io, source: []const u8, documents_dir: []const u8, when: u64) ![]const u8 {
    const filename = try formatUtc(allocator, when, .archive);
    defer allocator.free(filename);
    const destination = try join(allocator, documents_dir, filename);
    errdefer allocator.free(destination);
    const cwd = Io.Dir.cwd();
    var source_file = try cwd.openFile(io, source, .{});
    defer source_file.close(io);
    const source_stat = try source_file.stat(io);
    var atomic = try cwd.createFileAtomic(io, destination, .{
        .permissions = source_stat.permissions,
        .replace = true,
    });
    defer atomic.deinit(io);
    var source_buffer: [16384]u8 = undefined;
    var source_reader = source_file.reader(io, &source_buffer);
    var destination_buffer: [16384]u8 = undefined;
    var destination_writer = atomic.file.writer(io, &destination_buffer);
    _ = try destination_writer.interface.sendFileAll(&source_reader, .unlimited);
    try destination_writer.interface.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);
    try cwd.deleteFile(io, source);
    return destination;
}

const DateFormat = enum { config, archive };

fn realSeconds(io: Io) u64 {
    const nanoseconds = Io.Clock.real.now(io).nanoseconds;
    return @intCast(@max(0, @divFloor(nanoseconds, std.time.ns_per_s)));
}

fn formatUtc(allocator: Allocator, seconds: u64, format: DateFormat) ![]const u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return switch (format) {
        .config => std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} +0000", .{
            year_day.year,
            @intFromEnum(month_day.month),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        }),
        .archive => std.fmt.allocPrint(allocator, "KUAL-{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}.{d:0>2}+00.00.txt", .{
            year_day.year,
            @intFromEnum(month_day.month),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
        }),
    };
}
