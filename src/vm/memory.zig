const std = @import("std");

const Config = @import("../vm.zig").Config;

pub fn Heap(comptime T: type) type {
    return struct {
        const Optional = union(enum) {
            free: void,
            item: T,
        };
        items: []Optional,
        free_idx: usize,
        capacity: usize,

        pub fn init(gpa: std.mem.Allocator, capacity: usize) !Heap(T) {
            const items = try gpa.alloc(Optional, capacity);
            @memset(items, .free);
            return .{
                .items = items,
                .capacity = capacity,
                .free_idx = 0,
            };
        }

        pub fn deinit(self: *Heap(T), gpa: std.mem.Allocator) void {
            gpa.free(self.items);
        }

        pub fn getOne(self: *Heap(T)) !*T {
            for (self.free_idx..self.capacity) |idx| {
                if (self.items[idx] == .free) {
                    self.free_idx = idx;

                    self.items[idx] = .{ .item = undefined };

                    return &self.items[idx].item;
                }
            }
            for (0..self.free_idx) |idx| {
                if (self.items[idx] == .free) {
                    self.free_idx = idx;

                    self.items[idx] = .{ .item = undefined };

                    return &self.items[idx].item;
                }
            }
            return error.OutOfMemory;
        }

        pub fn freeOne(elem: *T) void {
            if (Config.debug_printing.print_frees) {
                std.debug.print("Free is called\n", .{});
            }
            const real_elem = @as(*Optional, @fieldParentPtr("item", elem));
            if (!Config.debug_printing.print_frees) {
                real_elem.* = .free;
            } else {
                switch (real_elem.*) {
                    .free => {
                        std.debug.print("Double-free\n", .{});
                    },
                    .item => {
                        real_elem.* = .free;
                    },
                }
            }
        }

        pub fn printUsage(self: *const Heap(T)) void {
            var used: usize = 0;
            for (self.items) |maybe_elem| {
                if (maybe_elem == .item) {
                    used += 1;
                }
            }
            const free = self.items.len - used;
            std.debug.print("Heap({s}): {} used, {} free, sizeOf(Optional) = {}, sizeOf(T) = {}\n", .{
                @typeName(T),
                used,
                free,
                @sizeOf(Optional),
                @sizeOf(T),
            });
        }
    };
}
