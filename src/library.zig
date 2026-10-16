const std = @import("std");
const parser = @import("parser.zig");
const render_mod = @import("render.zig");
const value = @import("value.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Node = parser.Node;
const Renderer = render_mod.Renderer;
const Value = value.Value;
const Writer = Io.Writer;

pub const Error = render_mod.Error || error{UnknownTemplate};

pub const Library = struct {
    arena: std.heap.ArenaAllocator,
    sources: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    nodes: std.ArrayList([]const Node) = .empty,

    cache: render_mod.Cache,

    /// 'gpa' must be thread-safe if many threads render. `io` gives the lock.
    pub fn init(gpa: Allocator, io: Io) Library {
        return .{ .arena = .init(gpa), .cache = .init(gpa, io) };
    }

    pub fn deinit(self: *Library) void {
        self.cache.deinit();
        self.arena.deinit();
    }

    pub fn add(self: *Library, name: []const u8, src: []const u8) (parser.Error || error{DuplicateName})!void {
        const a = self.arena.allocator();
        const gop = try self.sources.getOrPut(a, name);
        if (gop.found_existing) return error.DuplicateName;
        errdefer _ = self.sources.pop();
        gop.key_ptr.* = try a.dupe(u8, name);
        gop.value_ptr.* = try a.dupe(u8, src);
        try self.nodes.append(a, try parser.parse(a, gop.value_ptr.*, ""));
    }

    pub fn addDir(self: *Library, io: Io, dir: Io.Dir) !void {
        const ext = ".mustache";
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ext)) continue;
            const src = try dir.readFileAlloc(io, entry.name, self.arena.allocator(), .limited(16 << 20));
            const name = entry.name[0 .. entry.name.len - ext.len];
            self.add(name, src) catch |e| {
                std.log.err("{s}: {t}", .{ entry.name, e });
                return e;
            };
        }
    }

    pub fn warm(self: *Library) render_mod.Error!void {
        const gpa = self.arena.allocator();
        var discard: Writer.Discarding = .init(&.{});
        var r: Renderer = .init(gpa, &discard.writer, self.partialsValue(), &self.cache);
        defer r.deinit();
        for (self.nodes.items) |nodes| try r.warm(nodes, self.sources.keys());
    }

    pub fn cached(self: *Library) usize {
        return self.cache.count();
    }

    fn partialsValue(self: *const Library) Value {
        return value.from(@TypeOf(self.sources), &self.sources);
    }

    pub fn render(self: *Library, gpa: Allocator, name: []const u8, data: anytype, w: *Writer) Error!void {
        const i = self.sources.getIndex(name) orelse return error.UnknownTemplate;
        const dv = value.from(@TypeOf(data), &data);
        var r: Renderer = .init(gpa, w, self.partialsValue(), &self.cache);
        defer r.deinit();
        try r.push(dv);
        try r.render(self.nodes.items[i]);
    }
};

test "a cold library fills its cache; then a render allocates nothing" {
    const gpa = std.testing.allocator;
    var lib: Library = .init(gpa, std.testing.io);
    defer lib.deinit();
    try lib.add("layout", "<html>\n  {{$body}}\n  none\n  {{/body}}\n</html>\n");
    try lib.add("row", "<li>{{.}}</li>\n");
    try lib.add("page", "{{<layout}}\n{{$body}}\n<ul>\n  {{#items}}\n  {{>row}}\n  {{/items}}\n</ul>\n{{/body}}\n{{/layout}}\n");
    const data = .{ .items = .{ "a", "b" } };
    const expected = "<html>\n  <ul>\n    <li>a</li>\n    <li>b</li>\n  </ul>\n</html>\n";

    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.testing.expectEqual(@as(usize, 0), lib.cached());
    try lib.render(gpa, "page", data, &out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
    const filled = lib.cached();
    try std.testing.expect(filled > 0);

    // The second render finds everything in the cache.
    out.clearRetainingCapacity();
    var counting: CountingAllocator = .{ .child = gpa };
    try lib.render(counting.allocator(), "page", data, &out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
    try std.testing.expectEqual(@as(usize, 0), counting.count);
    try std.testing.expectEqual(filled, lib.cached());

    try std.testing.expectError(error.UnknownTemplate, lib.render(gpa, "nope", data, &out.writer));
}

test "warm fills the cache before the first render" {
    const gpa = std.testing.allocator;
    var lib: Library = .init(gpa, std.testing.io);
    defer lib.deinit();
    try lib.add("a", "x\n  {{>b}}\n");
    try lib.add("b", "{{>*kind}}");
    try lib.add("c", "C");
    try lib.warm();
    // a; b with indent "  "; c and the others for {{>*kind}} with indent "  ".
    try std.testing.expect(lib.cached() >= 3);
}

test "many threads render from one cold library" {
    const gpa = std.heap.smp_allocator;
    var lib: Library = .init(gpa, std.testing.io);
    defer lib.deinit();
    try lib.add("row", "<li>{{name}}</li>\n");
    try lib.add("page", "<ul>\n  {{#items}}\n  {{>row}}\n  {{/items}}\n</ul>\n");
    const Item = struct { name: []const u8 };
    const items = [_]Item{ .{ .name = "a" }, .{ .name = "b" } };

    const T = struct {
        fn run(l: *Library, it: []const Item, ok: *std.atomic.Value(u32)) void {
            for (0..200) |_| {
                var buf: [256]u8 = undefined;
                var w: Writer = .fixed(&buf);
                l.render(gpa, "page", .{ .items = it }, &w) catch return;
                if (!std.mem.eql(u8, "<ul>\n  <li>a</li>\n  <li>b</li>\n</ul>\n", w.buffered())) return;
            }
            _ = ok.fetchAdd(1, .monotonic);
        }
    };
    var ok: std.atomic.Value(u32) = .init(0);
    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, T.run, .{ &lib, &items, &ok });
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u32, 8), ok.load(.monotonic));
}

/// Counts the allocations, for tests.
const CountingAllocator = struct {
    child: Allocator,
    count: usize = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.child.rawAlloc(len, a, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, a, ra);
    }
};
