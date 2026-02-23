const std = @import("std");

const actions = @import("actions.zig");
const bar_mod = @import("../bar/bar.zig");
const client_mod = @import("../client.zig");
const core = @import("core.zig");
const tiling = @import("../layouts/tiling.zig");
const monitor_mod = @import("../monitor.zig");
const wm_mod = @import("wm.zig");
const events = @import("../x11/events.zig");
const xlib = @import("../x11/xlib.zig");

const WindowManager = wm_mod.WindowManager;

pub fn handle_event(event: *xlib.XEvent, wm: *WindowManager) void {
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
    if (client_mod.window_to_client(wm.monitors, event.window) != null) {
        return;
    }

    core.manage(event.window, &window_attributes, wm);
}

fn handle_configure_request(event: *xlib.XConfigureRequestEvent, wm: *WindowManager) void {
    const client = client_mod.window_to_client(wm.monitors, event.window);

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
                actions.execute_action(keybind.action, keybind.int_arg, keybind.str_arg, wm);
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

fn handle_expose(event: *xlib.XExposeEvent, wm: *WindowManager) void {
    if (event.count != 0) return;
    if (bar_mod.window_to_bar(wm.bars, event.window)) |bar| {
        bar.invalidate();
        bar.draw(wm.display.handle, wm.config);
    }
}

fn handle_button_press(event: *xlib.XButtonEvent, wm: *WindowManager) void {
    std.debug.print("button_press: window=0x{x} subwindow=0x{x}\n", .{ event.window, event.subwindow });

    const clicked_monitor = monitor_mod.window_to_monitor(wm.display.handle, wm.display.root, event.window);
    if (clicked_monitor) |monitor| {
        if (monitor != wm.selected_monitor) {
            if (wm.selected_monitor) |selmon| {
                core.unfocus_client(selmon.sel, true, wm);
            }
            wm.selected_monitor = monitor;
            core.focus(null, wm);
        }
    }

    if (bar_mod.window_to_bar(wm.bars, event.window)) |bar| {
        const clicked_tag = bar.handle_click(wm.display.handle, event.x, wm.config);
        if (clicked_tag) |tag_index| {
            const tag_mask: u32 = @as(u32, 1) << @intCast(tag_index);
            core.view(tag_mask, wm);
        }
        return;
    }

    const click_client = client_mod.window_to_client(wm.monitors, event.window);
    if (click_client) |found_client| {
        core.focus(found_client, wm);
        if (wm.selected_monitor) |selmon| {
            core.restack(selmon, wm);
        }
        _ = xlib.XAllowEvents(wm.display.handle, xlib.ReplayPointer, xlib.CurrentTime);
    }

    const clean_state = clean_mask(event.state, wm);
    for (wm.config.buttons.items) |button| {
        if (button.click != .client_win) continue;
        const button_clean_mask = clean_mask(button.mod_mask, wm);
        if (clean_state == button_clean_mask and event.button == button.button) {
            switch (button.action) {
                .move_mouse => actions.movemouse(wm),
                .resize_mouse => actions.resizemouse(wm),
                .toggle_floating => {
                    if (click_client) |found_client| {
                        found_client.is_floating = !found_client.is_floating;
                        if (wm.selected_monitor) |monitor| {
                            core.arrange(monitor, wm);
                        }
                    }
                },
            }
            return;
        }
    }
}

fn handle_client_message(event: *xlib.XClientMessageEvent, wm: *WindowManager) void {
    const client = client_mod.window_to_client(wm.monitors, event.window) orelse return;

    if (event.message_type == wm.atoms.net_wm_state) {
        const action = event.data.l[0];
        const first_property: xlib.Atom = @intCast(event.data.l[1]);
        const second_property: xlib.Atom = @intCast(event.data.l[2]);

        if (first_property == wm.atoms.net_wm_state_fullscreen or second_property == wm.atoms.net_wm_state_fullscreen) {
            const net_wm_state_remove = 0;
            const net_wm_state_add = 1;
            const net_wm_state_toggle = 2;

            if (action == net_wm_state_add) {
                core.set_fullscreen(client, true, wm);
            } else if (action == net_wm_state_remove) {
                core.set_fullscreen(client, false, wm);
            } else if (action == net_wm_state_toggle) {
                core.set_fullscreen(client, !client.is_fullscreen, wm);
            }
        }
    } else if (event.message_type == wm.atoms.net_active_window) {
        const selected = wm.selected_monitor orelse return;
        if (client != selected.sel and !client.is_urgent) {
            core.set_urgent(client, true, wm);
        }
    }
}

fn handle_destroy_notify(event: *xlib.XDestroyWindowEvent, wm: *WindowManager) void {
    const client = client_mod.window_to_client(wm.monitors, event.window) orelse return;
    std.debug.print("destroy_notify: window=0x{x}\n", .{event.window});
    core.unmanage(client, wm);
}

fn handle_unmap_notify(event: *xlib.XUnmapEvent, wm: *WindowManager) void {
    const client = client_mod.window_to_client(wm.monitors, event.window) orelse return;
    std.debug.print("unmap_notify: window=0x{x}\n", .{event.window});
    core.unmanage(client, wm);
}

fn handle_enter_notify(event: *xlib.XCrossingEvent, wm: *WindowManager) void {
    if ((event.mode != xlib.NotifyNormal or event.detail == xlib.NotifyInferior) and event.window != wm.display.root) {
        return;
    }

    const client = client_mod.window_to_client(wm.monitors, event.window);
    const target_mon = if (client) |c| c.monitor else monitor_mod.window_to_monitor(wm.display.handle, wm.display.root, event.window);
    const selmon = wm.selected_monitor;

    if (target_mon != selmon) {
        if (selmon) |sel| {
            core.unfocus_client(sel.sel, true, wm);
        }
        wm.selected_monitor = target_mon;
    } else if (client == null) {
        return;
    } else if (selmon) |sel| {
        if (client.? == sel.sel) {
            return;
        }
    }

    core.focus(client, wm);
}

fn handle_focus_in(event: *xlib.XFocusChangeEvent, wm: *WindowManager) void {
    const selmon = wm.selected_monitor orelse return;
    const selected = selmon.sel orelse return;
    if (event.window != selected.window) {
        core.set_focus(selected, wm);
    }
}

fn handle_motion_notify(event: *xlib.XMotionEvent, wm: *WindowManager) void {
    if (event.window != wm.display.root) return;

    const target_mon = monitor_mod.rect_to_monitor(event.x_root, event.y_root, 1, 1);
    if (target_mon != wm.last_motion_monitor and wm.last_motion_monitor != null) {
        if (wm.selected_monitor) |selmon| {
            core.unfocus_client(selmon.sel, true, wm);
        }
        wm.selected_monitor = target_mon;
        core.focus(null, wm);
    }
    wm.last_motion_monitor = target_mon;
}

fn handle_property_notify(event: *xlib.XPropertyEvent, wm: *WindowManager) void {
    if (event.state == xlib.PropertyDelete) {
        return;
    }

    const client = client_mod.window_to_client(wm.monitors, event.window) orelse return;

    if (event.atom == xlib.XA_WM_TRANSIENT_FOR) {
        var trans: xlib.Window = 0;
        if (!client.is_floating and xlib.XGetTransientForHint(wm.display.handle, client.window, &trans) != 0) {
            client.is_floating = client_mod.window_to_client(wm.monitors, trans) != null;
            if (client.is_floating) {
                if (client.monitor) |monitor| {
                    core.arrange(monitor, wm);
                }
            }
        }
    } else if (event.atom == xlib.XA_WM_NORMAL_HINTS) {
        client.hints_valid = false;
    } else if (event.atom == xlib.XA_WM_HINTS) {
        core.update_wm_hints(client, wm);
        wm.invalidate_bars();
    } else if (event.atom == xlib.XA_WM_NAME or event.atom == wm.atoms.net_wm_name) {
        core.update_title(client, wm);
    } else if (event.atom == wm.atoms.net_wm_window_type) {
        core.update_window_type(client, wm);
    }
}
