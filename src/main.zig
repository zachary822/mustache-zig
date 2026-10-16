const std = @import("std");
const Io = std.Io;

const mustache_zig = @import("mustache_zig");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: {s} TEMPLATE [DATA.json] [PARTIALS.json]\n", .{args[0]});
        return 2;
    }

    const template = readFile(io, arena, args[1]) orelse return 1;
    const data: std.json.Value = if (args.len > 2) readJson(io, arena, args[2]) orelse return 1 else .{ .object = .empty };
    const partials: std.json.Value = if (args.len > 3) readJson(io, arena, args[3]) orelse return 1 else .null;

    var buf: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buf);

    mustache_zig.renderPartials(init.gpa, template, data, partials, &stdout.interface) catch |e| {
        std.debug.print("{s}: {t}\n", .{ args[1], e });
        return 1;
    };
    try stdout.flush();

    return 0;
}

/// Prints the error and returns null if the file cannot be read.
fn readFile(io: Io, arena: std.mem.Allocator, path: []const u8) ?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 30)) catch |e| {
        std.debug.print("{s}: {t}\n", .{ path, e });
        return null;
    };
}

/// Prints the error and returns null if the file cannot be read or is not JSON.
fn readJson(io: Io, arena: std.mem.Allocator, path: []const u8) ?std.json.Value {
    const src = readFile(io, arena, path) orelse return null;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, src, .{}) catch |e| {
        std.debug.print("{s}: {t}\n", .{ path, e });
        return null;
    };
}
