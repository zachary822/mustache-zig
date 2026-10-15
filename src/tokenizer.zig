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
    set_delimiters, // {{=<% %>=}}

    /// The spec lets these tags be "standalone"
    pub fn canBeStandalone(k: Kind) bool {
        return switch (k) {
            .section, .inverted, .close, .comment, .partial, .set_delimiters => true,
            .text, .variable, .unescaped => false,
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

        if (tag.kind.canBeStandalone()) {
            if (self.standaloneLine(tag.start, tag.end)) |line| {
                text_end = line.indent_start;
                tag.indent = self.src[line.indent_start..tag.start];
                self.pos = line.after;
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
        const value = if (kind == .comment) self.src[i..close_at] else std.mem.trim(u8, self.src[i..close_at], " \t\r\n");
        if (value.len == 0 and kind != .comment) return error.EmptyTag;

        if (kind != .comment and kind != .set_delimiters) {
            for (value) |ch| switch (ch) {
                ' ', '\t', '\r', '\n' => return error.BadName,
                else => {},
            };
            // {{{ }}} tags cannot contain }} inside it
            if (close.len != self.close.len and std.mem.find(u8, value, self.close) != null) return error.BadName;
        }

        if (kind == .set_delimiters) {
            var parts = std.mem.tokenizeAny(u8, value, " \t\r\n");
            const new_open = parts.next() orelse return error.BadDelimiters;
            const new_close = parts.next() orelse return error.BadDelimiters;
            if (parts.next()) |_| {
                return error.BadDelimiters;
            }
            self.open = new_open;
            self.close = new_close;
            self.delims = value;
        }

        return .{ .kind = kind, .value = value, .start = start, .end = end };
    }

    const Line = struct { indent_start: usize, after: usize };

    fn standaloneLine(self: *const Tokenizer, start: usize, end: usize) ?Line {
        var a = start;

        while (a > 0 and isBlank(self.src[a - 1])) a -= 1;
        if (a > 0 and self.src[a - 1] != '\n') return null;

        if (a < self.last_tag_end) return null;

        var b = end;
        while (b < self.src.len and isBlank(self.src[b])) b += 1;
        if (b == self.src.len) return .{ .indent_start = a, .after = b };
        if (self.src[b] == '\n') return .{ .indent_start = a, .after = b + 1 };
        if (self.src[b] == '\r' and b + 1 < self.src.len and self.src[b + 1] == '\n')
            return .{ .indent_start = a, .after = b + 2 };
        return null;
    }
};

fn concat(buf: []u8, a: []const u8, b: []const u8) Error![]const u8 {
    if (a.len + b.len > buf.len) return error.BadDelimiters;
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

test "test tokenizer" {
    const gpa = std.testing.allocator;

    const source = "fun template {{{name  }}}";

    var tokenizer: Tokenizer = .init(source);

    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(gpa);

    while (try tokenizer.next()) |token| {
        try tokens.append(gpa, token);
    }

    try std.testing.expectEqualStrings("fun template ", tokens.items[0].value);
    try std.testing.expectEqualStrings("name", tokens.items[1].value);
}

test "names with whitespace" {
    var a: Tokenizer = .init("{{a b}}");
    try std.testing.expectError(error.BadName, a.next());
    var b: Tokenizer = .init("{{a\x0bb}}");
    try std.testing.expectEqualStrings("a\x0bb", (try b.next()).?.value);
}
