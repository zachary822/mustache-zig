const std = @import("std");
const parser = @import("parser.zig");
const value = @import("value.zig");
const escape = @import("escape.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Block = parser.Block;
const Node = parser.Node;
const Value = value.Value;
const Writer = Io.Writer;

pub const Error = Writer.Error || Allocator.Error || parser.Error || error{TooDeep};

pub const max_stack = 256;
pub const max_depth = 256;
pub const scratch_retain = 64 * 1024;
pub const max_lambda_levels = 4;
pub const max_warm_depth = 16;

pub const Key = struct { src: []const u8, dedent: []const u8, indent: []const u8 };

pub const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        const a: u64 = @intFromPtr(k.src.ptr) ^ (k.src.len << 48);
        const b: u64 = k.dedent.len | (k.indent.len << 32);
        return std.hash.int(a ^ std.hash.int(b));
    }

    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.src.ptr == b.src.ptr and a.src.len == b.src.len and
            std.mem.eql(u8, a.dedent, b.dedent) and std.mem.eql(u8, a.indent, b.indent);
    }
};

pub const NodeMap = std.HashMapUnmanaged(Key, []const Node, KeyContext, 80);

pub const Cache = struct {
    gpa: Allocator,
    io: ?Io,
    lock: Io.RwLock = .init,
    arena: std.heap.ArenaAllocator,
    map: NodeMap = .empty,

    pub fn init(gpa: Allocator, io: ?Io) Cache {
        return .{ .gpa = gpa, .io = io, .arena = .init(gpa) };
    }

    pub fn deinit(self: *Cache) void {
        self.map.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn count(self: *Cache) usize {
        if (self.io) |io| self.lock.lockSharedUncancelable(io);
        defer if (self.io) |io| self.lock.unlockShared(io);
        return self.map.count();
    }

    pub fn get(self: *Cache, src: []const u8, dedent: []const u8, indent: []const u8, delims: []const u8) Error![]const Node {
        const key: Key = .{ .src = src, .dedent = dedent, .indent = indent };
        if (self.io) |io| self.lock.lockSharedUncancelable(io);
        const hit = self.map.get(key);
        if (self.io) |io| self.lock.unlockShared(io);
        if (hit) |nodes| return nodes;

        if (self.io) |io| self.lock.lockUncancelable(io);
        defer if (self.io) |io| self.lock.unlock(io);
        const gop = try self.map.getOrPut(self.gpa, key);

        if (gop.found_existing) return gop.value_ptr.*;
        errdefer self.map.removeByPtr(gop.key_ptr);

        const arena = self.arena.allocator();
        gop.key_ptr.indent = try arena.dupe(u8, indent);
        gop.key_ptr.dedent = try arena.dupe(u8, dedent);
        gop.value_ptr.* = try parseInto(arena, src, dedent, indent, delims);
        return gop.value_ptr.*;
    }
};

fn parseInto(arena: Allocator, src: []const u8, dedent: []const u8, indent: []const u8, delims: []const u8) Error![]const Node {
    var text = src;
    if (dedent.len > 0 or indent.len > 0) {
        const buf = try arena.alloc(u8, parser.reindent(null, src, dedent, indent));
        _ = parser.reindent(buf, src, dedent, indent);
        text = buf;
    }
    return parser.parseDelims(arena, text, delims);
}

const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    cache: NodeMap = .empty,
};

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

const Memo = struct { name: []const u8 = "", indent: []const u8 = "", nodes: []const Node = &.{} };

