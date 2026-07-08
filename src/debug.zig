const std = @import("std");
const Config = @import("config");

pub fn log(
    comptime flag: std.meta.FieldEnum(@TypeOf(Config.debug_printing)),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (@field(Config.debug_printing, @tagName(flag))) {
        std.debug.print(fmt, args);
    }
}
