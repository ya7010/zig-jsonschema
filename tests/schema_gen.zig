//! Snapshot tests for schema generation (`toSchema`).
//!
//! Every case below is generated for every supported draft and compared
//! with the reviewed snapshot in `tests/schema_gen/<case>/<draft>.schema.json`.
//! Each snapshot must also be a valid schema for its draft's metaschema.
//!
//! After an intentional change to the generator, regenerate the snapshots
//! with `zig build test-schema-gen -Dupdate-snapshots` and review the diff.

const std = @import("std");
const js = @import("jsonschema");
const options = @import("schema_gen_options");

const Schema = js.Schema;

const drafts = [_]struct { name: []const u8, draft: js.Draft }{
    .{ .name = "draft4", .draft = .draft4 },
    .{ .name = "draft6", .draft = .draft6 },
    .{ .name = "draft7", .draft = .draft7 },
    .{ .name = "draft2019-09", .draft = .draft2019_09 },
    .{ .name = "draft2020-12", .draft = .draft2020_12 },
};

fn checkCase(comptime case_name: []const u8, comptime Decl: type) !void {
    return checkCaseWith(case_name, Decl, .{});
}

/// `base` supplies every option except `draft`, which is iterated.
fn checkCaseWith(comptime case_name: []const u8, comptime Decl: type, base: js.SchemaOptions) !void {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var root = try std.Io.Dir.cwd().openDir(io, options.snapshot_dir, .{});
    defer root.close(io);
    if (options.update) try root.createDirPath(io, case_name);

    var mismatches: usize = 0;
    for (drafts) |d| {
        var opts = base;
        opts.draft = d.draft;
        const schema = (try js.toSchema(Decl, arena, opts)).schema.?;
        const actual = try std.fmt.allocPrint(arena, "{s}\n", .{
            try std.json.Stringify.valueAlloc(arena, schema, .{ .whitespace = .indent_2 }),
        });
        const path = try std.fmt.allocPrint(arena, "{s}/{s}.schema.json", .{ case_name, d.name });

        // Whatever we generate must be a valid schema for the target draft.
        var v = js.Validator.init(std.testing.allocator, .{});
        defer v.deinit();
        if (!try v.isValidSchema(schema)) {
            std.debug.print("{s}: not valid against the {s} metaschema\n", .{ path, d.name });
            mismatches += 1;
        }

        if (options.update) {
            try root.writeFile(io, .{ .sub_path = path, .data = actual });
            continue;
        }
        const expected = root.readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("{s}: snapshot missing (run `zig build test-schema-gen -Dupdate-snapshots`)\n", .{path});
                mismatches += 1;
                continue;
            },
            else => |e| return e,
        };
        if (!std.mem.eql(u8, expected, actual)) {
            std.debug.print("{s}: generated schema differs from the snapshot\n", .{path});
            printFirstDifference(expected, actual);
            mismatches += 1;
        }
    }
    if (mismatches > 0) return error.SnapshotMismatch;
}