const DynMemo = struct {
    const max_name = 32;
    name: [max_name]u8 = undefined,
    len: usize = std.math.maxInt(usize),
    indent: []const u8 = "",
    nodes: []const Node = &.{},
};

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    w: *Writer,

    partials: ?Value = null,
    stack: [max_stack]Value = undefined,
    depth: usize = 0,
    nest: usize = 0,
    partial_depth: usize = 0,
    blocks: ?*const BlockFrame = null,

    cache: *Cache,

    scratch: [max_lambda_levels]Scratch = undefined,
    scratch_used: usize = 0,
    lambda_level: usize = 0,
    current: ?*Scratch = null,
    memo: [16]Memo = @splat(.{}),
    dyn_memo: [8]DynMemo = @splat(.{}),
    dyn_next: usize = 0,

    warm_budget: usize = 1_000_000,
    warm_seen: std.AutoHashMapUnmanaged(usize, void) = .empty,

    pub fn init(gpa: Allocator, w: *Writer, partials: ?Value, cache: *Cache) Renderer {
        return .{ .gpa = gpa, .w = w, .partials = partials, .cache = cache };
    }

    pub fn deinit(self: *Renderer) void {
        for (self.scratch[0..self.scratch_used]) |*sc| sc.arena.deinit();
        self.warm_seen.deinit(self.gpa);
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
        var local: Scratch = undefined;
        const sc: *Scratch = if (self.lambda_level < max_lambda_levels) self.enterScratch() else blk: {
            local = .{ .arena = .init(self.gpa) };
            break :blk &local;
        };
        defer if (sc == &local) local.arena.deinit();

        const saved = self.current;
        self.current = sc;
        self.lambda_level += 1;
        defer {
            self.lambda_level -= 1;
            self.current = saved;
        }

        const arena = sc.arena.allocator();
        var out: Writer.Allocating = .init(arena);
        l.func(l.ctx, text, &out.writer) catch return error.OutOfMemory;
        const nodes = try parser.parseDelims(arena, out.written(), delims);
        try self.render(nodes);
    }

    fn enterScratch(self: *Renderer) *Scratch {
        const sc = &self.scratch[self.lambda_level];
        if (self.lambda_level < self.scratch_used) {
            _ = sc.arena.reset(.{ .retain_with_limit = scratch_retain });
            sc.cache = .empty;
        } else {
            sc.* = .{ .arena = .init(self.gpa) };
            self.scratch_used += 1;
        }
        return sc;
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
        if (self.nest == max_depth) return error.TooDeep;
        self.nest += 1;
        defer self.nest -= 1;

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
        const stable = self.current == null;
        try self.render(try self.parseIndented(b.raw, b.dedent, indent, b.delims, stable));
    }

    fn parseIndented(self: *Renderer, src: []const u8, dedent: []const u8, indent: []const u8, delims: []const u8, stable: bool) Error![]const Node {
        if (stable or self.current == null) return self.cache.get(src, dedent, indent, delims);

        const sc = self.current.?;
        const arena = sc.arena.allocator();
        const gop = try sc.cache.getOrPut(arena, .{ .src = src, .dedent = dedent, .indent = indent });
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer sc.cache.removeByPtr(gop.key_ptr);
        gop.value_ptr.* = try parseInto(arena, src, dedent, indent, delims);
        return gop.value_ptr.*;
    }

    pub fn warm(self: *Renderer, nodes: []const Node, names: []const []const u8) Error!void {
        return self.warmRange(nodes, 0, nodes.len, names);
    }

    fn warmRange(self: *Renderer, nodes: []const Node, from: usize, to: usize, names: []const []const u8) Error!void {
        if (self.nest == max_depth) return;
        self.nest += 1;
        defer self.nest -= 1;

        var i = from;
        while (i < to) {
            if (self.warm_budget == 0) return;
            self.warm_budget -= 1;
            switch (nodes[i]) {
                .text, .variable, .section => {},
                .partial => |p| try self.warmPartial(p.name, p.dynamic, p.indent, null, names),
                .parent => |p| {
                    const frame: BlockFrame = .{ .nodes = nodes, .from = @intCast(i + 1), .to = p.end, .up = self.blocks };
                    try self.warmPartial(p.name, p.dynamic, p.indent, &frame, names);
                    i = p.end;
                    continue;
                },
                .block => |b| {
                    if (findOverride(self.blocks, b.name)) |o| {
                        const saved = self.blocks;
                        self.blocks = o.frame.up;
                        defer self.blocks = saved;
                        try self.warmContent(o.frame.nodes, o.index, o.frame.nodes[o.index].block, b.indent, names);
                    } else {
                        try self.warmContent(nodes, @intCast(i), b, b.indent, names);
                    }
                    i = b.end;
                    continue;
                },
            }
            i += 1;
        }
    }

    fn warmContent(self: *Renderer, nodes: []const Node, i: u32, b: Block, indent: []const u8, names: []const []const u8) Error!void {
        if (b.fits(indent)) return self.warmRange(nodes, i + 1, b.end, names);
        const bnodes = try self.parseIndented(b.raw, b.dedent, indent, b.delims, true);
        try self.warmRange(bnodes, 0, bnodes.len, names);
    }

    fn warmPartial(self: *Renderer, name: []const u8, dynamic: bool, indent: []const u8, frame: ?*const BlockFrame, names: []const []const u8) Error!void {
        if (self.partial_depth == max_warm_depth) return;
        if (!dynamic) return self.warmOne(name, indent, frame, names);
        for (names) |n| try self.warmOne(n, indent, frame, names);
    }

    fn warmOne(self: *Renderer, name: []const u8, indent: []const u8, frame: ?*const BlockFrame, names: []const []const u8) Error!void {
        const src = self.partialSource(name) orelse return;
        const nodes = try self.parseIndented(src, "", indent, "", true);
        if (frame == null and self.blocks == null) {
            const gop = try self.warm_seen.getOrPut(self.gpa, @intFromPtr(nodes.ptr));
            if (gop.found_existing) return;
        }

        self.partial_depth += 1;
        defer self.partial_depth -= 1;
        const saved = self.blocks;
        if (frame) |f| self.blocks = f;
        defer self.blocks = saved;
        try self.warmRange(nodes, 0, nodes.len, names);
    }

    fn renderPartial(self: *Renderer, name: []const u8, dynamic: bool, indent: []const u8, frame: ?*const BlockFrame) Error!void {
        const nodes = try self.partialNodes(name, dynamic, indent) orelse return;
        const saved = self.blocks;
        if (frame) |f| self.blocks = f;
        defer self.blocks = saved;
        try self.render(nodes);
    }

    fn partialNodes(self: *Renderer, name: []const u8, dynamic: bool, indent: []const u8) Error!?[]const Node {
        const use_memo = self.current == null;
        const slot = &self.memo[(@intFromPtr(name.ptr) >> 3) % self.memo.len];
        if (use_memo and !dynamic and slot.name.ptr == name.ptr and slot.name.len == name.len and
            slot.indent.ptr == indent.ptr and slot.indent.len == indent.len) return slot.nodes;

        var buf: [256]u8 = undefined;
        const real_name = if (dynamic) (try self.resolveName(name, &buf) orelse return null) else name;
        if (use_memo and dynamic) if (self.findDynMemo(real_name, indent)) |nodes| return nodes;

        const src = self.partialSource(real_name) orelse return null;
        const nodes = try self.parseIndented(src, "", indent, "", true);
        if (use_memo and !dynamic) slot.* = .{ .name = name, .indent = indent, .nodes = nodes };
        if (use_memo and dynamic) self.putDynMemo(real_name, indent, nodes);
        return nodes;
    }

    fn findDynMemo(self: *Renderer, name: []const u8, indent: []const u8) ?[]const Node {
        for (&self.dyn_memo) |*m| {
            if (m.len == name.len and m.indent.ptr == indent.ptr and m.indent.len == indent.len and
                std.mem.eql(u8, m.name[0..m.len], name)) return m.nodes;
        }
        return null;
    }

    fn putDynMemo(self: *Renderer, name: []const u8, indent: []const u8, nodes: []const Node) void {
        if (name.len > DynMemo.max_name) return;
        const m = &self.dyn_memo[self.dyn_next];
        self.dyn_next = (self.dyn_next + 1) % self.dyn_memo.len;
        @memcpy(m.name[0..name.len], name);
        m.len = name.len;
        m.indent = indent;
        m.nodes = nodes;
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
