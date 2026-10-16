const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;

pub const Error = tokenizer.Error || error{ UnclosedSection, UnexpectedClose, MismatchedClose, TooDeep, OutOfMemory };

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
    partial: struct { name: []const u8, indent: []const u8, dynamic: bool = false },
    parent: struct { name: []const u8, indent: []const u8, dynamic: bool = false, end: u32 },
    block: Block,
};

/// sites in a parent template that let's child override
/// or an argument child gives to parent
pub const Block = struct {
    name: []const u8,
    end: u32,
    raw: []const u8,
    delims: []const u8 = "",
    indent: []const u8 = "",
    dedent: []const u8 = "",
    uniform: bool = true,

    pub fn fits(self: Block, to: []const u8) bool {
        return self.uniform and std.mem.eql(u8, self.dedent, to);
    }
};

/// The maximum nesting of section and block tags in one template.
pub const max_nesting = 64;

fn parseWithDelims(src: []const u8, start_delims: []const u8, sink: anytype) Error!usize {
    const Text = struct { node: u32, text: []const u8 };
    const Open = struct {
        kind: enum { section, parent, site, arg, skip },
        node: u32,
        tok: tokenizer.Token,
        body: usize,
        delims: []const u8,
        before: ?Text,
    };
    var stack: [max_nesting]Open = undefined;
    var depth: usize = 0;

    var n: u32 = 0;
    var last_text: ?Text = null;
    var tz: Tokenizer = .init(src);
    if (start_delims.len > 0) try tz.setDelims(start_delims);

    while (try tz.next()) |tok| {
        const in_parent = depth > 0 and switch (stack[depth - 1].kind) {
            .parent, .skip => true,
            else => false,
        };
        switch (tok.kind) {
            .comment, .set_delimiters => {},
            .text, .variable, .unescaped, .partial => if (!in_parent) {
                try sink.append(switch (tok.kind) {
                    .text => .{ .text = tok.value },
                    .variable => .{ .variable = .{ .name = tok.value, .escape = true } },
                    .unescaped => .{ .variable = .{ .name = tok.value, .escape = false } },
                    else => .{ .partial = .{ .name = tok.value, .indent = tok.indent, .dynamic = tok.dynamic } },
                });
                if (tok.kind == .text) last_text = .{ .node = n, .text = tok.value };
                n += 1;
            },
            .section, .inverted, .parent, .block => {
                if (depth == max_nesting) return error.TooDeep;
                const open: Open = .{
                    .kind = if (tok.kind == .block)
                        (if (in_parent) .arg else .site)
                    else if (in_parent) .skip else if (tok.kind == .parent) .parent else .section,
                    .node = n,
                    .tok = tok,
                    .body = tz.pos,
                    .delims = tz.delims,
                    .before = last_text,
                };
                stack[depth] = open;
                depth += 1;
                if (open.kind == .skip) continue;
                try sink.append(undefined); // set when we see the close tag
                n += 1;
                if (open.kind == .arg and !tok.standalone) {
                    if (tok.line_after) |after| {
                        tz.pos = after;
                        stack[depth - 1].body = after;
                    }
                }
            },
            .close => {
                if (depth == 0) return error.UnexpectedClose;
                depth -= 1;
                const open = stack[depth];
                if (!std.mem.eql(u8, open.tok.value, tok.value)) return error.MismatchedClose;
                switch (open.kind) {
                    .skip => {},
                    .section => {
                        sink.set(open.node, .{ .section = .{ .name = open.tok.value, .inverted = open.tok.kind == .inverted, .end = n, .raw = src[open.tok.end..tok.start], .delims = open.delims } });
                    },
                    .parent => {
                        var indent: []const u8 = "";
                        if (open.tok.line_start != null and tok.line_after != null) {
                            indent = src[open.tok.line_start.?..open.tok.start];
                            trimBefore(src, open.before, open.tok, sink);
                            tz.pos = tok.line_after.?;
                        } else {
                            tz.pos = tok.end;
                        }
                        sink.set(open.node, .{ .parent = .{ .name = open.tok.value, .indent = indent, .dynamic = open.tok.dynamic, .end = n } });
                    },
                    .site, .arg => {
                        const body_end = if (tok.standalone) tok.line_start.? else tok.start;
                        var b: Block = .{ .name = open.tok.value, .end = n, .raw = src[open.body..body_end], .delims = open.delims };
                        if (open.kind == .arg) {
                            if (open.tok.line_after != null) b.dedent = leadingBlanks(b.raw);
                        } else if (open.tok.standalone and b.raw.len > 0) {
                            b.dedent = leadingBlanks(b.raw);
                            b.indent = b.dedent;
                        } else if (open.tok.line_start != null and tok.line_after != null) {
                            b.indent = src[open.tok.line_start.?..open.tok.start];
                            if (!open.tok.standalone) trimBefore(src, open.before, open.tok, sink);
                        }
                        b.uniform = isUniform(b.raw, b.dedent);
                        sink.set(open.node, .{ .block = b });
                    },
                }
            },
        }
    }
    if (depth != 0) return error.UnclosedSection;
    return n;
}

