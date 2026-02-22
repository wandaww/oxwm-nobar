const std = @import("std");
const VERSION = "v0.11.2";
const wm_mod = @import("wm.zig");
const display_mod = @import("x11/display.zig");
const events = @import("x11/events.zig");
const xlib = @import("x11/xlib.zig");
const client_mod = @import("client.zig");
const monitor_mod = @import("monitor.zig");
const tiling = @import("layouts/tiling.zig");
const scrolling = @import("layouts/scrolling.zig");
const bar_mod = @import("bar/bar.zig");
const config_mod = @import("config/config.zig");
const lua = @import("config/lua.zig");

const Client = client_mod.Client;
const Monitor = monitor_mod.Monitor;
const WindowManager = wm_mod.WindowManager;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const NormalState: c_long = 1;
const WithdrawnState: c_long = 0;
const IconicState: c_long = 3;
const IsViewable: c_int = 2;
const snap_distance: i32 = 32;

/// File descriptor of the X11 connection, used in spawn_child_setup.
/// Set from `wm.x11_fd` after init.
var x11_fd: c_int = -1;

fn print_help() void {
    std.debug.print(
        \\oxwm - A window manager
        \\
        \\USAGE:
        \\    oxwm [OPTIONS]
        \\
        \\OPTIONS:
        \\    --init              Create default config in ~/.config/oxwm/config.lua
        \\    --config <PATH>     Use custom config file
        \\    --validate          Validate config file without starting window manager
        \\    --version           Print version information
        \\    --help              Print this help message
        \\
        \\CONFIG:
        \\    Location: ~/.config/oxwm/config.lua
        \\    Edit the config file and use Mod+Shift+R to reload
        \\    No compilation needed - instant hot-reload!
        \\
        \\FIRST RUN:
        \\    Run 'oxwm --init' to create a config file
        \\    Or just start oxwm and it will create one automatically
        \\
    , .{});
}

fn get_config_path(allocator: std.mem.Allocator) ![]u8 {
    const config_home = std.posix.getenv("XDG_CONFIG_HOME") orelse blk: {
        const home = std.posix.getenv("HOME") orelse return error.CouldNotGetHomeDir;
        break :blk try std.fs.path.join(allocator, &.{ home, ".config" });
    };
    // TODO: wtf is this shit
    defer if (std.posix.getenv("XDG_CONFIG_HOME") == null) allocator.free(config_home);

    const config_path = try std.fs.path.join(allocator, &.{ config_home, "oxwm", "config.lua" });
    return config_path;
}

fn init_config(allocator: std.mem.Allocator) void {
    const config_path = get_config_path(allocator) catch return;
    defer allocator.free(config_path);

    const template = @embedFile("templates/config.lua");

    if (std.fs.path.dirname(config_path)) |dir_path| {
        var root = std.fs.openDirAbsolute("/", .{}) catch |err| {
            std.debug.print("error: could not open root directory: {}\n", .{err});
            return;
        };
        defer root.close();

        const relative_path = std.mem.trimLeft(u8, dir_path, "/");
        root.makePath(relative_path) catch |err| {
            std.debug.print("error: could not create config directory: {}\n", .{err});
            return;
        };
    }

    const file = std.fs.createFileAbsolute(config_path, .{}) catch |err| {
        std.debug.print("error: could not create config file: {}\n", .{err});
        return;
    };
    defer file.close();

    _ = file.writeAll(template) catch |err| {
        std.debug.print("error: could not write config file: {}\n", .{err});
        return;
    };

    std.debug.print("Config created at {s}\n", .{config_path});
    std.debug.print("Edit the file and reload with Mod+Shift+R\n", .{});
    std.debug.print("No compilation needed - changes take effect immediately!\n", .{});
}

fn validate_config(allocator: std.mem.Allocator, config_path: []const u8) !void {
    var config = config_mod.Config.init(allocator);
    defer config.deinit();

    if (!lua.init(&config)) {
        std.debug.print("error: failed to initialize lua\n", .{});
        std.process.exit(1);
    }
    defer lua.deinit();

    _ = std.fs.cwd().statFile(config_path) catch |err| {
        std.debug.print("error: config file not found: {s}\n", .{config_path});
        std.debug.print("  {}\n", .{err});
        std.process.exit(1);
    };

    if (lua.load_file(config_path)) {
        std.debug.print("✓ config valid: {s}\n", .{config_path});
        std.process.exit(0);
    } else {
        std.debug.print("✗ config validation failed\n", .{});
        std.process.exit(1);
    }
}

pub fn main() !void {
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const default_config_path = try get_config_path(allocator);
    defer allocator.free(default_config_path);

    var config_path: []const u8 = default_config_path;
    var validate_mode: bool = false;
    var args = std.process.args();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            if (args.next()) |path| config_path = path;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            print_help();
            return;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            std.debug.print("{s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "--init")) {
            init_config(allocator);
            return;
        } else if (std.mem.eql(u8, arg, "--validate")) {
            validate_mode = true;
        }
    }

    if (validate_mode) {
        try validate_config(allocator, config_path);
        return;
    }

    std.debug.print("oxwm starting\n", .{});

    var config = config_mod.Config.init(allocator);
    var config_path_global: ?[]const u8 = null;

    if (lua.init(&config)) {
        const loaded = if (std.fs.cwd().statFile(config_path)) |_|
            lua.load_file(config_path)
        else |_| blk: {
            init_config(allocator);
            break :blk lua.load_config();
        };

        if (loaded) {
            config_path_global = config_path;
            std.debug.print("loaded config from {s}\n", .{config_path});
        } else {
            std.debug.print("no config found, using defaults\n", .{});
            initialize_default_config(&config);
        }
    } else {
        std.debug.print("failed to init lua, using defaults\n", .{});
        initialize_default_config(&config);
    }

    var wm = WindowManager.init(allocator, config, config_path_global) catch |err| {
        std.debug.print("failed to start window manager: {}\n", .{err});
        return;
    };
    defer wm.deinit();

    // x11_fd is read by spawn_child_setup() which runs in a forked child
    // and cannot access wm directly.
    x11_fd = wm.x11_fd;

    std.debug.print("display opened: screen={d} root=0x{x}\n", .{ wm.display.screen, wm.display.root });
    std.debug.print("successfully became window manager\n", .{});
    std.debug.print("atoms initialized with EWMH support\n", .{});

    wm.grab_keybinds();
    scan_existing_windows(&wm);

    try run_autostart_commands(allocator, wm.config.autostart.items);
    std.debug.print("entering event loop\n", .{});
    run_event_loop(&wm);

    lua.deinit();
    std.debug.print("oxwm exiting\n", .{});
}

fn make_keybind(mod: u32, key: u64, action: config_mod.Action) config_mod.Keybind {
    var kb: config_mod.Keybind = .{ .action = action };
    kb.keys[0] = .{ .mod_mask = mod, .keysym = key };
    kb.key_count = 1;
    return kb;
}

fn make_keybind_int(mod: u32, key: u64, action: config_mod.Action, int_arg: i32) config_mod.Keybind {
    var kb = make_keybind(mod, key, action);
    kb.int_arg = int_arg;
    return kb;
}

fn make_keybind_str(mod: u32, key: u64, action: config_mod.Action, str_arg: []const u8) config_mod.Keybind {
    var kb = make_keybind(mod, key, action);
    kb.str_arg = str_arg;
    return kb;
}

fn initialize_default_config(cfg: *config_mod.Config) void {
    const mod_key: u32 = 1 << 6;
    const shift_key: u32 = 1 << 0;
    const control_key: u32 = 1 << 2;

    cfg.add_keybind(make_keybind(mod_key, 0xff0d, .spawn_terminal)) catch {};
    cfg.add_keybind(make_keybind_str(mod_key, 'd', .spawn, "rofi -show drun")) catch {};
    cfg.add_keybind(make_keybind_str(mod_key, 's', .spawn, "maim -s | xclip -selection clipboard -t image/png")) catch {};
    cfg.add_keybind(make_keybind(mod_key, 'q', .kill_client)) catch {};
    cfg.add_keybind(make_keybind(mod_key | shift_key, 'q', .quit)) catch {};
    cfg.add_keybind(make_keybind(mod_key | shift_key, 'r', .reload_config)) catch {};
    cfg.add_keybind(make_keybind(mod_key, 'j', .focus_next)) catch {};
    cfg.add_keybind(make_keybind(mod_key, 'k', .focus_prev)) catch {};
    cfg.add_keybind(make_keybind(mod_key | shift_key, 'j', .move_next)) catch {};
    cfg.add_keybind(make_keybind(mod_key | shift_key, 'k', .move_prev)) catch {};
    cfg.add_keybind(make_keybind_int(mod_key, 'h', .resize_master, -50)) catch {};
    cfg.add_keybind(make_keybind_int(mod_key, 'l', .resize_master, 50)) catch {};
    cfg.add_keybind(make_keybind(mod_key, 'i', .inc_master)) catch {};
    cfg.add_keybind(make_keybind(mod_key, 'p', .dec_master)) catch {};
    cfg.add_keybind(make_keybind(mod_key, 'a', .toggle_gaps)) catch {};
    cfg.add_keybind(make_keybind(mod_key, 'f', .toggle_fullscreen)) catch {};
    cfg.add_keybind(make_keybind(mod_key, 0x0020, .toggle_floating)) catch {};
    cfg.add_keybind(make_keybind(mod_key, 'n', .cycle_layout)) catch {};
    cfg.add_keybind(make_keybind_int(mod_key, 0x002c, .focus_monitor, -1)) catch {};
    cfg.add_keybind(make_keybind_int(mod_key, 0x002e, .focus_monitor, 1)) catch {};
    cfg.add_keybind(make_keybind_int(mod_key | shift_key, 0x002c, .send_to_monitor, -1)) catch {};
    cfg.add_keybind(make_keybind_int(mod_key | shift_key, 0x002e, .send_to_monitor, 1)) catch {};

    var tag_index: i32 = 0;
    while (tag_index < 9) : (tag_index += 1) {
        const keysym: u64 = @as(u64, '1') + @as(u64, @intCast(tag_index));
        cfg.add_keybind(make_keybind_int(mod_key, keysym, .view_tag, tag_index)) catch {};
        cfg.add_keybind(make_keybind_int(mod_key | shift_key, keysym, .move_to_tag, tag_index)) catch {};
        cfg.add_keybind(make_keybind_int(mod_key | control_key, keysym, .toggle_view_tag, tag_index)) catch {};
        cfg.add_keybind(make_keybind_int(mod_key | control_key | shift_key, keysym, .toggle_tag, tag_index)) catch {};
    }

    cfg.add_button(.{ .click = .client_win, .mod_mask = mod_key, .button = 1, .action = .move_mouse }) catch {};
    cfg.add_button(.{ .click = .client_win, .mod_mask = mod_key, .button = 3, .action = .resize_mouse }) catch {};
}

