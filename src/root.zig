//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const value = @import("value.zig");
const parser = @import("parser.zig");
const dynamic = @import("render.zig");
const static = @import("static.zig");
const library = @import("library.zig");
const Renderer = dynamic.Renderer;
const Cache = dynamic.Cache;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

pub const Comptime = static.Comptime;
pub const Library = library.Library;

pub const Node = parser.Node;
pub const Value = value.Value;
pub const Lambda = value.Lambda;
pub const Error = dynamic.Error;

pub const Template = struct {
    nodes: []const Node,

    pub fn parse(gpa: Allocator, src: []const u8) parser.Error!Template {
        return .{ .nodes = try parser.parse(gpa, src, "") };
    }

    pub fn deinit(self: Template, gpa: Allocator) void {
        gpa.free(self.nodes);
    }

    pub fn render(self: Template, gpa: Allocator, data: anytype, w: *Writer) Error!void {
        return self.renderPartials(gpa, data, null, w);
    }

    pub fn renderPartials(self: Template, gpa: Allocator, data: anytype, partials: anytype, w: *Writer) Error!void {
        const pv = if (comptime isComptimeOnly(@TypeOf(partials))) value.fromComptime(partials) else toValue(&partials);
        const dv = if (comptime isComptimeOnly(@TypeOf(data))) value.fromComptime(data) else toValue(&data);
        var cache: Cache = .init(gpa, null);
        defer cache.deinit();
        var r: Renderer = .init(gpa, w, pv, &cache);
        defer r.deinit();
        try r.push(dv);
        try r.render(self.nodes);
    }

    pub fn renderAlloc(self: Template, gpa: Allocator, data: anytype, partials: anytype) Error![]u8 {
        var out: Writer.Allocating = .init(gpa);
        defer out.deinit();
        try self.renderPartials(gpa, data, partials, &out.writer);
        return out.toOwnedSlice();
    }
};

pub fn render(gpa: Allocator, src: []const u8, data: anytype, w: *Writer) Error!void {
    return renderPartials(gpa, src, data, null, w);
}

pub fn renderPartials(gpa: Allocator, src: []const u8, data: anytype, partials: anytype, w: *Writer) Error!void {
    const t = try Template.parse(gpa, src);
    defer t.deinit(gpa);
    return t.renderPartials(gpa, data, partials, w);
}

pub fn allocRender(gpa: Allocator, src: []const u8, data: anytype, partials: anytype) Error![]u8 {
    const t = try Template.parse(gpa, src);
    defer t.deinit(gpa);
    return t.renderAlloc(gpa, data, partials);
}

pub fn toValue(ptr: anytype) Value {
    return value.from(@TypeOf(ptr.*), ptr);
}

fn isComptimeOnly(comptime T: type) bool {
    return value.Runtime(T) != T;
}

test {
    _ = @import("tokenizer.zig");
    _ = parser;
    _ = @import("escape.zig");
    _ = value;
    _ = static;
    _ = dynamic;
    _ = library;
}
