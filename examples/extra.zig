//! Example: `.extra`, for JSON Schema keywords the constraint fields don't
//! cover (`if` / `then` / `else`, `allOf`, `not`, `enum`, `dependentRequired`, ...).
//!
//! - The text must be a JSON object, checked at comptime, and must not
//!   contain a keyword the generator emits for that kind of value (such as
//!   `properties` on a struct): both are compile errors.
//! - `toSchema` merges it next to the generated keywords.
//! - `fromJson` enforces it with the runtime `Validator`, so the generated
//!   schema and `fromJson` still accept the same documents.
//! - Compiling that schema is the expensive part: a `Decoder` does it once
//!   and reuses it for every document, where `fromJson` alone repeats it.
const std = @import("std");
const js = @import("jsonschema");
const Schema = js.Schema;

/// A card payment needs a card number, a bank transfer an account.
const Payment = Schema(struct {
    method: Schema([]const u8, .{ .extra =
        \\{"enum": ["card", "bank", "cash"]}
    }),
    card_number: ?[]const u8,
    bank_account: ?[]const u8,
}, .{ .extra =
    \\{
    \\  "allOf": [
    \\    {"if": {"properties": {"method": {"const": "card"}}},
    \\     "then": {"required": ["card_number"]}},
    \\    {"if": {"properties": {"method": {"const": "bank"}}},
    \\     "then": {"required": ["bank_account"]}}
    \\  ]
    \\}
});

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    std.debug.print("== Payment ==\n{s}\n", .{try std.json.Stringify.valueAlloc(a, try js.toSchema(Payment, a, .{}), .{ .whitespace = .indent_2 })});

    const inputs = [_][]const u8{
        \\{"method": "card", "card_number": "4111"}
        ,
        \\{"method": "card"}
        ,
        \\{"method": "bank", "card_number": "4111"}
        ,
        \\{"method": "cheque"}
        ,
        \\{"method": "cash"}
        ,
    };
    // One decoder for all the documents (use one per thread).
    var decoder = js.Decoder.init(std.heap.page_allocator);
    defer decoder.deinit();
    std.debug.print("\n== Decoder.fromJson ==\n", .{});
    for (inputs) |text| {
        const result = try decoder.fromJson(Payment, a, text, .{});
        if (result.value) |p| {
            std.debug.print("{s}\n  -> ok: {s}\n", .{ text, p.method });
            continue;
        }
        for (result.errors.items) |err| {
            std.debug.print("{s}\n  -> {s}: {s}\n", .{ text, if (err.path.len == 0) "(root)" else err.path, err.message });
        }
    }
}
