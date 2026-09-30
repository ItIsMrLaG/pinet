//! TODO:(kogora)
const std = @import("std");
pub const CtrlCh = @import("flag_channel.zig").CtrlCh;
pub const CtrlSig = @import("flag_channel.zig").CtrlSig;
const CoreRc = @import("core_types.zig").CoreRc;

const Self = @This();

const AtomicState = std.atomic.Value(State);

raw_state: AtomicState,
vm_ch: CtrlCh.Slave,

sig: ?CtrlSig = null,
sig_rc: ?CoreRc = null,

pub fn init(ch: CtrlCh.Slave) Self {
    return .{
        .raw_state = AtomicState.init(State.newborn),
        .vm_ch = ch,
    };
}

pub inline fn receiveSig(self: *Self) ?CtrlSig {
    self.sig = self.vm_ch.tryReceiveFlag();
    self.sig_rc = null;
    return self.sig;
}

pub inline fn responsSig(self: *Self) !void {
    if (self.sig == null)
        return;

    if (self.sig_rc == null) {
        try self.vm_ch.processedFlag();
    } else {
        try self.vm_ch.deniedFlag();
    }

    self.sig = null;
}

pub inline fn sendSig(self: *Self, sig: CtrlSig) void {
    _ = self.vm_ch.trySetFlag(sig);
}

pub inline fn putState(self: *Self, state: State) void {
    self.raw_state.store(state, .release);
}

pub inline fn getState(self: *Self) State {
    return self.raw_state.load(.acquire);
}

pub inline fn getStatePriv(self: *Self) State {
    return self.raw_state.load(.monotonic);
}

// FIX:(kogora) move to types
pub const State = enum(u8) {
    newborn,
    applicant,
    worker,
    goner,
    corpse,

    pub inline fn applicantState(self: State) State {
        std.debug.assert(self == .newborn or self == .applicant or self == .worker);
        return .applicant;
    }

    pub inline fn gonerState(self: State) State {
        std.debug.assert(self == .applicant or self == .worker);
        return .goner;
    }

    pub inline fn corpseState(self: State) State {
        std.debug.assert(self == .goner);
        return .corpse;
    }

    pub fn sigNextState(
        self: State,
        sig: CtrlSig,
    ) ?State {
        return switch (sig) {
            .kill_sig => switch (self) {
                .applicant, .worker => .goner,
                else => null,
            },
            .exec_sig => switch (self) {
                .applicant, .worker => .worker,
                else => null,
            },
            .stop_sig => switch (self) {
                .worker => .applicant,
                else => null,
            },
        };
    }
};
