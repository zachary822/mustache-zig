//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub fn allocRender(gpa: std.mem.Allocator, template: []const u8, data: anytype, partials: anytype) ![]u8 {
    _ = data;
    _ = partials;
    return gpa.dupe(u8, template);
}

test {
    _ = @import("tokenizer.zig");
    _ = @import("parser.zig");
}
