const std = @import("std");
const Io = std.Io;

fn readU16(bytes: []const u8, offset: usize) !u16 {
    if (offset + 2 > bytes.len) return error.TruncatedElf;
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) !u32 {
    if (offset + 4 > bytes.len) return error.TruncatedElf;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

pub fn verify(bytes: []const u8) !void {
    if (bytes.len < 52 or !std.mem.eql(u8, bytes[0..4], "\x7fELF")) return error.NotElf;
    if (bytes[4] != 1) return error.NotElf32;
    if (bytes[5] != 1) return error.NotLittleEndian;
    if (try readU16(bytes, 18) != 40) return error.NotArm;
    if (try readU32(bytes, 20) != 1) return error.BadElfVersion;
    const flags = try readU32(bytes, 36);
    if (flags & 0xff000000 != 0x05000000) return error.NotEabi5;
    if (flags & 0x00000400 == 0) return error.NotHardFloat;

    const program_offset = try readU32(bytes, 28);
    const entry_size = try readU16(bytes, 42);
    const entry_count = try readU16(bytes, 44);
    var dynamic_offset: ?usize = null;
    var dynamic_size: usize = 0;
    for (0..entry_count) |index| {
        const offset = @as(usize, program_offset) + index * entry_size;
        const kind = try readU32(bytes, offset);
        if (kind == 3) return error.HasInterpreter;
        if (kind == 2) {
            dynamic_offset = try readU32(bytes, offset + 4);
            dynamic_size = try readU32(bytes, offset + 16);
        }
    }
    if (dynamic_offset) |offset| {
        var cursor = offset;
        const end = @min(bytes.len, offset + dynamic_size);
        while (cursor + 8 <= end) : (cursor += 8) {
            const tag = try readU32(bytes, cursor);
            if (tag == 0) break;
            if (tag == 1) return error.HasNeededLibrary;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) {
        std.debug.print("Usage: verify-elf PATH\n", .{});
        std.process.exit(2);
    }
    const bytes = try Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .unlimited);
    verify(bytes) catch |err| {
        std.debug.print("{s}: ELF verification failed: {s}\n", .{ args[1], @errorName(err) });
        std.process.exit(1);
    };
}

test "rejects non-ELF input" {
    try std.testing.expectError(error.NotElf, verify("not an ELF"));
}
