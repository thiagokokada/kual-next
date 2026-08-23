const std = @import("std");

// Zig 0.16 has no standard-library regex engine. KUAL conditions use POSIX
// extended regular expressions, so keep this ABI boundary confined here and
// use the regex implementation supplied by the target libc (musl on Kindle).
extern "c" fn regcomp(regex: *anyopaque, pattern: [*:0]const u8, flags: c_int) c_int;
extern "c" fn regexec(regex: *const anyopaque, text: [*:0]const u8, count: usize, matches: ?*anyopaque, flags: c_int) c_int;
extern "c" fn regfree(regex: *anyopaque) void;

const extended = 1;
const no_subexpressions = 8;
const regex_storage_bytes = 256;

pub const Regex = struct {
    // regex_t is opaque across libc implementations. This aligned buffer keeps
    // the ABI boundary isolated and exceeds its size in glibc and musl.
    storage: [regex_storage_bytes]u8 align(@alignOf(usize)) = undefined,
    compiled: bool = false,

    pub fn compile(self: *Regex, allocator: std.mem.Allocator, pattern: []const u8) !void {
        const pattern_z = try allocator.dupeZ(u8, pattern);
        defer allocator.free(pattern_z);
        if (regcomp(&self.storage, pattern_z.ptr, extended | no_subexpressions) != 0)
            return error.InvalidRegex;
        self.compiled = true;
    }

    pub fn deinit(self: *Regex) void {
        if (self.compiled) regfree(&self.storage);
        self.compiled = false;
    }

    pub fn matches(self: *const Regex, allocator: std.mem.Allocator, text: []const u8) !bool {
        const text_z = try allocator.dupeZ(u8, text);
        defer allocator.free(text_z);
        return regexec(&self.storage, text_z.ptr, 0, null, 0) == 0;
    }
};

test "POSIX extended expression" {
    var expression: Regex = .{};
    try expression.compile(std.testing.allocator, "^(alpha|beta)$");
    defer expression.deinit();
    try std.testing.expect(try expression.matches(std.testing.allocator, "alpha"));
    try std.testing.expect(!try expression.matches(std.testing.allocator, "gamma"));
}
