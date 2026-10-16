const std = @import("std");
const Io = std.Io;

pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    uint: u64,
    float: f64,
    string: []const u8,
    list: List,
    map: Map,
    lambda: Lambda,

    pub const List = struct {
        ptr: *const anyopaque,
        len: usize,
        at: *const fn (ptr: *const anyopaque, i: usize) Value,

        pub fn get(self: List, i: usize) Value {
            return self.at(self.ptr, i);
        }
    };

    pub const Map = struct {
        ptr: *const anyopaque,

        lookup: *const fn (ptr: *const anyopaque, key: []const u8) ?Value,

        pub fn get(self: Map, key: []const u8) ?Value {
            return self.lookup(self.ptr, key);
        }
    };

    pub fn truthy(self: Value) bool {
        return switch (self) {
            .null => false,
            .bool => |b| b,
            .list => |l| l.len > 0,
            else => true,
        };
    }
};

pub const Lambda = struct {
    ctx: ?*const anyopaque = null,
    func: *const fn (ctx: ?*const anyopaque, text: []const u8, out: *Io.Writer) Io.Writer.Error!void,
};

pub fn from(comptime T: type, p: *const T) Value {
    if (T == Value) return p.*;

    switch (@typeInfo(T)) {
        .void, .null => return .null,
        .bool => return .{ .bool = p.* },
        .int => |info| {
            if (info.bits > 64) @compileError("mustache: integers wider than 64 bits are not supported: " ++ @typeName(T));
            return if (info.signedness == .signed) .{ .int = p.* } else .{ .uint = p.* };
        },
        .float => return .{ .float = @floatCast(p.*) },
        .comptime_int, .comptime_float, .enum_literal => @compileError("mustache: comptime-only value; use fromComptime"),
        .@"enum" => |info| {
            if (info.mode == .exhaustive) return .{ .string = @tagName(p.*) };
            inline for (info.field_names) |name| {
                if (p.* == @field(T, name)) return .{ .string = name };
            }
            return .{ .int = @intCast(@backingInt(p.*)) };
        },
        .optional => |info| {
            if (p.*) |*x| return from(info.child, x);
            return .null;
        },
        .pointer => |info| switch (info.size) {
            .one => switch (@typeInfo(info.child)) {
                .array => |arr| {
                    if (arr.child == u8) return .{ .string = p.*[0..arr.len] };
                    return sliceList(arr.child, p.*);
                },
                .@"fn" => return fnValue(info.child, p.*),
                .@"opaque" => @compileError("mustache: cannot read data of type " ++ @typeName(T)),
                else => return from(info.child, p.*),
            },
            .slice => {
                if (info.child == u8) return .{ .string = p.* };
                return sliceList(info.child, p.*);
            },
            .many, .c => @compileError("mustache: cannot read data of type " ++ @typeName(T)),
        },
        .array => |info| {
            if (info.child == u8) return .{ .string = p };
            return sliceList(info.child, p);
        },
        .@"struct" => |info| {
            if (info.is_tuple) return tupleList(T, p);
            if (comptime isArrayList(T)) return sliceList(@typeInfo(@FieldType(T, "items")).pointer.child, p.items);
            if (comptime isStringMap(T)) return hashMap(T, p);
            return structMap(T, p);
        },
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("mustache: untagged unions are not supported: " ++ @typeName(T));
            switch (p.*) {
                inline else => |*x| return from(@TypeOf(x.*), x),
            }
        },
        .@"fn" => @compileError("mustache: use a function pointer or mustache.Lambda, not a function body: " ++ @typeName(T)),
        else => @compileError("mustache: cannot read data of type " ++ @typeName(T)),
    }
}

pub fn fromComptime(comptime v: anytype) Value {
    return from(Runtime(@TypeOf(v)), comptimePtr(v));
}

/// A runtime type that can hold a comptime-only value.
pub fn Runtime(comptime V: type) type {
    return switch (@typeInfo(V)) {
        .comptime_int => i64,
        .comptime_float => f64,
        .enum_literal => []const u8,
        .null => ?u8,
        else => V,
    };
}

/// A pointer to a static copy of `v`, with a runtime type.
pub fn comptimePtr(comptime v: anytype) *const Runtime(@TypeOf(v)) {
    const S = struct {
        const x: Runtime(@TypeOf(v)) = if (@typeInfo(@TypeOf(v)) == .enum_literal) @tagName(v) else v;
    };
    return &S.x;
}

