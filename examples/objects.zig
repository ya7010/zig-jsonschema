//! Example: objects. Nested structs, arrays of structs, optional objects,
//! object-level constraints, unknown keys, shared `$defs`, recursion and
//! flattened structs.
const std = @import("std");
const js = @import("jsonschema");
const Schema = js.Schema;

/// A named struct used in several places: emitted once under `$defs` and
/// referenced with `$ref` (see `reuse_definitions`).
const Address = struct {
    street: Schema([]const u8, .{ .minLength = 1 }),
    city: []const u8,
    zip: Schema([]const u8, .{ .pattern = "^[0-9]{3}-[0-9]{4}$" }),
};

const Customer = struct {
    name: Schema([]const u8, .{ .minLength = 1 }),
    /// A nested object.
    home: Address,
    /// An optional object: may be missing or `null`.
    billing: ?Address,
    /// An array of objects, with array constraints.
    previous: Schema([]const Address, .{ .maxItems = 3 }),
    /// Object constraints on a use of a struct. `additionalProperties =
    /// true` accepts (and ignores) keys that are not fields; an anonymous
    /// struct is always inlined.
    metadata: Schema(struct { source: []const u8 }, .{
        .description = "Free-form metadata",
        .additionalProperties = true,
        .minProperties = 1,
    }),
    /// A plain Zig default makes the key optional.
    vip: bool = false,
};

/// A recursive type: children refer back to the root with `"$ref": "#"`.
const Category = struct {
    name: []const u8,
    children: []const Category,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // --- Schema: Address is shared via $defs.
    try printJson(a, "Customer schema (named structs shared via $defs)", (try js.toSchema(Customer, a, .{})).schema.?);

    // --- The same type with every struct inlined.
    try printJson(a, "Customer schema with reuse_definitions = false", (try js.toSchema(Customer, a, .{ .reuse_definitions = false })).schema.?);

    // --- Decoding: nested values are plain Zig structs.
    const text =
        \\{
        \\  "name": "Ada",
        \\  "home": {"street": "1 Main St", "city": "Tokyo", "zip": "100-0001"},
        \\  "billing": null,
        \\  "previous": [{"street": "2 Side St", "city": "Osaka", "zip": "530-0001"}],
        \\  "metadata": {"source": "web", "campaign": "spring"}
        \\}
    ;
    const ok = try js.fromJson(Customer, a, text, .{});
    if (ok.value) |c| {
        std.debug.print("\n== Decoded ==\n{s} lives in {s}; billing: {s}; previous: {d}; vip: {}\n", .{
            c.name,
            c.home.city,
            if (c.billing == null) "none" else "set",
            c.previous.len,
            c.vip,
        });
    }

    // --- Errors carry the path of the offending value. Structural errors
    // (a wrong type, a missing field) are reported first: constraints are
    // checked once the whole value could be decoded.
    const broken =
        \\{"name": "Ada", "home": {"street": "1", "zip": 100}, "previous": [{"street": "x", "zip": "530-0001"}], "metadata": {}}
    ;
    try printErrors("Structural errors in nested objects", try js.fromJson(Customer, a, broken, .{}));
    const invalid =
        \\{
        \\  "name": "",
        \\  "home": {"street": "", "city": "Tokyo", "zip": "1000001"},
        \\  "previous": [],
        \\  "metadata": {"source": "web"}
        \\}
    ;
    try printErrors("Constraint errors in nested objects", try js.fromJson(Customer, a, invalid, .{}));

    // --- Unknown keys: ignored by default, rejected with unknown_fields =
    // .deny (except where a Schema sets additionalProperties explicitly, as
    // `metadata` does). The schema says the same: additionalProperties false.
    const extra =
        \\{"name": "Ada", "home": {"street": "1", "city": "T", "zip": "100-0001", "floor": 3},
        \\ "previous": [], "metadata": {"source": "web", "extra": 1}, "nickname": "A"}
    ;
    const strict: js.SchemaOptions = .{ .unknown_fields = .deny };
    try printErrors("unknown_fields = .deny", try js.fromJson(Customer, a, extra, strict));
    std.debug.print("(accepted with the default options: {})\n", .{(try js.fromJson(Customer, a, extra, .{})).value != null});

    // --- additionalProperties set explicitly on a Schema always wins over
    // unknown_fields; unset objects follow it. This also works on the root.
    try additionalPropertiesDemo(a);

    // --- Recursive types.
    try printJson(a, "Recursive Category schema", (try js.toSchema(Category, a, .{})).schema.?);
    const tree = (try js.fromJson(Category, a,
        \\{"name": "root", "children": [{"name": "a", "children": []}, {"name": "b", "children": [{"name": "b1", "children": []}]}]}
    , .{})).value.?;
    std.debug.print("\n== Decoded tree ==\n", .{});
    printTree(tree, 0);

    // --- Flattening: a struct's fields written into the enclosing object.
    try printJson(a, "Article (Timestamps flattened)", (try js.toSchema(Article, a, .{})).schema.?);
    const article = (try js.fromJson(Article, a,
        \\{"title": "Hello", "created_at": 1700000000, "updated_at": null}
    , .{ .unknown_fields = .deny })).value.?;
    std.debug.print("\n== Decoded article ==\n{s}, created at {d}\n", .{ article.title, article.times.created_at });
}

