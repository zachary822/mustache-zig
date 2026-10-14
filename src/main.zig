const std = @import("std");
const Io = std.Io;

const mustache_zig = @import("mustache_zig");

pub fn main(_: std.process.Init) !void {
    // Prints to stderr, unbuffered, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
}