fn get_state(window: xlib.Window, wm: *WindowManager) c_long {
    var actual_type: xlib.Atom = 0;
    var actual_format: c_int = 0;
    var num_items: c_ulong = 0;
    var bytes_after: c_ulong = 0;
    var prop: [*c]u8 = null;

    const result = xlib.XGetWindowProperty(
        wm.display.handle,
        window,
        wm.atoms.wm_state,
        0,
        2,
        xlib.False,
        wm.atoms.wm_state,
        &actual_type,
        &actual_format,
        &num_items,
        &bytes_after,
        &prop,
    );

    if (result != 0 or actual_type != wm.atoms.wm_state or num_items < 1) {
        if (prop != null) {
            _ = xlib.XFree(prop);
        }
        return WithdrawnState;
    }

    const state: c_long = @as(*c_long, @ptrCast(@alignCast(prop))).*;
    _ = xlib.XFree(prop);
    return state;
}

fn scan_existing_windows(wm: *WindowManager) void {
    var root_return: xlib.Window = undefined;
    var parent_return: xlib.Window = undefined;
    var children: [*c]xlib.Window = undefined;
    var num_children: c_uint = undefined;

    if (xlib.XQueryTree(wm.display.handle, wm.display.root, &root_return, &parent_return, &children, &num_children) == 0) {
        return;
    }

    var index: c_uint = 0;
    while (index < num_children) : (index += 1) {
        var window_attrs: xlib.XWindowAttributes = undefined;
        if (xlib.XGetWindowAttributes(wm.display.handle, children[index], &window_attrs) == 0) {
            continue;
        }
        if (window_attrs.override_redirect != 0) {
            continue;
        }
        var trans: xlib.Window = 0;
        if (xlib.XGetTransientForHint(wm.display.handle, children[index], &trans) != 0) {
            continue;
        }
        if (window_attrs.map_state == IsViewable or get_state(children[index], wm) == IconicState) {
            manage(children[index], &window_attrs, wm);
        }
    }

    index = 0;
    while (index < num_children) : (index += 1) {
        var window_attrs: xlib.XWindowAttributes = undefined;
        if (xlib.XGetWindowAttributes(wm.display.handle, children[index], &window_attrs) == 0) {
            continue;
        }
        var trans: xlib.Window = 0;
        if (xlib.XGetTransientForHint(wm.display.handle, children[index], &trans) != 0) {
            if (window_attrs.map_state == IsViewable or get_state(children[index], wm) == IconicState) {
                manage(children[index], &window_attrs, wm);
            }
        }
    }

    if (children != null) {
        _ = xlib.XFree(@ptrCast(children));
    }
}