fn printFirstDifference(expected: []const u8, actual: []const u8) void {
    var e_lines = std.mem.splitScalar(u8, expected, '\n');
    var a_lines = std.mem.splitScalar(u8, actual, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const e = e_lines.next();
        const a = a_lines.next();
        if (e == null and a == null) return;
        if (e == null or a == null or !std.mem.eql(u8, e.?, a.?)) {
            std.debug.print("  line {d}:\n  - snapshot:  {s}\n  + generated: {s}\n", .{ line, e orelse "<eof>", a orelse "<eof>" });
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------

test "product: every constraint kind" {
    try checkCase("product", struct {
        name: Schema([]const u8, .{ .title = "Name", .minLength = 1, .maxLength = 100 }),
        price: Schema(f64, .{
            .title = "Price",
            .description = "Unit price in JPY, must be positive",
            .minimum = 0,
            .exclusiveMinimum = 0,
        }),
        quantity: Schema(u32, .{ .minimum = 0, .maximum = 1000, .default = 1 }),
        discount: Schema(?f64, .{ .minimum = 0, .maximum = 1 }),
        in_stock: Schema(bool, .{ .title = "In stock", .default = true }),
        tags: Schema([]const []const u8, .{ .title = "Tags", .minItems = 1, .maxItems = 5, .uniqueItems = true }),
    });
}

test "numeric_bounds: inclusive/exclusive combinations and multipleOf" {
    try checkCase("numeric_bounds", struct {
        /// Only exclusive bounds.
        exclusive_only: Schema(f64, .{ .exclusiveMinimum = 0, .exclusiveMaximum = 1 }),
        /// Exclusive bound is the stricter one on both sides.
        exclusive_stricter: Schema(f64, .{ .minimum = 0, .exclusiveMinimum = 5, .maximum = 100, .exclusiveMaximum = 50 }),
        /// Inclusive bound is the stricter one on both sides.
        inclusive_stricter: Schema(f64, .{ .minimum = 10, .exclusiveMinimum = 5, .maximum = 20, .exclusiveMaximum = 50 }),
        /// Equal bounds: the exclusive one wins.
        equal_bounds: Schema(i64, .{ .minimum = 0, .exclusiveMinimum = 0 }),
        step: Schema(f64, .{ .multipleOf = 0.5 }),
        plain_int: u8,
        plain_float: f32,
    });
}

test "strings: lengths, pattern and default" {
    try checkCase("strings", struct {
        code: Schema([]const u8, .{ .minLength = 3, .maxLength = 3, .pattern = "^[A-Z]{3}$" }),
        note: Schema([]const u8, .{ .description = "Free text", .default = "" }),
        label: []const u8,
        nickname: ?[]const u8,
    });
}

test "arrays: item constraints and nesting" {
    try checkCase("arrays", struct {
        scores: Schema([]const Schema(f64, .{ .minimum = 0, .maximum = 100 }), .{ .minItems = 1 }),
        matrix: []const []const i32,
        ids: Schema([]const u64, .{ .uniqueItems = true, .maxItems = 10 }),
    });
}

const Address = struct {
    street: Schema([]const u8, .{ .minLength = 1 }),
    zip: Schema([]const u8, .{ .pattern = "^[0-9]{3}-[0-9]{4}$" }),
};

const Customer = Schema(struct {
    address: Address,
    previous: Schema([]const Address, .{ .maxItems = 3 }),
    metadata: Schema(struct { source: []const u8 }, .{ .additionalProperties = true, .minProperties = 1 }),
    billing: ?Address,
}, .{ .title = "Customer", .additionalProperties = false });

test "nested_objects: structs, arrays of structs and object constraints" {
    try checkCase("nested_objects", Customer);
}

test "nested_objects_inline: the same type with reuse_definitions = false" {
    try checkCaseWith("nested_objects_inline", Customer, .{ .reuse_definitions = false });
}

test "unknown_fields_deny: additionalProperties false everywhere unless overridden" {
    try checkCaseWith("unknown_fields_deny", struct {
        address: Address,
        previous: []const Address,
        billing: ?Address,
        /// An explicit setting wins over `unknown_fields`.
        metadata: Schema(struct { source: []const u8 }, .{ .additionalProperties = true }),
    }, .{ .unknown_fields = .deny });
}

test "unknown_fields_deny_open_root: an explicit root setting overrides unknown_fields" {
    try checkCaseWith("unknown_fields_deny_open_root", Schema(struct {
        name: []const u8,
        /// Not labelled, so it still follows `unknown_fields = .deny`.
        address: Address,
    }, .{ .additionalProperties = true }), .{ .unknown_fields = .deny });
}

const UserId = enum(u64) { _ };

test "newtype_enum: non-exhaustive enums as integer newtypes" {
    try checkCase("newtype_enum", struct {
        id: UserId,
        owner: Schema(UserId, .{ .minimum = 1, .description = "Owner account" }),
        members: Schema([]const UserId, .{ .uniqueItems = true }),
        parent: ?UserId,
    });
}

fn Page(comptime T: type) type {
    return struct { items: []const T, total: u32 };
}

const legacy = struct {
    /// Same short name as `Address`: emitted as `Address_2`.
    const Address = struct { line: []const u8 };
};

test "shared_definitions: use-site keywords, optional references and name clashes" {
    try checkCase("shared_definitions", struct {
        home: Address,
        work: Schema(Address, .{ .description = "Office address", .minProperties = 1 }),
        billing: ?Address,
        /// Explicit additionalProperties: inlined instead of referenced.
        strict: Schema(Address, .{ .additionalProperties = false }),
        history: Page(Address),
        legacy: legacy.Address,
    });
}

const TreeNode = struct {
    name: []const u8,
    children: []const TreeNode,
};

const Category = struct {
    name: []const u8,
    items: []const Item,
};

const Item = struct {
    title: []const u8,
    related: []const Category,
};

test "recursive_tree: a self-referencing root" {
    try checkCase("recursive_tree", TreeNode);
}

test "recursive_mutual: mutually recursive types" {
    try checkCase("recursive_mutual", struct {
        root: Category,
        featured: ?Item,
    });
}

test "with_id: a root $id (id in draft 4) that the $refs resolve against" {
    try checkCaseWith("with_id", struct {
        home: Address,
        billing: ?Address,
    }, .{ .id = "https://example.com/schemas/order.json" });
}

const Circle = struct { radius: Schema(f64, .{ .exclusiveMinimum = 0 }) };
const Rect = struct { width: f64, height: f64 };

/// Externally tagged, as std.json writes unions: `{"circle": {...}}`.
const Shape = union(enum) {
    circle: Circle,
    rect: Rect,
    label: Schema([]const u8, .{ .minLength = 1 }),
    empty,
};

/// Internally tagged: `{"kind": "circle", "radius": 1}`.
const TaggedShape = union(enum) {
    pub const json_discriminator = "kind";
    circle: Circle,
    rect: Rect,
    empty,
};

test "unions: external and internal tagging, void variants, optional unions" {
    try checkCase("unions", struct {
        shape: Shape,
        tagged: Schema(TaggedShape, .{ .description = "Tagged by kind" }),
        maybe: ?Shape,
    });
}

test "unions_if_then: tagged unions as if/then (oneOf before draft 7)" {
    try checkCaseWith("unions_if_then", struct {
        tagged: TaggedShape,
        inline_tagged: union(enum) {
            pub const json_discriminator = "type";
            on: struct { level: u8 },
            off,
        },
        /// Externally tagged: the single key names the variant.
        shape: Shape,
        /// Untagged: unchanged (anyOf).
        id: Id,
    }, .{ .union_encoding = .if_then });
}

/// Untagged: the bare payload, `5` or `"five"`.
const Id = union(enum) {
    pub const json_untagged = true;
    num: u32,
    str: Schema([]const u8, .{ .minLength = 1 }),
};

test "untagged_unions: anyOf of the bare payloads, shared and inline" {
    try checkCase("untagged_unions", struct {
        id: Schema(Id, .{ .description = "Numeric or textual id" }),
        parent: ?Id,
        value: union(enum) {
            pub const json_untagged = true;
            flag: bool,
            ids: []const Id,
            point: struct { x: f64, y: f64 },
        },
    });
}

const Expr = union(enum) {
    num: f64,
    add: []const Expr,
    neg: *const Expr,
};

test "recursive_union: a union that refers to itself" {
    try checkCase("recursive_union", struct { body: Expr });
}

test "field_naming: camelCase keys for fields and union variants" {
    try checkCaseWith("field_naming", struct {
        user_id: u32,
        display_name: ?[]const u8,
        home_address: Address,
        last_event: union(enum) { signed_in: struct { at_time: i64 }, signed_out },
    }, .{ .field_naming = .camel_case });
}

const PostalAddress = struct { city: []const u8, zip: ?[]const u8 };

test "extra: keywords merged next to the generated ones" {
    try checkCase("extra", struct {
        payment: Schema(struct {
            method: []const u8,
            card_number: ?[]const u8,
        }, .{ .extra =
            \\{"if": {"properties": {"method": {"const": "card"}}},
            \\ "then": {"required": ["card_number"]}}
        }),
        country: ?Schema([]const u8, .{ .minLength = 2, .extra =
            \\{"enum": ["jp", "us", null]}
        }),
        home: PostalAddress,
        /// The same named struct with `.extra` is inlined.
        work: Schema(PostalAddress, .{ .description = "Work address", .extra =
            \\{"dependentRequired": {"zip": ["city"]}}
        }),
    });
}

/// `"#rrggbb"`, with its own schema.
const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn jsonSchema(gen: *js.SchemaGen) std.mem.Allocator.Error!std.json.Value {
        return gen.parse(
            \\{"type": "string", "pattern": "^#[0-9a-f]{6}$"}
        );
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, _: std.json.Value, _: std.json.ParseOptions) !Color {
        unreachable; // generation only
    }
};

/// Embeds the schema of another type.
const Gradient = struct {
    from: Color,
    to: Color,

    pub fn jsonSchema(gen: *js.SchemaGen) std.mem.Allocator.Error!std.json.Value {
        var schema = try gen.parse(
            \\{"type": "array", "minItems": 2, "maxItems": 2}
        );
        try schema.object.put(gen.allocator(), "items", try gen.schemaFor(Color));
        return schema;
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, _: std.json.Value, _: std.json.ParseOptions) !Gradient {
        unreachable; // generation only
    }
};

test "custom_schema: types with their own jsonSchema, shared, embedded and optional" {
    try checkCase("custom_schema", struct {
        primary: Color,
        accent: ?Color,
        background: Gradient,
    });
}

const Timestamps = struct {
    created_at: Schema(i64, .{ .minimum = 0 }),
    updated_at: ?i64,
};

test "flatten: a struct's fields merged into the enclosing object, nested and under deny" {
    try checkCaseWith("flatten", struct {
        title: []const u8,
        audit: Schema(struct {
            times: Schema(Timestamps, .{ .flatten = true }),
            author: []const u8,
        }, .{ .flatten = true }),
        /// Not flattened: a nested object as usual.
        stamp: Timestamps,
    }, .{ .unknown_fields = .deny });
}
