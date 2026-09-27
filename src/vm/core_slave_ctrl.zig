//! TODO:(kogora)
const std = @import("std");
pub const CoreSlaveCh = @import("core_slave_channel.zig");
const CoreAction = @import("core_types.zig").CoreAction;

const Self = @This();

state: State,
vm_ch: *CoreSlaveCh,

pub fn init(ch: *CoreSlaveCh) Self {
    return .{ .self = State.newborn, .vm_ch = ch };
}

const State = enum(u64) {
    newborn,
    applicant,
    worker,
    goner,
    corpse,

    pub fn switchState(
        curState: State,
        needDie: bool,
        needWork: bool,
        wantWait: bool,
    ) !State {
        if (needDie) {
            return switch (curState) {
                .applicant, .worker => .goner,
                else => error.Unexpected,
            };
        }

        if (needWork) {
            return switch (curState) {
                .applicant, .worker => .worker,
                else => error.Unexpected,
            };
        }

        if (wantWait) {
            return switch (curState) {
                .applicant, .worker => .applicant,
                else => error.Unexpected,
            };
        }

        return switch (curState) {
            .newborn => .applicant,
            .goner => .corpse,
            else => curState,
        };
    }
};
