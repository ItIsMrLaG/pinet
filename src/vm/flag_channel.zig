//! Lock-free single-slot flag channel used to hand messages between a master
//! Core and a slave Core without either side ever taking a lock. Callers
//! wanting several independent channels hold an array of `FlagCh(T)`.
const std = @import("std");

const CtrlSig = @import("core_types.zig").CtrlSig;

pub const CtrlCh = FlagCh(CtrlSig);

// FIX:(kogora):
// - master shouldnt answer the slave if slave send signal (master always clear state)
// - that should be effective

/// Each slot packs a small protocol state machine into the low
/// `control_bits` bits of a u32, and the caller's own flag payload `T`
/// (e.g. FlagChType) into the remaining high bits.
fn FlagCh(comptime T: type) type {
    if (@typeInfo(T) != .@"enum") {
        @compileError("FlagCh(T): T must be an enum");
    }

    return struct {
        const Self = @This();
        const Flag = std.atomic.Value(u32);
        const init_value: u32 = 0;
        f: Flag align(std.atomic.cache_line) = Flag.init(init_value),

        pub const State = enum { empty, flagged, received, processed, denied };
        const Mode = enum { master, slave, none };

        /// b_flagged, b_received, b_processed, b_denied, b_slave_mode.
        const control_bits = 5;
        const payload_bits = 32 - control_bits;

        comptime {
            if (@bitSizeOf(T) > payload_bits) {
                @compileError("FlagCh(T): T's tag type doesn't fit in the value bits");
            }
        }

        const Bit = enum(u8) {
            b_flagged = 0,
            b_received = 1,
            b_processed = 2,
            b_denied = 3,
            b_slave_mode = 4,

            fn mask(comptime bit: Bit) u32 {
                return 1 << @intFromEnum(bit);
            }

            const m_flagged: u32 = Bit.b_flagged.mask();
            const m_received: u32 = Bit.b_received.mask() | m_flagged;
            const m_processed: u32 = Bit.b_processed.mask() | m_received;
            const m_denied: u32 = Bit.b_denied.mask() | m_received;

            const m_slave_mode: u32 = Bit.b_slave_mode.mask();
            const m_state_mask: u32 = m_flagged | m_received | m_processed | m_denied;
            const m_control_mask: u32 = m_state_mask | m_slave_mode;
            const m_value_mask: u32 = ~m_control_mask;

            fn getMask(comptime state: State, comptime mode: Mode) u32 {
                const m: u32 = switch (state) {
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

            fn extractMode(val: u32) struct { Mode, u32 } {
                const new_val = val & m_state_mask;
                const mode: Mode = if (val & m_slave_mode != 0)
                    .slave
                else if (new_val & m_flagged != 0)
                    .master
                else
                    .none;

                return .{ mode, new_val };
            }

            fn maskToState(val: u32) State {
                return switch (val) {
                    init_value => .empty,
                    m_flagged => .flagged,
                    m_received => .received,
                    m_processed => .processed,
                    m_denied => .denied,
                    else => unreachable,
                };
            }

            fn packValue(value: T) u32 {
                return @as(u32, @intFromEnum(value)) << control_bits;
            }

            fn unpackValue(val: u32) T {
                const raw: std.meta.Tag(T) = @intCast(val >> control_bits);
                return @enumFromInt(raw);
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

                ch: *Self,

                /// Publishes a new message carrying `value`. Fails if the
                /// channel isn't empty.
                pub fn trySetFlag(self: *User, value: T) bool {
                    const val = Bit.getMask(.flagged, mode) | Bit.packValue(value);
                    const r = self.ch.f.cmpxchgStrong(init_value, val, .seq_cst, .seq_cst);
                    return r == null;
                }

                /// Acknowledges a message the peer flagged and returns its
                /// payload, or null if the channel isn't flagged by the
                /// peer. The mode recorded in the flag stays the peer's,
                /// so only the peer can later clear it.
                pub fn tryReceiveFlag(self: *User) ?T {
                    const flagged_ctrl = Bit.getMask(.flagged, peerMode(mode));

                    const cur = self.ch.f.load(.acquire);
                    if (cur & Bit.m_control_mask != flagged_ctrl) {
                        return null;
                    }

                    const value_bits = cur & Bit.m_value_mask;
                    const received_ctrl = Bit.getMask(.received, peerMode(mode));

                    const r = self.ch.f.cmpxchgStrong(cur, value_bits | received_ctrl, .seq_cst, .seq_cst);
                    if (r != null) {
                        return null;
                    }

                    return Bit.unpackValue(value_bits);
                }

                pub fn processedFlag(self: *User) !void {
                    try self.transitionReceivedTo(.processed);
                }

                pub fn deniedFlag(self: *User) !void {
                    try self.transitionReceivedTo(.denied);
                }

                fn transitionReceivedTo(self: *User, comptime state: State) !void {
                    const received_ctrl = Bit.getMask(.received, peerMode(mode));

                    const cur = self.ch.f.load(.acquire);
                    if (cur & Bit.m_control_mask != received_ctrl) {
                        @branchHint(.unlikely);
                        return error.Unexpected;
                    }

                    const value_bits = cur & Bit.m_value_mask;
                    const final_ctrl = Bit.getMask(state, peerMode(mode));

                    const r = self.ch.f.cmpxchgStrong(cur, value_bits | final_ctrl, .seq_cst, .seq_cst);
                    if (r != null) {
                        @branchHint(.unlikely);
                        return error.Unexpected;
                    }
                }

                /// Resets the channel back to empty. Only the side that
                /// originally flagged it may clear it, and only once it's
                /// no longer mid-flight (i.e. not `.received`).
                pub fn tryClearFlag(self: *User) !struct { bool, State } {
                    const cur = self.ch.f.load(.acquire);

                    if (cur == init_value) {
                        return .{ true, .empty };
                    }

                    const r = Bit.extractMode(cur);
                    const cur_mode = r[0];
                    const cur_state = Bit.maskToState(r[1]);

                    if (cur_mode != mode or cur_state == .received) {
                        return .{ false, cur_state };
                    }

                    const r1 = self.ch.f.cmpxchgStrong(cur, init_value, .seq_cst, .seq_cst);
                    if (r1 != null) {
                        @branchHint(.unlikely);
                        return error.Unexpected;
                    }

                    return .{ true, cur_state };
                }

                pub fn readFlag(self: *User) struct { Mode, State, T } {
                    const cur = self.ch.f.load(.acquire);

                    const r = Bit.extractMode(cur);
                    const value_bits = cur & Bit.m_value_mask;
                    return .{ r[0], Bit.maskToState(r[1]), Bit.unpackValue(value_bits) };
                }
            };
        }

        pub const Master = ChUser(.master);
        pub const Slave = ChUser(.slave);

        pub fn create(gpa: std.mem.Allocator) !*Self {
            const self = try gpa.create(Self);
            self.* = .{};
            return self;
        }

        pub fn destroy(self: *Self, gpa: std.mem.Allocator) void {
            gpa.destroy(self);
        }

        pub fn getMaster(self: *Self) Master {
            return .{ .ch = self };
        }

        pub fn getSlave(self: *Self) Slave {
            return .{ .ch = self };
        }
    };
}

const testing = std.testing;
pub const TestCtrlSig = enum(u8) {
    kill_ch = 0,
    stop_ch = 1,
    exec_ch = 2,
};
const TestCh = FlagCh(TestCtrlSig);

test "create initializes all flags to empty" {
    const ch = try TestCh.create(testing.allocator);
    defer ch.destroy(testing.allocator);

    var master = ch.getMaster();
    const r = master.readFlag();
    try testing.expectEqual(TestCh.State.empty, r[1]);
}

test "master flags, slave receives and processes, master clears" {
    const ch = try TestCh.create(testing.allocator);
    defer ch.destroy(testing.allocator);

    var master = ch.getMaster();
    var slave = ch.getSlave();

    try testing.expect(master.trySetFlag(.exec_ch));

    {
        const r = slave.readFlag();
        try testing.expectEqual(.master, r[0]);
        try testing.expectEqual(.flagged, r[1]);
        try testing.expectEqual(.exec_ch, r[2]);
    }

    const received = slave.tryReceiveFlag();
    try testing.expectEqual(.exec_ch, received.?);
    try testing.expectEqual(.received, slave.readFlag()[1]);

    try slave.processedFlag();
    try testing.expectEqual(.processed, master.readFlag()[1]);
    try testing.expectEqual(.exec_ch, master.readFlag()[2]);

    const cleared = try master.tryClearFlag();
    try testing.expect(cleared[0]);
    try testing.expectEqual(.processed, cleared[1]);
    try testing.expectEqual(.empty, master.readFlag()[1]);
}

test "slave can deny a received message" {
    const ch = try TestCh.create(testing.allocator);
    defer ch.destroy(testing.allocator);

    var master = ch.getMaster();
    var slave = ch.getSlave();

    try testing.expect(master.trySetFlag(.kill_ch));
    try testing.expectEqual(.kill_ch, slave.tryReceiveFlag().?);
    try slave.deniedFlag();

    try testing.expectEqual(.denied, master.readFlag()[1]);

    const cleared = try master.tryClearFlag();
    try testing.expect(cleared[0]);
    try testing.expectEqual(.denied, cleared[1]);
}

test "trySetFlag fails when slot already flagged" {
    const ch = try TestCh.create(testing.allocator);
    defer ch.destroy(testing.allocator);

    var master = ch.getMaster();
    var other_master = ch.getMaster();

    try testing.expect(master.trySetFlag(.exec_ch));
    try testing.expect(!other_master.trySetFlag(.stop_ch));
}

test "tryReceiveFlag fails on empty or already-received slot" {
    const ch = try TestCh.create(testing.allocator);
    defer ch.destroy(testing.allocator);

    var master = ch.getMaster();
    var slave = ch.getSlave();

    try testing.expectEqual(null, slave.tryReceiveFlag());

    try testing.expect(master.trySetFlag(.stop_ch));
    try testing.expectEqual(.stop_ch, slave.tryReceiveFlag().?);
    try testing.expectEqual(null, slave.tryReceiveFlag());
}

test "slave cannot clear a flag it did not set" {
    const ch = try TestCh.create(testing.allocator);
    defer ch.destroy(testing.allocator);

    var master = ch.getMaster();
    var slave = ch.getSlave();

    try testing.expect(master.trySetFlag(.exec_ch));

    const r = try slave.tryClearFlag();
    try testing.expect(!r[0]);
    try testing.expectEqual(.flagged, r[1]);
}

test "master cannot clear a flag that is mid-flight (received)" {
    const ch = try TestCh.create(testing.allocator);
    defer ch.destroy(testing.allocator);

    var master = ch.getMaster();
    var slave = ch.getSlave();

    try testing.expect(master.trySetFlag(.exec_ch));
    _ = slave.tryReceiveFlag();

    const r = try master.tryClearFlag();
    try testing.expect(!r[0]);
    try testing.expectEqual(.received, r[1]);
}

test "master can cancel its own flagged (not yet received) message" {
    const ch = try TestCh.create(testing.allocator);
    defer ch.destroy(testing.allocator);

    var master = ch.getMaster();

    try testing.expect(master.trySetFlag(.exec_ch));

    const r = try master.tryClearFlag();
    try testing.expect(r[0]);
    try testing.expectEqual(.flagged, r[1]);
    try testing.expectEqual(.empty, master.readFlag()[1]);
}

test "master and slave flags on separate channels are independent" {
    const ch0 = try TestCh.create(testing.allocator);
    defer ch0.destroy(testing.allocator);
    const ch1 = try TestCh.create(testing.allocator);
    defer ch1.destroy(testing.allocator);

    var master0 = ch0.getMaster();
    var slave0 = ch0.getSlave();
    var master1 = ch1.getMaster();
    var slave1 = ch1.getSlave();

    try testing.expect(master0.trySetFlag(.exec_ch));
    try testing.expect(slave1.trySetFlag(.stop_ch));

    {
        const r0 = master0.readFlag();
        try testing.expectEqual(.master, r0[0]);
        try testing.expectEqual(.flagged, r0[1]);
        try testing.expectEqual(.exec_ch, r0[2]);

        const r1 = master1.readFlag();
        try testing.expectEqual(.slave, r1[0]);
        try testing.expectEqual(.flagged, r1[1]);
        try testing.expectEqual(.stop_ch, r1[2]);
    }

    try testing.expectEqual(.exec_ch, slave0.tryReceiveFlag().?);
    try testing.expectEqual(.stop_ch, master1.tryReceiveFlag().?);

    try testing.expectEqual(.received, slave0.readFlag()[1]);
    try testing.expectEqual(.received, master1.readFlag()[1]);
}

test "processedFlag and deniedFlag preserve the original payload" {
    const ch0 = try TestCh.create(testing.allocator);
    defer ch0.destroy(testing.allocator);
    const ch1 = try TestCh.create(testing.allocator);
    defer ch1.destroy(testing.allocator);

    var master0 = ch0.getMaster();
    var slave0 = ch0.getSlave();
    var master1 = ch1.getMaster();
    var slave1 = ch1.getSlave();

    try testing.expect(master0.trySetFlag(.kill_ch));
    _ = slave0.tryReceiveFlag();
    try slave0.processedFlag();
    try testing.expectEqual(.kill_ch, master0.readFlag()[2]);

    try testing.expect(master1.trySetFlag(.exec_ch));
    _ = slave1.tryReceiveFlag();
    try slave1.deniedFlag();
    try testing.expectEqual(.exec_ch, master1.readFlag()[2]);
}

test "flags are cache-line aligned to avoid false sharing" {
    const chs = try testing.allocator.alloc(TestCh, 8);
    defer testing.allocator.free(chs);

    for (chs) |*ch| {
        try testing.expect(std.mem.isAligned(@intFromPtr(&ch.f), std.atomic.cache_line));
    }
}
