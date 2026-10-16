const std = @import("std");
const esc = @import("escape.zig");
const dynamic = @import("render.zig");
const parser = @import("parser.zig");
const value = @import("value.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const BlockFrame = dynamic.BlockFrame;
const Lambda = value.Lambda;
const Node = parser.Node;
const Value = value.Value;
const Writer = Io.Writer;
const comptimePtr = value.comptimePtr;

pub const Error = dynamic.Error;

pub fn Comptime(comptime src: []const u8, comptime partials: anytype) type {
    return struct {
        pub const nodes = parser.parseComptime(src, "");

        pub fn render(gpa: Allocator, data: anytype, w: *Writer) Error!void {
            const D = value.Runtime(@TypeOf(data));
            const ptr: *const D = if (D != @TypeOf(data)) comptimePtr(data) else &data;
            const root: Frame(D, void) = .{ .v = ptr, .up = {} };
            var cache: dynamic.Cache = .init(gpa, null);
            defer cache.deinit();
            const c: Ctx = .{ .gpa = gpa, .w = w, .partials = value.fromComptime(partials), .cache = &cache };
            try renderNodes(nodes, partials, 0, nodes.len, &.{}, null, &root, &c);
        }

        pub fn renderAlloc(gpa: Allocator, data: anytype) Error![]u8 {
            var out: Writer.Allocating = .init(gpa);
            defer out.deinit();
            try render(gpa, data, &out.writer);
            return out.toOwnedSlice();
        }
    };
}

const Ctx = struct {
    gpa: Allocator,
    w: *Writer,
    partials: Value,
    cache: *dynamic.Cache,
};

fn Frame(comptime T: type, comptime Up: type) type {
    return struct { v: *const T, up: Up };
}

fn renderNodes(
    comptime nodes: []const Node,
    comptime partials: anytype,
    comptime from: usize,
    comptime to: usize,
    comptime active: []const []const u8,
    comptime blocks: ?*const BlockFrame,
    frame: anytype,
    c: *const Ctx,
) Error!void {
    @setEvalBranchQuota(10_000 + (to - from) * 100);
    comptime var i = from;
    inline while (i < to) {
        const node = comptime nodes[i];
        switch (node) {
            .text => |t| try c.w.writeAll(t),
            .variable => |v| try find(v.name, frame, VarK(@TypeOf(frame), blocks){ .c = c, .frame = frame, .escape = v.escape }),
            .section => |s| {
                const K = SectionK(nodes, partials, i, active, blocks, @TypeOf(frame));
                try find(s.name, frame, K{ .c = c, .frame = frame });
                i = s.end;
                continue;
            },
            .partial => |p| try renderNamed(nodes, i, p.name, p.dynamic, partials, active, blocks, frame, c),
            .parent => |p| {
                try renderNamed(nodes, i, p.name, p.dynamic, partials, active, blocks, frame, c);
                i = p.end;
                continue;
            },
            .block => |b| {
                try renderBlock(nodes, i, partials, active, blocks, frame, c);
                i = b.end;
                continue;
            },
        }
        i += 1;
    }
}

fn renderNamed(
    comptime nodes: []const Node,
    comptime i: usize,
    comptime name: []const u8,
    comptime is_dynamic: bool,
    comptime partials: anytype,
    comptime active: []const []const u8,
    comptime blocks: ?*const BlockFrame,
    frame: anytype,
    c: *const Ctx,
) Error!void {
    if (is_dynamic) {
        const K = NameK(nodes, i, partials, active, blocks, @TypeOf(frame));
        return find(name, frame, K{ .c = c, .frame = frame });
    }
    return renderTemplate(nodes, i, name, partials, active, blocks, frame, c);
}

fn renderTemplate(
    comptime nodes: []const Node,
    comptime i: usize,
    comptime name: []const u8,
    comptime partials: anytype,
    comptime active: []const []const u8,
    comptime blocks: ?*const BlockFrame,
    frame: anytype,
    c: *const Ctx,
) Error!void {
    if (comptime !@hasField(@TypeOf(partials), name)) return;
    inline for (active) |a| {
        if (comptime std.mem.eql(u8, a, name)) {
            var r = try runtimeRenderer(c, frame, blocks);
            defer r.deinit();
            return r.renderRange(nodes, i, nextIndex(nodes, i));
        }
    }
    const indent, const inner: ?*const BlockFrame = comptime switch (nodes[i]) {
        .partial => |p| .{ p.indent, blocks },
        .parent => |p| .{ p.indent, &BlockFrame{ .nodes = nodes, .from = i + 1, .to = p.end, .up = blocks } },
        else => unreachable,
    };
    const src = comptime parser.reindentComptime(@field(partials, name), "", indent);
    const pnodes = comptime parser.parseComptime(src, "");
    try renderNodes(pnodes, partials, 0, pnodes.len, active ++ [_][]const u8{name}, inner, frame, c);
}

fn nextIndex(comptime nodes: []const Node, comptime i: usize) usize {
    return switch (nodes[i]) {
        .parent => |p| p.end,
        else => i + 1,
    };
}

fn renderBlock(
    comptime nodes: []const Node,
    comptime i: usize,
    comptime partials: anytype,
    comptime active: []const []const u8,
    comptime blocks: ?*const BlockFrame,
    frame: anytype,
    c: *const Ctx,
) Error!void {
    const b = comptime nodes[i].block;
    if (comptime dynamic.findOverride(blocks, b.name)) |o| {
        return renderContent(o.frame.nodes, o.index, b.indent, partials, active, o.frame.up, frame, c);
    }
    return renderContent(nodes, i, b.indent, partials, active, blocks, frame, c);
}

fn renderContent(
    comptime nodes: []const Node,
    comptime i: usize,
    comptime indent: []const u8,
    comptime partials: anytype,
    comptime active: []const []const u8,
    comptime blocks: ?*const BlockFrame,
    frame: anytype,
    c: *const Ctx,
) Error!void {
    const b = comptime nodes[i].block;
    if (comptime b.fits(indent)) return renderNodes(nodes, partials, i + 1, b.end, active, blocks, frame, c);
    const bnodes = comptime parser.parseComptime(parser.reindentComptime(b.raw, b.dedent, indent), b.delims);
    return renderNodes(bnodes, partials, 0, bnodes.len, active, blocks, frame, c);
}

fn runtimeRenderer(c: *const Ctx, frame: anytype, comptime blocks: ?*const BlockFrame) Error!dynamic.Renderer {
    var r: dynamic.Renderer = .init(c.gpa, c.w, c.partials, c.cache);
    errdefer r.deinit();
    try pushFrames(&r, frame);
    r.blocks = blocks;
    return r;
}

fn partialNames(comptime partials: anytype) []const []const u8 {
    return switch (@typeInfo(@TypeOf(partials))) {
        .@"struct" => |info| info.field_names,
        else => &.{},
    };
}

fn NameK(
    comptime nodes: []const Node,
    comptime i: usize,
    comptime partials: anytype,
    comptime active: []const []const u8,
    comptime blocks: ?*const BlockFrame,
    comptime F: type,
) type {
    return struct {
        c: *const Ctx,
        frame: F,

        pub fn found(self: @This(), p: anytype) Error!void {
            var buf: [256]u8 = undefined;
            var fixed: Writer = .fixed(&buf);
            var c = self.c.*;
            c.w = &fixed;
            writeTyped(&c, self.frame, p, false, blocks) catch |e| switch (e) {
                error.WriteFailed => return,
                else => |err| return err,
            };
            const name = fixed.buffered();
            inline for (comptime partialNames(partials)) |pname| {
                if (std.mem.eql(u8, name, pname)) return renderTemplate(nodes, i, pname, partials, active, blocks, self.frame, self.c);
            }
        }

        pub fn missing(_: @This()) Error!void {}
    };
}

fn pushFrames(r: *dynamic.Renderer, frame: anytype) Error!void {
    const F = @TypeOf(frame.*);
    if (@FieldType(F, "up") != void) try pushFrames(r, frame.up);
    try r.push(value.from(@TypeOf(frame.v.*), frame.v));
}

fn find(comptime name: []const u8, frame: anytype, k: anytype) Error!void {
    if (comptime std.mem.eql(u8, name, ".")) return k.found(frame.v);
    const dot = comptime std.mem.findScalar(u8, name, '.');
    const first = if (dot) |d| name[0..d] else name;
    const rest = if (dot) |d| name[d + 1 ..] else "";
    return findFirst(first, rest, frame, k);
}

fn findFirst(comptime first: []const u8, comptime rest: []const u8, frame: anytype, k: anytype) Error!void {
    return member(first, frame.v, Rest(rest, @TypeOf(k)){ .k = k }, Below(first, rest, @TypeOf(frame), @TypeOf(k)){ .frame = frame, .k = k });
}

fn Rest(comptime rest: []const u8, comptime K: type) type {
    return struct {
        k: K,
        pub fn found(self: @This(), p: anytype) Error!void {
            if (rest.len == 0) return self.k.found(p);
            const dot = comptime std.mem.findScalar(u8, rest, '.');
            const part = if (dot) |d| rest[0..d] else rest;
            const more = if (dot) |d| rest[d + 1 ..] else "";
            return member(part, p, Rest(more, K){ .k = self.k }, self.k);
        }
    };
}

fn Below(comptime first: []const u8, comptime rest: []const u8, comptime F: type, comptime K: type) type {
    return struct {
        frame: F,
        k: K,
        pub fn missing(self: @This()) Error!void {
            if (@FieldType(@TypeOf(self.frame.*), "up") == void) return self.k.missing();
            return findFirst(first, rest, self.frame.up, self.k);
        }
    };
}

fn member(comptime key: []const u8, p: anytype, on_found: anytype, on_missing: anytype) Error!void {
    const T = @TypeOf(p.*);
    if (T == Value) return switch (p.*) {
        .map => |m| if (m.get(key)) |v| on_found.found(&v) else on_missing.missing(),
        else => on_missing.missing(),
    };
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (comptime value.isStringMap(T)) {
                if (p.getPtr(key)) |vp| return on_found.found(vp);
                return on_missing.missing();
            }
            if (info.is_tuple or comptime value.isArrayList(T)) return on_missing.missing();
            if (!@hasField(T, key)) return on_missing.missing();
            const idx = comptime for (info.field_names, 0..) |n, j| {
                if (std.mem.eql(u8, n, key)) break j;
            } else unreachable;
            if (comptime info.field_attrs[idx].@"comptime") return on_found.found(comptimePtr(@field(p.*, key)));
            return on_found.found(&@field(p.*, key));
        },
        .optional => {
            if (p.*) |*x| return member(key, x, on_found, on_missing);
            return on_missing.missing();
        },
        .pointer => |info| {
            if (info.size == .one and @typeInfo(info.child) != .array and @typeInfo(info.child) != .@"fn")
                return member(key, p.*, on_found, on_missing);
            return on_missing.missing();
        },
        .@"union" => switch (p.*) {
            inline else => |*x| return member(key, x, on_found, on_missing),
        },
        else => return on_missing.missing(),
    }
}

