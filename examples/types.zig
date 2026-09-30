//! Example: scalar types, reusable constrained types and newtypes.
//!
//! - Integer types are bounded by their range (`u8` is 0..255), so the
//!   schema rejects what `fromJson` could not store.
//! - `Field(T, ...)` is an ordinary type: give it a name to reuse a
//!   constraint (`Email`, `Percent`).
//! - A non-exhaustive enum (`enum(u64) { _ }`) is a distinct integer
//!   newtype: `UserId` and `OrderId` cannot be mixed up in Zig code, but both
//!   are plain integers in JSON.
const std = @import("std");
const js = @import("zig-jsonschema");
const Field = js.Field;

const Email = Field([]const u8, .{ .pattern = "^[^@\\s]+@[^@\\s]+$", .maxLength = 254 });
const Percent = Field(f64, .{ .minimum = 0, .maximum = 100 });
const UserId = enum(u64) { _ };
const OrderId = enum(u64) { _ };

const Order = struct {
    id: OrderId,
    owner: UserId,
    contact: Email,
    /// Optional: may be missing or null.
    cc: ?Email,
    discount: Percent,
    /// `u8`: 0..255 unless a stricter bound is given.
    quantity: Field(u8, .{ .minimum = 1 }),
    /// A default makes the key optional.
    priority: Field(i8, .{ .minimum = -5, .maximum = 5, .default = 0 }),
    note: Field([]const u8, .{ .maxLength = 10, .default = "" }),
    gift: bool = false,
    weights: []const f32,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const schema = try js.toSchema(Order, a, .{});
    std.debug.print("== Order schema ==\n{s}\n", .{try std.json.Stringify.valueAlloc(a, schema, .{ .whitespace = .indent_2 })});

    const text =
        \\{"id": 18446744073709551615, "owner": 42, "contact": "ada@example.com",
        \\ "discount": 12.5, "quantity": 3, "weights": [0.5, 1.25]}
    ;
    const order = (try js.fromJson(Order, a, text, .{})).value.?;
    std.debug.print("\n== Decoded ==\n", .{});
    std.debug.print("id={d} owner={d} contact={s} cc={s}\n", .{ @intFromEnum(order.id), @intFromEnum(order.owner), order.contact, order.cc orelse "-" });
    std.debug.print("discount={d}% quantity={d} priority={d} (default) note=\"{s}\" gift={}\n", .{ order.discount, order.quantity, order.priority, order.note, order.gift });
    // `order.owner = order.id;` would not compile: the newtypes are distinct.

    // Values a type cannot hold are decoding errors, as in the schema.
    const out_of_range =
        \\{"id": -1, "owner": 1.5, "contact": "a@b", "discount": 0, "quantity": 256, "weights": [1e39]}
    ;
    std.debug.print("\n== Out of the type's range ==\n", .{});
    for ((try js.fromJson(Order, a, out_of_range, .{})).errors.items) |err| {
        std.debug.print("- {s}: {s}\n", .{ err.path, err.message });
    }

    // Every constraint violation is reported, with the same rules as the
    // schema: lengths count code points and `pattern` is an ECMA-262 regex.
    const invalid =
        \\{"id": 1, "owner": 2, "contact": "not-an-email", "cc": "b@c",
        \\ "discount": 101, "quantity": 0, "priority": 9, "note": "ééééééééééé", "weights": []}
    ;
    std.debug.print("\n== Constraint violations ==\n", .{});
    for ((try js.fromJson(Order, a, invalid, .{})).errors.items) |err| {
        std.debug.print("- {s}: {s}\n", .{ err.path, err.message });
    }

    const integral_float =
        \\{"id": 1, "owner": 2.0, "contact": "a@b", "discount": 0, "quantity": 1, "weights": []}
    ;
    std.debug.print("\n\"owner\": 2.0 accepted in 2020-12: {}, in draft 4: {}\n", .{
        (try js.fromJson(Order, a, integral_float, .{})).value != null,
        (try js.fromJson(Order, a, integral_float, .{ .draft = .draft4 })).value != null,
    });
}
