const std = @import("std");
const client_mod = @import("../client.zig");
const monitor_mod = @import("../monitor.zig");
const xlib = @import("../x11/xlib.zig");
const tiling = @import("tiling.zig");

const Client = client_mod.Client;
const Monitor = monitor_mod.Monitor;

pub const layout = monitor_mod.Layout{
    .symbol = "[M]",
    .arrange_fn = monocle,
};

pub fn monocle(monitor: *Monitor) void {
    var client_count: u32 = 0;
    var count_current = client_mod.nextTiled(monitor.clients);
    while (count_current) |_| : (count_current = client_mod.nextTiled(count_current.?.next)) {
        client_count += 1;
    }

    const gap_h = if (monitor.smartgaps_enabled and client_count == 1) 0 else monitor.gap_outer_h;
    const gap_v = if (monitor.smartgaps_enabled and client_count == 1) 0 else monitor.gap_outer_v;

    var current = client_mod.nextTiled(monitor.clients);
    while (current) |client| {
        tiling.resize(
            client,
            monitor.win_x + gap_v,
            monitor.win_y + gap_h,
            monitor.win_w - 2 * gap_v - 2 * client.border_width,
            monitor.win_h - 2 * gap_h - 2 * client.border_width,
            false,
        );
        current = client_mod.nextTiled(client.next);
    }
}
