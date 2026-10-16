# mustache-zig

A [Mustache](https://mustache.github.io/) template engine for Zig.

- Render templates at runtime, or parse them at compile time.
- Use plain Zig structs, slices, optionals, hash maps and `std.json.Value` as data.
- Supports variables, sections, inverted sections, comments, partials, set delimiters, lambdas,
  template inheritance and dynamic names.
- Tested against the official [Mustache spec](https://github.com/mustache/spec).

Requires Zig 0.17.0 or later.

## Install

```sh
zig fetch --save git+https://github.com/zachary822/mustache-zig
```

Then add the module in `build.zig`:

```zig
const mustache = b.dependency("mustache_zig", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("mustache", mustache.module("mustache_zig"));
```

## Usage

### Runtime templates

```zig
const std = @import("std");
const mustache = @import("mustache");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const data = .{ .name = "World", .items = &[_][]const u8{ "a", "b" } };
    const partials = .{ .item = "[{{.}}]" };

    const out = try mustache.allocRender(alloc, "Hello, {{name}}! {{#items}}{{>item}}{{/items}}", data, partials);
    defer alloc.free(out);
    // out == "Hello, World! [a][b]"
}
```

To render the same template more than one time, parse it one time:

```zig
const t = try mustache.Template.parse(alloc, "Hello, {{name}}!");
defer t.deinit(alloc);
try t.render(alloc, .{ .name = "Ann" }, writer);
```

### Comptime templates

The template is parsed at compile time. A bad template is a compile error.

```zig
const Hello = mustache.Comptime("Hello, {{name}}!", .{});
const out = try Hello.renderAlloc(alloc, .{ .name = "World" });
defer alloc.free(out);
```

### Lambdas

A function pointer in the data is a lambda. It gets the raw section text.

```zig
fn bold(text: []const u8, out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.print("<b>{s}</b>", .{text});
}

const data = .{ .bold = &bold };
// "{{#bold}}hi{{/bold}}" renders "<b>hi</b>"
```

### Inheritance

A parent tag (`{{<name}}`) renders a partial as a parent template.
Block tags (`{{$name}}`) in the child replace the blocks with the same name in the parent.
A block in the parent that the child does not replace renders its default content.

```zig
const partials = .{ .layout = "<h1>{{$title}}Default{{/title}}</h1>" };
const out = try mustache.allocRender(alloc, "{{<layout}}{{$title}}Home{{/title}}{{/layout}}", .{}, partials);
// out == "<h1>Home</h1>"
```

### Dynamic names

A `*` before a partial or parent name makes the name dynamic.
The engine finds the partial name in the data.

```zig
const data = .{ .kind = "item" };
const partials = .{ .item = "[item]" };
// "{{>*kind}}" renders "[item]"
```

## Command-line tool

```sh
zig build run -- TEMPLATE [DATA.json] [PARTIALS.json]
```

Example files are in `examples/`:

```sh
zig build run -- examples/basic.mustache examples/basic.json
zig build run -- examples/partials.mustache examples/partials.json examples/partials.partials.json
```

## Tests

```sh
zig build test
zig build test -Dtest-filter="sections.json"
```

The spec tests are generated from the Mustache spec by `tools/gen_spec_tests.zig`.

## Spec support

| Spec | Status |
|---|---|
| Interpolation, sections, inverted, comments, partials, delimiters | Supported |
| Lambdas | Supported |
| Dynamic names | Supported |
| Inheritance | Supported |
