//! Example: `SchemaOptions`. The same options value is given to `toSchema`
//! and `fromJson`, so that the published schema accepts exactly what the
//! program accepts.
const std = @import("std");
const js = @import("jsonschema");
const Schema = js.Schema;

const Address = struct { postal_code: []const u8, city_name: []const u8 };

const Profile = struct {
    user_name: Schema([]const u8, .{ .minLength = 1 }),
    display_name: ?[]const u8,
    home_address: Address,
    score: Schema(f64, .{ .exclusiveMinimum = 0, .maximum = 10 }),
    last_seen: union(enum) { online, offline_since: struct { unix_time: i64 } },
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An API that speaks camelCase, rejects unknown keys and publishes its
    // schema under an $id.
    const api: js.SchemaOptions = .{
        .id = "https://example.com/schemas/profile.json",
        .field_naming = .camel_case,
        .unknown_fields = .deny,
    };
    try printJson(a, "camelCase, unknown keys denied, with $id (draft 2020-12)", (try js.toSchema(Profile, a, api)).schema.?);

    const text =
        \\{"userName": "ada", "homeAddress": {"postalCode": "100-0001", "cityName": "Tokyo"},
        \\ "score": 9.5, "lastSeen": {"offlineSince": {"unixTime": 1700000000}}}
    ;
    const profile = (try js.fromJson(Profile, a, text, api)).value.?;
    std.debug.print("\n== Decoded with the same options ==\nuser_name={s} city={s} offline since {d}\n", .{
        profile.user_name,
        profile.home_address.city_name,
        profile.last_seen.offline_since.unix_time,
    });

    // Zig spellings are unknown keys for this API; errors use JSON names.
    const zig_names =
        \\{"user_name": "ada", "homeAddress": {"postalCode": "1", "cityName": "T", "floor": 3},
        \\ "score": 0, "lastSeen": {"online": {}}}
    ;
    std.debug.print("\n== Errors with the same options ==\n", .{});
    for ((try js.fromJson(Profile, a, zig_names, api)).errors.items) |err| {
        std.debug.print("- {s}: {s}\n", .{ err.path, err.message });
    }

    // Other drafts: draft 4 writes exclusive bounds as booleans and uses
    // `id` and `definitions`.
    try printJson(a, "draft 4", (try js.toSchema(Profile, a, .{ .draft = .draft4, .id = "https://example.com/schemas/profile.json" })).schema.?);

    // Everything inlined, without $schema (e.g. to embed in another document).
    try printJson(a, "emit_schema_uri = false, reuse_definitions = false", (try js.toSchema(Profile, a, .{
        .emit_schema_uri = false,
        .reuse_definitions = false,
        .field_naming = .snake_case,
    })).schema.?);

    // Names that field_naming turns into the same key are refused: toSchema
    // returns no schema and fromJson no value, but every collision (as does
    // fieldNameCollisions, to see which names to rename).
    const Clash = struct { user_id: u32, userId: u32, home_page: []const u8, homePage: []const u8 };
    const camel: js.SchemaOptions = .{ .field_naming = .camel_case };
    std.debug.print("\n== field_naming collisions ==\n", .{});
    const generated = try js.toSchema(Clash, a, camel);
    std.debug.print("toSchema: schema is null: {}\n", .{generated.schema == null});
    for (generated.errors.items) |collision| std.debug.print("  {f}\n", .{collision});
    std.debug.print("fromJson:\n", .{});
    for ((try js.fromJson(Clash, a, "{}", camel)).errors.items) |err| std.debug.print("  {s}\n", .{err.message});
    std.debug.print("as_is is fine: {}\n", .{js.fieldNameCollisions(Clash, .as_is).len == 0});
}

fn printJson(a: std.mem.Allocator, title: []const u8, value: std.json.Value) !void {
    std.debug.print("\n== {s} ==\n{s}\n", .{ title, try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 }) });
}
