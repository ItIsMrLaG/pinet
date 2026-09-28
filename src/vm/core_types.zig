//! TODO:(kogora)
const std = @import("std");

pub const CoreMode = enum { singleThread, multiThread };
pub const CoreRole = enum { master, slave };
pub const CoreAction = enum { noop, exec, ret };

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