fn run_event_loop(wm: *WindowManager) void {
    var fds = [_]std.posix.pollfd{
        .{ .fd = wm.x11_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    _ = xlib.XSync(wm.display.handle, xlib.False);

    while (wm.running) {
        while (xlib.XPending(wm.display.handle) > 0) {
            var event = wm.display.next_event();
            handle_event(&event, wm);
        }

        tick_animations(wm);

        var current_bar = wm.bars;
        while (current_bar) |bar| {
            bar.update_blocks();
            bar.draw(wm.display.handle, wm.config);
            current_bar = bar.next;
        }

        const poll_timeout: i32 = if (wm.scroll_animation.is_active()) 16 else 1000;
        _ = std.posix.poll(&fds, poll_timeout) catch 0;
    }
}

fn handle_event(event: *xlib.XEvent, wm: *WindowManager) void {
    const event_type = events.get_event_type(event);

    if (event_type == .button_press) {
        std.debug.print("EVENT: button_press received type={d}\n", .{event.type});
    }

    switch (event_type) {
        .map_request => handle_map_request(&event.xmaprequest, wm),
        .configure_request => handle_configure_request(&event.xconfigurerequest, wm),
        .key_press => handle_key_press(&event.xkey, wm),
        .destroy_notify => handle_destroy_notify(&event.xdestroywindow, wm),
        .unmap_notify => handle_unmap_notify(&event.xunmap, wm),
        .enter_notify => handle_enter_notify(&event.xcrossing, wm),
        .focus_in => handle_focus_in(&event.xfocus, wm),
        .motion_notify => handle_motion_notify(&event.xmotion, wm),
        .client_message => handle_client_message(&event.xclient, wm),
        .button_press => handle_button_press(&event.xbutton, wm),
        .expose => handle_expose(&event.xexpose, wm),
        .property_notify => handle_property_notify(&event.xproperty, wm),
        else => {},
    }
}

fn handle_map_request(event: *xlib.XMapRequestEvent, wm: *WindowManager) void {
    std.debug.print("map_request: window=0x{x}\n", .{event.window});

    var window_attributes: xlib.XWindowAttributes = undefined;
    if (xlib.XGetWindowAttributes(wm.display.handle, event.window, &window_attributes) == 0) {
        return;
    }
    if (window_attributes.override_redirect != 0) {
        return;
    }
    if (client_mod.window_to_client(monitor_mod.monitors, event.window) != null) {
        return;
    }

    manage(event.window, &window_attributes, wm);
}

fn manage(win: xlib.Window, window_attrs: *xlib.XWindowAttributes, wm: *WindowManager) void {
    const client = client_mod.create(gpa.allocator(), win) orelse return;
    var trans: xlib.Window = 0;

    client.x = window_attrs.x;
    client.y = window_attrs.y;
    client.width = window_attrs.width;
    client.height = window_attrs.height;
    client.old_x = window_attrs.x;
    client.old_y = window_attrs.y;
    client.old_width = window_attrs.width;
    client.old_height = window_attrs.height;
    client.old_border_width = window_attrs.border_width;
    client.border_width = wm.config.border_width;

    update_title(client, wm);

    if (xlib.XGetTransientForHint(wm.display.handle, win, &trans) != 0) {
        if (client_mod.window_to_client(monitor_mod.monitors, trans)) |transient_client| {
            client.monitor = transient_client.monitor;
            client.tags = transient_client.tags;
        }
    }

    if (client.monitor == null) {
        client.monitor = monitor_mod.selected_monitor;
        apply_rules(client, wm);
    }

    const monitor = client.monitor orelse return;

    if (client.x + client.width > monitor.win_x + monitor.win_w) {
        client.x = monitor.win_x + monitor.win_w - client.width - 2 * client.border_width;
    }
    if (client.y + client.height > monitor.win_y + monitor.win_h) {
        client.y = monitor.win_y + monitor.win_h - client.height - 2 * client.border_width;
    }
    client.x = @max(client.x, monitor.win_x);
    client.y = @max(client.y, monitor.win_y);

    _ = xlib.XSetWindowBorderWidth(wm.display.handle, win, @intCast(client.border_width));
    _ = xlib.XSetWindowBorder(wm.display.handle, win, wm.config.border_unfocused);
    tiling.send_configure(client);

    update_window_type(client, wm);
    update_size_hints(client, wm);
    update_wm_hints(client, wm);

    _ = xlib.XSelectInput(
        wm.display.handle,
        win,
        xlib.EnterWindowMask | xlib.FocusChangeMask | xlib.PropertyChangeMask | xlib.StructureNotifyMask,
    );
    grabbuttons(client, false, wm);

    if (!client.is_floating) {
        client.is_floating = trans != 0 or client.is_fixed;
        client.old_state = client.is_floating;
    }
    if (client.is_floating) {
        _ = xlib.XRaiseWindow(wm.display.handle, client.window);
    }

    client_mod.attach_aside(client);
    client_mod.attach_stack(client);

    _ = xlib.XChangeProperty(wm.display.handle, wm.display.root, wm.atoms.net_client_list, xlib.XA_WINDOW, 32, xlib.PropModeAppend, @ptrCast(&client.window), 1);
    _ = xlib.XMoveResizeWindow(wm.display.handle, client.window, client.x + 2 * wm.display.screen_width(), client.y, @intCast(client.width), @intCast(client.height));
    set_client_state(client, NormalState, wm);

    if (client.monitor == monitor_mod.selected_monitor) {
        const selmon = monitor_mod.selected_monitor orelse return;
        unfocus_client(selmon.sel, false, wm);
    }
    monitor.sel = client;

    if (is_scrolling_layout(monitor)) {
        monitor.scroll_offset = 0;
    }

    arrange(monitor, wm);
    _ = xlib.XMapWindow(wm.display.handle, win);
    focus(null, wm);
}

fn handle_configure_request(event: *xlib.XConfigureRequestEvent, wm: *WindowManager) void {
    const client = client_mod.window_to_client(monitor_mod.monitors, event.window);

    if (client) |managed_client| {
        if ((event.value_mask & xlib.c.CWBorderWidth) != 0) {
            managed_client.border_width = event.border_width;
        } else if (managed_client.is_floating or (managed_client.monitor != null and managed_client.monitor.?.lt[managed_client.monitor.?.sel_lt] == null)) {
            const monitor = managed_client.monitor orelse return;
            if ((event.value_mask & xlib.c.CWX) != 0) {
                managed_client.old_x = managed_client.x;
                managed_client.x = monitor.mon_x + event.x;
            }
            if ((event.value_mask & xlib.c.CWY) != 0) {
                managed_client.old_y = managed_client.y;
                managed_client.y = monitor.mon_y + event.y;
            }
            if ((event.value_mask & xlib.c.CWWidth) != 0) {
                managed_client.old_width = managed_client.width;
                managed_client.width = event.width;
            }
            if ((event.value_mask & xlib.c.CWHeight) != 0) {
                managed_client.old_height = managed_client.height;
                managed_client.height = event.height;
            }
            const client_full_width = managed_client.width + managed_client.border_width * 2;
            const client_full_height = managed_client.height + managed_client.border_width * 2;
            if ((managed_client.x + managed_client.width) > monitor.mon_x + monitor.mon_w and managed_client.is_floating) {
                managed_client.x = monitor.mon_x + @divTrunc(monitor.mon_w, 2) - @divTrunc(client_full_width, 2);
            }
            if ((managed_client.y + managed_client.height) > monitor.mon_y + monitor.mon_h and managed_client.is_floating) {
                managed_client.y = monitor.mon_y + @divTrunc(monitor.mon_h, 2) - @divTrunc(client_full_height, 2);
            }
            if (((event.value_mask & (xlib.c.CWX | xlib.c.CWY)) != 0) and ((event.value_mask & (xlib.c.CWWidth | xlib.c.CWHeight)) == 0)) {
                tiling.send_configure(managed_client);
            }
            if (client_mod.is_visible(managed_client)) {
                _ = xlib.XMoveResizeWindow(wm.display.handle, managed_client.window, managed_client.x, managed_client.y, @intCast(managed_client.width), @intCast(managed_client.height));
            }
        } else {
            tiling.send_configure(managed_client);
        }
    } else {
        var changes: xlib.XWindowChanges = undefined;
        changes.x = event.x;
        changes.y = event.y;
        changes.width = event.width;
        changes.height = event.height;
        changes.border_width = event.border_width;
        changes.sibling = event.above;
        changes.stack_mode = event.detail;
        _ = xlib.XConfigureWindow(wm.display.handle, event.window, @intCast(event.value_mask), &changes);
    }
    _ = xlib.XSync(wm.display.handle, xlib.False);
}

fn handle_key_press(event: *xlib.XKeyEvent, wm: *WindowManager) void {
    const keysym = xlib.XKeycodeToKeysym(wm.display.handle, @intCast(event.keycode), 0);

    if (wm.overlay) |overlay| {
        if (overlay.handle_key(keysym)) return;
    }

    const clean_state = event.state & ~@as(c_uint, xlib.LockMask | xlib.Mod2Mask);

    if (wm.chord.is_timed_out()) {
        wm.chord.reset(wm.display.handle);
    }

    _ = wm.chord.push(.{ .mod_mask = clean_state, .keysym = keysym });

    for (wm.config.keybinds.items) |keybind| {
        if (keybind.key_count == 0) continue;

        if (keybind.key_count == wm.chord.index) {
            var matches = true;
            for (0..keybind.key_count) |i| {
                if (wm.chord.keys[i].keysym != keybind.keys[i].keysym or
                    wm.chord.keys[i].mod_mask != keybind.keys[i].mod_mask)
                {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                execute_action(keybind.action, keybind.int_arg, keybind.str_arg, wm);
                wm.chord.reset(wm.display.handle);
                return;
            }
        }
    }

    var has_partial_match = false;
    for (wm.config.keybinds.items) |keybind| {
        if (keybind.key_count > wm.chord.index) {
            var matches = true;
            for (0..wm.chord.index) |i| {
                if (wm.chord.keys[i].keysym != keybind.keys[i].keysym or
                    wm.chord.keys[i].mod_mask != keybind.keys[i].mod_mask)
                {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                has_partial_match = true;
                break;
            }
        }
    }

    if (has_partial_match) {
        wm.chord.grab_keyboard(wm.display.handle, wm.display.root);
    } else {
        wm.chord.reset(wm.display.handle);
    }
}

fn execute_action(action: config_mod.Action, int_arg: i32, str_arg: ?[]const u8, wm: *WindowManager) void {
    switch (action) {
        .spawn_terminal => spawn_terminal(wm),
        .spawn => {
            if (str_arg) |cmd| spawn_command(cmd);
        },
        .kill_client => kill_focused(wm),
        .quit => {
            std.debug.print("quit keybind pressed\n", .{});
            wm.running = false;
        },
        .reload_config => reload_config(wm),
        .restart => reload_config(wm),
        .show_keybinds => {
            if (wm.overlay) |overlay| {
                const mon = wm.selected_monitor orelse wm.monitors;
                if (mon) |m| {
                    overlay.toggle(m.mon_x, m.mon_y, m.mon_w, m.mon_h, &wm.config);
                }
            }
        },
        .focus_next => focusstack(1, wm),
        .focus_prev => focusstack(-1, wm),
        .move_next => movestack(1, wm),
        .move_prev => movestack(-1, wm),
        .resize_master => setmfact(@as(f32, @floatFromInt(int_arg)) / 1000.0, wm),
        .inc_master => incnmaster(1, wm),
        .dec_master => incnmaster(-1, wm),
        .toggle_floating => toggle_floating(wm),
        .toggle_fullscreen => toggle_fullscreen(wm),
        .toggle_gaps => toggle_gaps(wm),
        .cycle_layout => cycle_layout(wm),
        .set_layout => set_layout(str_arg, wm),
        .set_layout_tiling => set_layout_index(0, wm),
        .set_layout_floating => set_layout_index(2, wm),
        .view_tag => {
            const tag_mask: u32 = @as(u32, 1) << @intCast(int_arg);
            view(tag_mask, wm);
        },
        .view_next_tag => view_adjacent_tag(1, wm),
        .view_prev_tag => view_adjacent_tag(-1, wm),
        .view_next_nonempty_tag => view_adjacent_nonempty_tag(1, wm),
        .view_prev_nonempty_tag => view_adjacent_nonempty_tag(-1, wm),
        .move_to_tag => {
            const tag_mask: u32 = @as(u32, 1) << @intCast(int_arg);
            tag_client(tag_mask, wm);
        },
        .toggle_view_tag => {
            const tag_mask: u32 = @as(u32, 1) << @intCast(int_arg);
            toggle_view(tag_mask, wm);
        },
        .toggle_tag => {
            const tag_mask: u32 = @as(u32, 1) << @intCast(int_arg);
            toggle_client_tag(tag_mask, wm);
        },
        .focus_monitor => focusmon(int_arg, wm),
        .send_to_monitor => sendmon(int_arg, wm),
        .scroll_left => scroll_layout(-1, wm),
        .scroll_right => scroll_layout(1, wm),
    }
}

fn reload_config(wm: *WindowManager) void {
    std.debug.print("reloading config...\n", .{});

    wm.ungrab_keybinds();

    wm.config.keybinds.clearRetainingCapacity();
    wm.config.buttons.clearRetainingCapacity();
    wm.config.rules.clearRetainingCapacity();
    wm.config.blocks.clearRetainingCapacity();

    lua.deinit();
    _ = lua.init(&wm.config);

    const loaded = if (wm.config_path) |path|
        lua.load_file(path)
    else
        lua.load_config();

    if (loaded) {
        if (wm.config_path) |path| {
            std.debug.print("reloaded config from {s}\n", .{path});
        } else {
            std.debug.print("reloaded config from ~/.config/oxwm/config.lua\n", .{});
        }
    } else {
        std.debug.print("reload failed, restoring defaults\n", .{});
        initialize_default_config(&wm.config);
    }

    bar_mod.destroy_bars(wm.bars, gpa.allocator(), wm.display.handle);
    wm.bars = null;
    wm.setup_bars();
    wm.rebuild_bar_blocks();

    wm.grab_keybinds();
}

fn spawn_child_setup() void {
    _ = std.c.setsid();
    if (x11_fd >= 0) std.posix.close(@intCast(x11_fd));
    const sigchld_handler = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.CHLD, &sigchld_handler, null);
}

fn spawn_command(cmd: []const u8) void {
    std.debug.print("running cmd: {s}\n", .{cmd});
    const pid = std.posix.fork() catch return;
    if (pid == 0) {
        spawn_child_setup();
        var cmd_buf: [1024]u8 = undefined;
        if (cmd.len >= cmd_buf.len) {
            std.posix.exit(1);
        }
        @memcpy(cmd_buf[0..cmd.len], cmd);
        cmd_buf[cmd.len] = 0;
        const argv = [_:null]?[*:0]const u8{ "sh", "-c", @ptrCast(&cmd_buf) };
        _ = std.posix.execvpeZ("sh", &argv, std.c.environ) catch {};
        std.posix.exit(1);
    }
}

// TODO: take in the terminal cmd directly.
fn spawn_terminal(wm: *WindowManager) void {
    const pid = std.posix.fork() catch return;
    if (pid == 0) {
        spawn_child_setup();
        var term_buf: [256]u8 = undefined;
        const terminal = wm.config.terminal;
        if (terminal.len >= term_buf.len) {
            std.posix.exit(1);
        }
        @memcpy(term_buf[0..terminal.len], terminal);
        term_buf[terminal.len] = 0;
        const term_ptr: [*:0]const u8 = @ptrCast(&term_buf);
        const argv = [_:null]?[*:0]const u8{term_ptr};
        _ = std.posix.execvpeZ(term_ptr, &argv, std.c.environ) catch {};
        std.posix.exit(1);
    }
}

fn movestack(direction: i32, wm: *WindowManager) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const current = monitor.sel orelse return;

    if (current.is_floating) {
        return;
    }

    var target: ?*Client = null;

    if (direction > 0) {
        target = current.next;
        while (target) |client| {
            if (client_mod.is_visible(client) and !client.is_floating) {
                break;
            }
            target = client.next;
        }
        if (target == null) {
            target = monitor.clients;
            while (target) |client| {
                if (client == current) {
                    break;
                }
                if (client_mod.is_visible(client) and !client.is_floating) {
                    break;
                }
                target = client.next;
            }
        }
    } else {
        var prev: ?*Client = null;
        var iter = monitor.clients;
        while (iter) |client| {
            if (client == current) {
                break;
            }
            if (client_mod.is_visible(client) and !client.is_floating) {
                prev = client;
            }
            iter = client.next;
        }
        if (prev == null) {
            iter = current.next;
            while (iter) |client| {
                if (client_mod.is_visible(client) and !client.is_floating) {
                    prev = client;
                }
                iter = client.next;
            }
        }
        target = prev;
    }

    if (target) |swap_client| {
        if (swap_client != current) {
            client_mod.swap_clients(current, swap_client);
            arrange(monitor, wm);
            focus(current, wm);
        }
    }
}

fn toggle_view(tag_mask: u32, wm: *WindowManager) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const new_tags = monitor.tagset[monitor.sel_tags] ^ tag_mask;
    if (new_tags != 0) {
        monitor.tagset[monitor.sel_tags] = new_tags;

        if (new_tags == ~@as(u32, 0)) {
            monitor.pertag.prevtag = monitor.pertag.curtag;
            monitor.pertag.curtag = 0;
        }

        if ((new_tags & (@as(u32, 1) << @intCast(monitor.pertag.curtag -| 1))) == 0) {
            monitor.pertag.prevtag = monitor.pertag.curtag;
            var i: u32 = 0;
            while (i < 9) : (i += 1) {
                if ((new_tags & (@as(u32, 1) << @intCast(i))) != 0) break;
            }
            monitor.pertag.curtag = i + 1;
        }

        monitor.nmaster = monitor.pertag.nmasters[monitor.pertag.curtag];
        monitor.mfact = monitor.pertag.mfacts[monitor.pertag.curtag];
        monitor.sel_lt = monitor.pertag.sellts[monitor.pertag.curtag];

        focus_top_client(monitor, wm);
        arrange(monitor, wm);
        wm.invalidate_bars();
    }
}

fn toggle_client_tag(tag_mask: u32, wm: *WindowManager) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const client = monitor.sel orelse return;
    const new_tags = client.tags ^ tag_mask;
    if (new_tags != 0) {
        client.tags = new_tags;
        focus_top_client(monitor, wm);
        arrange(monitor, wm);
        wm.invalidate_bars();
    }
}

