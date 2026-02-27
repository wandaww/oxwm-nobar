const std = @import("std");
const client_mod = @import("../client.zig");
const monitor_mod = @import("../monitor.zig");
const tiling = @import("tiling.zig");

const Client = client_mod.Client;
const Monitor = monitor_mod.Monitor;

pub const layout = monitor_mod.Layout{
    .symbol = "[#]",
    .arrange_fn = grid,
};

pub fn grid(monitor: *Monitor) void {
    var client_count: u32 = 0;
    var current = client_mod.nextTiled(monitor.clients);
    while (current) |_| : (current = client_mod.nextTiled(current.?.next)) {
        client_count += 1;
    }

    if (client_count == 0) return;

    const gap_outer_h = if (monitor.smartgaps_enabled and client_count == 1) 0 else monitor.gap_outer_h;
    const gap_outer_v = if (monitor.smartgaps_enabled and client_count == 1) 0 else monitor.gap_outer_v;
    const gap_inner_h = monitor.gap_inner_h;
    const gap_inner_v = monitor.gap_inner_v;

    if (client_count == 1) {
        const client = client_mod.nextTiled(monitor.clients).?;
        tiling.resize(
            client,
            monitor.win_x + gap_outer_v,
            monitor.win_y + gap_outer_h,
            monitor.win_w - 2 * gap_outer_v - 2 * client.border_width,
            monitor.win_h - 2 * gap_outer_h - 2 * client.border_width,
            false,
        );
        return;
    }

    const cols: u32 = @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(client_count)))));
    const rows: u32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(client_count)) / @as(f64, @floatFromInt(cols))));

    const total_horizontal_gaps = 2 * gap_outer_v + gap_inner_v * @as(i32, @intCast(cols - 1));
    const total_vertical_gaps = 2 * gap_outer_h + gap_inner_h * @as(i32, @intCast(rows - 1));

    const available_width = monitor.win_w - total_horizontal_gaps;
    const available_height = monitor.win_h - total_vertical_gaps;
    const cell_width: i32 = @divTrunc(available_width, @as(i32, @intCast(cols)));
    const cell_height: i32 = @divTrunc(available_height, @as(i32, @intCast(rows)));

    var index: u32 = 0;
    current = client_mod.nextTiled(monitor.clients);
    while (current) |client| : (current = client_mod.nextTiled(client.next)) {
        const row = index / cols;
        const col = index % cols;

        const is_last_row = row == rows - 1;
        const windows_in_last_row = client_count - (rows - 1) * cols;

        var x: i32 = undefined;
        var y: i32 = undefined;
        var width: i32 = undefined;
        var height: i32 = undefined;

        if (is_last_row and windows_in_last_row < cols) {
            const last_row_col = index % cols;
            const last_row_gaps = 2 * gap_outer_v + gap_inner_v * @as(i32, @intCast(windows_in_last_row - 1));
            const last_row_available = monitor.win_w - last_row_gaps;
            const last_row_cell_width = @divTrunc(last_row_available, @as(i32, @intCast(windows_in_last_row)));

            x = monitor.win_x + gap_outer_v + @as(i32, @intCast(last_row_col)) * (last_row_cell_width + gap_inner_v);
            y = monitor.win_y + gap_outer_h + @as(i32, @intCast(row)) * (cell_height + gap_inner_h);
            width = last_row_cell_width - 2 * client.border_width;
            height = cell_height - 2 * client.border_width;
        } else {
            x = monitor.win_x + gap_outer_v + @as(i32, @intCast(col)) * (cell_width + gap_inner_v);
            y = monitor.win_y + gap_outer_h + @as(i32, @intCast(row)) * (cell_height + gap_inner_h);
            width = cell_width - 2 * client.border_width;
            height = cell_height - 2 * client.border_width;
        }

        tiling.resize(client, x, y, width, height, false);
        index += 1;
    }
}
