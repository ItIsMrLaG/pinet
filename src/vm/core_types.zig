//! TODO:(kogora)
const std = @import("std");

pub const CoreMode = enum { singleThread, multiThread };
pub const CoreRole = enum { master, slave };
pub const CoreAction = enum { noop, exec, ret };

pub const CoreRc = enum(u8) {
    /// The core finished execution normally.
    finishRc = 0,
    /// The core was stopped for some reason.
    stopRc,
};

pub const CoreId = union(CoreRole) {
    master: void,
    slave: u32,
};
