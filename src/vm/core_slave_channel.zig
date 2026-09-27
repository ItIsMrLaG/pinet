//! Lock-free per-index flag channel used to hand messages between a master
//! Core and a slave Core without either side ever taking a lock.
const std = @import("std");

pub const FlagCh = struct {
    const Flag = std.atomic.Value(u8);
    const init_value: u8 = 0;
    f: []align(std.atomic.cache_line) Flag,

    pub const State = enum { empty, flagged, received, processed, denied };
    const Mode = enum { master, slave, none };
    const Bit = enum(u8) {
        b_flagged = 0,
        b_received = 1,
        b_processed = 2,
        b_denied = 3,
        b_slave_mode = 4,

        const m_flagged: u8 = 1 << @intFromEnum(@This().b_flagged);
        const m_received: u8 = (1 << @intFromEnum(@This().b_received)) | m_flagged;
        const m_processed: u8 = (1 << @intFromEnum(@This().b_processed)) | m_received;
        const m_denied: u8 = (1 << @intFromEnum(@This().b_denied)) | m_received;

        const m_slave_mode: u8 = 1 << @intFromEnum(@This().b_slave_mode);
        const m_state_mask: u8 = m_flagged | m_received | m_processed | m_denied;

        fn getMask(comptime state: State, comptime mode: Mode) u8 {
            const m: u8 = switch (state) {
                .flagged => m_flagged,
                .received => m_received,
                .processed => m_processed,
                .denied => m_denied,
                .empty => unreachable,
            };

            return switch (mode) {
                .master => m,
                .slave => m_slave_mode | m,
                .none => unreachable,
            };
        }

        fn extractMode(val: u8) struct { Mode, u8 } {
            const new_val = val & m_state_mask;
            const mode: Mode = if (val & m_slave_mode != 0)
                .slave
            else if (new_val & m_flagged != 0)
                .master
            else
                .none;

            return .{ mode, new_val };
        }

        fn maskToState(val: u8) State {
            return switch (val) {
                init_value => .empty,
                m_flagged => .flagged,
                m_received => .received,
                m_processed => .processed,
                m_denied => .denied,
                else => unreachable,
            };
        }
    };

    fn peerMode(comptime mode: Mode) Mode {
        return switch (mode) {
            .master => .slave,
            .slave => .master,
            .none => unreachable,
        };
    }

    fn ChUser(comptime mode: Mode) type {
        return struct {
            const User = @This();

            ch: *FlagCh,

            /// Publishes a new message at idx. Fails if idx isn't empty.
            pub fn chTrySetFlag(self: *User, idx: usize) bool {
                const val = Bit.getMask(.flagged, mode);
                const r = self.ch.f[idx].cmpxchgStrong(init_value, val, .seq_cst, .seq_cst);
                return r == null;
            }

            /// Acknowledges a message the peer flagged at idx. Fails if idx
            /// isn't flagged by the peer. The mode recorded in the flag
            /// stays the peer's, so only the peer can later clear it.
            pub fn chTryReceiveFlag(self: *User, idx: usize) bool {
                const flagged_state = Bit.getMask(.flagged, peerMode(mode));
                const val = Bit.getMask(.received, peerMode(mode));

                const r = self.ch.f[idx].cmpxchgStrong(flagged_state, val, .seq_cst, .seq_cst);
                return r == null;
            }

            pub fn chProcessedFlag(self: *User, idx: usize) !void {
                const received_state = Bit.getMask(.received, peerMode(mode));
                const val = Bit.getMask(.processed, peerMode(mode));

                const r = self.ch.f[idx].cmpxchgStrong(received_state, val, .seq_cst, .seq_cst);
                if (r != null) {
                    @branchHint(.unlikely);
                    return error.Unexpected;
                }
            }

            pub fn chDeniedFlag(self: *User, idx: usize) !void {
                const received_state = Bit.getMask(.received, peerMode(mode));
                const val = Bit.getMask(.denied, peerMode(mode));

                const r = self.ch.f[idx].cmpxchgStrong(received_state, val, .seq_cst, .seq_cst);
                if (r != null) {
                    @branchHint(.unlikely);
                    return error.Unexpected;
                }
            }

            /// Resets idx back to empty. Only the side that originally
            /// flagged it may clear it, and only once it's no longer
            /// mid-flight (i.e. not `.received`).
            pub fn chTryClearFlag(self: *User, idx: usize) !struct { bool, State } {
                const cur = self.ch.f[idx].load(.acquire);

                if (cur == init_value) {
                    return .{ true, .empty };
                }

                const r = Bit.extractMode(cur);
                const cur_mode = r[0];
                const cur_state = Bit.maskToState(r[1]);

                if (cur_mode != mode or cur_state == .received) {
                    return .{ false, cur_state };
                }

                const r1 = self.ch.f[idx].cmpxchgStrong(cur, init_value, .seq_cst, .seq_cst);
                if (r1 != null) {
                    @branchHint(.unlikely);
                    return error.Unexpected;
                }

                return .{ true, cur_state };
            }

            pub fn chReadFlag(self: *User, idx: usize) struct { Mode, State } {
                const cur = self.ch.f[idx].load(.acquire);

                const r = Bit.extractMode(cur);
                return .{ r[0], Bit.maskToState(r[1]) };
            }
        };
    }

    pub const Master = ChUser(.master);
    pub const Slave = ChUser(.slave);

    pub fn create(gpa: std.mem.Allocator, len: usize) !*FlagCh {
        const self = try gpa.create(FlagCh);
        errdefer gpa.destroy(self);

        self.f = try gpa.alignedAlloc(Flag, .fromByteUnits(std.atomic.cache_line), len);
        for (self.f) |*flag| flag.* = Flag.init(init_value);

        return self;
    }

    pub fn destroy(self: *FlagCh, gpa: std.mem.Allocator) void {
        gpa.free(self.f);
        gpa.destroy(self);
    }

    pub fn getMaster(self: *FlagCh) Master {
        return .{ .ch = self };
    }

    pub fn getSlave(self: *FlagCh) Slave {
        return .{ .ch = self };
    }
};

