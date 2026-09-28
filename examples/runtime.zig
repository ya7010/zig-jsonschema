//! Example: the runtime `Validator`, for any JSON Schema document (drafts 4,
//! 6, 7, 2019-09 and 2020-12), not only schemas generated from Zig types.
const std = @import("std");
const js = @import("zig_jsonschema");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var v = js.Validator.init(gpa, .{
        // Check `format` ("email", "date", ...) instead of only annotating.
        .format_assertion = true,
    });
    defer v.deinit();

    // A document other schemas refer to (loaded from anywhere: file,
    // network, embedded). `$ref`s resolve against registered documents.
    try v.addDocumentJson("https://example.com/common.json",
        \\{"$defs": {
        \\  "email": {"type": "string", "format": "email"},
        \\  "positive": {"type": "integer", "exclusiveMinimum": 0}
        \\}}
    );

    const schema = try v.compileJson(
        \\{
        \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
        \\  "$id": "https://example.com/order.json",
        \\  "title": "Order",
        \\  "type": "object",
        \\  "properties": {
        \\    "customer": {"$ref": "common.json#/$defs/email"},
        \\    "items": {
        \\      "type": "array",
        \\      "minItems": 1,
        \\      "items": {
        \\        "type": "object",
        \\        "properties": {
        \\          "sku": {"type": "string", "pattern": "^[A-Z]{3}-[0-9]+$"},
        \\          "qty": {"$ref": "common.json#/$defs/positive"}
        \\        },
        \\        "required": ["sku", "qty"],
        \\        "additionalProperties": false
        \\      }
        \\    },
        \\    "coupon": {"anyOf": [{"type": "null"}, {"type": "string", "minLength": 4}]}
        \\  },
        \\  "required": ["customer", "items"]
        \\}
    );

    const good = try parse(a,
        \\{"customer": "ada@example.com", "items": [{"sku": "ABC-1", "qty": 2}], "coupon": null}
    );
    const bad = try parse(a,
        \\{"customer": "ada", "items": [{"sku": "abc", "qty": 0, "color": "red"}], "coupon": "x"}
    );

    // 1. A yes/no answer (stops at the first failure).
    std.debug.print("== isValid ==\ngood: {}\nbad: {}\n", .{ try schema.isValid(good), try schema.isValid(bad) });

    // 2. Every error, with where it is in the instance and in the schema.
    std.debug.print("\n== validate: every error ==\n", .{});
    const result = try schema.validate(a, bad);
    for (result.errors) |err| {
        std.debug.print("- {s}: {s}\n    keyword  {s}\n    absolute {s}\n", .{
            if (err.instance_location.len == 0) "(root)" else err.instance_location,
            err.message,
            err.keyword_location,
            err.absolute_keyword_location,
        });
    }

    // 3. The standard output formats (JSON Schema 2020-12, section 12).
    try printJson(a, "output .flag (invalid)", try schema.output(a, bad, .flag));
    try printJson(a, "output .basic (invalid): a flat list of errors", try schema.output(a, bad, .basic));
    try printJson(a, "output .detailed (invalid): errors along the schema structure", try schema.output(a, bad, .detailed));
    try printJson(a, "output .basic (valid): annotations", try schema.output(a, good, .basic));

    // 4. Checking a schema itself against its metaschema.
    std.debug.print("\n== isValidSchema ==\n", .{});
    for ([_][]const u8{ "{\"type\": \"string\", \"minLength\": 1}", "{\"type\": \"text\"}", "{\"minLength\": -1}" }) |text| {
        std.debug.print("{s}: {}\n", .{ text, try v.isValidSchema(try parse(a, text)) });
    }

    // 5. Draft 4 semantics, from `$schema`.
    const d4 = try v.compileJson(
        \\{"$schema": "http://json-schema.org/draft-04/schema#", "type": "integer", "maximum": 10, "exclusiveMaximum": true}
    );
    std.debug.print("\n== draft 4 ==\n10: {}, 9: {}, 9.0: {}\n", .{
        try d4.isValid(try parse(a, "10")),
        try d4.isValid(try parse(a, "9")),
        try d4.isValid(try parse(a, "9.0")), // not an integer in draft 4
    });

    // 6. Hostile input cannot stall validation: patterns without
    // backreferences run in linear time, others within a step budget.
    var strict = js.Validator.init(gpa, .{ .regex_step_limit = 100_000 });
    defer strict.deinit();
    const redos = try strict.compileJson(
        \\{"pattern": "^(a+)+\\1$"}
    );
    const long = try a.alloc(u8, 40);
    @memset(long, 'a');
    long[long.len - 1] = 'b';
    std.debug.print("\n== regex step limit ==\n", .{});
    if (redos.isValid(.{ .string = long })) |ok| {
        std.debug.print("result: {}\n", .{ok});
    } else |err| {
        std.debug.print("gave up safely: {t}\n", .{err});
    }
}

fn parse(a: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
}

fn printJson(a: std.mem.Allocator, title: []const u8, value: std.json.Value) !void {
    std.debug.print("\n== {s} ==\n{s}\n", .{ title, try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 }) });
}
