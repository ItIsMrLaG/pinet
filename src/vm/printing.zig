const std = @import("std");

const VM = @import("../vm.zig");
const Config = VM.Config;
const Types = @import("types.zig");

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const Equation = Types.Equation;

const BufferedStringStream = struct {
    buffer: []u8,
    offset: usize,
    print_buf: []u8,

    pub fn init(gpa: std.mem.Allocator, size: usize) !BufferedStringStream {
        const buffer = try gpa.alloc(u8, size);
        @memset(buffer, 0);
        return .{
            .buffer = buffer,
            .offset = 0,
            .print_buf = buffer,
        };
    }
    pub fn write(self: *BufferedStringStream, comptime fmt: []const u8, args: anytype) !void {
        const written = try std.fmt.bufPrint(self.print_buf, fmt, args);
        self.offset += written.len;
        self.print_buf = self.buffer[self.offset..];
    }
};

fn getAgentSymbolNested(vm: *const VM, ag: *const Agent, stream: *BufferedStringStream) !void {
    const name = vm.runtime.agent_id_map.findKey(ag.id);
    try stream.write("{s}(", .{name.?});
    {
        var idx: usize = 0;
        outer: while (ag.ports[idx]) |port| : (idx += 1) {
            if (idx != 0) {
                try stream.write(", ", .{});
            }
            switch (port) {
                .name => |_wire| {
                    var wire = _wire;
                    var cnt: u32 = 0;

                    const max_cycle_length = 20;

                    while (wire.port) |wired_to| {
                        if (Config.debug_printing.print_interactions) {
                            try stream.write("(n)", .{});
                        }
                        if (wired_to == .agent) {
                            try getAgentSymbolNested(vm, wired_to.agent, stream);
                            continue :outer;
                        } else {
                            wire = wired_to.name;
                        }
                        cnt = cnt + 1;
                        if (cnt > max_cycle_length) {
                            break;
                        }
                    }
                    try stream.write("<NAME>", .{});
                },
                .agent => |new_ag| {
                    try getAgentSymbolNested(vm, new_ag, stream);
                },
                .special => |special| {
                    switch (special) {
                        .float => |float| {
                            try stream.write("{}", .{float});
                        },
                        .integer => |integer| {
                            try stream.write("{}", .{integer});
                        },
                    }
                },
            }
        }
    }
    try stream.write(")", .{});
}

pub fn getAgentSymbol(vm: *const VM, ag: *const Agent) ![]const u8 {
    const max_agent_name_size = 512;
    var stream = try BufferedStringStream.init(vm.gpa, max_agent_name_size);
    try getAgentSymbolNested(vm, ag, &stream);
    return stream.buffer;
}

pub fn tryPrint(vm: *const VM, val: Value) !void {
    var cur = val;
    var idx: u32 = 0;
    while (cur == .name) : ({
        cur = cur.name.port.?;
        idx += 1;
    }) {
        if (Config.debug_printing.print_interactions) {
            std.debug.print("(n)", .{});
        }
        if (idx > 10) {
            std.debug.print("{any} is cyclic\n", .{val.name.*});
            return;
        }
    }
    const bytes = try getAgentSymbol(vm, cur.agent);
    defer vm.gpa.free(bytes);
    // TODO: use real io instead of debug print
    std.debug.print("{s}\n", .{bytes});
}
