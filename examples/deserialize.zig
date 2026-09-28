//! Example: mapping a JSON string into a "plain" struct (deserialization),
//! then running validation on the result in the same call.
const std = @import("std");
const js = @import("zig_jsonschema");

/// `Product` itself is only a schema "declaration"; it is never constructed.
const Product = struct {
    name: js.Field([]const u8, .{ .title = "Name", .minLength = 1, .maxLength = 100 }),
    price: js.Field(f64, .{
        .title = "Price",
        .description = "Unit price in JPY, must be positive",
        .minimum = 0,
        .exclusiveMinimum = 0,
    }),
    quantity: js.Field(u32, .{ .minimum = 0, .maximum = 1000, .default = 1 }),
    discount: js.Field(?f64, .{ .minimum = 0, .maximum = 1 }),
    in_stock: js.Field(bool, .{ .title = "In stock", .default = true }),
    tags: js.Field([]const []const u8, .{
        .title = "Tags",
        .minItems = 1,
        .maxItems = 5,
        .uniqueItems = true,
    }),
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const valid_json =
        \\{"name": "Widget", "price": 12.5, "quantity": 3, "discount": 0.1,
        \\ "in_stock": true, "tags": ["sale", "new"]}
    ;
    const valid_result = try js.fromJson(Product, allocator, valid_json, .{});
    std.debug.print("== fromJson: valid payload ==\nerrors: {d}\n", .{valid_result.errors.items.len});
    if (valid_result.value) |p| {
        // p is js.Unwrap(Product), so p.price is a plain f64 and p.tags a plain []const []const u8.
        std.debug.print("parsed: name={s} price={d} quantity={d} tags={d}\n", .{ p.name, p.price, p.quantity, p.tags.len });
        for (p.tags) |tag| std.debug.print("  tag: {s}\n", .{tag});
    }

    // Omitting quantity falls back to the Field's default (=1)
    const missing_quantity_json =
        \\{"name": "Widget", "price": 12.5, "tags": ["sale"]}
    ;
    const default_result = try js.fromJson(Product, allocator, missing_quantity_json, .{});
    std.debug.print("\n== fromJson: default applied ==\nerrors: {d}\n", .{default_result.errors.items.len});
    if (default_result.value) |p| {
        std.debug.print("parsed: quantity={d} (default)\n", .{p.quantity});
    }

    // Constraint violations: price <= 0, quantity > 1000, duplicate tags
    const constraint_violation_json =
        \\{"name": "Widget", "price": -5, "quantity": 5000, "tags": ["sale", "sale"]}
    ;
    const constraint_result = try js.fromJson(Product, allocator, constraint_violation_json, .{});
    std.debug.print("\n== fromJson: constraint violations ==\n", .{});
    for (constraint_result.errors.items) |err| {
        std.debug.print("- {s}: {s}\n", .{ err.path, err.message });
    }

    // Collect multiple structural errors at once (missing name & tags, wrong type for price)
    const structural_error_json =
        \\{"price": "not a number"}
    ;
    const structural_result = try js.fromJson(Product, allocator, structural_error_json, .{});
    std.debug.print("\n== fromJson: structural errors ==\n", .{});
    for (structural_result.errors.items) |err| {
        std.debug.print("- {s}: {s}\n", .{ err.path, err.message });
    }
}
