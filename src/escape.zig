const std = @import("std");
const Writer = std.Io.Writer;

const vec_len = std.simd.suggestVectorLength(u8) orelse 16;
const Vec = @Vector(vec_len, u8);
const Mask = @Int(.unsigned, vec_len);

fn entity(c: u8) []const u8 {
    return switch (c) {
        '&' => "&amp;",
        '"' => "&quot;",
        '\'' => "&#39;",
        '<' => "&lt;",
        '>' => "&gt;",
        else => unreachable,
    };
}

const slack = vec_len + 8;

pub fn writeEscaped(w: *Writer, s: []const u8) Writer.Error!void {
    const chunk_max = (w.buffer.len -| slack) / 6;
    if (chunk_max < 4 * vec_len) return writeEscapedRuns(w, s);
    var rest = s;
    while (rest.len > 0) {
        const n = @min(rest.len, chunk_max);
        const dst = try w.writableSliceGreedy(n * 6 + slack);
        w.advance(escapeInto(dst, rest[0..n]));
        rest = rest[n..];
    }
}

fn specialMask(v: Vec) Mask {
    return @as(Mask, @bitCast(v == @as(Vec, @splat('&')))) |
        @as(Mask, @bitCast(v == @as(Vec, @splat('<')))) |
        @as(Mask, @bitCast(v == @as(Vec, @splat('>')))) |
        @as(Mask, @bitCast(v == @as(Vec, @splat('"')))) |
        @as(Mask, @bitCast(v == @as(Vec, @splat('\''))));
}

fn escapeInto(dst: []u8, src: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + vec_len <= src.len) : (i += vec_len) {
        const v: Vec = src[i..][0..vec_len].*;
        if (specialMask(v) == 0) {
            dst[n..][0..vec_len].* = v;
            n += vec_len;
        } else {
            n += escapeBytes(dst[n..], src[i..][0..vec_len]);
        }
    }

    const tail = src[i..];
    if (tail.len == 0) return n;
    var pad: [vec_len]u8 = @splat(0);
    @memcpy(pad[0..tail.len], tail);
    const v: Vec = pad;
    if (specialMask(v) == 0) {
        dst[n..][0..vec_len].* = v;
        return n + tail.len;
    }
    return n + escapeBytes(dst[n..], tail);
}

const table = blk: {
    var out: [256][8]u8 = undefined;
    var lens: [256]u8 = undefined;
    for (0..256) |c| {
        out[c] = @splat(0);
        out[c][0] = c;
        lens[c] = 1;
    }
    for ("&\"'<>") |c| {
        const e = entity(c);
        @memcpy(out[c][0..e.len], e);
        lens[c] = e.len;
    }
    break :blk .{ .out = out, .lens = lens };
};

fn escapeBytes(dst: []u8, src: []const u8) usize {
    var n: usize = 0;
    for (src) |c| {
        dst[n..][0..8].* = table.out[c];
        n += table.lens[c];
    }
    return n;
}

fn writeEscapedRuns(w: *Writer, s: []const u8) Writer.Error!void {
    var start: usize = 0;
    var i: usize = 0;

    while (i + vec_len <= s.len) : (i += vec_len) {
        var m = specialMask(s[i..][0..vec_len].*);
        while (m != 0) : (m &= m - 1) {
            const at = i + @ctz(m);
            try w.writeAll(s[start..at]);
            try w.writeAll(entity(s[at]));
            start = at + 1;
        }
    }
    while (i < s.len) : (i += 1) switch (s[i]) {
        '&', '"', '\'', '<', '>' => {
            try w.writeAll(s[start..i]);
            try w.writeAll(entity(s[i]));
            start = i + 1;
        },
        else => {},
    };
    try w.writeAll(s[start..]);
}
