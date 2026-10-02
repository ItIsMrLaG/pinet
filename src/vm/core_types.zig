//! TODO:(kogora)
const std = @import("std");

pub const CoreMode = enum { singleThread, multiThread };
pub const CoreRole = enum { master, slave };

pub const CtrlSig = enum(u8) {
    kill_sig = 0,
    stop_sig = 1,
    exec_sig = 2,
};

pub const CoreRc = enum(u8) {
    Err = 1,
};

pub const Error = error{
    NotSupported,
};

pub const CoreId = union(CoreRole) {
    master: void,
    slave: u32,
};

pub const ActTimer = struct {
    is_start: bool = false,
    need: bool,

    max_ms: i64,
    io: std.Io,
    start_ts: std.Io.Timestamp = .zero,

    pub fn init(timout_opt: ?i64, io: std.Io) ActTimer {
        return if (timout_opt) |timout|
            .{ .need = true, .max_ms = timout, .io = io }
        else
            .{ .need = false, .max_ms = 0, .io = io };
    }

    pub fn start(self: *ActTimer) void {
        self.is_start = true;
        self.start_ts = std.Io.Clock.awake.now(self.io);
    }

    pub fn stop(self: *ActTimer) void {
        self.is_start = false;
        self.start_ts = .zero;
    }

    pub fn reset(self: *ActTimer) void {
        self.stop();
        self.start();
    }

    pub fn is_timeout(self: *ActTimer) bool {
        if (!self.need) {
            return false;
        }

        const now = std.Io.Clock.awake.now(self.io);
        const elapsed_ms = self.start_ts.durationTo(now).toMilliseconds();

        return elapsed_ms > self.max_ms;
    }
};
