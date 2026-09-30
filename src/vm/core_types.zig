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

pub const CoreId = union(CoreRole) {
    master: void,
    slave: u32,
};

const Policy = enum {
    // TODO:(kogora) add comments
    all,
    try_all,
    broudcast,

    fn need_next(comptime self: Policy, is_success: bool, timer: ActTimer) bool {
        return switch (self) {
            .all => is_success,
            .try_all => is_success or timer.is_timeout(),
            .broudcast => true,
        };
    }
};

const ActTimer = struct {
    need: bool,
    max_ms: i64,
    start_ms: i64 = 0,

    fn init(timout_opt: ?i64) ActTimer {
        return if (timout_opt) |timout|
            .{ .need = true, .max_ms = timout }
        else
            .{ .need = false, .max_ms = 0 };
    }

    fn start(self: *ActTimer) void {
        self.start_ms = std.time.milliTimestamp();
    }

    fn stop(self: *ActTimer) void {
        self.start_ms = 0;
    }

    fn reset(self: *ActTimer) void {
        self.stop();
        self.start();
    }

    fn is_timeout(self: *ActTimer) bool {
        // TODO:(kogora) is milliTimestamp() monotonic?
        const elapsed_ms: i64 = std.time.milliTimestamp() - self.start_ms;
        if (elapsed_ms > self.max_ms) {
            return false;
        }

        return true;
    }
};