fn VarK(comptime F: type, comptime blocks: ?*const BlockFrame) type {
    return struct {
        c: *const Ctx,
        frame: F,
        escape: bool,
        pub fn found(self: @This(), p: anytype) Error!void {
            return writeTyped(self.c, self.frame, p, self.escape, blocks);
        }
        pub fn missing(_: @This()) Error!void {}
    };
}

fn writeTyped(c: *const Ctx, frame: anytype, p: anytype, escape: bool, comptime blocks: ?*const BlockFrame) Error!void {
    const T = @TypeOf(p.*);
    const w = c.w;
    if (T == Lambda or (T == Value and p.* == .lambda)) {
        var r = try runtimeRenderer(c, frame, blocks);
        defer r.deinit();
        try r.push(value.from(T, p));
        return r.render(&[_]Node{.{ .variable = .{ .name = ".", .escape = escape } }});
    }
    if (T == Value) return switch (p.*) {
        .null, .list, .map, .lambda => {},
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        inline .int, .uint, .float => |x| try w.print("{d}", .{x}),
        .string => |x| try writeStr(w, x, escape),
    };
    switch (@typeInfo(T)) {
        .bool => try w.writeAll(if (p.*) "true" else "false"),
        inline .int, .float => try w.print("{d}", .{p.*}),
        .@"enum" => try writeStr(w, @tagName(p.*), escape),
        .optional => if (p.*) |*x| try writeTyped(c, frame, x, escape, blocks),
        .array => |info| if (info.child == u8) try writeStr(w, p, escape),
        .pointer => |info| switch (info.size) {
            .one => switch (@typeInfo(info.child)) {
                .array => |arr| if (arr.child == u8) try writeStr(w, p.*, escape),
                .@"fn" => {
                    const v = value.from(T, p);
                    return writeTyped(c, frame, &v, escape, blocks);
                },
                else => try writeTyped(c, frame, p.*, escape, blocks),
            },
            .slice => if (info.child == u8) try writeStr(w, p.*, escape),
            .many, .c => @compileError("mustache: cannot read data of type " ++ @typeName(T)),
        },
        .@"union" => switch (p.*) {
            inline else => |*x| try writeTyped(c, frame, x, escape, blocks),
        },
        else => {},
    }
}

