const std = @import("std");
const client_mod = @import("../client.zig");
const monitor_mod = @import("../monitor.zig");
const xlib = @import("../x11/xlib.zig");
const tiling = @import("tiling.zig");

const Client = client_mod.Client;
const Monitor = monitor_mod.Monitor;

pub const layout = monitor_mod.Layout{
    .symbol = "[S]",
    .arrange_fn = scroll,
};

pub fn scroll(monitor: *Monitor) void {
    var client_count: u32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |_| : (current = client_mod.nextTiled(current.?.next)) {
        client_count += 1;
    }

    if (client_count == 0) return;

    const gap_outer_h = if (monitor.smartgaps_enabled and client_count == 1) 0 else monitor.gap_outer_h;
    const gap_outer_v = if (monitor.smartgaps_enabled and client_count == 1) 0 else monitor.gap_outer_v;
    const gap_inner_v = monitor.gap_inner_v;

    const visible_count: u32 = @intCast(@max(1, monitor.nmaster));
    const available_width = monitor.win_w - 2 * gap_outer_v;
    const available_height = monitor.win_h - 2 * gap_outer_h;

    const total_gaps = gap_inner_v * @as(i32, @intCast(if (visible_count > 1) visible_count - 1 else 0));
    const window_width = @divTrunc(available_width - total_gaps, @as(i32, @intCast(visible_count)));

    var x_pos: i32 = monitor.win_x + gap_outer_v - monitor.scroll_offset;
    const y_pos: i32 = monitor.win_y + gap_outer_h;
    const height = available_height;

    var index: u32 = 0;
    current = client_mod.nextTiled(monitor.clients);
    while (current) |client| : (current = client_mod.nextTiled(client.next)) {
        const window_right = x_pos + window_width;
        const screen_left = monitor.win_x;
        const screen_right = monitor.win_x + monitor.win_w;
        const is_visible = window_right > screen_left and x_pos < screen_right;

        if (is_visible) {
            tiling.resize(
                client,
                x_pos,
                y_pos,
                window_width - 2 * client.border_width,
                height - 2 * client.border_width,
                false,
            );
        } else {
            tiling.resizeClient(
                client,
                -2 * window_width,
                y_pos,
                window_width - 2 * client.border_width,
                height - 2 * client.border_width,
            );
        }
        x_pos += window_width + gap_inner_v;
        index += 1;
    }
}

pub fn getScrollStep(monitor: *Monitor) i32 {
    var client_count: u32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |_| : (current = client_mod.nextTiled(current.?.next)) {
        client_count += 1;
    }

    const gap_outer_v = if (monitor.smartgaps_enabled and client_count == 1) 0 else monitor.gap_outer_v;
    const gap_inner_v = monitor.gap_inner_v;
    const visible_count: u32 = @intCast(@max(1, monitor.nmaster));
    const available_width = monitor.win_w - 2 * gap_outer_v;
    const total_gaps = gap_inner_v * @as(i32, @intCast(if (visible_count > 1) visible_count - 1 else 0));
    const window_width = @divTrunc(available_width - total_gaps, @as(i32, @intCast(visible_count)));
    return window_width + gap_inner_v;
}

pub fn getMaxScroll(monitor: *Monitor) i32 {
    var client_count: u32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |_| : (current = client_mod.nextTiled(current.?.next)) {
        client_count += 1;
    }

    const visible_count: u32 = @intCast(@max(1, monitor.nmaster));
    if (client_count <= visible_count) return 0;

    const scroll_step = getScrollStep(monitor);
    const scrollable = client_count - visible_count;
    return scroll_step * @as(i32, @intCast(scrollable));
}

pub fn getWindowIndex(monitor: *Monitor, target: *Client) ?u32 {
    var index: u32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |client| : (current = client_mod.nextTiled(client.next)) {
        if (client == target) return index;
        index += 1;
    }
    return null;
}

pub fn getTargetScrollForWindow(monitor: *Monitor, target: *Client) i32 {
    const index = getWindowIndex(monitor, target) orelse return 0;
    if (index == 0) return 0;

    const scroll_step = getScrollStep(monitor);
    const max_scroll = getMaxScroll(monitor);

    const target_scroll = scroll_step * @as(i32, @intCast(index));
    return @min(target_scroll, max_scroll);
}
