const std = @import("std");

const CoreMode = @import("core_types.zig").CoreMode;
const CoreId = @import("core_types.zig").CoreId;
const CoreRc = @import("core_types.zig").CoreRc;
const CoreRole = @import("core_types.zig").CoreRole;
const CtrlSig = @import("core_types.zig").CtrlSig;
const ActTimer = @import("core_types.zig").ActTimer;
const VmError = @import("core_types.zig").Error;

pub const VmCtxTypes = enum {
    observe,
    sent_event,
};

pub const VmCtxAction = union(enum) {
    observe: void,

    wait_answer: struct {
        sent_msg: Msg,
        timer: ActTimer,
    },

    need_send_msg: struct {
        msg: Msg,
        timer: ActTimer,
    },
};

pub const MsgType = enum {
    signal,
};

pub const Msg = union(enum) {
    signal: CtrlSig,
};

pub const EventType = enum {
    change_state,
};

pub const Event = union(EventType) {
    change_state: void,
};