fn writeStr(w: *Writer, s: []const u8, escape: bool) Error!void {
    if (escape) return esc.writeEscaped(w, s);
    return w.writeAll(s);
}

fn SectionK(
    comptime nodes: []const Node,
    comptime partials: anytype,
    comptime index: usize,
    comptime active: []const []const u8,
    comptime blocks: ?*const BlockFrame,
    comptime F: type,
) type {
    const s = nodes[index].section;
    const body_from = index + 1;
    const body_to = s.end;
    return struct {
        c: *const Ctx,
        frame: F,
        const Self = @This();

        pub fn missing(self: Self) Error!void {
            if (s.inverted) try self.body(self.frame);
        }

        pub fn found(self: Self, p: anytype) Error!void {
            if (s.inverted) {
                if (!truthy(p)) try self.body(self.frame);
                return;
            }
            try self.section(p);
        }

        fn body(self: Self, frame: anytype) Error!void {
            return renderNodes(nodes, partials, body_from, body_to, active, blocks, frame, self.c);
        }

        fn pushBody(self: Self, p: anytype) Error!void {
            const top: Frame(@TypeOf(p.*), F) = .{ .v = p, .up = self.frame };
            return self.body(&top);
        }

        fn section(self: Self, p: anytype) Error!void {
            const T = @TypeOf(p.*);
            if (T == Value) return switch (p.*) {
                .null => {},
                .bool => |b| if (b) try self.pushBody(p),
                .list => |l| for (0..l.len) |k| {
                    const item = l.get(k);
                    try self.pushBody(&item);
                },
                .lambda => |l| try self.lambda(l),
                else => try self.pushBody(p),
            };
            if (T == Lambda) return self.lambda(p.*);
            switch (@typeInfo(T)) {
                .void, .null => {},
                .bool => if (p.*) try self.pushBody(p),
                .optional => if (p.*) |*x| try self.section(x),
                .array => |info| if (info.child == u8) try self.pushBody(p) else for (p) |*item| try self.pushBody(item),
                .pointer => |info| switch (info.size) {
                    .one => switch (@typeInfo(info.child)) {
                        .array => |arr| if (arr.child == u8) try self.pushBody(p) else for (p.*) |*item| try self.pushBody(item),
                        .@"fn" => try self.lambda(value.from(T, p).lambda),
                        else => try self.section(p.*),
                    },
                    .slice => if (info.child == u8) try self.pushBody(p) else for (p.*) |*item| try self.pushBody(item),
                    .many, .c => @compileError("mustache: cannot read data of type " ++ @typeName(T)),
                },
                .@"struct" => |info| {
                    if (info.is_tuple) {
                        inline for (info.field_attrs, 0..) |attrs, k| {
                            if (attrs.@"comptime") try self.pushBody(comptimePtr(p.*[k])) else try self.pushBody(&p.*[k]);
                        }
                    } else if (comptime value.isArrayList(T)) {
                        for (p.items) |*item| try self.pushBody(item);
                    } else try self.pushBody(p);
                },
                .@"union" => switch (p.*) {
                    inline else => |*x| try self.section(x),
                },
                else => try self.pushBody(p),
            }
        }

        fn lambda(self: Self, l: Lambda) Error!void {
            var r = try runtimeRenderer(self.c, self.frame, blocks);
            defer r.deinit();
            try r.renderLambda(l, s.raw, s.delims);
        }
    };
}

fn truthy(p: anytype) bool {
    const T = @TypeOf(p.*);
    if (T == Value) return p.truthy();
    if (T == Lambda) return true;
    return switch (@typeInfo(T)) {
        .void, .null => false,
        .bool => p.*,
        .optional => if (p.*) |*x| truthy(x) else false,
        .array => |info| info.child == u8 or info.len > 0,
        .pointer => |info| switch (info.size) {
            .one => switch (@typeInfo(info.child)) {
                .array => |arr| arr.child == u8 or arr.len > 0,
                .@"fn" => true,
                else => truthy(p.*),
            },
            .slice => info.child == u8 or p.len > 0,
            .many, .c => @compileError("mustache: cannot read data of type " ++ @typeName(T)),
        },
        .@"struct" => |info| if (info.is_tuple) info.field_names.len > 0 else if (comptime value.isArrayList(T)) p.items.len > 0 else true,
        .@"union" => switch (p.*) {
            inline else => |*x| truthy(x),
        },
        else => true,
    };
}
