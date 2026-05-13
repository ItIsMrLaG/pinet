const std = @import("std");
const Io = std.Io;

const pinet = @import("pinet");

pub fn main(init: std.process.Init) !void {

    _ = init;
    pinet.Lexer.say_hello();
}
