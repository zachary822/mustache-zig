const std = @import("std");
const parser = @import("parser.zig");
const value = @import("value.zig");
const escape = @import("escape.zig");
const Allocator = std.mem.Allocator;
const Block = parser.Block;
const Node = parser.Node;
const Value = value.Value;
const Writer = std.Io.Writer;

pub const Error = Writer.Error || Allocator.Error || parser.Error || error{TooDeep};

pub const max_stack = 256;
pub const max_partial_depth = 256;

pub const BlockFrame = struct {
    nodes: []const Node,
    from: u32,
    to: u32,
    up: ?*const BlockFrame,

    fn find(self: *const BlockFrame, name: []const u8) ?u32 {
        var j = self.from;
        while (j < self.to) {
            const arg = self.nodes[j].block;
            if (std.mem.eql(u8, arg.name, name)) return j;
            j = arg.end;
        }
        return null;
    }
};

pub const Override = struct { frame: *const BlockFrame, index: u32 };

pub fn findOverride(blocks: ?*const BlockFrame, name: []const u8) ?Override {
    var found: ?Override = null;
    var f = blocks;
    while (f) |frame| : (f = frame.up) {
        if (frame.find(name)) |j| found = .{ .frame = frame, .index = j };
    }
    return found;
}

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    w: *Writer,

    partials: ?Value = null,
    stack: [max_stack]Value = undefined,
    depth: usize = 0,
    partial_depth: usize = 0,
    blocks: ?*const BlockFrame = null,

    arena: std.heap.ArenaAllocator,
    cache: std.HashMapUnmanaged(Key, []const Node, KeyContext, 80) = .empty,

    const Key = struct { src: []const u8, dedent: []const u8, indent: []const u8 };
    const KeyContext = struct {
        pub fn hash(_: KeyContext, k: Key) u64 {
            const a: u64 = @intFromPtr(k.src.ptr) ^ (k.src.len << 48);
            const b: u64 = k.indent.len | (k.indent.len << 32);
            return std.hash.int(a ^ std.hash.int(b));
        }

        pub fn eql(_: KeyContext, a: Key, b: Key) bool {
            return a.src.ptr == b.src.ptr and a.src.len == b.src.len and
                std.mem.eql(u8, a.dedent, b.dedent) and std.mem.eql(u8, a.indent, b.indent);
        }
    };

    pub fn init(gpa: Allocator, w: *Writer, partials: ?Value) Renderer {
        return .{ .gpa = gpa, .w = w, .partials = partials, .arena = .init(gpa) };
    }

    pub fn deinit(self: *Renderer) void {
        self.cache.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn push(self: *Renderer, v: Value) Error!void {
        if (self.depth == max_stack) return error.TooDeep;
        self.stack[self.depth] = v;
        self.depth += 1;
    }

    pub fn pop(self: *Renderer) void {
        self.depth -= 1;
    }

    pub fn lookup(self: *Renderer, name: []const u8) ?Value {
        if (name.len == 1 and name[0] == '.') return if (self.depth > 0) self.stack[self.depth - 1] else null;
        const dot = findDot(name);
        const first = if (dot) |d| name[0..d] else name;

        var cur: Value = blk: {
            var i = self.depth;
            while (i > 0) {
                i -= 1;
                switch (self.stack[i]) {
                    .map => |m| if (m.get(first)) |v| break :blk v,
                    else => {},
                }
            }
            return null;
        };

        var rest = if (dot) |d| name[d + 1 ..] else return cur;
        while (true) {
            const d = findDot(rest);
            const part = if (d) |k| rest[0..k] else rest;
            cur = switch (cur) {
                .map => |m| m.get(part) orelse return null,
                else => return null,
            };
            rest = if (d) |k| rest[k + 1 ..] else return cur;
        }
    }

    fn writeValue(self: *Renderer, v: Value, escaped: bool) Error!void {
        switch (v) {
            .null, .list, .map => {},
            .bool => |b| try self.w.writeAll(if (b) "true" else "false"),
            inline .int, .uint, .float => |x| try self.w.print("{d}", .{x}),
            .string => |s| if (escaped) try escape.writeEscaped(self.w, s) else try self.w.writeAll(s),
            .lambda => |l| {
                var rendered: Writer.Allocating = .init(self.gpa);
                defer rendered.deinit();
                const saved = self.w;
                self.w = &rendered.writer;
                defer self.w = saved;
                try self.renderLambda(l, "", "");
                self.w = saved;
                if (escaped) try escape.writeEscaped(self.w, rendered.written()) else try self.w.writeAll(rendered.written());
            },
        }
    }

    pub fn renderLambda(self: *Renderer, l: value.Lambda, text: []const u8, delims: []const u8) Error!void {
        const arena = self.arena.allocator();
        var out: Writer.Allocating = .init(arena);
        l.func(l.ctx, text, &out.writer) catch return error.OutOfMemory;
        const nodes = try parser.parseDelims(arena, out.written(), delims);
        try self.render(nodes);
    }

    fn renderBody(self: *Renderer, nodes: []const Node, from: usize, to: usize, top: Value) Error!void {
        try self.push(top);
        defer self.pop();
        try self.renderRange(nodes, from, to);
    }

    pub fn render(self: *Renderer, nodes: []const Node) Error!void {
        return self.renderRange(nodes, 0, nodes.len);
    }

    pub fn renderRange(self: *Renderer, nodes: []const Node, from: usize, to: usize) Error!void {
        var i = from;
        while (i < to) {
            switch (nodes[i]) {
                .text => |t| try self.w.writeAll(t),
                .variable => |v| if (self.lookup(v.name)) |x| try self.writeValue(x, v.escape),
                .section => |s| {
                    const found = self.lookup(s.name);
                    if (s.inverted) {
                        if (found == null or !found.?.truthy()) try self.renderRange(nodes, i + 1, s.end);
                    } else if (found) |v| switch (v) {
                        .null => {},
                        .bool => |b| if (b) try self.renderBody(nodes, i + 1, s.end, v),
                        .list => |l| for (0..l.len) |k| try self.renderBody(nodes, i + 1, s.end, l.get(k)),
                        .lambda => |l| try self.renderLambda(l, s.raw, s.delims),
                        else => try self.renderBody(nodes, i + 1, s.end, v),
                    };
                    i = s.end;
                    continue;
                },
                .partial => |p| try self.renderPartial(p.name, p.dynamic, p.indent, null),
                .parent => |p| {
                    const frame: BlockFrame = .{ .nodes = nodes, .from = @intCast(i + 1), .to = p.end, .up = self.blocks };
                    try self.renderPartial(p.name, p.dynamic, p.indent, &frame);
                    i = p.end;
                    continue;
                },
                .block => |b| {
                    try self.renderBlock(nodes, @intCast(i), b);
                    i = b.end;
                    continue;
                },
            }
            i += 1;
        }
    }

    fn renderBlock(self: *Renderer, nodes: []const Node, i: u32, b: Block) Error!void {
        const o = findOverride(self.blocks, b.name) orelse return self.renderContent(nodes, i, b, b.indent);
        const saved = self.blocks;
        self.blocks = o.frame.up;
        defer self.blocks = saved;
        try self.renderContent(o.frame.nodes, o.index, o.frame.nodes[o.index].block, b.indent);
    }

    fn renderContent(self: *Renderer, nodes: []const Node, i: u32, b: Block, indent: []const u8) Error!void {
        if (b.fits(indent)) return self.renderRange(nodes, i + 1, b.end);
        try self.render(try self.parseIndented(b.raw, b.dedent, indent, b.delims));
    }

    fn parseIndented(self: *Renderer, src: []const u8, dedent: []const u8, indent: []const u8, delims: []const u8) Error![]const Node {
        const gop = try self.cache.getOrPut(self.gpa, .{ .src = src, .dedent = dedent, .indent = indent });
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer self.cache.removeByPtr(gop.key_ptr);

        const arena = self.arena.allocator();
        var text = src;
        if (dedent.len > 0 or indent.len > 0) {
            const buf = try arena.alloc(u8, parser.reindent(null, src, dedent, indent));
            _ = parser.reindent(buf, src, dedent, indent);
            text = buf;
        }
        const nodes = try parser.parseDelims(arena, text, delims);
        gop.value_ptr.* = nodes;
        return nodes;
    }

    fn renderPartial(self: *Renderer, name: []const u8, dynamic: bool, indent: []const u8, frame: ?*const BlockFrame) Error!void {
        var buf: [256]u8 = undefined;
        const real_name = if (dynamic) (try self.resolveName(name, &buf) orelse return) else name;
        const src = self.partialSource(real_name) orelse return;
        const nodes = try self.parseIndented(src, "", indent, "");

        if (self.partial_depth == max_partial_depth) return error.TooDeep;
        self.partial_depth += 1;
        defer self.partial_depth -= 1;

        const saved = self.blocks;
        if (frame) |f| self.blocks = f;
        defer self.blocks = saved;
        try self.render(nodes);
    }

    fn partialSource(self: *Renderer, name: []const u8) ?[]const u8 {
        const partials = self.partials orelse return null;
        return switch (partials) {
            .map => |m| switch (m.get(name) orelse return null) {
                .string => |s| s,
                else => null,
            },
            else => null,
        };
    }

    fn resolveName(self: *Renderer, name: []const u8, buf: []u8) Error!?[]const u8 {
        const v = self.lookup(name) orelse return null;
        if (v == .string) return v.string;
        var fixed: Writer = .fixed(buf);
        const saved = self.w;
        self.w = &fixed;
        defer self.w = saved;
        self.writeValue(v, false) catch |e| switch (e) {
            error.WriteFailed => return null,
            else => |err| return err,
        };
        return fixed.buffered();
    }
};

fn findDot(name: []const u8) ?usize {
    for (name, 0..) |c, i| if (c == '.') return i;
    return null;
}
