const std = @import("std");
const xlib = @import("../x11/xlib.zig");
const config = @import("../config/config.zig");

pub const max_chord_len: u8 = 4;
/// How long (in milliseconds) the user has between key presses within
/// a chord before the sequence is abandoned and state is reset.
pub const timeout_ms: i64 = 1000;

/// Tracks the in-progress key-chord sequence.
///
/// Owned by `WindowManager`. Call `update` on every key press; it returns
/// whether the sequence is still live. Call `reset` to abandon the
/// current sequence and release the keyboard grab if one is held.
pub const ChordState = struct {
    keys: [max_chord_len]config.KeyPress = .{config.KeyPress{}} ** max_chord_len,
    index: u8 = 0,
    last_timestamp: i64 = 0,
    keyboard_grabbed: bool = false,

    /// Push a new key press onto the sequence and update the timestamp.
    ///
    /// Returns `false` if the sequence is already at maximum length, in which
    /// case the caller should call `reset` before retrying.
    pub fn push(self: *ChordState, key: config.KeyPress) bool {
        if (self.index >= max_chord_len) return false;
        self.keys[self.index] = key;
        self.index += 1;
        self.last_timestamp = std.time.milliTimestamp();

        return true;
    }

    /// Returns true if the sequence has timed out and should be reset.
    pub fn isTimedOut(self: *const ChordState) bool {
        if (self.index == 0) return false;
        return (std.time.milliTimestamp() - self.last_timestamp) >= timeout_ms;
    }

    /// Clears the sequence and releases the keyboard grab if one is held.
    ///
    /// `display` may be null only during early startup before the connection
    /// is open, in normal operation it should always be provided.
    pub fn reset(self: *ChordState, display: ?*xlib.Display) void {
        self.keys = .{config.KeyPress{}} ** max_chord_len;
        self.index = 0;
        self.last_timestamp = 0;

        if (self.keyboard_grabbed) {
            if (display) |dpy| {
                _ = xlib.XUngrabKeyboard(dpy, xlib.CurrentTime);
            }
            self.keyboard_grabbed = false;
        }
    }

    /// Try to grab the keyboard for exclusive input during a partial match.
    ///
    /// Sets `keyboard_grabbed` on success.  Safe to call repeatedly,
    /// does nothing if already grabbed.
    pub fn grabKeyboard(self: *ChordState, display: *xlib.Display, root: xlib.Window) void {
        if (self.keyboard_grabbed) return;

        const result = xlib.XGrabKeyboard(display, root, xlib.True, xlib.GrabModeAsync, xlib.GrabModeAsync, xlib.CurrentTime);
        if (result == xlib.GrabSuccess) {
            self.keyboard_grabbed = true;
        }
    }
};
