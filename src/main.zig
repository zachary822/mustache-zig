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

    const template = Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 30)) catch |e| {
        std.debug.print("{s}: {t}\n", .{ args[1], e });
        return 1;
    };
    const data: std.json.Value = if (args.len > 2) blk: {
        const src = Io.Dir.cwd().readFileAlloc(io, args[2], arena, .limited(1 << 30)) catch |e| {
            std.debug.print("{s}: {t}\n", .{ args[2], e });
            return 1;
        };
        break :blk std.json.parseFromSliceLeaky(std.json.Value, arena, src, .{}) catch |e| {
            std.debug.print("{s}: {t}\n", .{ args[2], e });
            return 1;
        };
    } else .{ .object = .empty };
    const partials = if (args.len > 3) blk: {
        const src = Io.Dir.cwd().readFileAlloc(io, args[3], arena, .limited(1 << 30)) catch |e| {
            std.debug.print("{s}: {t}\n", .{ args[3], e });
            return 1;
        };
        break :blk std.json.parseFromSliceLeaky(std.json.Value, arena, src, .{}) catch |e| {
            std.debug.print("{s}: {t}\n", .{ args[3], e });
            return 1;
        };
    } else .null;

    var buf: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buf);

    mustache_zig.renderPartials(init.gpa, template, data, partials, &stdout.interface) catch |e| {
        std.debug.print("{s}: {t}\n", .{ args[1], e });
        return 1;
    };
    try stdout.flush();

    return 0;
}
