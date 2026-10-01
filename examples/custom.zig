//! Example: a type that writes its own schema with `pub fn jsonSchema`,
//! for JSON shapes that don't follow the type's layout.
//!
//! - `jsonSchema` returns the schema (`gen.parse` checks JSON text at
//!   comptime; `gen.schemaFor(T)` embeds the generated schema of `T`).
//! - `jsonParseFromValue`, std.json's decoding hook, is required: it turns
//!   what the schema accepts into the Zig value.
//! - `fromJson` checks the JSON against `jsonSchema` with the runtime
//!   `Validator` before calling `jsonParseFromValue`.
const std = @import("std");
const js = @import("jsonschema");
const Schema = js.Schema;
const Allocator = std.mem.Allocator;

/// An RGB color, written as `"#rrggbb"`.
const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn jsonSchema(gen: *js.SchemaGen) Allocator.Error!std.json.Value {
        return gen.parse(
            \\{"type": "string", "pattern": "^#[0-9a-f]{6}$"}
        );
    }

    pub fn jsonParseFromValue(_: Allocator, source: std.json.Value, _: std.json.ParseOptions) !Color {
        const s = source.string; // the schema guarantees "#rrggbb"
        return .{
            .r = try std.fmt.parseInt(u8, s[1..3], 16),
            .g = try std.fmt.parseInt(u8, s[3..5], 16),
            .b = try std.fmt.parseInt(u8, s[5..7], 16),
        };
    }
};

/// Two colors, written as a pair: `["#000000", "#ffffff"]`.
const Gradient = struct {
    from: Color,
    to: Color,

    pub fn jsonSchema(gen: *js.SchemaGen) Allocator.Error!std.json.Value {
        var schema = try gen.parse(
            \\{"type": "array", "minItems": 2, "maxItems": 2}
        );
        // A `$ref` to Color's shared definition.
        try schema.object.put(gen.allocator(), "items", try gen.schemaFor(Color));
        return schema;
    }

    pub fn jsonParseFromValue(a: Allocator, source: std.json.Value, o: std.json.ParseOptions) !Gradient {
        const items = source.array.items;
        return .{ .from = try Color.jsonParseFromValue(a, items[0], o), .to = try Color.jsonParseFromValue(a, items[1], o) };
    }
};

const Theme = struct {
    name: Schema([]const u8, .{ .minLength = 1 }),
    primary: Color,
    accent: ?Color,
    background: Gradient,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    std.debug.print("== Theme ==\n{s}\n", .{try std.json.Stringify.valueAlloc(a, try js.toSchema(Theme, a, .{}), .{ .whitespace = .indent_2 })});

    const theme = (try js.fromJson(Theme, a,
        \\{"name": "dusk", "primary": "#ff8800", "accent": null, "background": ["#000000", "#3355ff"]}
    , .{})).value.?;
    std.debug.print("\n== Decoded ==\n{s}: primary rgb({d}, {d}, {d}), background to rgb({d}, {d}, {d})\n", .{
        theme.name,
        theme.primary.r,
        theme.primary.g,
        theme.primary.b,
        theme.background.to.r,
        theme.background.to.g,
        theme.background.to.b,
    });

    std.debug.print("\n== Invalid ==\n", .{});
    const text =
        \\{"name": "dusk", "primary": "orange", "accent": "#FFF", "background": ["#000000"]}
    ;
    for ((try js.fromJson(Theme, a, text, .{})).errors.items) |err| {
        std.debug.print("{s}: {s}\n", .{ err.path, err.message });
    }
}
