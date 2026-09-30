//! Example: validating an already-built value.
const std = @import("std");
const js = @import("jsonschema");

/// `Product` itself is only a schema "declaration"; it is never constructed.
const Product = struct {
    name: js.Schema([]const u8, .{ .title = "Name", .minLength = 1, .maxLength = 100 }),
    price: js.Schema(f64, .{
        .title = "Price",
        .description = "Unit price in JPY, must be positive",
        .minimum = 0,
        .exclusiveMinimum = 0,
    }),
    quantity: js.Schema(u32, .{ .minimum = 0, .maximum = 1000, .default = 1 }),
    discount: js.Schema(?f64, .{ .minimum = 0, .maximum = 1 }),
    in_stock: js.Schema(bool, .{ .title = "In stock", .default = true }),
    tags: js.Schema([]const []const u8, .{
        .title = "Tags",
        .minItems = 1,
        .maxItems = 5,
        .uniqueItems = true,
    }),
};

/// The type a program actually reads and writes is the "plain" type with
/// the labels stripped away. `js.Unwrap(Product)` is equivalent to
/// `struct { name: []const u8, price: f64, quantity: u32, discount: ?f64,
/// in_stock: bool, tags: []const []const u8 }`, so there is no need for a
/// `.value` wrapper.
const PlainProduct = js.Unwrap(Product);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Validate with the comptime-generated logic (build the plain value directly)
    const duplicate_tags = [_][]const u8{ "sale", "sale" };
    const bad_product: PlainProduct = .{
        .name = "",
        .price = -5,
        .quantity = 5000,
        .discount = null,
        .in_stock = true,
        .tags = &duplicate_tags,
    };

    var errors: std.ArrayList(js.ValidationError) = .empty;
    try js.validate(Product, bad_product, allocator, &errors);

    std.debug.print("== Validation of an invalid Product ==\n", .{});
    for (errors.items) |err| {
        std.debug.print("- {s}: {s}\n", .{ err.path, err.message });
    }

    const good_tags = [_][]const u8{ "sale", "new" };
    const good_product: PlainProduct = .{
        .name = "Widget",
        .price = 12.5,
        .quantity = 3,
        .discount = 0.1,
        .in_stock = true,
        .tags = &good_tags,
    };

    var ok_errors: std.ArrayList(js.ValidationError) = .empty;
    try js.validate(Product, good_product, allocator, &ok_errors);
    std.debug.print("\n== Validation of a valid Product ==\nerrors: {d}\n", .{ok_errors.items.len});
}
