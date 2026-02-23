const std = @import("std");
const xlib = @import("x11/xlib.zig");
const config_mod = @import("config/config.zig");

const padding: i32 = 32;
const line_spacing: i32 = 12;
const key_action_spacing: i32 = 32;
const border_width: i32 = 4;
const border_color: c_ulong = 0x7fccff;
const bg_color: c_ulong = 0x1a1a1a;
const fg_color: c_ulong = 0xffffff;
const key_bg_color: c_ulong = 0x2a2a2a;

const max_lines: usize = 12;

pub const KeybindOverlay = struct {
    window: xlib.Window = 0,
    pixmap: xlib.Pixmap = 0,
    gc: xlib.GC = null,
    xft_draw: ?*xlib.XftDraw = null,
    font: ?*xlib.XftFont = null,
    font_height: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    visible: bool = false,
    display: ?*xlib.Display = null,
    root: xlib.Window = 0,
    screen: c_int = 0,

    key_bufs: [max_lines][64]u8 = undefined,
    key_lens: [max_lines]usize = undefined,
    descs: [max_lines][]const u8 = undefined,
    line_count: usize = 0,

    pub fn init(display: *xlib.Display, screen: c_int, root: xlib.Window, font_name: []const u8, allocator: std.mem.Allocator) ?*KeybindOverlay {
        const overlay = allocator.create(KeybindOverlay) catch return null;

        const font_name_z = allocator.dupeZ(u8, font_name) catch {
            allocator.destroy(overlay);
            return null;
        };
        defer allocator.free(font_name_z);

        const font = xlib.XftFontOpenName(display, screen, font_name_z);
        if (font == null) {
            allocator.destroy(overlay);
            return null;
        }

        const font_height = font.*.ascent + font.*.descent;

        overlay.* = .{
            .display = display,
            .root = root,
            .font = font,
            .font_height = font_height,
            .screen = screen,
        };

        return overlay;
    }

    pub fn deinit(self: *KeybindOverlay, allocator: std.mem.Allocator) void {
        if (self.display) |display| {
            self.destroyWindow(display);
            if (self.font) |font| {
                xlib.XftFontClose(display, font);
            }
        }
        allocator.destroy(self);
    }

    fn destroyWindow(self: *KeybindOverlay, display: *xlib.Display) void {
        if (self.xft_draw) |xft_draw| {
            xlib.XftDrawDestroy(xft_draw);
            self.xft_draw = null;
        }
        if (self.gc) |gc| {
            _ = xlib.XFreeGC(display, gc);
            self.gc = null;
        }
        if (self.pixmap != 0) {
            _ = xlib.XFreePixmap(display, self.pixmap);
            self.pixmap = 0;
        }
        if (self.window != 0) {
            _ = xlib.c.XDestroyWindow(display, self.window);
            self.window = 0;
        }
    }

    pub fn toggle(self: *KeybindOverlay, mon_x: i32, mon_y: i32, mon_w: i32, mon_h: i32, config: *config_mod.Config) void {
        if (self.visible) {
            self.hide();
        } else {
            self.show(mon_x, mon_y, mon_w, mon_h, config);
        }
    }

    pub fn show(self: *KeybindOverlay, mon_x: i32, mon_y: i32, mon_w: i32, mon_h: i32, config: *config_mod.Config) void {
        const display = self.display orelse return;

        self.collectKeybinds(config);
        if (self.line_count == 0) return;

        var max_key_width: i32 = 0;
        var max_desc_width: i32 = 0;

        for (0..self.line_count) |i| {
            const key_slice = self.key_bufs[i][0..self.key_lens[i]];
            const key_w = self.textWidth(display, key_slice);
            const desc_w = self.textWidth(display, self.descs[i]);
            if (key_w > max_key_width) max_key_width = key_w;
            if (desc_w > max_desc_width) max_desc_width = desc_w;
        }

        const title = "Keybindings";
        const title_width = self.textWidth(display, title);

        const content_width = max_key_width + key_action_spacing + max_desc_width;
        const min_width = @max(title_width, content_width);

        self.width = min_width + padding * 2;
        const line_height = self.font_height + line_spacing;
        const title_height = self.font_height + 20;
        self.height = title_height + @as(i32, @intCast(self.line_count)) * line_height + padding * 2;

        self.destroyWindow(display);

        const x: i32 = mon_x + @divTrunc(mon_w - self.width, 2);
        const y: i32 = mon_y + @divTrunc(mon_h - self.height, 2);

        const visual = xlib.XDefaultVisual(display, self.screen);
        const colormap = xlib.XDefaultColormap(display, self.screen);
        const depth = xlib.XDefaultDepth(display, self.screen);

        self.window = xlib.c.XCreateSimpleWindow(
            display,
            self.root,
            x,
            y,
            @intCast(self.width),
            @intCast(self.height),
            @intCast(border_width),
            border_color,
            bg_color,
        );

        var attrs: xlib.c.XSetWindowAttributes = undefined;
        attrs.override_redirect = xlib.True;
        attrs.event_mask = xlib.c.ExposureMask | xlib.c.KeyPressMask | xlib.c.ButtonPressMask;
        _ = xlib.c.XChangeWindowAttributes(display, self.window, xlib.c.CWOverrideRedirect | xlib.c.CWEventMask, &attrs);

        self.pixmap = xlib.XCreatePixmap(display, self.window, @intCast(self.width), @intCast(self.height), @intCast(depth));
        self.gc = xlib.XCreateGC(display, self.pixmap, 0, null);
        self.xft_draw = xlib.XftDrawCreate(display, self.pixmap, visual, colormap);

        _ = xlib.XMapWindow(display, self.window);
        _ = xlib.XRaiseWindow(display, self.window);

        self.draw(display, max_key_width, title);

        _ = xlib.XGrabKeyboard(display, self.window, xlib.True, xlib.GrabModeAsync, xlib.GrabModeAsync, xlib.CurrentTime);

        _ = xlib.XSync(display, xlib.False);

        self.visible = true;
    }

    pub fn hide(self: *KeybindOverlay) void {
        if (!self.visible) return;
        if (self.display) |display| {
            _ = xlib.XUngrabKeyboard(display, xlib.CurrentTime);
            if (self.window != 0) {
                _ = xlib.c.XUnmapWindow(display, self.window);
            }
        }
        self.visible = false;
    }

    pub fn handleKey(self: *KeybindOverlay, keysym: u64) bool {
        if (!self.visible) return false;
        if (keysym == 0xff1b or keysym == 'q' or keysym == 'Q') {
            self.hide();
            return true;
        }
        return false;
    }

    pub fn isOverlayWindow(self: *KeybindOverlay, win: xlib.Window) bool {
        return self.visible and self.window != 0 and self.window == win;
    }

    fn draw(self: *KeybindOverlay, display: *xlib.Display, max_key_width: i32, title: []const u8) void {
        self.fillRect(display, 0, 0, self.width, self.height, bg_color);

        const title_x = @divTrunc(self.width - self.textWidth(display, title), 2);
        const title_y = padding + self.font.?.*.ascent;
        self.drawText(display, title_x, title_y, title, fg_color);

        const line_height = self.font_height + line_spacing;
        var y = padding + self.font_height + 20 + self.font.?.*.ascent;

        for (0..self.line_count) |i| {
            const key_slice = self.key_bufs[i][0..self.key_lens[i]];
            const key_w = self.textWidth(display, key_slice);
            self.fillRect(display, padding - 4, y - self.font.?.*.ascent - 2, key_w + 8, self.font_height + 4, key_bg_color);
            self.drawText(display, padding, y, key_slice, fg_color);

            const desc_x = padding + max_key_width + key_action_spacing;
            self.drawText(display, desc_x, y, self.descs[i], fg_color);

            y += line_height;
        }

        _ = xlib.c.XCopyArea(display, self.pixmap, self.window, self.gc, 0, 0, @intCast(self.width), @intCast(self.height), 0, 0);
        _ = xlib.c.XFlush(display);
    }

    fn fillRect(self: *KeybindOverlay, display: *xlib.Display, x: i32, y: i32, w: i32, h: i32, color: c_ulong) void {
        _ = xlib.XSetForeground(display, self.gc, color);
        _ = xlib.XFillRectangle(display, self.pixmap, self.gc, x, y, @intCast(w), @intCast(h));
    }

    fn drawText(self: *KeybindOverlay, display: *xlib.Display, x: i32, y: i32, text: []const u8, color: c_ulong) void {
        if (self.xft_draw == null or self.font == null) return;
        if (text.len == 0) return;

        var xft_color: xlib.XftColor = undefined;
        var render_color: xlib.XRenderColor = undefined;
        render_color.red = @intCast((color >> 16 & 0xff) * 257);
        render_color.green = @intCast((color >> 8 & 0xff) * 257);
        render_color.blue = @intCast((color & 0xff) * 257);
        render_color.alpha = 0xffff;

        const visual = xlib.XDefaultVisual(display, self.screen);
        const colormap = xlib.XDefaultColormap(display, self.screen);

        _ = xlib.XftColorAllocValue(display, visual, colormap, &render_color, &xft_color);
        xlib.XftDrawStringUtf8(self.xft_draw, &xft_color, self.font, x, y, text.ptr, @intCast(text.len));
        xlib.XftColorFree(display, visual, colormap, &xft_color);
    }

    fn textWidth(self: *KeybindOverlay, display: *xlib.Display, text: []const u8) i32 {
        if (self.font == null or text.len == 0) return 0;
        var extents: xlib.XGlyphInfo = undefined;
        xlib.XftTextExtentsUtf8(display, self.font, text.ptr, @intCast(text.len), &extents);
        return extents.xOff;
    }

    fn collectKeybinds(self: *KeybindOverlay, cfg: *config_mod.Config) void {
        const priority_actions = [_]config_mod.Action{
            .show_keybinds,
            .quit,
            .reload_config,
            .kill_client,
            .spawn_terminal,
            .toggle_fullscreen,
            .toggle_floating,
            .cycle_layout,
            .focus_next,
            .focus_prev,
            .view_tag,
            .move_to_tag,
        };

        self.line_count = 0;

        for (priority_actions) |action| {
            if (self.line_count >= max_lines) break;

            for (cfg.keybinds.items) |kb| {
                if (kb.action == action and kb.key_count > 0) {
                    self.formatKeyToBuf(self.line_count, &kb.keys[0]);
                    self.descs[self.line_count] = actionDesc(action);
                    self.line_count += 1;
                    break;
                }
            }
        }
    }

    fn formatKeyToBuf(self: *KeybindOverlay, idx: usize, key: *const config_mod.KeyPress) void {
        var len: usize = 0;
        var buf = &self.key_bufs[idx];

        if (key.mod_mask & (1 << 6) != 0) {
            const s = "Mod + ";
            @memcpy(buf[len .. len + s.len], s);
            len += s.len;
        }
        if (key.mod_mask & (1 << 0) != 0) {
            const s = "Shift + ";
            @memcpy(buf[len .. len + s.len], s);
            len += s.len;
        }
        if (key.mod_mask & (1 << 2) != 0) {
            const s = "Ctrl + ";
            @memcpy(buf[len .. len + s.len], s);
            len += s.len;
        }

        const key_name = keysymToName(key.keysym);
        if (len + key_name.len < buf.len) {
            @memcpy(buf[len .. len + key_name.len], key_name);
            len += key_name.len;
        }

        self.key_lens[idx] = len;
    }

    fn keysymToName(keysym: u64) []const u8 {
        const upper_letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        const digits = "0123456789";

        return switch (keysym) {
            0xff0d => "Return",
            0x0020 => "Space",
            0xff1b => "Escape",
            0xff08 => "BackSpace",
            0xff09 => "Tab",
            0xffbe => "F1",
            0xffbf => "F2",
            0xffc0 => "F3",
            0xffc1 => "F4",
            0xffc2 => "F5",
            0xffc3 => "F6",
            0xffc4 => "F7",
            0xffc5 => "F8",
            0xffc6 => "F9",
            0xffc7 => "F10",
            0xffc8 => "F11",
            0xffc9 => "F12",
            0xff51 => "Left",
            0xff52 => "Up",
            0xff53 => "Right",
            0xff54 => "Down",
            0x002c => ",",
            0x002e => ".",
            0x002f => "/",
            'a'...'z' => |c| upper_letters[c - 'a' ..][0..1],
            'A'...'Z' => |c| upper_letters[c - 'A' ..][0..1],
            '0'...'9' => |c| digits[c - '0' ..][0..1],
            else => "?",
        };
    }

    fn actionDesc(action: config_mod.Action) []const u8 {
        return switch (action) {
            .show_keybinds => "Show Keybinds",
            .quit => "Quit WM",
            .reload_config => "Reload Config",
            .restart => "Restart WM",
            .kill_client => "Close Window",
            .spawn_terminal => "Open Terminal",
            .spawn => "Launch Program",
            .toggle_fullscreen => "Toggle Fullscreen",
            .toggle_floating => "Toggle Floating",
            .toggle_gaps => "Toggle Gaps",
            .cycle_layout => "Cycle Layout",
            .set_layout => "Set Layout",
            .focus_next => "Focus Next",
            .focus_prev => "Focus Previous",
            .move_next => "Move Next",
            .move_prev => "Move Previous",
            .view_tag => "View Tag",
            .move_to_tag => "Move to Tag",
            .focus_monitor => "Focus Monitor",
            .send_to_monitor => "Send to Monitor",
            else => "Action",
        };
    }
};