/// Fields shared by several types.
const Timestamps = struct {
    created_at: i64,
    updated_at: ?i64,
};

/// `{"title": ..., "created_at": ..., "updated_at": ...}`, read into
/// `.times.created_at`. A field named like one of Timestamps' would be a
/// compile error.
const Article = struct {
    title: []const u8,
    times: Schema(Timestamps, .{ .flatten = true }),
};

const Tags = struct { color: []const u8 };

/// The root is open (`additionalProperties: true`) even under
/// `unknown_fields = .deny`; its unlabelled `unset` object still follows the option.
const Settings = Schema(struct {
    /// Extra keys always accepted (and ignored), whatever the options say.
    open: Schema(Tags, .{ .additionalProperties = true }),
    /// Extra keys always rejected, whatever the options say.
    closed: Schema(Tags, .{ .additionalProperties = false }),
    /// Not set: follows `unknown_fields`.
    unset: Tags,
}, .{ .additionalProperties = true });

fn additionalPropertiesDemo(a: std.mem.Allocator) !void {
    const deny: js.SchemaOptions = .{ .unknown_fields = .deny, .reuse_definitions = false };
    try printJson(a, "Settings schema with unknown_fields = .deny", (try js.toSchema(Settings, a, deny)).schema.?);

    const cases = [_]struct { label: []const u8, text: []const u8 }{
        .{ .label = "no extra keys", .text =
        \\{"open": {"color": "r"}, "closed": {"color": "g"}, "unset": {"color": "b"}}
        },
        .{ .label = "extra key at the root", .text =
        \\{"open": {"color": "r"}, "closed": {"color": "g"}, "unset": {"color": "b"}, "theme": "dark"}
        },
        .{ .label = "extra key in open", .text =
        \\{"open": {"color": "r", "size": 1}, "closed": {"color": "g"}, "unset": {"color": "b"}}
        },
        .{ .label = "extra key in closed", .text =
        \\{"open": {"color": "r"}, "closed": {"color": "g", "size": 1}, "unset": {"color": "b"}}
        },
        .{ .label = "extra key in unset", .text =
        \\{"open": {"color": "r"}, "closed": {"color": "g"}, "unset": {"color": "b", "size": 1}}
        },
    };
    std.debug.print("\n== additionalProperties: accepted? ==\n{s:<24} {s:<8} {s:<8}\n", .{ "", "allow", "deny" });
    for (cases) |c| {
        const allowed = (try js.fromJson(Settings, a, c.text, .{})).value != null;
        const denied = (try js.fromJson(Settings, a, c.text, deny)).value != null;
        std.debug.print("{s:<24} {s:<8} {s:<8}\n", .{ c.label, yesNo(allowed), yesNo(denied) });
    }
    // Extra keys are accepted but not kept: the decoded value only has the fields.
    const decoded = (try js.fromJson(Settings, a, cases[2].text, deny)).value.?;
    std.debug.print("open.color = {s} (\"size\" was ignored)\n", .{decoded.open.color});
}

fn yesNo(b: bool) []const u8 {
    return if (b) "yes" else "no";
}

fn printTree(c: Category, depth: usize) void {
    for (0..depth) |_| std.debug.print("  ", .{});
    std.debug.print("- {s}\n", .{c.name});
    for (c.children) |child| printTree(child, depth + 1);
}

fn printJson(a: std.mem.Allocator, title: []const u8, value: std.json.Value) !void {
    std.debug.print("\n== {s} ==\n{s}\n", .{ title, try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 }) });
}

fn printErrors(title: []const u8, result: anytype) !void {
    std.debug.print("\n== {s} ==\n", .{title});
    for (result.errors.items) |err| std.debug.print("- {s}: {s}\n", .{ err.path, err.message });
}
