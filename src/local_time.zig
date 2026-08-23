const std = @import("std");

const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("stdlib.h");
    @cInclude("time.h");
});

pub fn formatDisplayDate(allocator: std.mem.Allocator, when: u64) ![]u8 {
    const timestamp = std.math.cast(c.time_t, when) orelse return error.TimestampOutOfRange;
    var local: c.struct_tm = undefined;
    if (c.localtime_r(&timestamp, &local) == null) return error.LocalTimeFailed;
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u16, @intCast(local.tm_year + 1900)),
        @as(u8, @intCast(local.tm_mon + 1)),
        @as(u8, @intCast(local.tm_mday)),
        @as(u8, @intCast(local.tm_hour)),
        @as(u8, @intCast(local.tm_min)),
        @as(u8, @intCast(local.tm_sec)),
    });
}

test "display dates use the process timezone" {
    const allocator = std.testing.allocator;
    const previous = if (c.getenv("TZ")) |value| try allocator.dupeZ(u8, std.mem.span(value)) else null;
    defer {
        if (previous) |value| {
            _ = c.setenv("TZ", value.ptr, 1);
            allocator.free(value);
        } else {
            _ = c.unsetenv("TZ");
        }
        c.tzset();
    }

    try std.testing.expectEqual(@as(c_int, 0), c.setenv("TZ", "EST5", 1));
    c.tzset();
    const formatted = try formatDisplayDate(allocator, 0);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("1969-12-31 19:00:00", formatted);
}