const testing = std.testing;

test "create initializes all flags to empty" {
    const ch = try FlagCh.create(testing.allocator, 4);
    defer ch.destroy(testing.allocator);

    var master = ch.getMaster();
    for (0..4) |idx| {
        const r = master.chReadFlag(idx);
        try testing.expectEqual(FlagCh.State.empty, r[1]);
    }
}

test "master flags, slave receives and processes, master clears" {
    const ch = try FlagCh.create(testing.allocator, 1);
    defer ch.destroy(testing.allocator);

    var master = ch.getMaster();
    var slave = ch.getSlave();

    try testing.expect(master.chTrySetFlag(0));

    {
        const r = slave.chReadFlag(0);
        try testing.expectEqual(.master, r[0]);
        try testing.expectEqual(.flagged, r[1]);
    }

    try testing.expect(slave.chTryReceiveFlag(0));
    try testing.expectEqual(.received, slave.chReadFlag(0)[1]);

    try slave.chProcessedFlag(0);
    try testing.expectEqual(.processed, master.chReadFlag(0)[1]);

    const cleared = try master.chTryClearFlag(0);
    try testing.expect(cleared[0]);
    try testing.expectEqual(.processed, cleared[1]);
    try testing.expectEqual(.empty, master.chReadFlag(0)[1]);
}

test "slave can deny a received message" {
    const ch = try FlagCh.create(testing.allocator, 1);
    defer ch.destroy(testing.allocator);

    var master = ch.getMaster();
    var slave = ch.getSlave();

    try testing.expect(master.chTrySetFlag(0));
    try testing.expect(slave.chTryReceiveFlag(0));
    try slave.chDeniedFlag(0);

    try testing.expectEqual(.denied, master.chReadFlag(0)[1]);

    const cleared = try master.chTryClearFlag(0);
    try testing.expect(cleared[0]);
    try testing.expectEqual(.denied, cleared[1]);
}

test "chTrySetFlag fails when slot already flagged" {
    const ch = try FlagCh.create(testing.allocator, 1);
    defer ch.destroy(testing.allocator);

    var master = ch.getMaster();
    var other_master = ch.getMaster();

    try testing.expect(master.chTrySetFlag(0));
    try testing.expect(!other_master.chTrySetFlag(0));
}

test "chTryReceiveFlag fails on empty or already-received slot" {
    const ch = try FlagCh.create(testing.allocator, 1);
    defer ch.destroy(testing.allocator);

    var master = ch.getMaster();
    var slave = ch.getSlave();

    try testing.expect(!slave.chTryReceiveFlag(0));

    try testing.expect(master.chTrySetFlag(0));
    try testing.expect(slave.chTryReceiveFlag(0));
    try testing.expect(!slave.chTryReceiveFlag(0));
}

test "slave cannot clear a flag it did not set" {
    const ch = try FlagCh.create(testing.allocator, 1);
    defer ch.destroy(testing.allocator);

    var master = ch.getMaster();
    var slave = ch.getSlave();

    try testing.expect(master.chTrySetFlag(0));

    const r = try slave.chTryClearFlag(0);
    try testing.expect(!r[0]);
    try testing.expectEqual(.flagged, r[1]);
}

test "master cannot clear a flag that is mid-flight (received)" {
    const ch = try FlagCh.create(testing.allocator, 1);
    defer ch.destroy(testing.allocator);

    var master = ch.getMaster();
    var slave = ch.getSlave();

    try testing.expect(master.chTrySetFlag(0));
    try testing.expect(slave.chTryReceiveFlag(0));

    const r = try master.chTryClearFlag(0);
    try testing.expect(!r[0]);
    try testing.expectEqual(.received, r[1]);
}

test "master can cancel its own flagged (not yet received) message" {
    const ch = try FlagCh.create(testing.allocator, 1);
    defer ch.destroy(testing.allocator);

    var master = ch.getMaster();

    try testing.expect(master.chTrySetFlag(0));

    const r = try master.chTryClearFlag(0);
    try testing.expect(r[0]);
    try testing.expectEqual(.flagged, r[1]);
    try testing.expectEqual(.empty, master.chReadFlag(0)[1]);
}

test "master and slave flags on separate indices are independent" {
    const ch = try FlagCh.create(testing.allocator, 2);
    defer ch.destroy(testing.allocator);

    var master = ch.getMaster();
    var slave = ch.getSlave();

    try testing.expect(master.chTrySetFlag(0));
    try testing.expect(slave.chTrySetFlag(1));

    {
        const r0 = master.chReadFlag(0);
        try testing.expectEqual(.master, r0[0]);
        try testing.expectEqual(.flagged, r0[1]);

        const r1 = master.chReadFlag(1);
        try testing.expectEqual(.slave, r1[0]);
        try testing.expectEqual(.flagged, r1[1]);
    }

    try testing.expect(slave.chTryReceiveFlag(0));
    try testing.expect(master.chTryReceiveFlag(1));

    try testing.expectEqual(.received, slave.chReadFlag(0)[1]);
    try testing.expectEqual(.received, master.chReadFlag(1)[1]);
}

test "flags are cache-line aligned to avoid false sharing" {
    const ch = try FlagCh.create(testing.allocator, 8);
    defer ch.destroy(testing.allocator);

    try testing.expect(std.mem.isAligned(@intFromPtr(ch.f.ptr), std.atomic.cache_line));
}
