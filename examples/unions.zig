//! Example: tagged unions (`union(enum)`), which become `oneOf` (or `anyOf`
//! when untagged).
//!
//! - By default a value is externally tagged, as std.json writes unions:
//!   `{"circle": {"radius": 1}}` (a void variant is `{"none": {}}`).
//! - `pub const json_discriminator = "kind";` makes a union internally
//!   tagged: `{"kind": "circle", "radius": 1}`. Every variant must then be a
//!   struct or void.
//! - `pub const json_untagged = true;` writes the bare payload: `5` or
//!   `"five"`. The schema is an `anyOf`, and `fromJson` takes the first
//!   variant (in declaration order) that accepts the value.
const std = @import("std");
const js = @import("jsonschema");
const Schema = js.Schema;

const Circle = struct { radius: Schema(f64, .{ .exclusiveMinimum = 0 }) };
const Rect = struct { width: f64, height: f64 };

/// Externally tagged.
const Shape = union(enum) {
    circle: Circle,
    rect: Rect,
    /// Any payload type works, including labelled ones.
    label: Schema([]const u8, .{ .minLength = 1 }),
    none,
};

/// Internally tagged.
const Event = union(enum) {
    pub const json_discriminator = "type";
    signed_in: struct { user: []const u8 },
    signed_out: struct { user: []const u8, reason: ?[]const u8 },
    heartbeat,
};

/// Untagged: an id may be a number or a non-empty string.
const Id = union(enum) {
    pub const json_untagged = true;
    num: u64,
    str: Schema([]const u8, .{ .minLength = 1 }),
};

/// A recursive union: a single-item pointer (or a slice) breaks the cycle.
const Expr = union(enum) {
    num: f64,
    neg: *const Expr,
    add: []const Expr,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try printJson(a, "Shape (externally tagged)", try js.toSchema(Shape, a, .{}));
    try printJson(a, "Event (internally tagged by \"type\")", try js.toSchema(Event, a, .{}));

    // --- Decoding gives a plain Zig union to switch on.
    const shapes = [_][]const u8{
        \\{"circle": {"radius": 2}}
        ,
        \\{"rect": {"width": 3, "height": 4}}
        ,
        \\{"label": "hello"}
        ,
        \\{"none": {}}
        ,
    };
    std.debug.print("\n== Decoded shapes ==\n", .{});
    for (shapes) |text| {
        const shape = (try js.fromJson(Shape, a, text, .{})).value.?;
        switch (shape) {
            .circle => |c| std.debug.print("circle, area {d:.2}\n", .{std.math.pi * c.radius * c.radius}),
            .rect => |r| std.debug.print("rect, area {d}\n", .{r.width * r.height}),
            .label => |l| std.debug.print("label \"{s}\"\n", .{l}),
            .none => std.debug.print("none\n", .{}),
        }
    }

    const events = [_][]const u8{
        \\{"type": "signed_in", "user": "ada"}
        ,
        \\{"type": "signed_out", "user": "ada", "reason": "timeout"}
        ,
        \\{"type": "heartbeat"}
        ,
    };
    std.debug.print("\n== Decoded events ==\n", .{});
    for (events) |text| {
        const event = (try js.fromJson(Event, a, text, .{})).value.?;
        switch (event) {
            .signed_in => |e| std.debug.print("{s} signed in\n", .{e.user}),
            .signed_out => |e| std.debug.print("{s} signed out ({s})\n", .{ e.user, e.reason orelse "-" }),
            .heartbeat => std.debug.print("heartbeat\n", .{}),
        }
    }

    // --- Invalid values: the error path follows the JSON layout.
    const invalid = [_][]const u8{
        \\{"circle": {"radius": 0}}
        ,
        \\{"circle": {"radius": 1}, "rect": {"width": 1, "height": 1}}
        ,
        \\{"triangle": {}}
        ,
    };
    std.debug.print("\n== Invalid shapes ==\n", .{});
    for (invalid) |text| {
        for ((try js.fromJson(Shape, a, text, .{})).errors.items) |err| {
            std.debug.print("{s}\n  -> {s}: {s}\n", .{ text, if (err.path.len == 0) "(root)" else err.path, err.message });
        }
    }
    std.debug.print("\n== Invalid events ==\n", .{});
    for ([_][]const u8{ "{\"type\": \"crashed\"}", "{\"user\": \"ada\"}" }) |text| {
        for ((try js.fromJson(Event, a, text, .{})).errors.items) |err| {
            std.debug.print("{s}\n  -> {s}: {s}\n", .{ text, if (err.path.len == 0) "(root)" else err.path, err.message });
        }
    }

    // --- Untagged: the payload alone, the first matching variant wins.
    try printJson(a, "Id (untagged, anyOf)", try js.toSchema(Id, a, .{}));
    std.debug.print("\n== Decoded ids ==\n", .{});
    for ([_][]const u8{ "42", "\"ada\"" }) |text| {
        switch ((try js.fromJson(Id, a, text, .{})).value.?) {
            .num => |n| std.debug.print("{s} -> num {d}\n", .{ text, n }),
            .str => |s| std.debug.print("{s} -> str \"{s}\"\n", .{ text, s }),
        }
    }
    std.debug.print("\n== Invalid ids (every variant's reason) ==\n", .{});
    for ([_][]const u8{ "\"\"", "true" }) |text| {
        for ((try js.fromJson(Id, a, text, .{})).errors.items) |err| {
            std.debug.print("{s}\n  -> {s}: {s}\n", .{ text, if (err.path.len == 0) "(root)" else err.path, err.message });
        }
    }

    // --- Recursion through the union.
    try printJson(a, "Expr (recursive, via $defs)", try js.toSchema(struct { body: Expr }, a, .{}));
    const program = (try js.fromJson(Expr, a,
        \\{"add": [{"num": 1}, {"neg": {"num": 2}}, {"add": [{"num": 3}, {"num": 4}]}]}
    , .{})).value.?;
    std.debug.print("\n== Evaluated Expr ==\n1 + -2 + (3 + 4) = {d}\n", .{eval(program)});
}

fn eval(e: Expr) f64 {
    return switch (e) {
        .num => |n| n,
        .neg => |inner| -eval(inner.*),
        .add => |terms| blk: {
            var sum: f64 = 0;
            for (terms) |t| sum += eval(t);
            break :blk sum;
        },
    };
}

fn printJson(a: std.mem.Allocator, title: []const u8, value: std.json.Value) !void {
    std.debug.print("\n== {s} ==\n{s}\n", .{ title, try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 }) });
}
