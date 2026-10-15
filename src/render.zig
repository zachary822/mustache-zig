const std = @import("std");
const parser = @import("parser.zig");
const value = @import("value.zig");
const escape = @import("escape.zig");
const Allocator = std.mem.Allocator;
const Node = parser.Node;
const Value = value.Value;
const Writer = std.Io.Writer;

pub const Error = Writer.Error || Allocator.Error || parser.Error || error{TooDeep};

pub const max_stack = 256;
pub const max_partial_depth = 100;

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    w: *Writer,

    partials: ?Value = null,
    stack: [max_stack]Value = undefined,
    depth: usize = 0,
    cache: std.AutoHashMapUnmanaged(Key, Parsed) = .empty,

    const Key = struct { name: [*]const u8, name_len: usize, ident: [*]const u8, ident_len: usize };
    const Parsed = struct { name: []u8, ident: []u8, src: []u8, nodes: []Node };

    fn freeParsed(self: *Renderer, p: Parsed) void {
        self.gpa.free(p.name);
        self.gpa.free(p.ident);
        self.gpa.free(p.src);
        self.gpa.free(p.nodes);
    }

    pub fn init(gpa: Allocator, w: *Writer, partials: ?Value) Renderer {
        return .{ .gpa = gpa, .w = w, .partials = partials };
    }

    pub fn deinit(self: *Renderer) void {
        var it = self.cache.valueIterator();
        while (it.next()) |p| self.freeParsed(p.*);
        self.cache.deinit(self.gpa);
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
        var out: Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        l.func(l.ctx, text, &out.writer) catch return error.OutOfMemory;
        const nodes = try parser.parseDelims(self.gpa, out.written(), delims);
        defer self.gpa.free(nodes);
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

    fn renderRange(self: *Renderer, nodes: []const Node, from: usize, to: usize) Error!void {
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
                .partial => |p| try self.renderPartial(p.name, p.indent),
            }
            i += 1;
        }
    }

    fn renderPartial(self: *Renderer, name: []const u8, indent: []const u8) Error!void {
        const partials = self.partials orelse return;
        const src = switch (partials) {
            .map => |m| switch (m.get(name) orelse return) {
                .string => |s| s,
                else => return,
            },
            else => return,
        };
        const key: Key = .{ .name = name.ptr, .name_len = name.len, .ident = indent.ptr, .ident_len = indent.len };
        const gop = try self.cache.getOrPut(self.gpa, key);
        var fresh = !gop.found_existing;
        if (!fresh and !(std.mem.eql(u8, gop.value_ptr.name, name)) and std.mem.eql(u8, gop.value_ptr.ident, indent)) {
            self.freeParsed(gop.value_ptr.*);
            fresh = true;
        }
        if (fresh) {
            errdefer self.cache.removeByPtr(gop.key_ptr);
            const name_copy = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(name_copy);
            const indent_copy = try self.gpa.dupe(u8, indent);
            errdefer self.gpa.free(indent_copy);

            const indented = try indentLines(self.gpa, src, indent);
            errdefer self.gpa.free(indented);

            gop.value_ptr.* = .{ .name = name_copy, .ident = indent_copy, .src = indented, .nodes = try parser.parse(self.gpa, indented) };
        }

        // copy the slice: a nested partial can grow the cache and move the entry;
        const nodes = gop.value_ptr.nodes;
        // partial uses the same context stack
        try self.render(nodes);
    }
};

fn findDot(name: []const u8) ?usize {
    for (name, 0..) |c, i| if (c == '.') return i;
    return null;
}

fn indentLines(gpa: Allocator, src: []const u8, indent: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, src.len + indent.len * 4);
    var lines = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        if (line.len > 0) try out.appendSlice(gpa, indent);
        try out.appendSlice(gpa, line);
        first = false;
    }
    return out.toOwnedSlice(gpa);
}
