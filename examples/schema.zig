//! Example: generating a JSON Schema.
const std = @import("std");
const js = @import("jsonschema");

/// A declaration style close to pydantic's `Field(gt=0, le=1000)`.
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

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Generate a JSON Schema at comptime (defaults: draft 2020-12, with `$schema`)
    const schema = (try js.toSchema(Product, allocator, .{ .id = "https://example.com/product.schema.json" })).schema.?;
    const schema_json = try std.json.Stringify.valueAlloc(allocator, schema, .{ .whitespace = .indent_2 });
    std.debug.print("== JSON Schema ==\n{s}\n", .{schema_json});

    // Generate for a specific draft (here draft-07).
    const draft7 = (try js.toSchema(Product, allocator, .{ .draft = .draft7 })).schema.?;
    const draft7_json = try std.json.Stringify.valueAlloc(allocator, draft7, .{ .whitespace = .indent_2 });
    std.debug.print("\n== JSON Schema (draft-07) ==\n{s}\n", .{draft7_json});
}
