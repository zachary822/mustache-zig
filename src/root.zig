//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const value = @import("value.zig");
const parser = @import("parser.zig");
const Renderer = @import("render.zig").Renderer;
const static = @import("static.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;

pub const Comptime = static.Comptime;

pub const Node = parser.Node;
pub const Value = value.Value;
pub const Lambda = value.Lambda;
pub const Error = @import("render.zig").Error;

pub const Template = struct {
    nodes: []const Node,

    pub fn parse(gpa: Allocator, src: []const u8) parser.Error!Template {
        return .{ .nodes = try parser.parse(gpa, src) };
    }

    pub fn deinit(self: Template, gpa: Allocator) void {
        gpa.free(self.nodes);
    }

    pub fn render(self: Template, gpa: Allocator, data: anytype, w: *Writer) Error!void {
        return self.renderPartials(gpa, data, no_partials, w);
    }

    pub fn renderPartials(self: Template, gpa: Allocator, data: anytype, partials: anytype, w: *Writer) Error!void {
        const pv = if (comptime comptimeOnly(@TypeOf(partials))) value.fromComptime(partials) else toValue(&partials);
        const dv = if (comptime comptimeOnly(@TypeOf(data))) value.fromComptime(data) else toValue(&data);
        var r: Renderer = .init(gpa, w, pv);
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

pub const no_partials: ?Value = null;

pub fn render(gpa: Allocator, src: []const u8, data: anytype, w: *Writer) Error!void {
    return renderPartials(gpa, src, data, no_partials, w);
}

pub fn renderPartials(gpa: Allocator, src: []const u8, data: anytype, partials: anytype, w: *Writer) Error!void {
    const t = try Template.parse(gpa, src);
    defer t.deinit(gpa);
    return t.renderPartials(gpa, data, partials, w);
}

pub fn allocRender(gpa: std.mem.Allocator, src: []const u8, data: anytype, partials: anytype) ![]u8 {
    const t = try Template.parse(gpa, src);
    defer t.deinit(gpa);
    return t.renderAlloc(gpa, data, partials);
}

pub fn toValue(ptr: anytype) Value {
    const T = @typeInfo(@TypeOf(ptr)).pointer.child;
    if (T == ?Value) return ptr.* orelse .null;
    return value.from(T, ptr);
}

fn comptimeOnly(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .comptime_int, .comptime_float, .enum_literal, .null => true,
        else => false,
    };
}

test {
    _ = @import("tokenizer.zig");
    _ = parser;
    _ = @import("escape.zig");
    _ = value;
    _ = static;
}
