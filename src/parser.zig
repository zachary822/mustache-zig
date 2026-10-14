const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;

pub const Node = union(enum) {
    text: []const u8,
    variable: struct { name: []const u8, escape: bool },
    section: struct {
        name: []const u8,
        inverted: bool,
        end: u32,
        raw: []const u8,
        delims: []const u8 = "",
    },
    partial: struct { name: []const u8, indent: []const u8 },
};

pub const Error = tokenizer.Error || error{ UnclosedSection, UnexpectedClose, MismatchedClose, TooDeep, OutOfSpace, OutOfMemory };

pub const max_depth = 64;

pub fn parseWith(src: []const u8, sink: anytype) Error!usize {
    return parseWithDelims(src, "", sink);
}

pub fn parseWithDelims(src: []const u8, start_delims: []const u8, sink: anytype) Error!usize {
    const Open = struct { node: u32, name: []const u8, body_start: usize };
    var stack: [max_depth]Open = undefined;
    var depth: usize = 0;

    var n: u32 = 0;
    var tz: Tokenizer = .init(src);
    const start = splitDelims(start_delims);
    tz.open = start[0];
    tz.close = start[1];
    tz.delims = start_delims;

    while (try tz.next()) |tok| {
        const node: ?Node = switch (tok.kind) {
            .text => .{ .text = tok.value },
            .variable => .{ .variable = .{ .name = tok.value, .escape = true } },
            .unescaped => .{ .variable = .{ .name = tok.value, .escape = false } },
            .partial => .{ .partial = .{ .name = tok.value, .indent = tok.indent } },
            .comment, .set_delimiters => null,
            .section, .inverted => blk: {
                if (depth == max_depth) return error.TooDeep;
                stack[depth] = .{ .node = n, .name = tok.value, .body_start = tok.end };
                depth += 1;
                break :blk .{
                    .section = .{
                        .name = tok.value,
                        .inverted = tok.kind == .inverted,
                        .end = 0, // set when we see the close tag
                        .raw = "",
                        .delims = tz.delims,
                    },
                };
            },
            .close => blk: {
                if (depth == 0) return error.UnexpectedClose;
                depth -= 1;
                const open = stack[depth];
                if (!std.mem.eql(u8, open.name, tok.value)) return error.MismatchedClose;
                sink.setEnd(open.node, n, src[open.body_start..tok.start]);
                break :blk null;
            },
        };
        if (node) |nd| {
            try sink.append(nd);
            n += 1;
        }
    }
    if (depth != 0) return error.UnclosedSection;
    return n;
}

pub fn splitDelims(d: []const u8) [2][]const u8 {
    if (d.len == 0) return .{ "{{", "}}" };
    var parts = std.mem.tokenizeAny(u8, d, " \t\r\n");
    const o = parts.next() orelse "{{";
    const c = parts.next() orelse "}}";
    return .{ o, c };
}

const CountSink = struct {
    fn append(_: *CountSink, _: Node) Error!void {}
    fn setEnd(_: *CountSink, _: u32, _: u32, _: []const u8) void {}
};

const SliceSink = struct {
    nodes: []Node,
    n: usize = 0,
    fn append(self: *SliceSink, nd: Node) Error!void {
        if (self.n >= self.nodes.len) return error.OutOfSpace;
        self.nodes[self.n] = nd;
        self.n += 1;
    }
    fn setEnd(self: *SliceSink, i: u32, end: u32, raw: []const u8) void {
        self.nodes[i].section.end = end;
        self.nodes[i].section.raw = raw;
    }
};

const ListSink = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(Node) = .empty,
    fn append(self: *ListSink, nd: Node) Error!void {
        self.list.append(self.gpa, nd) catch return error.OutOfMemory;
    }
    fn setEnd(self: *ListSink, i: u32, end: u32, raw: []const u8) void {
        self.list.items[i].section.end = end;
        self.list.items[i].section.raw = raw;
    }
};

pub fn parseInto(src: []const u8, out: ?[]Node) Error!usize {
    if (out) |nodes| {
        var sink: SliceSink = .{ .nodes = nodes };
        return parseWith(src, &sink);
    }
    var sink: CountSink = .{};
    return parseWith(src, &sink);
}

pub fn parse(gpa: std.mem.Allocator, src: []const u8) Error![]Node {
    return parseDelims(gpa, src, "");
}

pub fn parseDelims(gpa: std.mem.Allocator, src: []const u8, start_delim: []const u8) Error![]Node {
    var sink: ListSink = .{ .gpa = gpa };
    errdefer sink.list.deinit(gpa);

    sink.list.ensureTotalCapacity(gpa, @min(src.len / 16 + 4, 256)) catch return error.OutOfMemory;
    _ = try parseWithDelims(src, start_delim, &sink);
    return sink.list.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

pub fn parseComptime(comptime src: []const u8) []const Node {
    comptime {
        @setEvalBranchQuota(10_000 + src.len * 500);
        const n = parseInto(src, null) catch |e| @compileError("mustache: " ++ @errorName(e));
        var buf: [n]Node = undefined;
        _ = parseInto(src, &buf) catch unreachable;
        const final = buf;
        return &final;
    }
}

test "parse comptime" {
    const src =
        \\ test template {{>hmm}} {{fun}}
    ;

    const nodes = comptime parseComptime(src);
    try std.testing.expectEqualStrings(nodes[0].text, " test template ");
    try std.testing.expectEqualStrings(nodes[1].partial.name, "hmm");
    try std.testing.expectEqualStrings(nodes[2].text, " ");
    try std.testing.expectEqualStrings(nodes[3].variable.name, "fun");
}