fn toggle_gaps(wm: *WindowManager) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    if (monitor.gap_inner_h == 0) {
        monitor.gap_inner_h = wm.config.gap_inner_h;
        monitor.gap_inner_v = wm.config.gap_inner_v;
        monitor.gap_outer_h = wm.config.gap_outer_h;
        monitor.gap_outer_v = wm.config.gap_outer_v;
    } else {
        monitor.gap_inner_h = 0;
        monitor.gap_inner_v = 0;
        monitor.gap_outer_h = 0;
        monitor.gap_outer_v = 0;
    }
    arrange(monitor, wm);
}

fn kill_focused(wm: *WindowManager) void {
    const selected = monitor_mod.selected_monitor orelse return;
    const client = selected.sel orelse return;
    std.debug.print("killing window: 0x{x}\n", .{client.window});

    if (!send_event(client, wm.atoms.wm_delete, wm)) {
        _ = xlib.XGrabServer(wm.display.handle);
        _ = xlib.XKillClient(wm.display.handle, client.window);
        _ = xlib.XSync(wm.display.handle, xlib.False);
        _ = xlib.XUngrabServer(wm.display.handle);
    }
}

fn toggle_fullscreen(wm: *WindowManager) void {
    const selected = monitor_mod.selected_monitor orelse return;
    const client = selected.sel orelse return;
    set_fullscreen(client, !client.is_fullscreen, wm);
}

fn set_fullscreen(client: *Client, fullscreen: bool, wm: *WindowManager) void {
    const monitor = client.monitor orelse return;

    if (fullscreen and !client.is_fullscreen) {
        var fullscreen_atom = wm.atoms.net_wm_state_fullscreen;
        _ = xlib.XChangeProperty(
            wm.display.handle,
            client.window,
            wm.atoms.net_wm_state,
            xlib.XA_ATOM,
            32,
            xlib.PropModeReplace,
            @ptrCast(&fullscreen_atom),
            1,
        );
        client.is_fullscreen = true;
        client.old_state = client.is_floating;
        client.old_border_width = client.border_width;
        client.border_width = 0;
        client.is_floating = true;

        _ = xlib.XSetWindowBorderWidth(wm.display.handle, client.window, 0);
        tiling.resize_client(client, monitor.mon_x, monitor.mon_y, monitor.mon_w, monitor.mon_h);
        _ = xlib.XRaiseWindow(wm.display.handle, client.window);

        std.debug.print("fullscreen enabled: window=0x{x}\n", .{client.window});
    } else if (!fullscreen and client.is_fullscreen) {
        var no_atom: xlib.Atom = 0;
        _ = xlib.XChangeProperty(
            wm.display.handle,
            client.window,
            wm.atoms.net_wm_state,
            xlib.XA_ATOM,
            32,
            xlib.PropModeReplace,
            @ptrCast(&no_atom),
            0,
        );
        client.is_fullscreen = false;
        client.is_floating = client.old_state;
        client.border_width = client.old_border_width;

        client.x = client.old_x;
        client.y = client.old_y;
        client.width = client.old_width;
        client.height = client.old_height;

        tiling.resize_client(client, client.x, client.y, client.width, client.height);
        arrange(monitor, wm);

        std.debug.print("fullscreen disabled: window=0x{x}\n", .{client.window});
    }
}

fn view(tag_mask: u32, wm: *WindowManager) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    if (tag_mask == monitor.tagset[monitor.sel_tags]) {
        return;
    }
    monitor.sel_tags ^= 1;
    if (tag_mask != 0) {
        monitor.tagset[monitor.sel_tags] = tag_mask;
        monitor.pertag.prevtag = monitor.pertag.curtag;

        if (tag_mask == ~@as(u32, 0)) {
            monitor.pertag.curtag = 0;
        } else {
            var i: u32 = 0;
            while (i < 9) : (i += 1) {
                if ((tag_mask & (@as(u32, 1) << @intCast(i))) != 0) break;
            }
            monitor.pertag.curtag = i + 1;
        }
    } else {
        const tmp = monitor.pertag.prevtag;
        monitor.pertag.prevtag = monitor.pertag.curtag;
        monitor.pertag.curtag = tmp;
    }

    monitor.nmaster = monitor.pertag.nmasters[monitor.pertag.curtag];
    monitor.mfact = monitor.pertag.mfacts[monitor.pertag.curtag];
    monitor.sel_lt = monitor.pertag.sellts[monitor.pertag.curtag];

    focus_top_client(monitor, wm);
    arrange(monitor, wm);
    wm.invalidate_bars();
    std.debug.print("view: tag_mask={d}\n", .{monitor.tagset[monitor.sel_tags]});
}

fn view_adjacent_tag(direction: i32, wm: *WindowManager) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const current_tag = monitor.pertag.curtag;
    var new_tag: i32 = @intCast(current_tag);

    new_tag += direction;
    if (new_tag < 1) new_tag = 9;
    if (new_tag > 9) new_tag = 1;

    const tag_mask: u32 = @as(u32, 1) << @intCast(new_tag - 1);
    view(tag_mask, wm);
}

fn view_adjacent_nonempty_tag(direction: i32, wm: *WindowManager) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const current_tag = monitor.pertag.curtag;
    var new_tag: i32 = @intCast(current_tag);

    var attempts: i32 = 0;
    while (attempts < 9) : (attempts += 1) {
        new_tag += direction;
        if (new_tag < 1) new_tag = 9;
        if (new_tag > 9) new_tag = 1;

        const tag_mask: u32 = @as(u32, 1) << @intCast(new_tag - 1);
        if (has_clients_on_tag(monitor, tag_mask)) {
            view(tag_mask, wm);
            return;
        }
    }
}

fn has_clients_on_tag(monitor: *monitor_mod.Monitor, tag_mask: u32) bool {
    var client = monitor.clients;
    while (client) |c| {
        if ((c.tags & tag_mask) != 0) {
            return true;
        }
        client = c.next;
    }
    return false;
}

fn tag_client(tag_mask: u32, wm: *WindowManager) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const client = monitor.sel orelse return;
    if (tag_mask == 0) {
        return;
    }
    client.tags = tag_mask;
    focus_top_client(monitor, wm);
    arrange(monitor, wm);
    wm.invalidate_bars();
    std.debug.print("tag_client: window=0x{x} tag_mask={d}\n", .{ client.window, tag_mask });
}

fn focus_top_client(monitor: *Monitor, wm: *WindowManager) void {
    var visible_client = monitor.stack;
    while (visible_client) |client| {
        if (client_mod.is_visible(client)) {
            focus(client, wm);
            return;
        }
        visible_client = client.stack_next;
    }
    monitor.sel = null;
    _ = xlib.XSetInputFocus(wm.display.handle, wm.display.root, xlib.RevertToPointerRoot, xlib.CurrentTime);
}

fn focusstack(direction: i32, wm: *WindowManager) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const current = monitor.sel orelse return;

    var next_client: ?*Client = null;

    if (direction > 0) {
        next_client = current.next;
        while (next_client) |client| {
            if (client_mod.is_visible(client)) {
                break;
            }
            next_client = client.next;
        }
        if (next_client == null) {
            next_client = monitor.clients;
            while (next_client) |client| {
                if (client_mod.is_visible(client)) {
                    break;
                }
                next_client = client.next;
            }
        }
    } else {
        var prev: ?*Client = null;
        var iter = monitor.clients;
        while (iter) |client| {
            if (client == current) {
                break;
            }
            if (client_mod.is_visible(client)) {
                prev = client;
            }
            iter = client.next;
        }
        if (prev == null) {
            iter = current.next;
            while (iter) |client| {
                if (client_mod.is_visible(client)) {
                    prev = client;
                }
                iter = client.next;
            }
        }
        next_client = prev;
    }

    if (next_client) |client| {
        focus(client, wm);
        if (client.monitor) |client_monitor| {
            restack(client_monitor, wm);
        }
    }
}

