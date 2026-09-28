//! Example: `SchemaOptions`. The same options value is given to `toSchema`
//! and `fromJson`, so that the published schema accepts exactly what the
//! program accepts.
const std = @import("std");
const js = @import("zig_jsonschema");
const Field = js.Field;

const Address = struct { postal_code: []const u8, city_name: []const u8 };

const Profile = struct {
    user_name: Field([]const u8, .{ .minLength = 1 }),
    display_name: ?[]const u8,
    home_address: Address,
    score: Field(f64, .{ .exclusiveMinimum = 0, .maximum = 10 }),
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
    try printJson(a, "camelCase, unknown keys denied, with $id (draft 2020-12)", try js.toSchema(Profile, a, api));

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
    try printJson(a, "draft 4", try js.toSchema(Profile, a, .{ .draft = .draft4, .id = "https://example.com/schemas/profile.json" }));

    // Everything inlined, without $schema (e.g. to embed in another document).
    try printJson(a, "emit_schema_uri = false, reuse_definitions = false", try js.toSchema(Profile, a, .{
        .emit_schema_uri = false,
        .reuse_definitions = false,
        .field_naming = .snake_case,
    }));
}

fn printJson(a: std.mem.Allocator, title: []const u8, value: std.json.Value) !void {
    std.debug.print("\n== {s} ==\n{s}\n", .{ title, try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 }) });
}
