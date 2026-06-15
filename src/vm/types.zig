const std = @import("std");
const Heap = @import("../vm.zig").Heap;

const number_of_ports = 10;

pub const Ports = [number_of_ports]?Value;

pub const Agent = struct {
    id: Id,
    ports: Ports,
    pub const Id = u32;
    pub const Arity = u8;
};

pub const Name = struct {
    port: ?Value,

    // Unchaining is not used anywhere
    // As it brings instability
    pub fn unchain(name: *Name) void {
        var node = if ((name.port orelse return) == .name) name.port.?.name else return;
        while (node.port) |port| {
            if (port == .name) {
                Heap(Name).freeOne(node);
                node = port.name;
            } else break;
        }
        name.port = node.port;
        Heap(Name).freeOne(node);
    }

    pub fn is_open(name: *Name) bool {
        return if (name.port) |_| false else true;
    }
};

pub const Special = union(enum) {
    float: f32,
    integer: i32,

    pub fn coerceFloat(self: Special) f32 {
        switch (self) {
            .float => |float| return float,
            .integer => |integer| return @floatFromInt(integer),
        }
    }

    pub fn add(self: Special, other: Special) Special {
        if (self == .integer and other == .integer) {
            return .{ .integer = self.integer + other.integer };
        } else {
            return .{ .float = self.coerceFloat() + other.coerceFloat() };
        }
    }
    pub fn sub(self: Special, other: Special) Special {
        if (self == .integer and other == .integer) {
            return .{ .integer = self.integer - other.integer };
        } else {
            return .{ .float = self.coerceFloat() - other.coerceFloat() };
        }
    }
    pub fn mul(self: Special, other: Special) Special {
        if (self == .integer and other == .integer) {
            return .{ .integer = self.integer * other.integer };
        } else {
            return .{ .float = self.coerceFloat() * other.coerceFloat() };
        }
    }
    pub fn div(self: Special, other: Special) Special {
        if (self == .integer and other == .integer) {
            return .{ .integer = @divFloor(self.integer, other.integer) };
        } else {
            return .{ .float = self.coerceFloat() / other.coerceFloat() };
        }
    }

    pub fn eq(self: Special, other: Special) bool {
        if (self == .integer and other == .integer) {
            return self.integer == other.integer;
        } else {
            // no guarantees
            return self.coerceFloat() == other.coerceFloat();
        }
    }
    pub fn neq(self: Special, other: Special) bool {
        if (self == .integer and other == .integer) {
            return self.integer != other.integer;
        } else {
            // no guarantees
            return self.coerceFloat() != other.coerceFloat();
        }
    }

    pub fn less(self: Special, other: Special) bool {
        if (self == .integer and other == .integer) {
            return self.integer < other.integer;
        } else {
            return self.coerceFloat() < other.coerceFloat();
        }
    }
    pub fn leq(self: Special, other: Special) bool {
        if (self == .integer and other == .integer) {
            return self.integer <= other.integer;
        } else {
            return self.coerceFloat() <= other.coerceFloat();
        }
    }
    pub fn greater(self: Special, other: Special) bool {
        if (self == .integer and other == .integer) {
            return self.integer > other.integer;
        } else {
            return self.coerceFloat() > other.coerceFloat();
        }
    }
    pub fn geq(self: Special, other: Special) bool {
        if (self == .integer and other == .integer) {
            return self.integer >= other.integer;
        } else {
            return self.coerceFloat() >= other.coerceFloat();
        }
    }
};

pub const Value = union(enum) {
    name: *Name,
    agent: *Agent,

    // specials are special in the fact that they can not interact directly
    special: Special,

    pub fn unchain(val: Value) Value {
        switch (val) {
            .name => |name| {
                name.unchain();
                if (name.port) |port| {
                    Heap(Name).freeOne(name);
                    return .{ .agent = port.agent };
                }
                return val;
            },
            .agent => {
                return val;
            },
        }
    }

    pub fn unchainPtr(val: *Value) void {
        switch (val.*) {
            .name => |name| {
                name.unchain();
                if (name.port) |port| {
                    Heap(Name).freeOne(name);
                    val.* = .{ .agent = port.agent };
                }
            },
            .agent => {},
        }
    }
};

pub const Equation = struct {
    lhs: Value,
    rhs: Value,
};
