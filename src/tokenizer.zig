const std = @import("std");

pub const Kind = enum {
    text, // plain text between tags
    variable, // {{name}}
    unescaped, // {{{name}}} or {{&name}}
    section, // {{#name}}
    inverted, // {{^name}}
    close, // {{/name}}
    comment, // {{! ...}}
    partial, // {{>name}}
    parent, // {{<name}}
    block, // {{$name}}
    set_delimiters, // {{=<% %>=}}

    /// The spec lets these tags be "standalone"
    pub fn canBeStandalone(k: Kind) bool {
        return switch (k) {
            .section, .inverted, .close, .comment, .partial, .block, .set_delimiters => true,
            .text, .variable, .unescaped, .parent => false,
        };
    }
};

pub const Token = struct {
    kind: Kind,
    /// For .text: the text. For tags: the trimmed name
    value: []const u8,
    start: usize,
    end: usize,
    indent: []const u8 = "",
    dynamic: bool = false,
    line_start: ?usize = null,
    line_after: ?usize = null,
    standalone: bool = false,
};

pub const Error = error{ UnclosedTag, EmptyTag, BadName, BadDelimiters };

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn findDelim(src: []const u8, start: usize, delim: []const u8) ?usize {
    var i = start;
    while (std.mem.findScalarPos(u8, src, i, delim[0])) |at| {
        if (std.mem.startsWith(u8, src[at..], delim)) return at;
        i = at + 1;
    }
    return null;
}

pub const Tokenizer = struct {
    src: []const u8,
    pos: usize = 0,
    open: []const u8 = "{{",
    close: []const u8 = "}}",
    delims: []const u8 = "",

    last_tag_end: usize = 0,

    pending: ?Token = null,

    pub fn init(src: []const u8) Tokenizer {
        return .{ .src = src };
    }

    pub fn next(self: *Tokenizer) Error!?Token {
        if (self.pending) |tok| {
            self.pending = null;
            return tok;
        }
        if (self.pos >= self.src.len) return null;

        const tag_start = findDelim(self.src, self.pos, self.open) orelse {
            const start = self.pos;
            self.pos = self.src.len;
            return .{ .kind = .text, .value = self.src[start..], .start = start, .end = self.src.len };
        };

        var tag = try self.readTag(tag_start);
        const text_start = self.pos;
        var text_end = tag_start;
        self.pos = tag.end;

        if (tag.kind.canBeStandalone() or tag.kind == .parent) {
            tag.line_start = self.clearLeft(tag.start);
            tag.line_after = self.clearRight(tag.end);
            if (tag.kind.canBeStandalone() and tag.line_start != null and tag.line_after != null) {
                text_end = tag.line_start.?;
                tag.indent = self.src[text_end..tag.start];
                self.pos = tag.line_after.?;
                tag.standalone = true;
            }
        }
        self.last_tag_end = tag.end;

        if (text_end > text_start) {
            self.pending = tag;
            return .{ .kind = .text, .value = self.src[text_start..text_end], .start = text_start, .end = text_end };
        }
        return tag;
    }

    fn readTag(self: *Tokenizer, start: usize) Error!Token {
        var i = start + self.open.len;
        if (i >= self.src.len) return error.UnclosedTag;

        var kind: Kind = .variable;
        var close = self.close;
        var close_buf: [64]u8 = undefined;

        switch (self.src[i]) {
            '#' => kind = .section,
            '^' => kind = .inverted,
            '/' => kind = .close,
            '!' => kind = .comment,
            '>' => kind = .partial,
            '<' => kind = .parent,
            '$' => kind = .block,
            '&' => kind = .unescaped,
            '{' => {
                kind = .unescaped;
                close = try concat(&close_buf, "}", self.close);
            },
            '=' => {
                kind = .set_delimiters;
                close = try concat(&close_buf, "=", self.close);
            },
            else => i -= 1, // no sigil, name starts here
        }
        i += 1;

        const close_at = findDelim(self.src, i, close) orelse return error.UnclosedTag;
        const end = close_at + close.len;
        var value = if (kind == .comment) self.src[i..close_at] else std.mem.trim(u8, self.src[i..close_at], " \t\r\n");
        var dynamic = false;
        if ((kind == .partial or kind == .parent) and value.len > 0 and value[0] == '*') {
            dynamic = true;
            value = std.mem.trim(u8, value[1..], " \t\r\n");
        }
        if (value.len == 0 and kind != .comment) return error.EmptyTag;

        if (kind != .comment and kind != .set_delimiters) {
            if (std.mem.findAny(u8, value, " \t\r\n") != null) return error.BadName;
            // {{{ }}} tags cannot contain }} inside it
            if (close.len != self.close.len and std.mem.find(u8, value, self.close) != null) return error.BadName;
        }

        if (kind == .set_delimiters) try self.setDelims(value);

        return .{ .kind = kind, .value = value, .start = start, .end = end, .dynamic = dynamic };
    }

    /// `delims` is the text between `=` and `=`, for example "<% %>".
    pub fn setDelims(self: *Tokenizer, delims: []const u8) Error!void {
        var parts = std.mem.tokenizeAny(u8, delims, " \t\r\n");
        const open = parts.next() orelse return error.BadDelimiters;
        const close = parts.next() orelse return error.BadDelimiters;
        if (parts.next() != null) return error.BadDelimiters;
        self.open = open;
        self.close = close;
        self.delims = delims;
    }

    fn clearLeft(self: *const Tokenizer, start: usize) ?usize {
        var a = start;
        while (a > 0 and isBlank(self.src[a - 1])) a -= 1;
        if (a > 0 and self.src[a - 1] != '\n') return null;
        if (a < self.last_tag_end) return null;
        return a;
    }

    fn clearRight(self: *const Tokenizer, end: usize) ?usize {
        var b = end;
        while (b < self.src.len and isBlank(self.src[b])) b += 1;
        if (b == self.src.len) return b;
        if (self.src[b] == '\n') return b + 1;
        if (self.src[b] == '\r' and b + 1 < self.src.len and self.src[b + 1] == '\n') return b + 2;
        return null;
    }
};

fn concat(buf: []u8, a: []const u8, b: []const u8) Error![]const u8 {
    if (a.len + b.len > buf.len) return error.BadDelimiters;
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

test "dynamic names" {
    var t: Tokenizer = .init("{{> * dyn }}{{<*a.b}}{{/a.b}}");
    const p = (try t.next()).?;
    try std.testing.expect(p.kind == .partial and p.dynamic);
    try std.testing.expectEqualStrings("dyn", p.value);
    const q = (try t.next()).?;
    try std.testing.expect(q.kind == .parent and q.dynamic);
    try std.testing.expectEqualStrings("a.b", q.value);
}

test "names with whitespace" {
    var a: Tokenizer = .init("{{a b}}");
    try std.testing.expectError(error.BadName, a.next());
    var b: Tokenizer = .init("{{a\x0bb}}");
    try std.testing.expectEqualStrings("a\x0bb", (try b.next()).?.value);
}