fn toggle_floating(wm: *WindowManager) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const client = monitor.sel orelse return;

    if (client.is_fullscreen) {
        return;
    }

    client.is_floating = !client.is_floating;

    if (client.is_floating) {
        tiling.resize(client, client.x, client.y, client.width, client.height, false);
    }

    arrange(monitor, wm);
    std.debug.print("toggle_floating: window=0x{x} floating={}\n", .{ client.window, client.is_floating });
}

fn incnmaster(delta: i32, wm: *WindowManager) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const new_val = @max(0, monitor.nmaster + delta);
    monitor.nmaster = new_val;
    monitor.pertag.nmasters[monitor.pertag.curtag] = new_val;
    arrange(monitor, wm);
    std.debug.print("incnmaster: nmaster={d}\n", .{monitor.nmaster});
}

fn setmfact(delta: f32, wm: *WindowManager) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const new_mfact = monitor.mfact + delta;
    if (new_mfact < 0.05 or new_mfact > 0.95) {
        return;
    }
    monitor.mfact = new_mfact;
    monitor.pertag.mfacts[monitor.pertag.curtag] = new_mfact;
    arrange(monitor, wm);
    std.debug.print("setmfact: mfact={d:.2}\n", .{monitor.mfact});
}

fn cycle_layout(wm: *WindowManager) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const new_lt = (monitor.sel_lt + 1) % 5;
    monitor.sel_lt = new_lt;
    monitor.pertag.sellts[monitor.pertag.curtag] = new_lt;
    if (new_lt != 3) {
        monitor.scroll_offset = 0;
    }
    arrange(monitor, wm);
    wm.invalidate_bars();
    if (monitor.lt[monitor.sel_lt]) |layout| {
        std.debug.print("cycle_layout: {s}\n", .{layout.symbol});
    }
}

fn set_layout(layout_name: ?[]const u8, wm: *WindowManager) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const name = layout_name orelse return;

    const new_lt: u32 = if (std.mem.eql(u8, name, "tiling") or std.mem.eql(u8, name, "[]="))
        0
    else if (std.mem.eql(u8, name, "monocle") or std.mem.eql(u8, name, "[M]"))
        1
    else if (std.mem.eql(u8, name, "floating") or std.mem.eql(u8, name, "><>"))
        2
    else if (std.mem.eql(u8, name, "scrolling") or std.mem.eql(u8, name, "[S]"))
        3
    else if (std.mem.eql(u8, name, "grid") or std.mem.eql(u8, name, "[#]"))
        4
    else {
        std.debug.print("set_layout: unknown layout '{s}'\n", .{name});
        return;
    };

    monitor.sel_lt = new_lt;
    monitor.pertag.sellts[monitor.pertag.curtag] = new_lt;
    if (new_lt != 3) {
        monitor.scroll_offset = 0;
    }
    arrange(monitor, wm);
    wm.invalidate_bars();
    if (monitor.lt[monitor.sel_lt]) |layout| {
        std.debug.print("set_layout: {s}\n", .{layout.symbol});
    }
}

fn set_layout_index(index: u32, wm: *WindowManager) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    monitor.sel_lt = index;
    monitor.pertag.sellts[monitor.pertag.curtag] = index;
    if (index != 3) {
        monitor.scroll_offset = 0;
    }
    arrange(monitor, wm);
    wm.invalidate_bars();
    if (monitor.lt[monitor.sel_lt]) |layout| {
        std.debug.print("set_layout_index: {s}\n", .{layout.symbol});
    }
}

fn focusmon(direction: i32, wm: *WindowManager) void {
    const selmon = monitor_mod.selected_monitor orelse return;
    const target = monitor_mod.dir_to_monitor(direction) orelse return;
    if (target == selmon) {
        return;
    }
    unfocus_client(selmon.sel, false, wm);
    monitor_mod.selected_monitor = target;
    focus(null, wm);
    std.debug.print("focusmon: monitor {d}\n", .{target.num});
}

fn sendmon(direction: i32, wm: *WindowManager) void {
    const source_monitor = monitor_mod.selected_monitor orelse return;
    const client = source_monitor.sel orelse return;
    const target = monitor_mod.dir_to_monitor(direction) orelse return;

    if (target == source_monitor) {
        return;
    }

    client_mod.detach(client);
    client_mod.detach_stack(client);
    client.monitor = target;
    client.tags = target.tagset[target.sel_tags];
    client_mod.attach_aside(client);
    client_mod.attach_stack(client);

    focus_top_client(source_monitor, wm);
    arrange(source_monitor, wm);
    arrange(target, wm);

    std.debug.print("sendmon: window=0x{x} to monitor {d}\n", .{ client.window, target.num });
}

fn snap_x(client: *Client, new_x: i32, monitor: *Monitor) i32 {
    const client_width = client.width + 2 * client.border_width;
    if (@abs(monitor.win_x - new_x) < snap_distance) {
        return monitor.win_x;
    } else if (@abs((monitor.win_x + monitor.win_w) - (new_x + client_width)) < snap_distance) {
        return monitor.win_x + monitor.win_w - client_width;
    }
    return new_x;
}

fn snap_y(client: *Client, new_y: i32, monitor: *Monitor) i32 {
    const client_height = client.height + 2 * client.border_width;
    if (@abs(monitor.win_y - new_y) < snap_distance) {
        return monitor.win_y;
    } else if (@abs((monitor.win_y + monitor.win_h) - (new_y + client_height)) < snap_distance) {
        return monitor.win_y + monitor.win_h - client_height;
    }
    return new_y;
}

fn movemouse(wm: *WindowManager) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const client = monitor.sel orelse return;

    if (client.is_fullscreen) {
        return;
    }

    restack(monitor, wm);

    const was_floating = client.is_floating;
    if (!client.is_floating) {
        client.is_floating = true;
    }

    var root_x: c_int = undefined;
    var root_y: c_int = undefined;
    var dummy_win: xlib.Window = undefined;
    var dummy_int: c_int = undefined;
    var dummy_uint: c_uint = undefined;

    _ = xlib.XQueryPointer(wm.display.handle, wm.display.root, &dummy_win, &dummy_win, &root_x, &root_y, &dummy_int, &dummy_int, &dummy_uint);

    const grab_result = xlib.XGrabPointer(
        wm.display.handle,
        wm.display.root,
        xlib.False,
        xlib.ButtonPressMask | xlib.ButtonReleaseMask | xlib.PointerMotionMask,
        xlib.GrabModeAsync,
        xlib.GrabModeAsync,
        xlib.None,
        wm.cursors.move,
        xlib.CurrentTime,
    );

    if (grab_result != xlib.GrabSuccess) {
        return;
    }

    const start_x = client.x;
    const start_y = client.y;
    const pointer_start_x = root_x;
    const pointer_start_y = root_y;
    var last_time: c_ulong = 0;

    var event: xlib.XEvent = undefined;
    var done = false;

    while (!done) {
        _ = xlib.XNextEvent(wm.display.handle, &event);

        switch (event.type) {
            xlib.MotionNotify => {
                const motion = &event.xmotion;
                if ((motion.time - last_time) < (1000 / 60)) {
                    continue;
                }
                last_time = motion.time;
                const delta_x = motion.x_root - pointer_start_x;
                const delta_y = motion.y_root - pointer_start_y;
                var new_x = start_x + delta_x;
                var new_y = start_y + delta_y;
                if (client.monitor) |client_monitor| {
                    new_x = snap_x(client, new_x, client_monitor);
                    new_y = snap_y(client, new_y, client_monitor);
                }
                tiling.resize(client, new_x, new_y, client.width, client.height, true);
            },
            xlib.ButtonRelease => {
                done = true;
            },
            else => {},
        }
    }

    _ = xlib.XUngrabPointer(wm.display.handle, xlib.CurrentTime);

    const new_mon = monitor_mod.rect_to_monitor(client.x, client.y, client.width, client.height);
    if (new_mon != null and new_mon != monitor) {
        client_mod.detach(client);
        client_mod.detach_stack(client);
        client.monitor = new_mon;
        client.tags = new_mon.?.tagset[new_mon.?.sel_tags];
        client_mod.attach_aside(client);
        client_mod.attach_stack(client);
        monitor_mod.selected_monitor = new_mon;
        focus(client, wm);
        arrange(monitor, wm);
        arrange(new_mon.?, wm);
    } else {
        arrange(monitor, wm);
    }

    if (wm.config.auto_tile and !was_floating) {
        const drop_monitor = client.monitor orelse return;
        const center_x = client.x + @divTrunc(client.width, 2);
        const center_y = client.y + @divTrunc(client.height, 2);

        if (client_mod.tiled_window_at(client, drop_monitor, center_x, center_y)) |target| {
            client_mod.insert_before(client, target);
        }

        client.is_floating = false;
        arrange(drop_monitor, wm);
    }
}

