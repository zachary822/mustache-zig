//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

const tokenizer = @import("tokenizer.zig");
pub const Tokenizer = tokenizer.Tokenizer;

pub fn render(template: []const u8, _: anytype) []const u8 {
    return template;
}

test {
    _ = tokenizer;
}
