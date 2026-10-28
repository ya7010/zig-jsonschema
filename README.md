# zig-jsonschema

JSON Schema for Zig 0.17, in two parts:

- **Comptime schema generation and typed decoding.** Declare constraints on
  a Zig struct with `Schema(T, constraints)`, generate a JSON Schema
  document from it (any of drafts 4, 6, 7, 2019-09, 2020-12), and decode
  JSON straight into a plain Zig value with `fromJson`. The generated
  schema and `fromJson` are built from the same declaration, so they
  always accept exactly the same documents.
- **A runtime `Validator`** for arbitrary JSON Schema documents, not only
  ones generated from Zig types — `$ref`, `$dynamicRef`, `unevaluated*`,
  formats (including IDNA2008 hostnames), an ECMA-262 regex engine, and the
  standard output formats (`flag` / `basic` / `detailed` / `verbose`).
  Verified against the full
  [JSON-Schema-Test-Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)
  — required and optional tests, every draft, all passing.

## Installation

```sh
zig fetch --save git+https://github.com/ya7010/zig-jsonschema
```

```zig
// build.zig
const dep = b.dependency("jsonschema", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("jsonschema", dep.module("jsonschema"));
```

## Quick start

```zig
const std = @import("std");
const js = @import("jsonschema");

const Product = struct {
    name: js.Schema([]const u8, .{ .minLength = 1, .maxLength = 100 }),
    price: js.Schema(f64, .{ .minimum = 0, .exclusiveMinimum = 0 }),
    quantity: js.Schema(u32, .{ .minimum = 0, .default = 1 }),
    tags: js.Schema([]const []const u8, .{ .minItems = 1, .uniqueItems = true }),
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Generate a JSON Schema document from the declaration. `.schema` is null
    // only if `.errors` is not empty (names that `field_naming` makes the same
    // key), as `fromJson` reports its errors.
    const generated = try js.toSchema(Product, a, .{});
    const schema = generated.schema.?;
    _ = schema;

    // Decode JSON into a plain Zig value (js.Unwrap(Product)), validating
    // in the same pass. `result.value` is null if `errors` is non-empty.
    const result = try js.fromJson(Product, a, "{\"name\": \"Widget\", \"price\": 12.5, \"tags\": [\"sale\"]}", .{});
    if (result.value) |p| std.debug.print("{s}: {d}\n", .{ p.name, p.price });
}
```

`Schema(T, constraints)` is a compile-time label, not a runtime wrapper: the
value you actually read and write is the "plain" type produced by
`Unwrap()` (`js.Unwrap(Product)` above), so there is no `.value` to unpack.

Supported kinds: numbers (bounded by the Zig type's own range, e.g. `u8` is
0..255), strings, booleans, arrays, objects (nested structs, shared via
`$defs`, recursion included, or flattened into the enclosing object with
`.flatten`), tagged unions (`union(enum)`, as `oneOf`,
either externally or internally tagged, or as `anyOf` when untagged) and integer newtypes
(non-exhaustive enums). `SchemaOptions` (shared by `toSchema` and
`fromJson`) picks the draft, how unknown object keys are handled, a root
`$id`, the JSON spelling of field names (`camelCase`, `snake_case`, ...),
and whether tagged unions are written as `oneOf` or as
`if` / `then` per variant (`union_encoding`, for clearer errors in other
validators).

Keywords the constraint fields don't cover (`if` / `then` / `else`, `allOf`,
`not`, `enum`, ...) go in `.extra`, as JSON text merged into the generated
schema. It is checked at comptime (it must be a JSON object that doesn't
contain a keyword the generator emits for that kind of value), and
`fromJson` enforces it with the runtime validator (use a `js.Decoder` to
decode many documents, which compiles that schema once instead of on every
call):

```zig
const Payment = js.Schema(struct {
    method: []const u8,
    card_number: ?[]const u8,
}, .{ .extra =
    \\{"if": {"properties": {"method": {"const": "card"}}},
    \\ "then": {"required": ["card_number"]}}
});
```

A type whose JSON doesn't follow its layout can write its whole schema
itself, with `pub fn jsonSchema(gen: *js.SchemaGen)`, together with
std.json's `pub fn jsonParseFromValue` to decode it. `fromJson` checks the
JSON against that schema before decoding (see
[`examples/custom.zig`](examples/custom.zig)).

## The runtime validator

```zig
var v = js.Validator.init(allocator, .{});
defer v.deinit();
const schema = try v.compileJson(schema_text);

const ok = try schema.isValid(instance);               // stop at the first failure
const result = try schema.validate(allocator, instance); // every error, with its location
const output = try schema.output(allocator, instance, .basic); // standard output format
```

See [`examples/`](examples/) for runnable examples of every feature,
listed in [`examples/README.md`](examples/README.md).

## Development

```sh
zig build test        # unit tests + the official JSON-Schema-Test-Suite
zig build test-suite -Dsuite-verbose   # just the test suite, listing every failure
zig build examples    # build and run every example
```

`tests/schema_gen/` holds reviewable snapshots of generated schemas, one
per example case per draft; after a generator change, run
`zig build test-schema-gen -Dupdate-snapshots` and review the diff.

## Known limitations

- A recursive type cannot contain `Schema()` labels (Zig cannot build a
  self-referential unwrapped type); use plain field types in the cycle.
- The suite's `output-tests` are checked, but annotation collection beyond
  what they exercise is lightly tested.