fn resizemouse(wm: *WindowManager) void {
    const monitor = monitor_mod.selected_monitor orelse return;
    const client = monitor.sel orelse return;

    if (client.is_fullscreen) {
        return;
    }

    restack(monitor, wm);

    if (!client.is_floating) {
        client.is_floating = true;
    }

    const grab_result = xlib.XGrabPointer(
        wm.display.handle,
        wm.display.root,
        xlib.False,
        xlib.ButtonPressMask | xlib.ButtonReleaseMask | xlib.PointerMotionMask,
        xlib.GrabModeAsync,
        xlib.GrabModeAsync,
        xlib.None,
        wm.cursors.resize,
        xlib.CurrentTime,
    );

    if (grab_result != xlib.GrabSuccess) {
        return;
    }

    _ = xlib.XWarpPointer(wm.display.handle, xlib.None, client.window, 0, 0, 0, 0, client.width + client.border_width - 1, client.height + client.border_width - 1);

    var event: xlib.XEvent = undefined;
    var done = false;
    var last_time: c_ulong = 0;

    while (!done) {
        _ = xlib.XNextEvent(wm.display.handle, &event);

        switch (event.type) {
            xlib.MotionNotify => {
                const motion = &event.xmotion;
                if ((motion.time - last_time) < (1000 / 60)) {
                    continue;
                }
                last_time = motion.time;
                var new_width = @max(1, motion.x_root - client.x - 2 * client.border_width + 1);
                var new_height = @max(1, motion.y_root - client.y - 2 * client.border_width + 1);
                if (client.monitor) |client_monitor| {
                    const client_right = client.x + new_width + 2 * client.border_width;
                    const client_bottom = client.y + new_height + 2 * client.border_width;
                    const mon_right = client_monitor.win_x + client_monitor.win_w;
                    const mon_bottom = client_monitor.win_y + client_monitor.win_h;
                    if (@abs(mon_right - client_right) < snap_distance) {
                        new_width = @max(1, mon_right - client.x - 2 * client.border_width);
                    }
                    if (@abs(mon_bottom - client_bottom) < snap_distance) {
                        new_height = @max(1, mon_bottom - client.y - 2 * client.border_width);
                    }
                }
                tiling.resize(client, client.x, client.y, new_width, new_height, true);
            },
            xlib.ButtonRelease => {
                done = true;
            },
            else => {},
        }
    }

    _ = xlib.XUngrabPointer(wm.display.handle, xlib.CurrentTime);
    arrange(monitor, wm);
}

fn handle_expose(event: *xlib.XExposeEvent, wm: *WindowManager) void {
    if (event.count != 0) return;
    if (bar_mod.window_to_bar(wm.bars, event.window)) |bar| {
        bar.invalidate();
        bar.draw(wm.display.handle, wm.config);
    }
}

fn clean_mask(mask: c_uint, wm: *WindowManager) c_uint {
    const lock: c_uint = @intCast(xlib.LockMask);
    const shift: c_uint = @intCast(xlib.ShiftMask);
    const ctrl: c_uint = @intCast(xlib.ControlMask);
    const mod1: c_uint = @intCast(xlib.Mod1Mask);
    const mod2: c_uint = @intCast(xlib.Mod2Mask);
    const mod3: c_uint = @intCast(xlib.Mod3Mask);
    const mod4: c_uint = @intCast(xlib.Mod4Mask);
    const mod5: c_uint = @intCast(xlib.Mod5Mask);
    return mask & ~(lock | wm.numlock_mask) & (shift | ctrl | mod1 | mod2 | mod3 | mod4 | mod5);
}

fn handle_button_press(event: *xlib.XButtonEvent, wm: *WindowManager) void {
    std.debug.print("button_press: window=0x{x} subwindow=0x{x}\n", .{ event.window, event.subwindow });

    const clicked_monitor = monitor_mod.window_to_monitor(wm.display.handle, wm.display.root, event.window);
    if (clicked_monitor) |monitor| {
        if (monitor != monitor_mod.selected_monitor) {
            if (monitor_mod.selected_monitor) |selmon| {
                unfocus_client(selmon.sel, true, wm);
            }
            monitor_mod.selected_monitor = monitor;
            focus(null, wm);
        }
    }

    if (bar_mod.window_to_bar(wm.bars, event.window)) |bar| {
        const clicked_tag = bar.handle_click(wm.display.handle, event.x, wm.config);
        if (clicked_tag) |tag_index| {
            const tag_mask: u32 = @as(u32, 1) << @intCast(tag_index);
            view(tag_mask, wm);
        }
        return;
    }

    const click_client = client_mod.window_to_client(monitor_mod.monitors, event.window);
    if (click_client) |found_client| {
        focus(found_client, wm);
        if (monitor_mod.selected_monitor) |selmon| {
            restack(selmon, wm);
        }
        _ = xlib.XAllowEvents(wm.display.handle, xlib.ReplayPointer, xlib.CurrentTime);
    }

    const clean_state = clean_mask(event.state, wm);
    for (wm.config.buttons.items) |button| {
        if (button.click != .client_win) continue;
        const button_clean_mask = clean_mask(button.mod_mask, wm);
        if (clean_state == button_clean_mask and event.button == button.button) {
            switch (button.action) {
                .move_mouse => movemouse(wm),
                .resize_mouse => resizemouse(wm),
                .toggle_floating => {
                    if (click_client) |found_client| {
                        found_client.is_floating = !found_client.is_floating;
                        if (monitor_mod.selected_monitor) |monitor| {
                            arrange(monitor, wm);
                        }
                    }
                },
            }
            return;
        }
    }
}

fn handle_client_message(event: *xlib.XClientMessageEvent, wm: *WindowManager) void {
    const client = client_mod.window_to_client(monitor_mod.monitors, event.window) orelse return;

    if (event.message_type == wm.atoms.net_wm_state) {
        const action = event.data.l[0];
        const first_property = @as(xlib.Atom, @intCast(event.data.l[1]));
        const second_property = @as(xlib.Atom, @intCast(event.data.l[2]));

        if (first_property == wm.atoms.net_wm_state_fullscreen or second_property == wm.atoms.net_wm_state_fullscreen) {
            const net_wm_state_remove = 0;
            const net_wm_state_add = 1;
            const net_wm_state_toggle = 2;

            if (action == net_wm_state_add) {
                set_fullscreen(client, true, wm);
            } else if (action == net_wm_state_remove) {
                set_fullscreen(client, false, wm);
            } else if (action == net_wm_state_toggle) {
                set_fullscreen(client, !client.is_fullscreen, wm);
            }
        }
    } else if (event.message_type == wm.atoms.net_active_window) {
        const selected = monitor_mod.selected_monitor orelse return;
        if (client != selected.sel and !client.is_urgent) {
            set_urgent(client, true, wm);
        }
    }
}

fn handle_destroy_notify(event: *xlib.XDestroyWindowEvent, wm: *WindowManager) void {
    const client = client_mod.window_to_client(monitor_mod.monitors, event.window) orelse return;
    std.debug.print("destroy_notify: window=0x{x}\n", .{event.window});
    unmanage(client, wm);
}

fn handle_unmap_notify(event: *xlib.XUnmapEvent, wm: *WindowManager) void {
    const client = client_mod.window_to_client(monitor_mod.monitors, event.window) orelse return;
    std.debug.print("unmap_notify: window=0x{x}\n", .{event.window});
    unmanage(client, wm);
}

fn unmanage(client: *Client, wm: *WindowManager) void {
    const client_monitor = client.monitor;

    var next_focus: ?*Client = null;
    if (client_monitor) |monitor| {
        if (monitor.sel == client and is_scrolling_layout(monitor)) {
            next_focus = client.next;
            if (next_focus == null) {
                var prev: ?*Client = null;
                var iter = monitor.clients;
                while (iter) |c| {
                    if (c == client) break;
                    prev = c;
                    iter = c.next;
                }
                next_focus = prev;
            }
        }
    }

    client_mod.detach(client);
    client_mod.detach_stack(client);

    if (client_monitor) |monitor| {
        if (monitor.sel == client) {
            monitor.sel = if (next_focus) |nf| nf else monitor.stack;
        }
        if (is_scrolling_layout(monitor)) {
            const target = if (monitor.sel) |sel| scrolling.get_target_scroll_for_window(monitor, sel) else 0;
            if (target == 0) {
                monitor.scroll_offset = scrolling.get_scroll_step(monitor);
            } else {
                monitor.scroll_offset = 0;
            }
        }
        arrange(monitor, wm);
    }

    if (client_monitor) |monitor| {
        if (monitor.sel) |selected| {
            focus(selected, wm);
        }
    }

    client_mod.destroy(gpa.allocator(), client);
    update_client_list(wm);
    wm.invalidate_bars();
}

fn handle_enter_notify(event: *xlib.XCrossingEvent, wm: *WindowManager) void {
    if ((event.mode != xlib.NotifyNormal or event.detail == xlib.NotifyInferior) and event.window != wm.display.root) {
        return;
    }

    const client = client_mod.window_to_client(monitor_mod.monitors, event.window);
    const target_mon = if (client) |c| c.monitor else monitor_mod.window_to_monitor(wm.display.handle, wm.display.root, event.window);
    const selmon = monitor_mod.selected_monitor;

    if (target_mon != selmon) {
        if (selmon) |sel| {
            unfocus_client(sel.sel, true, wm);
        }
        monitor_mod.selected_monitor = target_mon;
    } else if (client == null) {
        return;
    } else if (selmon) |sel| {
        if (client.? == sel.sel) {
            return;
        }
    }

    focus(client, wm);
}

fn handle_focus_in(event: *xlib.XFocusChangeEvent, wm: *WindowManager) void {
    const selmon = monitor_mod.selected_monitor orelse return;
    const selected = selmon.sel orelse return;
    if (event.window != selected.window) {
        set_focus(selected, wm);
    }
}

fn set_focus(client: *Client, wm: *WindowManager) void {
    if (!client.never_focus) {
        _ = xlib.XSetInputFocus(wm.display.handle, client.window, xlib.RevertToPointerRoot, xlib.CurrentTime);
        _ = xlib.XChangeProperty(wm.display.handle, wm.display.root, wm.atoms.net_active_window, xlib.XA_WINDOW, 32, xlib.PropModeReplace, @ptrCast(&client.window), 1);
    }
    _ = send_event(client, wm.atoms.wm_take_focus, wm);
}

fn handle_motion_notify(event: *xlib.XMotionEvent, wm: *WindowManager) void {
    if (event.window != wm.display.root) return;

    const target_mon = monitor_mod.rect_to_monitor(event.x_root, event.y_root, 1, 1);
    if (target_mon != wm.last_motion_monitor and wm.last_motion_monitor != null) {
        if (monitor_mod.selected_monitor) |selmon| {
            unfocus_client(selmon.sel, true, wm);
        }
        monitor_mod.selected_monitor = target_mon;
        focus(null, wm);
    }
    wm.last_motion_monitor = target_mon;
}