fn trimBefore(src: []const u8, before: anytype, open: tokenizer.Token, sink: anytype) void {
    const t = before orelse return;
    if (t.text.ptr + t.text.len != src.ptr + open.start) return;
    sink.set(t.node, .{ .text = t.text[0 .. t.text.len - (open.start - open.line_start.?)] });
}

fn leadingBlanks(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return s[0..i];
}

fn isUniform(raw: []const u8, dedent: []const u8) bool {
    if (dedent.len == 0) return true;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line.len == dedent.len or !std.mem.startsWith(u8, line, dedent)) return false;
    }
    return true;
}

pub fn reindent(out: ?[]u8, src: []const u8, dedent: []const u8, indent: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (lines.next()) |l| {
        if (!first) n += put(out, n, "\n");
        first = false;
        const line = if (std.mem.startsWith(u8, l, dedent)) l[dedent.len..] else l;
        if (line.len > 0) {
            n += put(out, n, indent);
            n += put(out, n, line);
        }
    }
    return n;
}

fn put(out: ?[]u8, at: usize, s: []const u8) usize {
    if (out) |o| @memcpy(o[at..][0..s.len], s);
    return s.len;
}

pub fn reindentComptime(comptime src: []const u8, comptime dedent: []const u8, comptime indent: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000 + src.len * 50);
        var buf: [reindent(null, src, dedent, indent)]u8 = undefined;
        _ = reindent(&buf, src, dedent, indent);
        const final = buf;
        return &final;
    }
}

const CountSink = struct {
    fn append(_: *CountSink, _: Node) Error!void {}
    fn set(_: *CountSink, _: u32, _: Node) void {}
};

const SliceSink = struct {
    nodes: []Node,
    n: usize = 0,
    fn append(self: *SliceSink, nd: Node) Error!void {
        self.nodes[self.n] = nd;
        self.n += 1;
    }
    fn set(self: *SliceSink, i: u32, nd: Node) void {
        self.nodes[i] = nd;
    }
};

const ListSink = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(Node) = .empty,
    fn append(self: *ListSink, nd: Node) Error!void {
        self.list.append(self.gpa, nd) catch return error.OutOfMemory;
    }
    fn set(self: *ListSink, i: u32, nd: Node) void {
        self.list.items[i] = nd;
    }
};

pub fn parseInto(src: []const u8, delims: []const u8, out: ?[]Node) Error!usize {
    if (out) |nodes| {
        var sink: SliceSink = .{ .nodes = nodes };
        return parseWithDelims(src, delims, &sink);
    }
    var sink: CountSink = .{};
    return parseWithDelims(src, delims, &sink);
}

pub fn parse(gpa: std.mem.Allocator, src: []const u8, start_delim: []const u8) Error![]Node {
    var sink: ListSink = .{ .gpa = gpa };
    errdefer sink.list.deinit(gpa);

    sink.list.ensureTotalCapacity(gpa, @min(src.len / 16 + 4, 256)) catch return error.OutOfMemory;
    _ = try parseWithDelims(src, start_delim, &sink);
    return sink.list.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

pub fn parseComptime(comptime src: []const u8, comptime delims: []const u8) []const Node {
    comptime {
        @setEvalBranchQuota(10_000 + src.len * 500);
        const n = parseInto(src, delims, null) catch |e| @compileError("mustache: " ++ @errorName(e));
        var buf: [n]Node = undefined;
        _ = parseInto(src, delims, &buf) catch unreachable;
        const final = buf;
        return &final;
    }
}

test "parse comptime" {
    const src =
        \\ test template {{>hmm}} {{fun}}
    ;

    const nodes = comptime parseComptime(src, "");
    try std.testing.expectEqualStrings(nodes[0].text, " test template ");
    try std.testing.expectEqualStrings(nodes[1].partial.name, "hmm");
    try std.testing.expectEqualStrings(nodes[2].text, " ");
    try std.testing.expectEqualStrings(nodes[3].variable.name, "fun");
}