fn fnValue(comptime F: type, f: *const F) Value {
    if (*const F == @FieldType(Lambda, "func")) return .{ .lambda = .{ .func = f } };
    const Plain = *const fn (text: []const u8, out: *Io.Writer) Io.Writer.Error!void;
    if (*const F == Plain) {
        const S = struct {
            fn call(ctx: ?*const anyopaque, text: []const u8, out: *Io.Writer) Io.Writer.Error!void {
                const g: Plain = @ptrCast(@alignCast(ctx.?));
                return g(text, out);
            }
        };
        return .{ .lambda = .{ .ctx = @ptrCast(f), .func = S.call } };
    }
    @compileError("mustache: a function in the data must be fn ([]const u8, *std.Io.Writer) std.Io.Writer.Error!void, not " ++ @typeName(F));
}

fn sliceList(comptime E: type, s: []const E) Value {
    const S = struct {
        fn at(ptr: *const anyopaque, i: usize) Value {
            const items: [*]const E = @ptrCast(@alignCast(ptr));
            return from(E, &items[i]);
        }
    };
    return .{ .list = .{ .ptr = @ptrCast(s.ptr), .len = s.len, .at = S.at } };
}

fn tupleList(comptime T: type, p: *const T) Value {
    const info = @typeInfo(T).@"struct";
    const S = struct {
        fn at(ptr: *const anyopaque, i: usize) Value {
            const t: *const T = @ptrCast(@alignCast(ptr));
            inline for (info.field_attrs, 0..) |attrs, k| {
                if (i == k) {
                    if (attrs.@"comptime") return fromComptime(t[k]);
                    return from(@TypeOf(t[k]), &t[k]);
                }
            }
            unreachable;
        }
    };
    return .{ .list = .{ .ptr = @ptrCast(p), .len = info.field_names.len, .at = S.at } };
}

fn structMap(comptime T: type, p: *const T) Value {
    const info = @typeInfo(T).@"struct";
    const S = struct {
        fn lookup(ptr: *const anyopaque, key: []const u8) ?Value {
            const s: *const T = @ptrCast(@alignCast(ptr));
            const k = prefix(key);
            inline for (info.field_names, info.field_types, info.field_attrs) |name, FT, attrs| {
                const n = comptime prefix(name);
                if (key.len == name.len and k == n and (name.len <= 8 or std.mem.eql(u8, key[8..], name[8..]))) {
                    if (attrs.@"comptime") return fromComptime(@field(s.*, name));
                    return from(FT, &@field(s.*, name));
                }
            }
            return null;
        }
    };

    return .{ .map = .{ .ptr = @ptrCast(p), .lookup = S.lookup } };
}

fn prefix(s: []const u8) u64 {
    var buf: [8]u8 = @splat(0);
    const n = @min(s.len, 8);
    @memcpy(buf[0..n], s[0..n]);
    return @bitCast(buf);
}

fn hashMap(comptime T: type, p: *const T) Value {
    const S = struct {
        fn lookup(ptr: *const anyopaque, key: []const u8) ?Value {
            const m: *const T = @ptrCast(@alignCast(ptr));
            const vp = m.getPtr(key) orelse return null;
            return from(@TypeOf(vp.*), vp);
        }
    };
    return .{ .map = .{ .ptr = @ptrCast(p), .lookup = S.lookup } };
}

pub fn isArrayList(comptime T: type) bool {
    if (!@hasField(T, "items") or !@hasField(T, "capacity")) return false;
    const I = @typeInfo(@FieldType(T, "items"));
    return I == .pointer and I.pointer.size == .slice;
}

pub fn isStringMap(comptime T: type) bool {
    if (!@hasDecl(T, "KV") or !@hasDecl(T, "getPtr")) return false;
    if (!@hasField(T.KV, "key")) return false;
    return @FieldType(T.KV, "key") == []const u8;
}

test "Values from Zig data" {
    const d = .{ .name = "Ann", .n = 3, .xs = .{ 1, 2 }, .e = .red, .none = null };
    const v = fromComptime(d);

    try std.testing.expectEqualStrings("Ann", v.map.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 3), v.map.get("n").?.int);
    try std.testing.expectEqual(@as(usize, 2), v.map.get("xs").?.list.len);
    try std.testing.expectEqualStrings("red", v.map.get("e").?.string);
    try std.testing.expect(v.map.get("none").? == .null);
    try std.testing.expect(v.map.get("nope") == null);

    var x: i32 = -4;
    x += 1;
    const opt: ?[]const u8 = "hi";
    const r = .{ .x = x, .opt = opt, .list = &[_]u16{ 7, 8, 9 } };
    const rv = from(@TypeOf(r), &r);
    try std.testing.expectEqual(@as(i64, -3), rv.map.get("x").?.int);
    try std.testing.expectEqualStrings("hi", rv.map.get("opt").?.string);
    try std.testing.expectEqual(@as(u64, 9), rv.map.get("list").?.list.get(2).uint);
}