fn handle_property_notify(event: *xlib.XPropertyEvent, wm: *WindowManager) void {
    if (event.state == xlib.PropertyDelete) {
        return;
    }

    const client = client_mod.window_to_client(monitor_mod.monitors, event.window) orelse return;

    if (event.atom == xlib.XA_WM_TRANSIENT_FOR) {
        var trans: xlib.Window = 0;
        if (!client.is_floating and xlib.XGetTransientForHint(wm.display.handle, client.window, &trans) != 0) {
            client.is_floating = client_mod.window_to_client(monitor_mod.monitors, trans) != null;
            if (client.is_floating) {
                if (client.monitor) |monitor| {
                    arrange(monitor, wm);
                }
            }
        }
    } else if (event.atom == xlib.XA_WM_NORMAL_HINTS) {
        client.hints_valid = false;
    } else if (event.atom == xlib.XA_WM_HINTS) {
        update_wm_hints(client, wm);
        wm.invalidate_bars();
    } else if (event.atom == xlib.XA_WM_NAME or event.atom == wm.atoms.net_wm_name) {
        update_title(client, wm);
    } else if (event.atom == wm.atoms.net_wm_window_type) {
        update_window_type(client, wm);
    }
}

fn unfocus_client(client: ?*Client, reset_input_focus: bool, wm: *WindowManager) void {
    const unfocus_target = client orelse return;
    grabbuttons(unfocus_target, false, wm);
    _ = xlib.XSetWindowBorder(wm.display.handle, unfocus_target.window, wm.config.border_unfocused);
    if (reset_input_focus) {
        _ = xlib.XSetInputFocus(wm.display.handle, wm.display.root, xlib.RevertToPointerRoot, xlib.CurrentTime);
        _ = xlib.XDeleteProperty(wm.display.handle, wm.display.root, wm.atoms.net_active_window);
    }
}

fn set_client_state(client: *Client, state: c_long, wm: *WindowManager) void {
    var data: [2]c_long = .{ state, xlib.None };
    _ = xlib.c.XChangeProperty(wm.display.handle, client.window, wm.atoms.wm_state, xlib.XA_ATOM, 32, xlib.PropModeReplace, @ptrCast(&data), 2);
}

fn grabbuttons(client: *Client, focused: bool, wm: *WindowManager) void {
    wm.update_numlock_mask();
    const modifiers = [_]c_uint{ 0, xlib.LockMask, wm.numlock_mask, wm.numlock_mask | xlib.LockMask };

    _ = xlib.XUngrabButton(wm.display.handle, xlib.AnyButton, xlib.AnyModifier, client.window);
    if (!focused) {
        _ = xlib.XGrabButton(
            wm.display.handle,
            xlib.AnyButton,
            xlib.AnyModifier,
            client.window,
            xlib.False,
            xlib.ButtonPressMask | xlib.ButtonReleaseMask,
            xlib.GrabModeSync,
            xlib.GrabModeSync,
            xlib.None,
            xlib.None,
        );
    }
    for (wm.config.buttons.items) |button| {
        if (button.click == .client_win) {
            for (modifiers) |modifier| {
                _ = xlib.XGrabButton(
                    wm.display.handle,
                    @intCast(button.button),
                    button.mod_mask | modifier,
                    client.window,
                    xlib.False,
                    xlib.ButtonPressMask | xlib.ButtonReleaseMask,
                    xlib.GrabModeAsync,
                    xlib.GrabModeSync,
                    xlib.None,
                    xlib.None,
                );
            }
        }
    }
}

fn focus(target_client: ?*Client, wm: *WindowManager) void {
    const selmon = monitor_mod.selected_monitor orelse return;

    var focus_client = target_client;
    if (focus_client == null or !client_mod.is_visible(focus_client.?)) {
        focus_client = selmon.stack;
        while (focus_client) |iter| {
            if (client_mod.is_visible(iter)) break;
            focus_client = iter.stack_next;
        }
    }

    if (selmon.sel != null and selmon.sel != focus_client) {
        unfocus_client(selmon.sel, false, wm);
    }

    if (focus_client) |client| {
        if (client.monitor != selmon) {
            monitor_mod.selected_monitor = client.monitor;
        }
        if (client.is_urgent) {
            set_urgent(client, false, wm);
        }
        client_mod.detach_stack(client);
        client_mod.attach_stack(client);
        grabbuttons(client, true, wm);
        _ = xlib.XSetWindowBorder(wm.display.handle, client.window, wm.config.border_focused);
        if (!client.never_focus) {
            _ = xlib.XSetInputFocus(wm.display.handle, client.window, xlib.RevertToPointerRoot, xlib.CurrentTime);
            _ = xlib.XChangeProperty(wm.display.handle, wm.display.root, wm.atoms.net_active_window, xlib.XA_WINDOW, 32, xlib.PropModeReplace, @ptrCast(&client.window), 1);
        }
        _ = send_event(client, wm.atoms.wm_take_focus, wm);
    } else {
        _ = xlib.XSetInputFocus(wm.display.handle, wm.display.root, xlib.RevertToPointerRoot, xlib.CurrentTime);
        _ = xlib.XDeleteProperty(wm.display.handle, wm.display.root, wm.atoms.net_active_window);
    }

    const current_selmon = monitor_mod.selected_monitor orelse return;
    current_selmon.sel = focus_client;

    if (focus_client) |client| {
        if (is_scrolling_layout(current_selmon)) {
            scroll_to_window(client, true, wm);
        }
    }

    wm.invalidate_bars();
}

fn restack(monitor: *Monitor, wm: *WindowManager) void {
    wm.invalidate_bars();
    const selected_client = monitor.sel orelse return;

    if (selected_client.is_floating or monitor.lt[monitor.sel_lt] == null) {
        _ = xlib.XRaiseWindow(wm.display.handle, selected_client.window);
    }

    if (monitor.lt[monitor.sel_lt] != null) {
        var window_changes: xlib.c.XWindowChanges = undefined;
        window_changes.stack_mode = xlib.c.Below;
        window_changes.sibling = monitor.bar_win;

        var current = monitor.stack;
        while (current) |client| {
            if (!client.is_floating and client_mod.is_visible(client)) {
                _ = xlib.c.XConfigureWindow(wm.display.handle, client.window, xlib.c.CWSibling | xlib.c.CWStackMode, &window_changes);
                window_changes.sibling = client.window;
            }
            current = client.stack_next;
        }
    }

    _ = xlib.XSync(wm.display.handle, xlib.False);

    var discard_event: xlib.XEvent = undefined;
    while (xlib.c.XCheckMaskEvent(wm.display.handle, xlib.EnterWindowMask, &discard_event) != 0) {}
}

fn arrange(monitor: *Monitor, wm: *WindowManager) void {
    showhide(monitor, wm);
    if (monitor.lt[monitor.sel_lt]) |layout| {
        if (layout.arrange_fn) |arrange_fn| {
            arrange_fn(monitor);
        }
    }
    restack(monitor, wm);
}

fn tick_animations(wm: *WindowManager) void {
    if (!wm.scroll_animation.is_active()) return;

    const monitor = wm.selected_monitor orelse return;
    if (wm.scroll_animation.update()) |new_offset| {
        monitor.scroll_offset = new_offset;
        arrange(monitor, wm);
    }
}

fn is_scrolling_layout(monitor: *Monitor) bool {
    if (monitor.lt[monitor.sel_lt]) |layout| {
        return layout.arrange_fn == scrolling.layout.arrange_fn;
    }
    return false;
}

fn scroll_layout(direction: i32, wm: *WindowManager) void {
    const monitor = wm.selected_monitor orelse return;
    if (!is_scrolling_layout(monitor)) return;

    const scroll_step = scrolling.get_scroll_step(monitor);
    const max_scroll = scrolling.get_max_scroll(monitor);

    const current = if (wm.scroll_animation.is_active())
        wm.scroll_animation.target()
    else
        monitor.scroll_offset;

    var target = current + direction * scroll_step;
    target = @max(0, @min(target, max_scroll));

    wm.scroll_animation.start(monitor.scroll_offset, target, wm.animation_config);
}

fn scroll_to_window(client: *Client, animate: bool, wm: *WindowManager) void {
    const monitor = client.monitor orelse return;
    if (!is_scrolling_layout(monitor)) return;

    const target = scrolling.get_target_scroll_for_window(monitor, client);

    if (animate) {
        wm.scroll_animation.start(monitor.scroll_offset, target, wm.animation_config);
    } else {
        monitor.scroll_offset = target;
        arrange(monitor, wm);
    }
}

fn showhide_client(client: ?*Client, wm: *WindowManager) void {
    const target = client orelse return;
    if (client_mod.is_visible(target)) {
        _ = xlib.XMoveWindow(wm.display.handle, target.window, target.x, target.y);
        const monitor = target.monitor orelse return;
        if ((monitor.lt[monitor.sel_lt] == null or target.is_floating) and !target.is_fullscreen) {
            tiling.resize(target, target.x, target.y, target.width, target.height, false);
        }
        showhide_client(target.stack_next, wm);
    } else {
        showhide_client(target.stack_next, wm);
        const client_width = target.width + 2 * target.border_width;
        _ = xlib.XMoveWindow(wm.display.handle, target.window, -2 * client_width, target.y);
    }
}

fn showhide(monitor: *Monitor, wm: *WindowManager) void {
    showhide_client(monitor.stack, wm);
}

