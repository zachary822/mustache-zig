//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub fn render(template: []const u8, _: anytype) []const u8 {
    return template;
}

test {
    _ = @import("parser.zig");
}
