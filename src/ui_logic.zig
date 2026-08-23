const std = @import("std");

pub const page_rows = 10;

pub const Layout = struct {
    top_height: u32,
    status_height: u32,
    side_width: u32,
    gap: u32,
    chrome_text_size: u32,
    list_y: u32,
    list_height: u32,
    button_x: u32,
    button_width: u32,
    button_height: u32,
};

pub fn calculateLayout(width: u32, height: u32) Layout {
    const gap = @max(4, width / 190);
    const top_height = @max(28, height / 25);
    const status_height = @max(28, height / 25);
    const list_y = top_height;
    const available_height = height - top_height - status_height;
    const side_width = width * 13 / 100;
    const button_x = gap / 2 + side_width + gap;
    const button_height = (available_height - (page_rows - 1) * gap) / page_rows;
    return .{
        .top_height = top_height,
        .status_height = status_height,
        .side_width = side_width,
        .gap = gap,
        .chrome_text_size = @min(width / 36, @min(top_height, status_height) * 3 / 4),
        .list_y = list_y,
        .list_height = page_rows * button_height + (page_rows - 1) * gap,
        .button_x = button_x,
        .button_width = width - 2 * button_x,
        .button_height = button_height,
    };
}

pub const Hit = union(enum) {
    none,
    close,
    back,
    top,
    next,
    entry: usize,
};

pub fn mapTap(layout: Layout, depth: usize, page: usize, child_count: usize, x: i32, y: i32) Hit {
    if (y < layout.list_y or y >= layout.list_y + layout.list_height) return .none;
    if (x < layout.button_x) return if (depth > 0) .back else .none;
    if (x >= layout.button_x + layout.button_width) return .next;
    const row: usize = @intCast(@divFloor(y - @as(i32, @intCast(layout.list_y)), @as(i32, @intCast(layout.button_height + layout.gap))));
    const row_y = layout.list_y + @as(u32, @intCast(row)) * (layout.button_height + layout.gap);
    if (row >= page_rows or y >= row_y + layout.button_height) return .none;
    const index = page * page_rows + row;
    if (index < child_count) return .{ .entry = index };
    const pages = (child_count + 1 + page_rows - 1) / page_rows;
    if (page + 1 == pages and row == page_rows - 1) return if (depth > 0) .top else .close;
    return .none;
}

test "layout and tap mapping share geometry" {
    const layout = calculateLayout(1072, 1448);
    try std.testing.expectEqual(layout.list_height, layout.button_height * page_rows + layout.gap * (page_rows - 1));
    const first_y: i32 = @intCast(layout.list_y + layout.button_height / 2);
    const center_x: i32 = @intCast(layout.button_x + layout.button_width / 2);
    try std.testing.expectEqual(Hit{ .entry = 0 }, mapTap(layout, 0, 0, 10, center_x, first_y));
    try std.testing.expectEqual(Hit.back, mapTap(layout, 1, 0, 10, 0, first_y));
    try std.testing.expectEqual(Hit.next, mapTap(layout, 0, 0, 11, @intCast(layout.button_x + layout.button_width), first_y));
    const last_y: i32 = @intCast(layout.list_y + 9 * (layout.button_height + layout.gap) + layout.button_height / 2);
    try std.testing.expectEqual(Hit.close, mapTap(layout, 0, 0, 0, center_x, last_y));
    try std.testing.expectEqual(Hit.top, mapTap(layout, 1, 0, 0, center_x, last_y));
    try std.testing.expectEqual(Hit.none, mapTap(layout, 0, 0, 0, center_x, @intCast(layout.list_y + layout.button_height + layout.gap - 1)));
}