fn update_size_hints(client: *Client, wm: *WindowManager) void {
    var size_hints: xlib.XSizeHints = undefined;
    var msize: c_long = 0;

    if (xlib.XGetWMNormalHints(wm.display.handle, client.window, &size_hints, &msize) == 0) {
        size_hints.flags = xlib.PSize;
    }

    if ((size_hints.flags & xlib.PBaseSize) != 0) {
        client.base_width = size_hints.base_width;
        client.base_height = size_hints.base_height;
    } else if ((size_hints.flags & xlib.PMinSize) != 0) {
        client.base_width = size_hints.min_width;
        client.base_height = size_hints.min_height;
    } else {
        client.base_width = 0;
        client.base_height = 0;
    }

    if ((size_hints.flags & xlib.PResizeInc) != 0) {
        client.increment_width = size_hints.width_inc;
        client.increment_height = size_hints.height_inc;
    } else {
        client.increment_width = 0;
        client.increment_height = 0;
    }

    if ((size_hints.flags & xlib.PMaxSize) != 0) {
        client.max_width = size_hints.max_width;
        client.max_height = size_hints.max_height;
    } else {
        client.max_width = 0;
        client.max_height = 0;
    }

    if ((size_hints.flags & xlib.PMinSize) != 0) {
        client.min_width = size_hints.min_width;
        client.min_height = size_hints.min_height;
    } else if ((size_hints.flags & xlib.PBaseSize) != 0) {
        client.min_width = size_hints.base_width;
        client.min_height = size_hints.base_height;
    } else {
        client.min_width = 0;
        client.min_height = 0;
    }

    if ((size_hints.flags & xlib.PAspect) != 0) {
        client.min_aspect = @as(f32, @floatFromInt(size_hints.min_aspect.y)) / @as(f32, @floatFromInt(size_hints.min_aspect.x));
        client.max_aspect = @as(f32, @floatFromInt(size_hints.max_aspect.x)) / @as(f32, @floatFromInt(size_hints.max_aspect.y));
    } else {
        client.min_aspect = 0.0;
        client.max_aspect = 0.0;
    }

    client.is_fixed = (client.max_width != 0 and client.max_height != 0 and client.max_width == client.min_width and client.max_height == client.min_height);
    client.hints_valid = true;
}

fn update_wm_hints(client: *Client, wm: *WindowManager) void {
    const wmh = xlib.XGetWMHints(wm.display.handle, client.window);
    if (wmh) |hints| {
        defer _ = xlib.XFree(@ptrCast(hints));

        if (client == (monitor_mod.selected_monitor orelse return).sel and (hints.*.flags & xlib.XUrgencyHint) != 0) {
            hints.*.flags = hints.*.flags & ~@as(c_long, xlib.XUrgencyHint);
            _ = xlib.XSetWMHints(wm.display.handle, client.window, hints);
        } else {
            client.is_urgent = (hints.*.flags & xlib.XUrgencyHint) != 0;
        }

        if ((hints.*.flags & xlib.InputHint) != 0) {
            client.never_focus = hints.*.input == 0;
        } else {
            client.never_focus = false;
        }
    }
}

fn update_window_type(client: *Client, wm: *WindowManager) void {
    const state = get_atom_prop(client, wm.atoms.net_wm_state, wm);
    const window_type = get_atom_prop(client, wm.atoms.net_wm_window_type, wm);

    if (state == wm.atoms.net_wm_state_fullscreen) {
        set_fullscreen(client, true, wm);
    }
    if (window_type == wm.atoms.net_wm_window_type_dialog) {
        client.is_floating = true;
    }
}

fn update_title(client: *Client, wm: *WindowManager) void {
    if (!get_text_prop(client.window, wm.atoms.net_wm_name, &client.name, wm)) {
        _ = get_text_prop(client.window, xlib.XA_WM_NAME, &client.name, wm);
    }
    if (client.name[0] == 0) {
        @memcpy(client.name[0..6], "broken");
    }
}

fn get_atom_prop(client: *Client, prop: xlib.Atom, wm: *WindowManager) xlib.Atom {
    var actual_type: xlib.Atom = undefined;
    var actual_format: c_int = undefined;
    var num_items: c_ulong = undefined;
    var bytes_after: c_ulong = undefined;
    var prop_data: [*c]u8 = undefined;

    if (xlib.XGetWindowProperty(wm.display.handle, client.window, prop, 0, @sizeOf(xlib.Atom), xlib.False, xlib.XA_ATOM, &actual_type, &actual_format, &num_items, &bytes_after, &prop_data) == 0 and prop_data != null) {
        const atom: xlib.Atom = @as(*xlib.Atom, @ptrCast(@alignCast(prop_data))).*;
        _ = xlib.XFree(@ptrCast(prop_data));
        return atom;
    }
    return 0;
}

fn get_text_prop(window: xlib.Window, atom: xlib.Atom, text: *[256]u8, wm: *WindowManager) bool {
    var name: xlib.XTextProperty = undefined;
    text[0] = 0;

    if (xlib.XGetTextProperty(wm.display.handle, window, &name, atom) == 0 or name.nitems == 0) {
        return false;
    }

    if (name.encoding == xlib.XA_STRING) {
        const len = @min(name.nitems, 255);
        @memcpy(text[0..len], name.value[0..len]);
        text[len] = 0;
    } else {
        var list: [*c][*c]u8 = undefined;
        var count: c_int = undefined;
        if (xlib.XmbTextPropertyToTextList(wm.display.handle, &name, &list, &count) >= xlib.Success and count > 0 and list[0] != null) {
            const str = std.mem.sliceTo(list[0], 0);
            const copy_len = @min(str.len, 255);
            @memcpy(text[0..copy_len], str[0..copy_len]);
            text[copy_len] = 0;
            xlib.XFreeStringList(list);
        }
    }
    text[255] = 0;
    _ = xlib.XFree(@ptrCast(name.value));
    return true;
}

fn apply_rules(client: *Client, wm: *WindowManager) void {
    var class_hint: xlib.XClassHint = .{ .res_name = null, .res_class = null };
    _ = xlib.XGetClassHint(wm.display.handle, client.window, &class_hint);

    const class_str: []const u8 = if (class_hint.res_class) |ptr| std.mem.sliceTo(ptr, 0) else "";
    const instance_str: []const u8 = if (class_hint.res_name) |ptr| std.mem.sliceTo(ptr, 0) else "";

    client.is_floating = false;
    client.tags = 0;
    var rule_focus = false;

    for (wm.config.rules.items) |rule| {
        const class_matches = if (rule.class) |rc| std.mem.indexOf(u8, class_str, rc) != null else true;
        const instance_matches = if (rule.instance) |ri| std.mem.indexOf(u8, instance_str, ri) != null else true;
        const title_matches = if (rule.title) |rt| std.mem.indexOf(u8, std.mem.sliceTo(&client.name, 0), rt) != null else true;

        if (class_matches and instance_matches and title_matches) {
            client.is_floating = rule.is_floating;
            client.tags |= rule.tags;
            if (rule.monitor >= 0) {
                var target = monitor_mod.monitors;
                var index: i32 = 0;
                while (target) |mon| {
                    if (index == rule.monitor) {
                        client.monitor = mon;
                        break;
                    }
                    index += 1;
                    target = mon.next;
                }
            }
            if (rule.focus) {
                rule_focus = true;
            }
        }
    }

    if (class_hint.res_class) |ptr| {
        _ = xlib.XFree(@ptrCast(ptr));
    }
    if (class_hint.res_name) |ptr| {
        _ = xlib.XFree(@ptrCast(ptr));
    }

    const monitor = client.monitor orelse return;
    if (client.tags == 0) {
        client.tags = monitor.tagset[monitor.sel_tags];
    }

    if (rule_focus and client.tags != 0) {
        const monitor_tagset = monitor.tagset[monitor.sel_tags];
        const is_tag_focused = (monitor_tagset & client.tags) == client.tags;
        if (!is_tag_focused) {
            view(client.tags, wm);
        }
    }
}

fn update_client_list(wm: *WindowManager) void {
    _ = xlib.XDeleteProperty(wm.display.handle, wm.display.root, wm.atoms.net_client_list);

    var current_monitor = monitor_mod.monitors;
    while (current_monitor) |monitor| {
        var current_client = monitor.clients;
        while (current_client) |client| {
            _ = xlib.XChangeProperty(wm.display.handle, wm.display.root, wm.atoms.net_client_list, xlib.XA_WINDOW, 32, xlib.PropModeAppend, @ptrCast(&client.window), 1);
            current_client = client.next;
        }
        current_monitor = monitor.next;
    }
}

fn send_event(client: *Client, protocol: xlib.Atom, wm: *WindowManager) bool {
    var protocols: [*c]xlib.Atom = undefined;
    var num_protocols: c_int = 0;
    var exists = false;

    if (xlib.XGetWMProtocols(wm.display.handle, client.window, &protocols, &num_protocols) != 0) {
        var index: usize = 0;
        while (index < @as(usize, @intCast(num_protocols))) : (index += 1) {
            if (protocols[index] == protocol) {
                exists = true;
                break;
            }
        }
        _ = xlib.XFree(@ptrCast(protocols));
    }

    if (exists) {
        var event: xlib.XEvent = undefined;
        event.type = xlib.ClientMessage;
        event.xclient.window = client.window;
        event.xclient.message_type = wm.atoms.wm_protocols;
        event.xclient.format = 32;
        event.xclient.data.l[0] = @intCast(protocol);
        event.xclient.data.l[1] = xlib.CurrentTime;
        _ = xlib.XSendEvent(wm.display.handle, client.window, xlib.False, xlib.NoEventMask, &event);
    }
    return exists;
}

fn set_urgent(client: *Client, urgent: bool, wm: *WindowManager) void {
    client.is_urgent = urgent;
    const wmh = xlib.XGetWMHints(wm.display.handle, client.window);
    if (wmh) |hints| {
        if (urgent) {
            hints.*.flags = hints.*.flags | xlib.XUrgencyHint;
        } else {
            hints.*.flags = hints.*.flags & ~@as(c_long, xlib.XUrgencyHint);
        }
        _ = xlib.XSetWMHints(wm.display.handle, client.window, hints);
        _ = xlib.XFree(@ptrCast(hints));
    }
}

fn run_autostart_commands(_: std.mem.Allocator, commands: []const []const u8) !void {
    for (commands) |cmd| spawn_command(cmd);
}

test {
    _ = @import("x11/events.zig");
}
