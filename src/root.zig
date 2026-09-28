//! zig-jsonschema: comptime JSON Schema and validator generation from Zig
//! structs, with a declaration style close to pydantic's `Field()`, plus a
//! runtime `Validator` for arbitrary JSON Schema documents (drafts 4, 6, 7,
//! 2019-09 and 2020-12), verified against the official
//! JSON-Schema-Test-Suite (`zig build test-suite`).
//!
//! Supported kinds: number (int/float, bounded by the type's range), string,
//! boolean, array (Zig slice), object (Zig struct), tagged union
//! (`union(enum)`, as `oneOf`), integer newtype (non-exhaustive enum) and
//! single-item pointer (transparent), each with its own constraint set.
//! `SchemaOptions` picks the draft, unknown-key handling and JSON key
//! spelling (`field_naming`), shared by `toSchema` and `fromJson` so that
//! both accept the same documents.
//!
//! `Field(T, constraints)` never becomes a real type at runtime; it is only a
//! **schema declaration label**. The type actually read/written by callers is
//! the "plain" struct produced by `Unwrap()` (equivalent to a pydantic parsed
//! model), so there is no `.value`-style wrapper to go through.
//!
//! ```zig
//! const Product = struct {
//!     name: Field([]const u8, .{ .minLength = 1 }),
//!     price: Field(f64, .{ .minimum = 0, .exclusiveMinimum = 0 }),
//!     tags: Field([]const []const u8, .{ .minItems = 1, .uniqueItems = true }),
//! };
//! const result = try fromJson(Product, allocator, json_text, .{});
//! if (result.value) |p| {
//!     std.debug.print("{s}: {d}\n", .{ p.name, p.price }); // plain types, no wrapper
//! }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

// --- Runtime validation of arbitrary JSON Schema documents -------------------
//
// The comptime API below derives schemas from Zig types. For validating
// against any JSON Schema document (drafts 4, 6, 7, 2019-09, 2020-12), use
// the runtime `Validator`:
//
// ```zig
// var v = Validator.init(gpa, .{});
// defer v.deinit();
// const schema = try v.compileJson(schema_text);
// const ok = try schema.isValid(instance);
// ```

const validator = @import("validator.zig");
pub const Validator = validator.Validator;
pub const CompiledSchema = validator.Schema;
pub const Draft = validator.Draft;
pub const Options = validator.Options;
pub const CompileError = validator.CompileError;
pub const ValidateError = validator.ValidateError;
pub const SchemaError = validator.Error;
pub const Result = validator.Result;
pub const OutputFormat = validator.OutputFormat;
pub const Regex = @import("regex.zig").Regex;
pub const format = @import("format.zig");

test {
    _ = validator;
    _ = @import("regex.zig");
    _ = @import("uri.zig");
    _ = format;
}

/// Numeric constraints for JSON Schema (2020-12).
pub const NumberConstraints = struct {
    // --- Metadata annotations (JSON Schema "annotation" keywords) ---
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// Default value used when the field is absent from the JSON input.
    default: ?f64 = null,

    // --- Validation constraints (JSON Schema "assertion" keywords) ---
    minimum: ?f64 = null,
    maximum: ?f64 = null,
    exclusiveMinimum: ?f64 = null,
    exclusiveMaximum: ?f64 = null,
    multipleOf: ?f64 = null,
};

/// String constraints for JSON Schema (2020-12).
pub const StringConstraints = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// Default value used when the field is absent from the JSON input.
    default: ?[]const u8 = null,

    /// Lengths count Unicode code points, as JSON Schema does.
    minLength: ?usize = null,
    maxLength: ?usize = null,
    /// An ECMA-262 regular expression, matched anywhere in the string (anchor
    /// it with `^...$` to match the whole string). Enforced by `validate` /
    /// `fromJson` with the same engine as the runtime `Validator`, within
    /// `Regex.default_step_limit` steps.
    pattern: ?[]const u8 = null,
};

/// Boolean constraints for JSON Schema (2020-12).
pub const BoolConstraints = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    /// Default value used when the field is absent from the JSON input.
    default: ?bool = null,
};

/// Array constraints for JSON Schema (2020-12). Applies to Zig slices; the
/// element type's own schema is derived from the slice's child type (which
/// may itself be `Field()`-labeled for per-item constraints).
pub const ArrayConstraints = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,

    minItems: ?usize = null,
    maxItems: ?usize = null,
    /// `fromJson` compares the JSON items (as JSON Schema does); `validate`
    /// compares the Zig values structurally.
    uniqueItems: ?bool = null,
};

/// Object constraints for JSON Schema (2020-12). Applies to Zig structs.
/// Since a Zig struct always has a fixed, compile-time known set of fields,
/// `minProperties`/`maxProperties` mostly only matter together with
/// `additionalProperties`.
pub const ObjectConstraints = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,

    minProperties: ?usize = null,
    maxProperties: ?usize = null,
    /// `false` rejects JSON object keys that don't match any struct field
    /// (checked by `fromJson`), `true` allows them. `null` defers to
    /// `SchemaOptions.unknown_fields` (which allows them by default, like
    /// JSON Schema itself).
    additionalProperties: ?bool = null,
};

/// Constraints for a tagged union (`union(enum)`), which maps to a `oneOf`
/// with one branch per variant. By default a value is written as
/// `{"<variant>": <payload>}` (a void payload as `{}`), as std.json does.
/// A union that declares `pub const json_discriminator = "kind";` is
/// written internally tagged instead: `{"kind": "<variant>", ...payload
/// fields}`, which requires every payload to be a struct or void.
pub const UnionConstraints = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

/// Selects the constraints type that applies to `T` (or, if `T` is
/// optional, to its child type).
fn ConstraintsFor(comptime T: type) type {
    const Inner = switch (@typeInfo(T)) {
        .optional => |info| info.child,
        else => T,
    };
    if (comptime isField(Inner)) {
        @compileError("zig-jsonschema: nesting Field() inside another Field() is not supported");
    }
    return switch (@typeInfo(Inner)) {
        .int, .float => NumberConstraints,
        .@"enum" => blk: {
            requireOpenEnum(Inner);
            break :blk NumberConstraints;
        },
        .bool => BoolConstraints,
        .pointer => |p| blk: {
            if (p.size == .slice and p.child == u8) break :blk StringConstraints;
            if (p.size == .slice) break :blk ArrayConstraints;
            if (p.size == .one) break :blk ConstraintsFor(p.child); // transparent
            @compileError("zig-jsonschema: unsupported Field inner type " ++ @typeName(T));
        },
        .@"struct" => ObjectConstraints,
        .@"union" => blk: {
            requireTaggedUnion(Inner);
            break :blk UnionConstraints;
        },
        else => @compileError("zig-jsonschema: unsupported Field inner type " ++ @typeName(T)),
    };
}

fn requireTaggedUnion(comptime T: type) void {
    if (@typeInfo(T).@"union".tag_type == null) {
        @compileError("zig-jsonschema: untagged union " ++ @typeName(T) ++ " is not supported; use union(enum)");
    }
}

/// The discriminator key of an internally tagged union, or null.
fn discriminatorOf(comptime T: type) ?[]const u8 {
    if (!@hasDecl(T, "json_discriminator")) return null;
    const key: []const u8 = T.json_discriminator;
    for (@typeInfo(T).@"union".fields) |f| {
        const Payload = stripField(f.type);
        switch (@typeInfo(Payload)) {
            .void => {},
            .@"struct" => if (@hasField(Payload, key)) @compileError("zig-jsonschema: variant '" ++ f.name ++ "' of " ++
                @typeName(T) ++ " has a field named like the discriminator '" ++ key ++ "'"),
            else => @compileError("zig-jsonschema: variant '" ++ f.name ++ "' of internally tagged union " ++
                @typeName(T) ++ " must be a struct or void, got " ++ @typeName(Payload)),
        }
    }
    return key;
}

/// `T` below its `Field()` label, if any.
fn stripField(comptime T: type) type {
    return if (isField(T)) T.zjs_inner else T;
}

/// A non-exhaustive enum (`enum(u64) { _ }`) is Zig's idiomatic integer
/// newtype: it is a distinct type, but is (de)serialized and constrained as
/// its tag integer. Exhaustive enums have no such obvious JSON form.
fn requireOpenEnum(comptime T: type) void {
    if (@typeInfo(T).@"enum".is_exhaustive) {
        @compileError("zig-jsonschema: exhaustive enum " ++ @typeName(T) ++
            " is not supported; use a non-exhaustive enum such as `enum(u64) { _ }` for an integer newtype");
    }
}

/// Labels a struct field's type with constraints.
///
/// `Field(T, constraints)` itself is a comptime-only marker type with no
/// fields; it is never actually constructed. `toSchema`/`validate`/
/// `fromJson` read `T` and `constraints` through this marker, and callers
/// always work with the "plain" type produced by `Unwrap()`.
pub fn Field(comptime T: type, comptime constraints: ConstraintsFor(T)) type {
    return struct {
        pub const zjs_is_field = true;
        pub const zjs_inner = T;
        pub const zjs_constraints = constraints;
    };
}

fn isField(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zjs_is_field");
}

/// Derives, at comptime, the "plain" type obtained by stripping the labels
/// from a schema declaration type `Schema` (a struct containing fields
/// labeled with `Field()`).
///
/// - `Field(T, ...)` field → `Unwrap(T)`
/// - Plain number/string/bool field → unchanged
/// - Slice (array) → `[]const Unwrap(child)`
/// - Nested struct (object) → recursively `Unwrap`
///
/// The value a program actually reads and writes always uses this type.
pub fn Unwrap(comptime Schema: type) type {
    // Walking nested and recursive types takes more than the default quota.
    @setEvalBranchQuota(100_000);
    if (comptime isField(Schema)) return Unwrap(Schema.zjs_inner);

    return switch (@typeInfo(Schema)) {
        .int, .float, .bool, .void => Schema,
        .@"enum" => blk: {
            requireOpenEnum(Schema);
            break :blk Schema; // the newtype itself is kept, for type safety
        },
        .optional => |info| ?Unwrap(info.child),
        .pointer => |info| blk: {
            if (info.size == .slice and info.child == u8) break :blk Schema; // string
            if (info.size == .slice) break :blk []const Unwrap(info.child); // array
            // A single-item pointer is transparent in JSON (and lets a
            // union refer to itself).
            if (info.size == .one) break :blk *const Unwrap(info.child);
            @compileError("zig-jsonschema: unsupported pointer type " ++ @typeName(Schema));
        },
        // Structs without any `Field()` label are already plain: keep the
        // user's type (and its methods), which also makes recursive types work.
        .@"struct" => if (!hasLabels(Schema, &.{})) Schema else if (reaches(Schema, Schema, &.{}))
            @compileError("zig-jsonschema: recursive type " ++ @typeName(Schema) ++
                " cannot contain Field() labels (Zig cannot build a self-referential unwrapped type); use plain field types in it")
        else
            unwrapStruct(Schema),
        .@"union" => blk: {
            requireTaggedUnion(Schema);
            if (!hasLabels(Schema, &.{})) break :blk Schema;
            if (reaches(Schema, Schema, &.{})) @compileError("zig-jsonschema: recursive type " ++ @typeName(Schema) ++
                " cannot contain Field() labels (Zig cannot build a self-referential unwrapped type); use plain field types in it");
            break :blk unwrapUnion(Schema);
        },
        else => @compileError("zig-jsonschema: unsupported type " ++ @typeName(Schema)),
    };
}

/// The same union with every payload type unwrapped (and the same tag enum).
fn unwrapUnion(comptime Schema: type) type {
    const info = @typeInfo(Schema).@"union";
    var names: [info.fields.len][]const u8 = undefined;
    var types: [info.fields.len]type = undefined;
    for (info.fields, 0..) |f, i| {
        names[i] = f.name;
        types[i] = Unwrap(f.type);
    }
    return @Union(.auto, info.tag_type, &names, &types, &@splat(.{}));
}

/// Types `T` refers to that `Unwrap` descends into.
fn containedTypes(comptime T: type) []const type {
    return switch (@typeInfo(T)) {
        .optional => |o| &.{o.child},
        .pointer => |p| if ((p.size == .slice and p.child != u8) or p.size == .one) &.{p.child} else &.{},
        .@"struct" => |s| blk: {
            if (isField(T)) break :blk &.{T.zjs_inner};
            var types: [s.fields.len]type = undefined;
            for (s.fields, 0..) |f, i| types[i] = f.type;
            const final = types;
            break :blk &final;
        },
        .@"union" => |u| blk: {
            var types: [u.fields.len]type = undefined;
            for (u.fields, 0..) |f, i| types[i] = f.type;
            const final = types;
            break :blk &final;
        },
        else => &.{},
    };
}

/// Whether `T` contains a `Field()` label anywhere (cycles are cut off).
fn hasLabels(comptime T: type, comptime visiting: []const type) bool {
    @setEvalBranchQuota(100_000);
    if (isField(T)) return true;
    for (visiting) |v| if (v == T) return false;
    for (containedTypes(T)) |C| if (hasLabels(C, visiting ++ &[_]type{T})) return true;
    return false;
}

/// Whether `target` is reachable from the types `T` contains.
fn reaches(comptime T: type, comptime target: type, comptime visiting: []const type) bool {
    @setEvalBranchQuota(100_000);
    for (visiting) |v| if (v == T) return false;
    for (containedTypes(T)) |C| {
        if (C == target or reaches(C, target, visiting ++ &[_]type{T})) return true;
    }
    return false;
}

fn unwrapStruct(comptime Schema: type) type {
    @setEvalBranchQuota(100_000);
    const info = @typeInfo(Schema).@"struct";
    var field_names: [info.fields.len][]const u8 = undefined;
    var field_types: [info.fields.len]type = undefined;
    var field_attrs: [info.fields.len]std.builtin.Type.StructField.Attributes = undefined;

    for (info.fields, 0..) |f, i| {
        field_names[i] = f.name;
        field_types[i] = Unwrap(f.type);
        field_attrs[i] = fieldAttrs(f);
    }

    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

fn fieldAttrs(comptime f: std.builtin.Type.StructField) std.builtin.Type.StructField.Attributes {
    if (fieldDefaultValue(f)) |dv| {
        const FieldT = Unwrap(f.type);
        const default_val: FieldT = dv;
        return .{ .default_value_ptr = @ptrCast(&default_val) };
    }
    return .{};
}

/// Default value (as a plain value, not a pointer) used when the field is
/// absent from the JSON input. `fieldAttrs` deals with comptime-only
/// pointers for type construction (`@Struct`), whereas `decodeValue` just
/// needs a single value at runtime, hence this separate helper.
fn fieldDefaultValue(comptime f: std.builtin.Type.StructField) ?Unwrap(f.type) {
    if (comptime isField(f.type)) return constraintsDefaultValue(f.type);
    // A plain field whose type contains `Field()` labels (e.g. a nested
    // schema struct) is a different type once unwrapped, so its Zig default
    // cannot be carried over.
    if (comptime Unwrap(f.type) != f.type) {
        if (f.default_value_ptr != null) {
            @compileError("zig-jsonschema: default values are not supported on field '" ++ f.name ++ "' because its type contains Field() labels");
        }
        return null;
    }
    // Plain fields keep their original Zig default value as-is.
    return f.defaultValue();
}

/// Default value declared via `Field(T, constraints)`'s `.default`. Only
/// number/string/bool constraints support `.default` in this MVP.
/// `FieldSchema` must satisfy `isField(FieldSchema)`.
fn constraintsDefaultValue(comptime FieldSchema: type) ?Unwrap(FieldSchema) {
    const c = FieldSchema.zjs_constraints;
    if (comptime @TypeOf(c) == NumberConstraints) {
        if (c.default) |d| return numberFromF64(Unwrap(FieldSchema), d);
        return null;
    }
    if (comptime @TypeOf(c) == StringConstraints) return c.default;
    if (comptime @TypeOf(c) == BoolConstraints) return c.default;
    return null;
}

fn numberFromF64(comptime T: type, v: f64) T {
    return switch (@typeInfo(T)) {
        .optional => |info| @as(T, numberFromF64(info.child, v)),
        .int => @intFromFloat(v),
        .float => @floatCast(v),
        .@"enum" => |e| @enumFromInt(@as(e.tag_type, @intFromFloat(v))),
        else => @compileError("zig-jsonschema: default is only supported for numeric types, got " ++ @typeName(T)),
    };
}

/// Whether a field may be omitted from the JSON input (it has a default
/// value, or its type is optional).
fn isOptionalField(comptime f: std.builtin.Type.StructField) bool {
    if (fieldDefaultValue(f) != null) return true;
    if (comptime isField(f.type)) return @typeInfo(f.type.zjs_inner) == .optional;
    return @typeInfo(f.type) == .optional;
}

/// Options shared by schema generation (`toSchema`) and
/// decoding (`fromJson`), so that a generated schema accepts
/// exactly what `fromJson` accepts when both use the same options.
pub const SchemaOptions = struct {
    /// Emit this URI as the root's `$id` (`id` in draft 4), right after
    /// `$schema`. It names the schema and becomes the base URI that the
    /// generated `$ref`s resolve against. From 2019-09 on it must not have
    /// a non-empty fragment. Generation only.
    id: ?[]const u8 = null,
    /// JSON Schema version (dialect) to generate. `fromJson` follows it
    /// where the drafts differ: before draft 6, `1.0` is not an integer.
    draft: Draft = .draft2020_12,
    /// Emit `$schema` at the root, so consumers know which dialect the
    /// schema is written in. Generation only.
    emit_schema_uri: bool = true,
    /// How JSON object keys that match no struct field are treated, for
    /// every object whose `Field()` does not set `additionalProperties`
    /// explicitly (an explicit setting always wins).
    unknown_fields: UnknownFields = .allow,
    /// How struct field names are spelled as JSON object keys. Two fields
    /// must not map to the same key.
    field_naming: FieldNaming = .as_is,
    /// Emit every named struct type (other than the root) once under
    /// `$defs` (`definitions` before 2019-09) and refer to it with `$ref`,
    /// instead of inlining it at each use. Recursive types are always
    /// emitted this way. Generation only.
    reuse_definitions: bool = true,
};

pub const UnknownFields = enum {
    /// Accept and ignore them (the JSON Schema default); nothing is emitted.
    allow,
    /// Reject them; `"additionalProperties": false` is emitted.
    deny,
};

/// JSON key spelling of struct field names. Words are split at `_` and at
/// lower-to-upper case changes, so both `user_id` and `userId` become
/// `userId` in `.camel_case`. Leading underscores are kept.
pub const FieldNaming = enum {
    /// The Zig field name unchanged.
    as_is,
    /// `user_id` -> `userId`
    camel_case,
    /// `user_id` -> `UserId`
    pascal_case,
    /// `userId` -> `user_id`
    snake_case,
    /// `user_id` -> `user-id`
    kebab_case,
};

/// The JSON key of the field named `name`.
fn jsonName(comptime name: []const u8, naming: FieldNaming) []const u8 {
    return switch (naming) {
        inline else => |n| comptime convertName(name, n),
    };
}

fn convertName(comptime name: []const u8, comptime naming: FieldNaming) []const u8 {
    if (naming == .as_is) return name;
    @setEvalBranchQuota(10_000);
    var out: []const u8 = "";
    var i: usize = 0;
    while (i < name.len and name[i] == '_') : (i += 1) out = out ++ "_";
    var word_index: usize = 0;
    var at_word_start = true;
    while (i < name.len) : (i += 1) {
        const c = name[i];
        if (c == '_') {
            at_word_start = true;
            continue;
        }
        // `userId`: an upper-case letter after a lower-case one or a digit starts a word.
        if (std.ascii.isUpper(c) and i > 0 and (std.ascii.isLower(name[i - 1]) or std.ascii.isDigit(name[i - 1]))) {
            at_word_start = true;
        }
        // A new word, unless nothing but leading underscores came before.
        if (at_word_start and out.len > 0 and out[out.len - 1] != '_') {
            word_index += 1;
            switch (naming) {
                .snake_case => out = out ++ "_",
                .kebab_case => out = out ++ "-",
                else => {},
            }
        }
        const capitalize = at_word_start and switch (naming) {
            .camel_case => word_index > 0,
            .pascal_case => true,
            else => false,
        };
        out = out ++ &[_]u8{if (capitalize) std.ascii.toUpper(c) else std.ascii.toLower(c)};
        at_word_start = false;
    }
    return out;
}

fn additionalPropertiesFor(explicit: ?bool, options: SchemaOptions) ?bool {
    return explicit orelse switch (options.unknown_fields) {
        .allow => null,
        .deny => false,
    };
}

/// Builds a JSON Schema from type `Schema` at comptime, in the dialect
/// selected by `options.draft` (e.g. draft 4 expresses `exclusiveMinimum`
/// as a boolean modifier of `minimum`). Pass `.{}` for the defaults: draft
/// 2020-12 with `$schema`, named struct types shared via `$defs`. Every
/// `std.json.Value` in the result is owned by `allocator` (using an
/// `ArenaAllocator` at the call site is recommended).
pub fn toSchema(comptime Schema: type, allocator: Allocator, options: SchemaOptions) Allocator.Error!std.json.Value {
    var gen: Gen = .{ .allocator = allocator, .options = options, .inline_next_struct = comptime rootIsStruct(Schema) };
    // A plain root struct that refers to itself is referenced as "#".
    if (comptime isNamedStruct(Schema)) try gen.refs.put(allocator, @typeName(Schema), "#");
    const body = try buildSchema(Schema, &gen);

    var obj: std.json.ObjectMap = .empty;
    if (options.emit_schema_uri) {
        const schema_uri = switch (options.draft) {
            // Drafts up to 7 conventionally reference their metaschema with an empty fragment.
            .draft4, .draft6, .draft7 => try std.fmt.allocPrint(allocator, "{s}#", .{options.draft.metaschemaUri()}),
            .draft2019_09, .draft2020_12 => options.draft.metaschemaUri(),
        };
        // `$schema` first, so it reads naturally in the serialized output.
        try obj.put(allocator, "$schema", .{ .string = schema_uri });
    }
    if (options.id) |id| {
        const keyword = if (options.draft == .draft4) "id" else "$id";
        try obj.put(allocator, keyword, .{ .string = try allocator.dupe(u8, id) });
    }
    var it = body.object.iterator();
    while (it.next()) |e| try obj.put(allocator, e.key_ptr.*, e.value_ptr.*);
    if (gen.defs.count() > 0) try obj.put(allocator, gen.defsKeyword(), .{ .object = gen.defs });
    return .{ .object = obj };
}

/// State of one schema generation: the shared definitions emitted so far.
const Gen = struct {
    allocator: Allocator,
    options: SchemaOptions,
    /// Definition name -> schema, in order of first use.
    defs: std.json.ObjectMap = .empty,
    /// `@typeName` -> `$ref` target, for every type defined (or being defined).
    refs: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Definition name -> `@typeName`, to keep names unique.
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Named struct types currently being inlined (to detect recursion).
    inlining: std.StringHashMapUnmanaged(void) = .empty,
    /// Set while the root struct has not been emitted: the root is always
    /// inlined, never turned into a `$ref`.
    inline_next_struct: bool,

    fn defsKeyword(gen: *const Gen) []const u8 {
        return switch (gen.options.draft) {
            .draft4, .draft6, .draft7 => "definitions",
            .draft2019_09, .draft2020_12 => "$defs",
        };
    }

    /// Returns the `$ref` target for `T`, defining it first if needed, or
    /// null if `T` should be inlined here.
    fn refFor(gen: *Gen, comptime T: type) Allocator.Error!?[]const u8 {
        const type_name = @typeName(T);
        if (gen.refs.get(type_name)) |r| return r;
        if (!gen.options.reuse_definitions and !gen.inlining.contains(type_name)) return null;

        const name = try gen.uniqueName(type_name);
        const ref = try std.fmt.allocPrint(gen.allocator, "#/{s}/{s}", .{ gen.defsKeyword(), name });
        try gen.refs.put(gen.allocator, type_name, ref);
        // Reserve the slot so definitions keep their order of first use.
        try gen.defs.put(gen.allocator, name, .null);
        const schema = switch (@typeInfo(T)) {
            .@"struct" => try buildObjectSchema(T, .{}, null, gen),
            .@"union" => try buildUnionSchema(T, .{}, gen),
            else => unreachable,
        };
        try gen.defs.put(gen.allocator, name, schema);
        return ref;
    }

    fn uniqueName(gen: *Gen, type_name: []const u8) Allocator.Error![]const u8 {
        const base = try shortTypeName(gen.allocator, type_name);
        var name = base;
        var n: usize = 2;
        while (gen.names.get(name)) |owner| : (n += 1) {
            if (std.mem.eql(u8, owner, type_name)) break;
            name = try std.fmt.allocPrint(gen.allocator, "{s}_{d}", .{ base, n });
        }
        try gen.names.put(gen.allocator, name, type_name);
        return name;
    }
};

/// Whether the root of `Schema` (below `Field()` and `?`) is a struct or union.
fn rootIsStruct(comptime Schema: type) bool {
    if (isField(Schema)) return rootIsStruct(Schema.zjs_inner);
    return switch (@typeInfo(Schema)) {
        .optional => |o| rootIsStruct(o.child),
        .@"struct", .@"union" => true,
        else => false,
    };
}

/// Whether `T` is a struct or union with a user-given name (anonymous
/// `struct {}` / `union(enum) {}` literals are always inlined).
fn isNamedStruct(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => !isField(T) and std.mem.indexOf(u8, @typeName(T), "__struct_") == null,
        .@"union" => std.mem.indexOf(u8, @typeName(T), "__union_") == null,
        else => false,
    };
}

/// Turns a fully qualified type name into a definition name by dropping
/// namespaces: `app.models.Address` -> `Address`, `app.List(app.Address)`
/// -> `List_Address`.
fn shortTypeName(allocator: Allocator, type_name: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var token_start: usize = 0;
    for (type_name, 0..) |c, i| {
        if (std.ascii.isAlphanumeric(c) or c == '_') continue;
        if (c == '.') {
            // Whatever came before a '.' was a namespace.
            token_start = i + 1;
            continue;
        }
        try out.appendSlice(allocator, type_name[token_start..i]);
        if (out.items.len > 0 and out.items[out.items.len - 1] != '_') try out.append(allocator, '_');
        token_start = i + 1;
    }
    try out.appendSlice(allocator, type_name[token_start..]);
    while (out.items.len > 0 and out.items[out.items.len - 1] == '_') _ = out.pop();
    return out.items;
}

fn buildSchema(comptime Schema: type, gen: *Gen) Allocator.Error!std.json.Value {
    if (comptime isField(Schema)) {
        return buildSchemaFor(Schema.zjs_inner, Schema.zjs_constraints, gen);
    }
    // `?Email` where `Email = Field([]const u8, ...)`: the same as
    // `Field(?[]const u8, ...)`.
    if (comptime @typeInfo(Schema) == .optional and isField(@typeInfo(Schema).optional.child)) {
        const F = @typeInfo(Schema).optional.child;
        return buildSchemaFor(?F.zjs_inner, F.zjs_constraints, gen);
    }
    return buildSchemaFor(Schema, ConstraintsFor(Schema){}, gen);
}

fn buildSchemaFor(comptime T: type, constraints: ConstraintsFor(T), gen: *Gen) Allocator.Error!std.json.Value {
    const allocator = gen.allocator;
    if (comptime @typeInfo(T) == .optional) {
        // `?T` accepts `null` (as `fromJson` does).
        var schema = try buildSchemaFor(@typeInfo(T).optional.child, constraints, gen);
        if (schema.object.get("type")) |t| {
            // Widen `type` to `[<type>, "null"]`. The other keywords only
            // constrain their own instance type, so they keep applying to
            // non-null values unchanged.
            var types: std.json.Array = .init(allocator);
            try types.append(t);
            try types.append(.{ .string = "null" });
            try schema.object.put(allocator, "type", .{ .array = types });
            return schema;
        }
        // A reference: `$ref` cannot be widened in place.
        var null_schema: std.json.ObjectMap = .empty;
        try null_schema.put(allocator, "type", .{ .string = "null" });
        var branches: std.json.Array = .init(allocator);
        try branches.append(schema);
        try branches.append(.{ .object = null_schema });
        var obj: std.json.ObjectMap = .empty;
        try obj.put(allocator, "anyOf", .{ .array = branches });
        return .{ .object = obj };
    }
    switch (@typeInfo(T)) {
        .int, .float => return buildNumberSchema(T, constraints, gen),
        .@"enum" => |e| return buildNumberSchema(e.tag_type, constraints, gen),
        .bool => return buildBoolSchema(constraints, allocator),
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return buildStringSchema(constraints, allocator);
            if (p.size == .slice) return buildArraySchema(p.child, constraints, gen);
            if (p.size == .one) {
                if (comptime isField(p.child)) return buildSchema(p.child, gen);
                return buildSchemaFor(p.child, constraints, gen);
            }
            @compileError("zig-jsonschema: unsupported pointer type " ++ @typeName(T));
        },
        .@"struct" => return buildStructUse(T, constraints, gen),
        .@"union" => return buildUnionUse(T, constraints, gen),
        else => @compileError("zig-jsonschema: unsupported type " ++ @typeName(T)),
    }
}

/// Schema for one use of struct `T`: a `$ref` to its shared definition
/// (with use-site keywords layered on top), or the struct inlined.
fn buildStructUse(comptime T: type, constraints: ObjectConstraints, gen: *Gen) Allocator.Error!std.json.Value {
    const allocator = gen.allocator;
    if (gen.inline_next_struct) {
        gen.inline_next_struct = false;
        return buildInlineStruct(T, constraints, gen);
    }
    // An explicit `additionalProperties` changes the object's shape, which a
    // shared definition cannot express, so such uses are inlined.
    if (comptime !isNamedStruct(T)) return buildObjectSchema(T, constraints, null, gen);
    if (constraints.additionalProperties != null) return buildInlineStruct(T, constraints, gen);
    const ref = (try gen.refFor(T)) orelse return buildInlineStruct(T, constraints, gen);
    var obj = try refWithSiblings(ref, constraints.title, constraints.description, allocator);
    if (obj.object.get("allOf") == null and (constraints.minProperties != null or constraints.maxProperties != null)) {
        obj = try wrapInAllOf(obj, allocator);
    }
    if (constraints.minProperties) |v| try obj.object.put(allocator, "minProperties", .{ .integer = @intCast(v) });
    if (constraints.maxProperties) |v| try obj.object.put(allocator, "maxProperties", .{ .integer = @intCast(v) });
    return obj;
}

/// `{"$ref": ref}`, wrapped in `allOf` when annotations are layered on top:
/// drafts up to 7 ignore keywords next to `$ref` (the `allOf` form is
/// valid in every draft).
fn refWithSiblings(ref: []const u8, title: ?[]const u8, description: ?[]const u8, allocator: Allocator) Allocator.Error!std.json.Value {
    var ref_obj: std.json.ObjectMap = .empty;
    try ref_obj.put(allocator, "$ref", .{ .string = ref });
    if (title == null and description == null) return .{ .object = ref_obj };
    var obj = try wrapInAllOf(.{ .object = ref_obj }, allocator);
    if (title) |v| try obj.object.put(allocator, "title", .{ .string = v });
    if (description) |v| try obj.object.put(allocator, "description", .{ .string = v });
    return obj;
}

fn wrapInAllOf(schema: std.json.Value, allocator: Allocator) Allocator.Error!std.json.Value {
    var all_of: std.json.Array = .init(allocator);
    try all_of.append(schema);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "allOf", .{ .array = all_of });
    return .{ .object = obj };
}

fn buildInlineStruct(comptime T: type, constraints: ObjectConstraints, gen: *Gen) Allocator.Error!std.json.Value {
    try gen.inlining.put(gen.allocator, @typeName(T), {});
    defer _ = gen.inlining.remove(@typeName(T));
    return buildObjectSchema(T, constraints, null, gen);
}

/// Schema for one use of union `T`: a `$ref` to its shared definition, or
/// the union inlined.
fn buildUnionUse(comptime T: type, constraints: UnionConstraints, gen: *Gen) Allocator.Error!std.json.Value {
    if (gen.inline_next_struct) {
        gen.inline_next_struct = false;
        return buildInlineUnion(T, constraints, gen);
    }
    if (comptime !isNamedStruct(T)) return buildUnionSchema(T, constraints, gen);
    const ref = (try gen.refFor(T)) orelse return buildInlineUnion(T, constraints, gen);
    return refWithSiblings(ref, constraints.title, constraints.description, gen.allocator);
}

fn buildInlineUnion(comptime T: type, constraints: UnionConstraints, gen: *Gen) Allocator.Error!std.json.Value {
    try gen.inlining.put(gen.allocator, @typeName(T), {});
    defer _ = gen.inlining.remove(@typeName(T));
    return buildUnionSchema(T, constraints, gen);
}

/// `oneOf` with one branch per variant (see `UnionConstraints`).
fn buildUnionSchema(comptime T: type, constraints: UnionConstraints, gen: *Gen) Allocator.Error!std.json.Value {
    const allocator = gen.allocator;
    const discriminator = comptime discriminatorOf(T);
    var branches: std.json.Array = .init(allocator);
    inline for (@typeInfo(T).@"union".fields) |f| {
        const name = jsonName(f.name, gen.options.field_naming);
        const Payload = stripField(f.type);
        if (discriminator) |key| {
            // `{"<key>": "<name>", ...payload fields}`
            const tag: ObjectTag = .{ .key = key, .value = name };
            if (Payload == void) {
                try branches.append(try buildObjectSchema(struct {}, .{}, tag, gen));
            } else {
                const c: ObjectConstraints = if (comptime isField(f.type)) f.type.zjs_constraints else .{};
                try gen.inlining.put(allocator, @typeName(Payload), {});
                defer _ = gen.inlining.remove(@typeName(Payload));
                try branches.append(try buildObjectSchema(Payload, c, tag, gen));
            }
        } else {
            // `{"<name>": <payload>}`, a void payload being `{}`.
            const payload: std.json.Value = if (Payload == void) blk: {
                var empty: std.json.ObjectMap = .empty;
                try empty.put(allocator, "type", .{ .string = "object" });
                try empty.put(allocator, "maxProperties", .{ .integer = 0 });
                break :blk .{ .object = empty };
            } else try buildSchema(f.type, gen);
            var props: std.json.ObjectMap = .empty;
            try props.put(allocator, name, payload);
            var required: std.json.Array = .init(allocator);
            try required.append(.{ .string = name });
            var branch: std.json.ObjectMap = .empty;
            try branch.put(allocator, "type", .{ .string = "object" });
            try branch.put(allocator, "properties", .{ .object = props });
            try branch.put(allocator, "required", .{ .array = required });
            // Exactly one key: the variant's.
            try branch.put(allocator, "additionalProperties", .{ .bool = false });
            try branches.append(.{ .object = branch });
        }
    }
    var obj: std.json.ObjectMap = .empty;
    if (constraints.title) |v| try obj.put(allocator, "title", .{ .string = v });
    if (constraints.description) |v| try obj.put(allocator, "description", .{ .string = v });
    try obj.put(allocator, "oneOf", .{ .array = branches });
    return .{ .object = obj };
}

/// The discriminator property an internally tagged union adds to a variant's object.
const ObjectTag = struct { key: []const u8, value: []const u8 };

fn buildNumberSchema(comptime T: type, constraints: NumberConstraints, gen: *Gen) Allocator.Error!std.json.Value {
    const allocator = gen.allocator;
    const type_name = switch (@typeInfo(T)) {
        .int => "integer",
        .float => "number",
        else => @compileError("zig-jsonschema: Field constraints only support numeric types, got " ++ @typeName(T)),
    };

    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "type", .{ .string = type_name });
    if (constraints.title) |v| try obj.put(allocator, "title", .{ .string = v });
    if (constraints.description) |v| try obj.put(allocator, "description", .{ .string = v });
    if (constraints.default) |v| try obj.put(allocator, "default", .{ .float = v });

    // The type's own range applies unless a user bound is at least as strict,
    // so that the schema rejects what `fromJson` cannot store (e.g. 300 for u8).
    const range = typeRange(T);
    var lower: SideBounds = .{ .inclusive = floatBound(constraints.minimum), .exclusive = floatBound(constraints.exclusiveMinimum) };
    var upper: SideBounds = .{ .inclusive = floatBound(constraints.maximum), .exclusive = floatBound(constraints.exclusiveMaximum) };
    if (range) |r| {
        if (!lower.atLeast(r.min, .lower)) lower = .{ .inclusive = r.min };
        if (!upper.atLeast(r.max, .upper)) upper = .{ .inclusive = r.max };
    }

    if (gen.options.draft == .draft4) {
        // Draft 4 has a single bound per side, made exclusive by a boolean.
        try putDraft4Bound(&obj, allocator, "minimum", "exclusiveMinimum", lower, .lower);
        try putDraft4Bound(&obj, allocator, "maximum", "exclusiveMaximum", upper, .upper);
    } else {
        if (lower.inclusive) |b| try obj.put(allocator, "minimum", try b.toJson(allocator));
        if (upper.inclusive) |b| try obj.put(allocator, "maximum", try b.toJson(allocator));
        if (lower.exclusive) |b| try obj.put(allocator, "exclusiveMinimum", try b.toJson(allocator));
        if (upper.exclusive) |b| try obj.put(allocator, "exclusiveMaximum", try b.toJson(allocator));
    }
    if (constraints.multipleOf) |v| try obj.put(allocator, "multipleOf", .{ .float = v });
    return .{ .object = obj };
}

/// A numeric bound: exact for integer type ranges, f64 for user bounds.
const Bound = union(enum) {
    int: i256,
    float: f64,

    fn order(a: Bound, b: Bound) std.math.Order {
        return switch (a) {
            .int => |x| switch (b) {
                .int => |y| std.math.order(x, y),
                .float => |y| validator.compareIntFloat(x, y),
            },
            .float => |x| switch (b) {
                .int => |y| validator.compareIntFloat(y, x).invert(),
                .float => |y| std.math.order(x, y),
            },
        };
    }

    fn toJson(b: Bound, allocator: Allocator) Allocator.Error!std.json.Value {
        return switch (b) {
            // std.json writes floats positionally: keep 3.4e38 readable.
            .float => |f| if (@abs(f) >= 1e21)
                .{ .number_string = try std.fmt.allocPrint(allocator, "{e}", .{f}) }
            else
                .{ .float = f },
            .int => |i| if (std.math.cast(i64, i)) |small|
                .{ .integer = small }
            else
                // Beyond i64 (e.g. the u64 maximum): written out verbatim.
                .{ .number_string = try std.fmt.allocPrint(allocator, "{d}", .{i}) },
        };
    }
};

fn floatBound(v: ?f64) ?Bound {
    return if (v) |f| .{ .float = f } else null;
}

const SideBounds = struct {
    inclusive: ?Bound = null,
    exclusive: ?Bound = null,

    /// Whether these bounds already exclude everything beyond `limit`.
    fn atLeast(s: SideBounds, limit: Bound, comptime side: Side) bool {
        inline for (.{ s.inclusive, s.exclusive }) |maybe| {
            if (maybe) |b| if (side.stricterOrEqual(b, limit)) return true;
        }
        return false;
    }
};

const Side = enum {
    lower,
    upper,

    fn stricterOrEqual(side: Side, a: Bound, b: Bound) bool {
        const ord = a.order(b);
        return ord == .eq or ord == if (side == .lower) std.math.Order.gt else std.math.Order.lt;
    }
};

/// The range of values `T` can hold, for types narrower than a JSON number:
/// every integer type, and floats narrower than f64 (larger JSON numbers
/// would overflow to infinity).
fn typeRange(comptime T: type) ?struct { min: Bound, max: Bound } {
    return switch (@typeInfo(T)) {
        .int => |i| blk: {
            if (i.bits > 255) @compileError("zig-jsonschema: integer types wider than 255 bits are not supported");
            break :blk .{ .min = .{ .int = std.math.minInt(T) }, .max = .{ .int = std.math.maxInt(T) } };
        },
        .float => |f| if (f.bits < 64)
            .{ .min = .{ .float = -std.math.floatMax(T) }, .max = .{ .float = std.math.floatMax(T) } }
        else
            null,
        else => null,
    };
}

/// Emits the stricter of an inclusive and an exclusive bound in draft 4
/// form (`minimum` + `exclusiveMinimum: true`, or the maximum equivalent).
fn putDraft4Bound(
    obj: *std.json.ObjectMap,
    allocator: Allocator,
    comptime bound_key: []const u8,
    comptime exclusive_key: []const u8,
    bounds: SideBounds,
    comptime side: Side,
) Allocator.Error!void {
    const use_exclusive = blk: {
        const ex = bounds.exclusive orelse break :blk false;
        const in = bounds.inclusive orelse break :blk true;
        break :blk side.stricterOrEqual(ex, in);
    };
    if (use_exclusive) {
        try obj.put(allocator, bound_key, try bounds.exclusive.?.toJson(allocator));
        try obj.put(allocator, exclusive_key, .{ .bool = true });
    } else if (bounds.inclusive) |in| {
        try obj.put(allocator, bound_key, try in.toJson(allocator));
    }
}

fn buildBoolSchema(constraints: BoolConstraints, allocator: Allocator) Allocator.Error!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "type", .{ .string = "boolean" });
    if (constraints.title) |v| try obj.put(allocator, "title", .{ .string = v });
    if (constraints.description) |v| try obj.put(allocator, "description", .{ .string = v });
    if (constraints.default) |v| try obj.put(allocator, "default", .{ .bool = v });
    return .{ .object = obj };
}

fn buildStringSchema(constraints: StringConstraints, allocator: Allocator) Allocator.Error!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "type", .{ .string = "string" });
    if (constraints.title) |v| try obj.put(allocator, "title", .{ .string = v });
    if (constraints.description) |v| try obj.put(allocator, "description", .{ .string = v });
    if (constraints.default) |v| try obj.put(allocator, "default", .{ .string = v });
    if (constraints.minLength) |v| try obj.put(allocator, "minLength", .{ .integer = @intCast(v) });
    if (constraints.maxLength) |v| try obj.put(allocator, "maxLength", .{ .integer = @intCast(v) });
    if (constraints.pattern) |v| try obj.put(allocator, "pattern", .{ .string = v });
    return .{ .object = obj };
}

fn buildArraySchema(comptime Item: type, constraints: ArrayConstraints, gen: *Gen) Allocator.Error!std.json.Value {
    const allocator = gen.allocator;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "type", .{ .string = "array" });
    if (constraints.title) |v| try obj.put(allocator, "title", .{ .string = v });
    if (constraints.description) |v| try obj.put(allocator, "description", .{ .string = v });
    if (constraints.minItems) |v| try obj.put(allocator, "minItems", .{ .integer = @intCast(v) });
    if (constraints.maxItems) |v| try obj.put(allocator, "maxItems", .{ .integer = @intCast(v) });
    if (constraints.uniqueItems) |v| try obj.put(allocator, "uniqueItems", .{ .bool = v });
    try obj.put(allocator, "items", try buildSchema(Item, gen));
    return .{ .object = obj };
}

fn buildObjectSchema(comptime StructT: type, constraints: ObjectConstraints, tag: ?ObjectTag, gen: *Gen) Allocator.Error!std.json.Value {
    const allocator = gen.allocator;
    const info = @typeInfo(StructT).@"struct";
    var props: std.json.ObjectMap = .empty;
    var required: std.json.Array = .init(allocator);

    if (tag) |t| {
        // Draft 4 has no `const`.
        var values: std.json.Array = .init(allocator);
        try values.append(.{ .string = t.value });
        var tag_schema: std.json.ObjectMap = .empty;
        if (gen.options.draft == .draft4) {
            try tag_schema.put(allocator, "enum", .{ .array = values });
        } else {
            try tag_schema.put(allocator, "const", .{ .string = t.value });
        }
        try props.put(allocator, t.key, .{ .object = tag_schema });
        try required.append(.{ .string = t.key });
    }

    inline for (info.fields) |f| {
        const name = jsonName(f.name, gen.options.field_naming);
        const field_schema = try buildSchema(f.type, gen);
        try props.put(allocator, name, field_schema);
        if (!isOptionalField(f)) {
            try required.append(.{ .string = name });
        }
    }

    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "type", .{ .string = "object" });
    if (constraints.title) |v| try obj.put(allocator, "title", .{ .string = v });
    if (constraints.description) |v| try obj.put(allocator, "description", .{ .string = v });
    try obj.put(allocator, "properties", .{ .object = props });
    if (required.items.len > 0) {
        try obj.put(allocator, "required", .{ .array = required });
    }
    if (constraints.minProperties) |v| try obj.put(allocator, "minProperties", .{ .integer = @intCast(v) });
    if (constraints.maxProperties) |v| try obj.put(allocator, "maxProperties", .{ .integer = @intCast(v) });
    if (additionalPropertiesFor(constraints.additionalProperties, gen.options)) |v| {
        try obj.put(allocator, "additionalProperties", .{ .bool = v });
    }
    return .{ .object = obj };
}

/// A single violation found during validation.
pub const ValidationError = struct {
    /// Dot-separated field/index path (e.g. "items.0.price").
    path: []const u8,
    message: []const u8,
};

/// Validates `value` (of type `Unwrap(Schema)`) against the constraints
/// declared on `Schema`. Every violation found is appended to `errors`
/// (validation does not stop at the first one).
pub fn validate(
    comptime Schema: type,
    value: Unwrap(Schema),
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
) Allocator.Error!void {
    try validatePath(Schema, value, "", .{}, allocator, errors);
}

/// How `validatePath` checks a value.
const Check = struct {
    /// Spelling of field names in error paths.
    naming: FieldNaming = .as_is,
    /// Check `uniqueItems` on the Zig values. `fromJson` checks it on the
    /// JSON items instead: e.g. `{"a": null}` and `{}` are different JSON
    /// values that decode to the same Zig value.
    unique_items: bool = true,
};

fn validatePath(
    comptime Schema: type,
    value: Unwrap(Schema),
    path: []const u8,
    check: Check,
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
) Allocator.Error!void {
    if (comptime isField(Schema)) {
        try checkConstraints(Schema.zjs_inner, value, Schema.zjs_constraints, path, check, allocator, errors);
        try validatePath(Schema.zjs_inner, value, path, check, allocator, errors);
        return;
    }

    switch (@typeInfo(Schema)) {
        .int, .float, .bool, .@"enum" => {}, // leaf types: constraints (if any) were already applied above
        .optional => |info| {
            if (value) |inner| try validatePath(info.child, inner, path, check, allocator, errors);
        },
        .pointer => |info| {
            if (info.size == .slice and info.child == u8) return; // string leaf
            if (info.size == .one) return validatePath(info.child, value.*, path, check, allocator, errors);
            for (value, 0..) |elem, i| {
                const idx_path = try childPath(path, try std.fmt.allocPrint(allocator, "{d}", .{i}), allocator);
                try validatePath(info.child, elem, idx_path, check, allocator, errors);
            }
        },
        .@"struct" => |info| {
            inline for (info.fields) |f| {
                const child_path = try childPath(path, jsonName(f.name, check.naming), allocator);
                try validatePath(f.type, @field(value, f.name), child_path, check, allocator, errors);
            }
        },
        .@"union" => switch (value) {
            inline else => |payload, tag| {
                const name = @tagName(tag);
                // Internally tagged payload fields sit next to the tag.
                const payload_path = if (comptime discriminatorOf(Schema) != null) path else try childPath(path, jsonName(name, check.naming), allocator);
                try validatePath(@FieldType(Schema, name), payload, payload_path, check, allocator, errors);
            },
        },
        .void => {},
        else => @compileError("zig-jsonschema: unsupported type " ++ @typeName(Schema)),
    }
}

/// Applies the constraints declared via `Field(Inner, constraints)` to
/// `value`. Structural drill-down (into struct fields / array items) is
/// handled separately by `validatePath`.
fn checkConstraints(
    comptime Inner: type,
    value: Unwrap(Inner),
    constraints: ConstraintsFor(Inner),
    path: []const u8,
    check: Check,
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
) Allocator.Error!void {
    if (comptime @typeInfo(Inner) == .optional) {
        if (value) |v| try checkConstraints(@typeInfo(Inner).optional.child, v, constraints, path, check, allocator, errors);
        return;
    }

    switch (@typeInfo(Inner)) {
        .int, .float => try checkNumberConstraints(Inner, value, constraints, path, allocator, errors),
        .@"enum" => |e| try checkNumberConstraints(e.tag_type, @intFromEnum(value), constraints, path, allocator, errors),
        .bool => {}, // no assertion keywords for booleans in this MVP
        .pointer => |p| {
            if (p.size == .one) {
                try checkConstraints(p.child, value.*, constraints, path, check, allocator, errors);
            } else if (p.size == .slice and p.child == u8) {
                try checkStringConstraints(value, constraints, path, allocator, errors);
            } else {
                try checkArrayConstraints(p.child, value, constraints, path, check, allocator, errors);
            }
        },
        .@"struct" => try checkObjectConstraints(Inner, constraints, path, allocator, errors),
        .@"union" => {}, // annotations only
        else => @compileError("zig-jsonschema: unsupported type " ++ @typeName(Inner)),
    }
}

fn childPath(path: []const u8, name: []const u8, allocator: Allocator) Allocator.Error![]const u8 {
    return if (path.len == 0) name else try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, name });
}

fn addError(
    errors: *std.ArrayList(ValidationError),
    allocator: Allocator,
    path: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    try errors.append(allocator, .{
        .path = path,
        .message = try std.fmt.allocPrint(allocator, fmt, args),
    });
}

fn checkNumberConstraints(
    comptime T: type,
    value: T,
    constraints: NumberConstraints,
    path: []const u8,
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
) Allocator.Error!void {
    const v: f64 = switch (@typeInfo(T)) {
        .int => @floatFromInt(value),
        .float => value,
        else => @compileError("zig-jsonschema: Field constraints only support numeric types, got " ++ @typeName(T)),
    };

    if (constraints.minimum) |min| {
        if (v < min) try addError(errors, allocator, path, "{d} is less than minimum {d}", .{ v, min });
    }
    if (constraints.maximum) |max| {
        if (v > max) try addError(errors, allocator, path, "{d} is greater than maximum {d}", .{ v, max });
    }
    if (constraints.exclusiveMinimum) |min| {
        if (v <= min) try addError(errors, allocator, path, "{d} must be strictly greater than {d}", .{ v, min });
    }
    if (constraints.exclusiveMaximum) |max| {
        if (v >= max) try addError(errors, allocator, path, "{d} must be strictly less than {d}", .{ v, max });
    }
    if (constraints.multipleOf) |m| {
        const remainder = @mod(v, m);
        if (@abs(remainder) > 1e-9 and @abs(remainder - m) > 1e-9) {
            try addError(errors, allocator, path, "{d} is not a multiple of {d}", .{ v, m });
        }
    }
}

fn checkStringConstraints(
    value: []const u8,
    constraints: StringConstraints,
    path: []const u8,
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
) Allocator.Error!void {
    // Code points, as JSON Schema counts them (invalid UTF-8: bytes).
    const len = std.unicode.utf8CountCodepoints(value) catch value.len;
    if (constraints.minLength) |min| {
        if (len < min) try addError(errors, allocator, path, "string length {d} is less than minLength {d}", .{ len, min });
    }
    if (constraints.maxLength) |max| {
        if (len > max) try addError(errors, allocator, path, "string length {d} is greater than maxLength {d}", .{ len, max });
    }
    if (constraints.pattern) |pattern| {
        const re = Regex.compile(allocator, pattern) catch |err| switch (err) {
            error.InvalidRegex => return addError(errors, allocator, path, "invalid pattern \"{s}\"", .{pattern}),
            else => |e| return e,
        };
        const matched = re.isMatch(allocator, value) catch |err| switch (err) {
            error.RegexLimitExceeded => return addError(errors, allocator, path, "pattern \"{s}\" exceeded the regex step limit", .{pattern}),
            else => |e| return e,
        };
        if (!matched) try addError(errors, allocator, path, "string does not match pattern \"{s}\"", .{pattern});
    }
}

fn checkArrayConstraints(
    comptime Item: type,
    value: []const Unwrap(Item),
    constraints: ArrayConstraints,
    path: []const u8,
    check: Check,
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
) Allocator.Error!void {
    if (constraints.minItems) |min| {
        if (value.len < min) try addError(errors, allocator, path, "array has {d} items, less than minItems {d}", .{ value.len, min });
    }
    if (constraints.maxItems) |max| {
        if (value.len > max) try addError(errors, allocator, path, "array has {d} items, more than maxItems {d}", .{ value.len, max });
    }
    if (check.unique_items and (constraints.uniqueItems orelse false)) {
        var i: usize = 0;
        while (i < value.len) : (i += 1) {
            var j: usize = i + 1;
            while (j < value.len) : (j += 1) {
                if (valuesEqual(Unwrap(Item), value[i], value[j])) {
                    try addError(errors, allocator, path, "array items at index {d} and {d} are not unique", .{ i, j });
                }
            }
        }
    }
}

/// Structural equality of plain values (for `uniqueItems` in `validate`).
fn valuesEqual(comptime T: type, a: T, b: T) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum" => a == b,
        .void => true,
        .optional => |info| if (a == null or b == null) (a == null and b == null) else valuesEqual(info.child, a.?, b.?),
        .pointer => |p| switch (p.size) {
            .one => valuesEqual(p.child, a.*, b.*),
            .slice => blk: {
                if (p.child == u8) break :blk std.mem.eql(u8, a, b);
                if (a.len != b.len) break :blk false;
                for (a, b) |x, y| if (!valuesEqual(p.child, x, y)) break :blk false;
                break :blk true;
            },
            else => @compileError("zig-jsonschema: unsupported pointer type " ++ @typeName(T)),
        },
        .@"struct" => |info| blk: {
            inline for (info.fields) |f| if (!valuesEqual(f.type, @field(a, f.name), @field(b, f.name))) break :blk false;
            break :blk true;
        },
        .@"union" => switch (a) {
            inline else => |payload, tag| b == tag and valuesEqual(@TypeOf(payload), payload, @field(b, @tagName(tag))),
        },
        else => @compileError("zig-jsonschema: unsupported type " ++ @typeName(T)),
    };
}

fn checkObjectConstraints(
    comptime StructT: type,
    constraints: ObjectConstraints,
    path: []const u8,
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
) Allocator.Error!void {
    const count = @typeInfo(StructT).@"struct".fields.len;
    if (constraints.minProperties) |min| {
        if (count < min) try addError(errors, allocator, path, "object has {d} properties, less than minProperties {d}", .{ count, min });
    }
    if (constraints.maxProperties) |max| {
        if (count > max) try addError(errors, allocator, path, "object has {d} properties, more than maxProperties {d}", .{ count, max });
    }
}

/// Maps a JSON string into `Unwrap(Schema)` and runs constraint validation
/// on the result in the same call.
///
/// - JSON syntax errors, type mismatches, missing required fields,
///   unexpected extra properties (when `additionalProperties = false`), and
///   constraint violations are all collected into `errors` (this does not
///   stop at the first one).
/// - If there is at least one error, `value` is `null` (a partially built,
///   invalid value is never exposed to the caller).
/// - Every string/slice in the returned value is owned by `allocator` (using
///   an `ArenaAllocator` at the call site is recommended).
pub fn FromJsonResult(comptime T: type) type {
    return struct {
        value: ?T,
        errors: std.ArrayList(ValidationError),
    };
}

/// Decodes and validates `json_text` against `Schema`. Pass `.{}` for the
/// defaults; `options.unknown_fields` is honoured and the generation-only
/// fields of `SchemaOptions` are ignored, so passing the options given to
/// `toSchema` makes both accept the same documents.
pub fn fromJson(
    comptime Schema: type,
    allocator: Allocator,
    json_text: []const u8,
    options: SchemaOptions,
) Allocator.Error!FromJsonResult(Unwrap(Schema)) {
    var errors: std.ArrayList(ValidationError) = .empty;

    const json_value = std.json.parseFromSliceLeaky(std.json.Value, allocator, json_text, .{}) catch |err| {
        try addError(&errors, allocator, "", "invalid JSON: {s}", .{@errorName(err)});
        return .{ .value = null, .errors = errors };
    };

    const decoded: ?Unwrap(Schema) = decodeValue(Schema, json_value, "", null, options, allocator, &errors) catch |err| switch (err) {
        error.Invalid => null,
        else => |e| return e,
    };

    if (decoded) |value| {
        try validatePath(Schema, value, "", .{ .naming = options.field_naming, .unique_items = false }, allocator, &errors);
        return .{ .value = if (errors.items.len == 0) value else null, .errors = errors };
    }
    return .{ .value = null, .errors = errors };
}

const DecodeError = error{Invalid} || Allocator.Error;

/// `additional` is the explicit `additionalProperties` of the `Field()`
/// labelling this value (if it is an object), or null.
fn decodeValue(
    comptime Schema: type,
    value: std.json.Value,
    path: []const u8,
    additional: ?bool,
    options: SchemaOptions,
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
) DecodeError!Unwrap(Schema) {
    if (comptime isField(Schema)) {
        const c = Schema.zjs_constraints;
        const explicit: ?bool = if (comptime @TypeOf(c) == ObjectConstraints) c.additionalProperties else null;
        const decoded = decodeValue(Schema.zjs_inner, value, path, explicit, options, allocator, errors);
        if (comptime @TypeOf(c) == ArrayConstraints) {
            if ((c.uniqueItems orelse false) and value == .array) try reportDuplicateItems(value.array.items, path, allocator, errors);
        }
        return decoded;
    }

    switch (@typeInfo(Schema)) {
        .optional => |info| {
            if (value == .null) return @as(Unwrap(Schema), null);
            return try decodeValue(info.child, value, path, additional, options, allocator, errors);
        },
        .bool => {
            switch (value) {
                .bool => |b| return b,
                else => {
                    try addError(errors, allocator, path, "expected a boolean, got {s}", .{@tagName(value)});
                    return error.Invalid;
                },
            }
        },
        .@"enum" => |e| return @enumFromInt(try decodeInt(e.tag_type, Schema, value, path, options, allocator, errors)),
        .int => return decodeInt(Schema, Schema, value, path, options, allocator, errors),
        .float => {
            const f: f64 = switch (value) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                // Integers beyond i64 and literals beyond f64 (such as 1e400).
                .number_string => |s| std.fmt.parseFloat(f64, s) catch unreachable,
                else => {
                    try addError(errors, allocator, path, "expected a number, got {s}", .{@tagName(value)});
                    return error.Invalid;
                },
            };
            // The schema bounds floats narrower than f64 by their range
            // (`typeRange`). Wider ones take any JSON number, like std.json
            // (a literal beyond f64 such as 1e400 becomes infinity).
            if ((comptime typeRange(Schema) != null) and !(@abs(f) <= std.math.floatMax(Schema))) {
                try addError(errors, allocator, path, "{s} does not fit in {s}", .{ try numberText(value, allocator), @typeName(Schema) });
                return error.Invalid;
            }
            return @as(Schema, @floatCast(f));
        },
        .pointer => |info| {
            if (info.size == .one) {
                const ptr = try allocator.create(Unwrap(info.child));
                ptr.* = try decodeValue(info.child, value, path, additional, options, allocator, errors);
                return ptr;
            }
            if (info.size == .slice and info.child == u8) {
                switch (value) {
                    .string => |s| return try allocator.dupe(u8, s),
                    else => {
                        try addError(errors, allocator, path, "expected a string, got {s}", .{@tagName(value)});
                        return error.Invalid;
                    },
                }
            }
            if (info.size == .slice) {
                if (value != .array) {
                    try addError(errors, allocator, path, "expected an array, got {s}", .{@tagName(value)});
                    return error.Invalid;
                }

                const items = value.array.items;
                const buf = try allocator.alloc(Unwrap(info.child), items.len);
                var any_failed = false;

                for (items, 0..) |item_value, i| {
                    const idx_path = try childPath(path, try std.fmt.allocPrint(allocator, "{d}", .{i}), allocator);
                    if (decodeValue(info.child, item_value, idx_path, null, options, allocator, errors)) |decoded| {
                        buf[i] = decoded;
                    } else |err| switch (err) {
                        error.Invalid => any_failed = true,
                        else => |e| return e,
                    }
                }

                if (any_failed) return error.Invalid;
                return buf;
            }
            @compileError("zig-jsonschema: unsupported pointer type " ++ @typeName(Schema));
        },
        .@"struct" => |info| {
            if (value != .object) {
                try addError(errors, allocator, path, "expected an object, got {s}", .{@tagName(value)});
                return error.Invalid;
            }

            var result: Unwrap(Schema) = undefined;
            var any_failed = false;
            if (additionalPropertiesFor(additional, options) == false) {
                any_failed = try reportAdditionalProperties(Schema, value.object, path, options.field_naming, allocator, errors);
            }

            inline for (info.fields) |f| {
                const name = jsonName(f.name, options.field_naming);
                const child_path = try childPath(path, name, allocator);
                if (value.object.get(name)) |sub_value| {
                    if (decodeValue(f.type, sub_value, child_path, null, options, allocator, errors)) |decoded| {
                        @field(result, f.name) = decoded;
                    } else |err| switch (err) {
                        error.Invalid => any_failed = true,
                        else => |e| return e,
                    }
                } else if (fieldDefaultValue(f)) |def| {
                    @field(result, f.name) = def;
                } else if (@typeInfo(Unwrap(f.type)) == .optional) {
                    @field(result, f.name) = null;
                } else {
                    try addError(errors, allocator, child_path, "missing required field", .{});
                    any_failed = true;
                }
            }

            if (any_failed) return error.Invalid;
            return result;
        },
        .@"union" => return decodeUnion(Schema, value, path, options, allocator, errors),
        .void => {
            if (value != .object or value.object.count() != 0) {
                try addError(errors, allocator, path, "expected an empty object", .{});
                return error.Invalid;
            }
        },
        else => @compileError("zig-jsonschema: unsupported type " ++ @typeName(Schema)),
    }
}

fn decodeUnion(
    comptime Schema: type,
    value: std.json.Value,
    path: []const u8,
    options: SchemaOptions,
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
) DecodeError!Unwrap(Schema) {
    const fields = @typeInfo(Schema).@"union".fields;
    if (value != .object) {
        try addError(errors, allocator, path, "expected an object, got {s}", .{@tagName(value)});
        return error.Invalid;
    }
    if (comptime discriminatorOf(Schema)) |key| {
        const tag_path = try childPath(path, key, allocator);
        const tag_value = value.object.get(key) orelse {
            try addError(errors, allocator, tag_path, "missing discriminator", .{});
            return error.Invalid;
        };
        if (tag_value != .string) {
            try addError(errors, allocator, tag_path, "expected a string, got {s}", .{@tagName(tag_value)});
            return error.Invalid;
        }
        inline for (fields) |f| {
            if (std.mem.eql(u8, jsonName(f.name, options.field_naming), tag_value.string)) {
                // The payload is the rest of the object.
                var rest = try value.object.clone(allocator);
                _ = rest.orderedRemove(key);
                const Payload = stripField(f.type);
                if (Payload == void) {
                    if (additionalPropertiesFor(null, options) == false and rest.count() > 0) {
                        _ = try reportAdditionalProperties(struct {}, rest, path, options.field_naming, allocator, errors);
                        return error.Invalid;
                    }
                    return @unionInit(Unwrap(Schema), f.name, {});
                }
                return @unionInit(Unwrap(Schema), f.name, try decodeValue(f.type, .{ .object = rest }, path, null, options, allocator, errors));
            }
        }
        try addError(errors, allocator, tag_path, "unknown variant \"{s}\"", .{tag_value.string});
        return error.Invalid;
    }

    if (value.object.count() != 1) {
        try addError(errors, allocator, path, "expected an object with exactly one key naming the variant, got {d} keys", .{value.object.count()});
        return error.Invalid;
    }
    const key = value.object.keys()[0];
    inline for (fields) |f| {
        const name = jsonName(f.name, options.field_naming);
        if (std.mem.eql(u8, name, key)) {
            const payload_path = try childPath(path, name, allocator);
            return @unionInit(Unwrap(Schema), f.name, try decodeValue(f.type, value.object.values()[0], payload_path, null, options, allocator, errors));
        }
    }
    try addError(errors, allocator, try childPath(path, key, allocator), "unknown variant", .{});
    return error.Invalid;
}

/// `uniqueItems`, on the JSON items: the same equality as the validator.
fn reportDuplicateItems(items: []const std.json.Value, path: []const u8, allocator: Allocator, errors: *std.ArrayList(ValidationError)) Allocator.Error!void {
    for (items, 0..) |x, i| {
        for (items[i + 1 ..], i + 1..) |y, j| {
            if (validator.jsonEqual(x, y)) try addError(errors, allocator, path, "array items at index {d} and {d} are not unique", .{ i, j });
        }
    }
}

/// Decodes a JSON integer into `T` (named `Named` in messages), accepting
/// exactly what the generated `"type": "integer"` plus the range of `T`
/// accepts: integer literals of any size, and, from draft 6 on, floats
/// without a fractional part such as `1.0`.
fn decodeInt(
    comptime T: type,
    comptime Named: type,
    value: std.json.Value,
    path: []const u8,
    options: SchemaOptions,
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
) DecodeError!T {
    const wide: ?i256 = switch (value) {
        .integer => |i| i,
        // Only integer literals beyond i64 are kept as strings (anything
        // else is 1e400-like, i.e. not an integer).
        .number_string => |s| if (std.mem.indexOfAny(u8, s, ".eE") != null) null else std.fmt.parseInt(i256, s, 10) catch {
            try addError(errors, allocator, path, "{s} does not fit in {s}", .{ s, @typeName(Named) });
            return error.Invalid;
        },
        // Draft 4 predates "1.0 is an integer".
        .float => |f| if (options.draft != .draft4 and @floor(f) == f)
            if (@abs(f) < 0x1p255) validator.integralToInt(f) else {
                try addError(errors, allocator, path, "{d} does not fit in {s}", .{ f, @typeName(Named) });
                return error.Invalid;
            }
        else
            null,
        else => null,
    };
    const i = wide orelse {
        try addError(errors, allocator, path, "expected an integer, got {s}", .{try numberText(value, allocator)});
        return error.Invalid;
    };
    return std.math.cast(T, i) orelse {
        try addError(errors, allocator, path, "{d} does not fit in {s}", .{ i, @typeName(Named) });
        return error.Invalid;
    };
}

/// The number itself for numbers, or the JSON type name otherwise (for error messages).
fn numberText(value: std.json.Value, allocator: Allocator) Allocator.Error![]const u8 {
    return switch (value) {
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .number_string => |s| s,
        else => @tagName(value),
    };
}

fn reportAdditionalProperties(
    comptime StructT: type,
    obj: std.json.ObjectMap,
    path: []const u8,
    naming: FieldNaming,
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
) Allocator.Error!bool {
    const info = @typeInfo(StructT).@"struct";
    var found = false;
    var it = obj.iterator();
    while (it.next()) |entry| {
        var known = false;
        inline for (info.fields) |f| {
            if (std.mem.eql(u8, jsonName(f.name, naming), entry.key_ptr.*)) known = true;
        }
        if (!known) {
            found = true;
            const child_path = try childPath(path, entry.key_ptr.*, allocator);
            try addError(errors, allocator, child_path, "unexpected additional property", .{});
        }
    }
    return found;
}

test "toSchema builds constraints for a Field-wrapped numeric field" {
    const Product = struct {
        name: []const u8,
        price: Field(f64, .{
            .minimum = 0,
            .exclusiveMinimum = 0,
            .title = "Price",
            .description = "Unit price in JPY, must be positive",
        }),
        quantity: Field(u32, .{ .maximum = 1000, .default = 1 }),
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try toSchema(Product, arena.allocator(), .{});

    const props = schema.object.get("properties").?.object;
    const price = props.get("price").?.object;
    try std.testing.expectEqualStrings("number", price.get("type").?.string);
    try std.testing.expectEqualStrings("Price", price.get("title").?.string);
    try std.testing.expectEqualStrings("Unit price in JPY, must be positive", price.get("description").?.string);
    try std.testing.expectEqual(@as(f64, 0), price.get("minimum").?.float);
    try std.testing.expectEqual(@as(f64, 0), price.get("exclusiveMinimum").?.float);

    const quantity = props.get("quantity").?.object;
    try std.testing.expectEqualStrings("integer", quantity.get("type").?.string);
    try std.testing.expectEqual(@as(f64, 1000), quantity.get("maximum").?.float);
    try std.testing.expectEqual(@as(f64, 1), quantity.get("default").?.float);
    try std.testing.expect(quantity.get("title") == null);

    // quantity has a default, so it is excluded from "required".
    const required = schema.object.get("required").?.array;
    try std.testing.expectEqual(@as(usize, 2), required.items.len);
}

test "toSchema builds constraints for string, bool, array and object fields" {
    const Tag = Field([]const u8, .{ .minLength = 1, .maxLength = 10 });
    const Product = struct {
        name: Field([]const u8, .{ .minLength = 1, .maxLength = 100, .title = "Name" }),
        in_stock: Field(bool, .{ .default = true }),
        tags: Field([]const Tag, .{ .minItems = 1, .maxItems = 5, .uniqueItems = true }),
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try toSchema(Product, arena.allocator(), .{});
    const props = schema.object.get("properties").?.object;

    const name = props.get("name").?.object;
    try std.testing.expectEqualStrings("string", name.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 1), name.get("minLength").?.integer);
    try std.testing.expectEqual(@as(i64, 100), name.get("maxLength").?.integer);

    const in_stock = props.get("in_stock").?.object;
    try std.testing.expectEqualStrings("boolean", in_stock.get("type").?.string);
    try std.testing.expectEqual(true, in_stock.get("default").?.bool);

    const tags = props.get("tags").?.object;
    try std.testing.expectEqualStrings("array", tags.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 1), tags.get("minItems").?.integer);
    try std.testing.expectEqual(@as(i64, 5), tags.get("maxItems").?.integer);
    try std.testing.expectEqual(true, tags.get("uniqueItems").?.bool);
    try std.testing.expectEqualStrings("string", tags.get("items").?.object.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 10), tags.get("items").?.object.get("maxLength").?.integer);

    // in_stock has a default, so it is excluded from "required".
    const required = schema.object.get("required").?.array;
    try std.testing.expectEqual(@as(usize, 2), required.items.len);
}

test "Unwrap produces a plain struct with no Field wrapper" {
    const Product = struct {
        name: []const u8,
        price: Field(f64, .{ .minimum = 0 }),
        quantity: Field(u32, .{ .default = 1 }),
    };
    const Plain = Unwrap(Product);

    const p: Plain = .{ .name = "Widget", .price = 12.5 };
    try std.testing.expectEqualStrings("Widget", p.name);
    try std.testing.expectEqual(@as(f64, 12.5), p.price);
    try std.testing.expectEqual(@as(u32, 1), p.quantity); // inherited from the Field's default
}

test "Unwrap turns a slice-of-Field into a plain slice" {
    const Product = struct {
        scores: Field([]const Field(f64, .{ .minimum = 0 }), .{}),
    };
    const Plain = Unwrap(Product);

    const scores = [_]f64{ 1.0, 2.0 };
    const p: Plain = .{ .scores = &scores };
    try std.testing.expectEqual(@as(usize, 2), p.scores.len);
    try std.testing.expectEqual(@as(f64, 1.0), p.scores[0]);
}

test "validate reports every constraint violation, not just the first" {
    const Product = struct {
        price: Field(f64, .{ .exclusiveMinimum = 0 }),
        quantity: Field(u32, .{ .maximum = 1000 }),
    };
    const Plain = Unwrap(Product);

    const bad: Plain = .{ .price = -5, .quantity = 2000 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var errors: std.ArrayList(ValidationError) = .empty;
    try validate(Product, bad, arena.allocator(), &errors);

    try std.testing.expectEqual(@as(usize, 2), errors.items.len);
    try std.testing.expectEqualStrings("price", errors.items[0].path);
    try std.testing.expectEqualStrings("quantity", errors.items[1].path);
}

test "validate accepts values within bounds" {
    const Product = struct {
        price: Field(f64, .{ .minimum = 0, .exclusiveMinimum = 0 }),
        quantity: Field(u32, .{ .maximum = 1000 }),
    };
    const Plain = Unwrap(Product);

    const good: Plain = .{ .price = 12.5, .quantity = 3 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var errors: std.ArrayList(ValidationError) = .empty;
    try validate(Product, good, arena.allocator(), &errors);

    try std.testing.expectEqual(@as(usize, 0), errors.items.len);
}

test "validate checks string length, array size and uniqueItems" {
    const Product = struct {
        name: Field([]const u8, .{ .minLength = 3, .maxLength = 5 }),
        tags: Field([]const []const u8, .{ .minItems = 2, .uniqueItems = true }),
    };
    const Plain = Unwrap(Product);

    const tags = [_][]const u8{ "a", "a" };
    const bad: Plain = .{ .name = "ab", .tags = &tags };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var errors: std.ArrayList(ValidationError) = .empty;
    try validate(Product, bad, arena.allocator(), &errors);

    try std.testing.expectEqual(@as(usize, 2), errors.items.len);
    try std.testing.expectEqualStrings("name", errors.items[0].path);
    try std.testing.expectEqualStrings("tags", errors.items[1].path);
}

test "validate reports per-item errors with an indexed path" {
    const Product = struct {
        scores: Field([]const Field(f64, .{ .minimum = 0 }), .{}),
    };
    const Plain = Unwrap(Product);

    const scores = [_]f64{ 1.0, -1.0 };
    const bad: Plain = .{ .scores = &scores };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var errors: std.ArrayList(ValidationError) = .empty;
    try validate(Product, bad, arena.allocator(), &errors);

    try std.testing.expectEqual(@as(usize, 1), errors.items.len);
    try std.testing.expectEqualStrings("scores.1", errors.items[0].path);
}

test "fromJson maps valid JSON into a plain struct with no errors" {
    const Product = struct {
        name: []const u8,
        price: Field(f64, .{ .minimum = 0, .exclusiveMinimum = 0 }),
        quantity: Field(u32, .{ .maximum = 1000 }),
        discount: Field(?f64, .{ .minimum = 0, .maximum = 1 }),
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try fromJson(Product, allocator,
        \\{"name": "Widget", "price": 12.5, "quantity": 3}
    , .{});

    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const product = result.value.?;
    try std.testing.expectEqualStrings("Widget", product.name);
    try std.testing.expectEqual(@as(f64, 12.5), product.price);
    try std.testing.expectEqual(@as(u32, 3), product.quantity);
    try std.testing.expectEqual(@as(?f64, null), product.discount);
}

test "fromJson decodes bool and array fields" {
    const Product = struct {
        in_stock: Field(bool, .{}),
        tags: Field([]const []const u8, .{ .minItems = 1 }),
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try fromJson(Product, allocator,
        \\{"in_stock": true, "tags": ["a", "b"]}
    , .{});

    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    const product = result.value.?;
    try std.testing.expectEqual(true, product.in_stock);
    try std.testing.expectEqual(@as(usize, 2), product.tags.len);
    try std.testing.expectEqualStrings("a", product.tags[0]);
}

test "fromJson collects per-item array decode errors" {
    const Product = struct {
        scores: Field([]const f64, .{}),
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try fromJson(Product, allocator,
        \\{"scores": [1.0, "not a number", 3.0]}
    , .{});

    try std.testing.expect(result.value == null);
    try std.testing.expectEqual(@as(usize, 1), result.errors.items.len);
    try std.testing.expectEqualStrings("scores.1", result.errors.items[0].path);
}

test "fromJson rejects additional properties when configured" {
    const Product = struct {
        name: []const u8,
    };
    const Strict = Field(Product, .{ .additionalProperties = false });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try fromJson(Strict, allocator,
        \\{"name": "Widget", "unexpected": 1}
    , .{});

    try std.testing.expect(result.value == null);
    try std.testing.expectEqual(@as(usize, 1), result.errors.items.len);
    try std.testing.expectEqualStrings("unexpected", result.errors.items[0].path);
}

test "fromJson collects every constraint violation" {
    const Product = struct {
        price: Field(f64, .{ .exclusiveMinimum = 0 }),
        quantity: Field(u32, .{ .maximum = 1000 }),
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try fromJson(Product, allocator,
        \\{"price": -5, "quantity": 5000}
    , .{});

    try std.testing.expect(result.value == null);
    try std.testing.expectEqual(@as(usize, 2), result.errors.items.len);
    try std.testing.expectEqualStrings("price", result.errors.items[0].path);
    try std.testing.expectEqualStrings("quantity", result.errors.items[1].path);
}

test "fromJson collects every structural error: missing field, wrong type" {
    const Product = struct {
        name: []const u8,
        price: Field(f64, .{ .minimum = 0 }),
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try fromJson(Product, allocator,
        \\{"price": "not a number"}
    , .{});

    try std.testing.expect(result.value == null);
    try std.testing.expectEqual(@as(usize, 2), result.errors.items.len);
    try std.testing.expectEqualStrings("name", result.errors.items[0].path);
    try std.testing.expectEqualStrings("price", result.errors.items[1].path);
}

test "fromJson applies Field-level defaults for missing keys" {
    const Product = struct {
        name: []const u8,
        quantity: Field(u32, .{ .default = 1 }),
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try fromJson(Product, allocator,
        \\{"name": "Widget"}
    , .{});

    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    try std.testing.expectEqual(@as(u32, 1), result.value.?.quantity);
}

test "fromJson reports invalid JSON syntax" {
    const Product = struct {
        name: []const u8,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try fromJson(Product, allocator, "{not valid json", .{});

    try std.testing.expect(result.value == null);
    try std.testing.expectEqual(@as(usize, 1), result.errors.items.len);
}

test "toSchema output is a valid 2020-12 schema that the runtime Validator agrees with" {
    const Product = struct {
        name: Field([]const u8, .{ .minLength = 1, .maxLength = 10 }),
        price: Field(f64, .{ .exclusiveMinimum = 0 }),
        quantity: Field(u32, .{ .maximum = 1000, .default = 1 }),
        tags: Field([]const []const u8, .{ .minItems = 1, .uniqueItems = true }),
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const generated = try toSchema(Product, allocator, .{});
    var v = Validator.init(std.testing.allocator, .{});
    defer v.deinit();
    try std.testing.expect(try v.isValidSchema(generated));
    const schema = try v.compile(generated);

    const cases = [_][]const u8{
        \\{"name": "Widget", "price": 12.5, "quantity": 3, "tags": ["a"]}
        ,
        \\{"name": "Widget", "price": 12.5, "tags": ["a"]}
        ,
        \\{"name": "", "price": 12.5, "tags": ["a"]}
        ,
        \\{"name": "Widget", "price": 0, "tags": ["a"]}
        ,
        \\{"name": "Widget", "price": 1, "quantity": 5000, "tags": ["a"]}
        ,
        \\{"name": "Widget", "price": 1, "tags": ["a", "a"]}
        ,
        \\{"price": 1, "tags": ["a"]}
        ,
    };
    for (cases) |text| {
        const via_comptime = (try fromJson(Product, allocator, text, .{})).value != null;
        const instance = try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
        try std.testing.expectEqual(via_comptime, try schema.isValid(instance));
    }
}

test "toSchema emits $schema and draft-specific keywords" {
    const Product = struct {
        price: Field(f64, .{ .minimum = 0, .exclusiveMinimum = 0, .maximum = 100 }),
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const d4 = try toSchema(Product, allocator, .{ .draft = .draft4 });
    try std.testing.expectEqualStrings("http://json-schema.org/draft-04/schema#", d4.object.get("$schema").?.string);
    const price4 = d4.object.get("properties").?.object.get("price").?.object;
    try std.testing.expectEqual(@as(f64, 0), price4.get("minimum").?.float);
    try std.testing.expectEqual(true, price4.get("exclusiveMinimum").?.bool);
    try std.testing.expectEqual(@as(f64, 100), price4.get("maximum").?.float);
    try std.testing.expect(price4.get("exclusiveMaximum") == null);

    const d7 = try toSchema(Product, allocator, .{ .draft = .draft7 });
    try std.testing.expectEqualStrings("http://json-schema.org/draft-07/schema#", d7.object.get("$schema").?.string);
    const price7 = d7.object.get("properties").?.object.get("price").?.object;
    try std.testing.expectEqual(@as(f64, 0), price7.get("exclusiveMinimum").?.float);

    const d2020 = try toSchema(Product, allocator, .{});
    try std.testing.expectEqualStrings("https://json-schema.org/draft/2020-12/schema", d2020.object.get("$schema").?.string);
    const plain = try toSchema(Product, allocator, .{ .emit_schema_uri = false });
    try std.testing.expect(plain.object.get("$schema") == null);
}

test "toSchema emits the root id with the draft's keyword" {
    const T = reuse_test_types;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const id = "https://example.com/schemas/customer.json";
    inline for (std.meta.fields(Draft)) |f| {
        const draft: Draft = @enumFromInt(f.value);
        const schema = try toSchema(T.Customer, a, .{ .draft = draft, .id = id });
        const keyword, const other = if (draft == .draft4) .{ "id", "$id" } else .{ "$id", "id" };
        try std.testing.expectEqualStrings(id, schema.object.get(keyword).?.string);
        try std.testing.expect(schema.object.get(other) == null);
        // `$schema` stays first, the id follows it.
        try std.testing.expectEqualStrings("$schema", schema.object.keys()[0]);
        try std.testing.expectEqualStrings(keyword, schema.object.keys()[1]);

        // The `$ref`s into the definitions resolve against the id.
        var v = Validator.init(std.testing.allocator, .{});
        defer v.deinit();
        try std.testing.expect(try v.isValidSchema(schema));
        const compiled = try v.compile(schema);
        const bad = try std.json.parseFromSliceLeaky(std.json.Value, a,
            \\{"home": {"zip": ""}, "work": {"zip": "2"}, "strict": {"zip": "3"}, "history": {"entries": []}, "legacy": {"line": "x"}}
        , .{});
        try std.testing.expect(!try compiled.isValid(bad));
    }

    const without = try toSchema(T.Customer, a, .{});
    try std.testing.expect(without.object.get("$id") == null);
}

test "toSchema output is valid for every draft and matches fromJson" {
    const Product = struct {
        name: Field([]const u8, .{ .minLength = 1, .maxLength = 10 }),
        price: Field(f64, .{ .minimum = 1, .exclusiveMinimum = 0, .exclusiveMaximum = 1000 }),
        quantity: Field(u32, .{ .maximum = 1000, .default = 1 }),
        tags: Field([]const []const u8, .{ .minItems = 1, .uniqueItems = true }),
        discount: Field(?f64, .{ .minimum = 0, .maximum = 1 }),
        billing: ?struct { zip: Field([]const u8, .{ .minLength = 1 }) },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cases = [_][]const u8{
        \\{"name": "Widget", "price": 12.5, "quantity": 3, "tags": ["a"]}
        ,
        \\{"name": "Widget", "price": 1, "tags": ["a"], "discount": null, "billing": null}
        ,
        \\{"name": "Widget", "price": 1, "tags": ["a"], "discount": 0.5, "billing": {"zip": "1"}}
        ,
        \\{"name": "Widget", "price": 1, "tags": ["a"], "discount": 2}
        ,
        \\{"name": "Widget", "price": 1, "tags": ["a"], "billing": {"zip": ""}}
        ,
        \\{"name": "Widget", "price": 1, "tags": ["a"], "billing": 5}
        ,
        \\{"name": null, "price": 1, "tags": ["a"]}
        ,
        \\{"name": "Widget", "price": 1, "tags": ["a"]}
        ,
        \\{"name": "Widget", "price": 0.5, "tags": ["a"]}
        ,
        \\{"name": "Widget", "price": 1000, "tags": ["a"]}
        ,
        \\{"name": "", "price": 12.5, "tags": ["a"]}
        ,
        \\{"name": "Widget", "price": 1, "quantity": 5000, "tags": ["a"]}
        ,
        \\{"name": "Widget", "price": 1, "tags": ["a", "a"]}
        ,
        \\{"price": 1, "tags": ["a"]}
        ,
        // Unknown keys, at the top level and in a nested object.
        \\{"name": "Widget", "price": 1, "tags": ["a"], "colour": "red"}
        ,
        \\{"name": "Widget", "price": 1, "tags": ["a"], "billing": {"zip": "1", "city": "X"}}
        ,
    };

    inline for (std.meta.fields(Draft)) |f| {
        for ([_]UnknownFields{ .allow, .deny }) |mode| {
            const options: SchemaOptions = .{ .draft = @enumFromInt(f.value), .unknown_fields = mode };
            const generated = try toSchema(Product, allocator, options);

            // The runtime validator picks the dialect up from `$schema`, not from its default.
            var v = Validator.init(std.testing.allocator, .{ .default_draft = .draft2020_12 });
            defer v.deinit();
            try std.testing.expect(try v.isValidSchema(generated));
            const schema = try v.compile(generated);
            for (cases) |text| {
                const via_comptime = (try fromJson(Product, allocator, text, options)).value != null;
                const instance = try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
                try std.testing.expectEqual(via_comptime, try schema.isValid(instance));
            }
        }
    }
}

test "integer and narrow float ranges agree between toSchema and fromJson" {
    const Id = enum(u64) { _ };
    // Every field optional, so each case can set just one of them.
    const T = struct {
        small: ?u8,
        signed: ?i8,
        big: ?u64,
        wide: ?i64,
        /// Looser than u8: the u8 range wins.
        bounded: Field(?u8, .{ .maximum = 1000 }),
        strict: Field(?u16, .{ .minimum = 1, .exclusiveMaximum = 10 }),
        id: ?Id,
        single: ?f32,
        double: ?f64,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_][]const u8{
        \\{"small": 255, "signed": -128, "big": 18446744073709551615, "wide": -9223372036854775808}
        ,
        \\{"small": 256}
        ,
        \\{"small": -1}
        ,
        \\{"signed": 128}
        ,
        \\{"big": 18446744073709551616}
        ,
        \\{"big": -1}
        ,
        \\{"wide": 9223372036854775808}
        ,
        \\{"wide": -9223372036854775809}
        ,
        \\{"bounded": 255}
        ,
        \\{"bounded": 300}
        ,
        \\{"strict": 0}
        ,
        \\{"strict": 9}
        ,
        \\{"strict": 10}
        ,
        \\{"id": 18446744073709551615}
        ,
        \\{"id": 18446744073709551616}
        ,
        \\{"small": 1.0}
        ,
        \\{"small": 1.5}
        ,
        \\{"big": 1e19}
        ,
        \\{"big": 1e20}
        ,
        \\{"single": 3.4e38}
        ,
        \\{"single": 3.5e38}
        ,
        \\{"double": 1e308}
        ,
        \\{"double": 123456789012345678901234567890}
        ,
        \\{"small": 1e400}
        ,
        \\{"small": 100000000000000000000000000000000000000000000000000000000000000000000000000000000}
        ,
    };

    inline for (std.meta.fields(Draft)) |f| {
        const options: SchemaOptions = .{ .draft = @enumFromInt(f.value) };
        var v = Validator.init(std.testing.allocator, .{});
        defer v.deinit();
        const generated = try toSchema(T, a, options);
        try std.testing.expect(try v.isValidSchema(generated));
        const schema = try v.compile(generated);
        for (cases) |text| {
            const decoded = (try fromJson(T, a, text, options)).value != null;
            const instance = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
            const valid = try schema.isValid(instance);
            if (decoded != valid) {
                std.debug.print("{s} on {s}: fromJson {}, schema {}\n", .{ text, f.name, decoded, valid });
                return error.TestUnexpectedResult;
            }
        }
    }

    // Spot checks of the expected outcome (draft 2020-12).
    try std.testing.expect((try fromJson(T, a, "{\"small\": 255}", .{})).value != null);
    try std.testing.expect((try fromJson(T, a, "{\"small\": 256}", .{})).value == null);
    try std.testing.expectEqual(@as(?u8, 1), (try fromJson(T, a, "{\"small\": 1.0}", .{})).value.?.small);
    try std.testing.expect((try fromJson(T, a, "{\"small\": 1.0}", .{ .draft = .draft4 })).value == null);
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), (try fromJson(T, a, "{\"big\": 18446744073709551615}", .{})).value.?.big);
}

test "string pattern and code point lengths agree between toSchema and fromJson" {
    const T = struct {
        zip: Field(?[]const u8, .{ .pattern = "^[0-9]{3}-[0-9]{4}$" }),
        word: Field(?[]const u8, .{ .pattern = "\\p{Lu}" }),
        short: Field(?[]const u8, .{ .maxLength = 2 }),
        long: Field(?[]const u8, .{ .minLength = 2 }),
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const u8{
        \\{"zip": "123-4567"}
        ,
        \\{"zip": "1234567"}
        ,
        \\{"zip": "x123-4567"}
        ,
        \\{"word": "abcÉ"}
        ,
        \\{"word": "abcé"}
        ,
        \\{"short": "éé"}
        ,
        \\{"short": "ééé"}
        ,
        \\{"short": "🐲🐲"}
        ,
        \\{"long": "é"}
        ,
        \\{"long": "éa"}
        ,
    };
    var v = Validator.init(std.testing.allocator, .{});
    defer v.deinit();
    const schema = try v.compile(try toSchema(T, a, .{}));
    for (cases) |text| {
        const instance = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
        const decoded = (try fromJson(T, a, text, .{})).value != null;
        if (decoded != try schema.isValid(instance)) {
            std.debug.print("{s}: fromJson {}\n", .{ text, decoded });
            return error.TestUnexpectedResult;
        }
    }
    const bad = try fromJson(T, a, "{\"zip\": \"1234567\"}", .{});
    try std.testing.expectEqualStrings("string does not match pattern \"^[0-9]{3}-[0-9]{4}$\"", bad.errors.items[0].message);
}

test "named Field types can be made optional and used in arrays" {
    const Email = Field([]const u8, .{ .pattern = "^[^@]+@[^@]+$" });
    const T = struct { to: Email, cc: ?Email, bcc: []const Email };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const schema = try toSchema(T, a, .{});
    const cc = schema.object.get("properties").?.object.get("cc").?.object;
    try std.testing.expectEqualStrings("^[^@]+@[^@]+$", cc.get("pattern").?.string);
    try std.testing.expectEqual(@as(usize, 2), cc.get("type").?.array.items.len);

    const ok = (try fromJson(T, a,
        \\{"to": "a@b", "cc": null, "bcc": ["c@d"]}
    , .{})).value.?;
    try std.testing.expect(ok.cc == null);
    const bad = try fromJson(T, a,
        \\{"to": "a@b", "cc": "nope", "bcc": ["c@d", "x"]}
    , .{});
    try std.testing.expectEqual(@as(usize, 2), bad.errors.items.len);
    try std.testing.expectEqualStrings("cc", bad.errors.items[0].path);
    try std.testing.expectEqualStrings("bcc.1", bad.errors.items[1].path);
}

test "uniqueItems works for any item type and agrees with the schema" {
    const Point = struct { x: i32, label: ?[]const u8 = null };
    const T = struct {
        points: Field([]const Point, .{ .uniqueItems = true }),
        /// Not unique-checked: must still compile for struct items.
        others: Field([]const Point, .{ .maxItems = 3 }),
        nested: Field([]const []const u8, .{ .uniqueItems = true }),
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var v = Validator.init(std.testing.allocator, .{});
    defer v.deinit();
    const schema = try v.compile(try toSchema(T, a, .{}));
    const cases = [_][]const u8{
        \\{"points": [{"x": 1}, {"x": 2}], "others": [], "nested": ["a", "b"]}
        ,
        \\{"points": [{"x": 1}, {"x": 1}], "others": [], "nested": []}
        ,
        \\{"points": [{"x": 1, "label": "a"}, {"x": 1, "label": "b"}], "others": [], "nested": []}
        ,
        \\{"points": [{"x": 1, "label": null}, {"x": 1}], "others": [], "nested": []}
        ,
        \\{"points": [{"x": 1.0}, {"x": 1}], "others": [], "nested": []}
        ,
        \\{"points": [], "others": [], "nested": ["a", "a"]}
        ,
    };
    for (cases) |text| {
        const instance = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
        const decoded = (try fromJson(T, a, text, .{})).value != null;
        if (decoded != try schema.isValid(instance)) {
            std.debug.print("{s}: fromJson {}\n", .{ text, decoded });
            return error.TestUnexpectedResult;
        }
    }

    // `validate` compares the Zig values structurally.
    const dup = [_]Point{ .{ .x = 1, .label = "a" }, .{ .x = 1, .label = "a" } };
    var errors: std.ArrayList(ValidationError) = .empty;
    try validate(T, .{ .points = &dup, .others = &.{}, .nested = &.{} }, a, &errors);
    try std.testing.expectEqual(@as(usize, 1), errors.items.len);
    try std.testing.expectEqualStrings("points", errors.items[0].path);
}

test "field names are converted by field_naming" {
    const cases = .{
        .{ "user_id", "user_id", "userId", "UserId", "user_id", "user-id" },
        .{ "userId", "userId", "userId", "UserId", "user_id", "user-id" },
        .{ "name", "name", "name", "Name", "name", "name" },
        .{ "address_2", "address_2", "address2", "Address2", "address_2", "address-2" },
        .{ "item2Count", "item2Count", "item2Count", "Item2Count", "item2_count", "item2-count" },
        .{ "_private_key", "_private_key", "_privateKey", "_PrivateKey", "_private_key", "_private-key" },
    };
    inline for (cases) |c| {
        inline for (.{ FieldNaming.as_is, .camel_case, .pascal_case, .snake_case, .kebab_case }, 1..) |naming, i| {
            try std.testing.expectEqualStrings(c[i], jsonName(c[0], naming));
        }
    }
}

test "field_naming applies to the schema, fromJson keys, unknown keys and error paths alike" {
    const Address = struct { zip_code: Field([]const u8, .{ .minLength = 1 }) };
    const User = struct {
        user_id: u32,
        display_name: ?[]const u8,
        home_address: Address,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const options: SchemaOptions = .{ .field_naming = .camel_case, .unknown_fields = .deny };

    const schema = try toSchema(User, a, options);
    const props = schema.object.get("properties").?.object;
    try std.testing.expectEqualStrings("userId", props.keys()[0]);
    try std.testing.expectEqualStrings("displayName", props.keys()[1]);
    const address_def = schema.object.get("$defs").?.object.values()[0];
    try std.testing.expectEqualStrings("zipCode", address_def.object.get("properties").?.object.keys()[0]);
    try std.testing.expectEqualStrings("userId", schema.object.get("required").?.array.items[0].string);

    const ok = try fromJson(User, a,
        \\{"userId": 1, "homeAddress": {"zipCode": "100"}}
    , options);
    try std.testing.expectEqual(@as(u32, 1), ok.value.?.user_id);
    try std.testing.expectEqualStrings("100", ok.value.?.home_address.zip_code);

    // Zig spellings are unknown keys now; errors use the JSON spelling.
    const bad = try fromJson(User, a,
        \\{"user_id": 1, "homeAddress": {"zipCode": ""}}
    , options);
    try std.testing.expect(bad.value == null);
    var paths: std.ArrayList([]const u8) = .empty;
    for (bad.errors.items) |e| try paths.append(a, e.path);
    try std.testing.expectEqual(@as(usize, 2), paths.items.len);
    try std.testing.expectEqualStrings("user_id", paths.items[0]);
    try std.testing.expectEqualStrings("userId", paths.items[1]);

    var v = Validator.init(std.testing.allocator, .{});
    defer v.deinit();
    const compiled = try v.compile(schema);
    const texts = [_][]const u8{
        \\{"userId": 1, "homeAddress": {"zipCode": "100"}}
        ,
        \\{"userId": 1, "displayName": null, "homeAddress": {"zipCode": "1"}}
        ,
        \\{"user_id": 1, "homeAddress": {"zipCode": "100"}}
        ,
        \\{"userId": 1, "homeAddress": {"zip_code": "100"}}
        ,
        \\{"userId": 1, "homeAddress": {"zipCode": ""}}
        ,
    };
    for (texts) |text| {
        const instance = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
        try std.testing.expectEqual((try fromJson(User, a, text, options)).value != null, try compiled.isValid(instance));
    }
}

const union_test_types = struct {
    const Circle = struct { radius: Field(f64, .{ .exclusiveMinimum = 0 }) };
    const Rect = struct { width: f64, height: f64 };
    /// std.json's form: `{"circle": {...}}`.
    const Shape = union(enum) {
        circle: Circle,
        rect: Rect,
        label: Field([]const u8, .{ .minLength = 1 }),
        empty,
    };
    /// Internally tagged: `{"kind": "circle", ...}`.
    const TaggedShape = union(enum) {
        pub const json_discriminator = "kind";
        circle: Circle,
        rect: Rect,
        empty,
    };
    /// Recursive through the union.
    const Expr = union(enum) {
        num: f64,
        add: []const Expr,
        neg: *const Expr,
    };
    const Drawing = struct {
        shape: Shape,
        tagged: TaggedShape,
        maybe: ?Shape,
    };
};

test "tagged unions: toSchema and fromJson agree in both representations on every draft" {
    const T = union_test_types;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base =
        \\"tagged": {"kind": "empty"}, "maybe": null
    ;
    const cases = [_][]const u8{
        "{\"shape\": {\"circle\": {\"radius\": 1}}, " ++ base ++ "}",
        "{\"shape\": {\"circle\": {\"radius\": 0}}, " ++ base ++ "}",
        "{\"shape\": {\"rect\": {\"width\": 1, \"height\": 2}}, " ++ base ++ "}",
        "{\"shape\": {\"label\": \"x\"}, " ++ base ++ "}",
        "{\"shape\": {\"label\": \"\"}, " ++ base ++ "}",
        "{\"shape\": {\"empty\": {}}, " ++ base ++ "}",
        "{\"shape\": {\"empty\": {\"x\": 1}}, " ++ base ++ "}",
        "{\"shape\": {}, " ++ base ++ "}",
        "{\"shape\": {\"circle\": {\"radius\": 1}, \"rect\": {\"width\": 1, \"height\": 2}}, " ++ base ++ "}",
        "{\"shape\": {\"triangle\": {}}, " ++ base ++ "}",
        "{\"shape\": \"circle\", " ++ base ++ "}",
        \\{"shape": {"empty": {}}, "tagged": {"kind": "circle", "radius": 2}, "maybe": {"rect": {"width": 1, "height": 1}}}
        ,
        \\{"shape": {"empty": {}}, "tagged": {"kind": "circle", "radius": -2}}
        ,
        \\{"shape": {"empty": {}}, "tagged": {"kind": "rect", "width": 1}}
        ,
        \\{"shape": {"empty": {}}, "tagged": {"kind": "rect", "width": 1, "height": 1, "extra": true}}
        ,
        \\{"shape": {"empty": {}}, "tagged": {"kind": "empty", "extra": true}}
        ,
        \\{"shape": {"empty": {}}, "tagged": {"kind": "triangle"}}
        ,
        \\{"shape": {"empty": {}}, "tagged": {"kind": 1}}
        ,
        \\{"shape": {"empty": {}}, "tagged": {"radius": 1}}
        ,
    };

    inline for (std.meta.fields(Draft)) |f| {
        for ([_]UnknownFields{ .allow, .deny }) |unknown| {
            for ([_]bool{ true, false }) |reuse| {
                const options: SchemaOptions = .{ .draft = @enumFromInt(f.value), .unknown_fields = unknown, .reuse_definitions = reuse };
                var v = Validator.init(std.testing.allocator, .{});
                defer v.deinit();
                const generated = try toSchema(T.Drawing, a, options);
                try std.testing.expect(try v.isValidSchema(generated));
                const schema = try v.compile(generated);
                for (cases) |text| {
                    const decoded = (try fromJson(T.Drawing, a, text, options)).value != null;
                    const instance = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
                    const valid = try schema.isValid(instance);
                    if (decoded != valid) {
                        std.debug.print("{s} ({s}, {t}, reuse={}): fromJson {}, schema {}\n", .{ text, f.name, unknown, reuse, decoded, valid });
                        return error.TestUnexpectedResult;
                    }
                }
            }
        }
    }

    const ok = (try fromJson(T.Drawing, a,
        \\{"shape": {"circle": {"radius": 1.5}}, "tagged": {"kind": "rect", "width": 2, "height": 3}, "maybe": {"empty": {}}}
    , .{})).value.?;
    try std.testing.expectEqual(@as(f64, 1.5), ok.shape.circle.radius);
    try std.testing.expectEqual(@as(f64, 3), ok.tagged.rect.height);
    try std.testing.expect(ok.maybe.? == .empty);

    // Error paths follow the JSON layout of each representation.
    const bad = try fromJson(T.Drawing, a,
        \\{"shape": {"circle": {"radius": 0}}, "tagged": {"kind": "circle", "radius": 0}}
    , .{});
    try std.testing.expectEqual(@as(usize, 2), bad.errors.items.len);
    try std.testing.expectEqualStrings("shape.circle.radius", bad.errors.items[0].path);
    try std.testing.expectEqualStrings("tagged.radius", bad.errors.items[1].path);
}

test "recursive unions are shared through definitions" {
    const T = union_test_types;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const Program = struct { body: T.Expr };
    const shared = try toSchema(Program, a, .{});
    const body = shared.object.get("properties").?.object.get("body").?.object;
    try std.testing.expectEqualStrings("#/$defs/Expr", body.get("$ref").?.string);

    const cases = [_][]const u8{
        \\{"body": {"add": [{"num": 1}, {"neg": {"num": 2}}, {"add": []}]}}
        ,
        \\{"body": {"add": [{"num": 1}, {"neg": {"num": "x"}}]}}
        ,
        \\{"body": {"neg": {"add": [{"mul": 1}]}}}
        ,
    };
    // With reuse off the first use is inlined; recursion still goes through $defs.
    for ([_]bool{ true, false }) |reuse| {
        var v = Validator.init(std.testing.allocator, .{});
        defer v.deinit();
        const compiled = try v.compile(try toSchema(Program, a, .{ .reuse_definitions = reuse }));
        for (cases) |text| {
            const instance = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
            try std.testing.expectEqual((try fromJson(Program, a, text, .{})).value != null, try compiled.isValid(instance));
        }
    }
    const decoded = (try fromJson(Program, a, cases[0], .{})).value.?;
    try std.testing.expectEqual(@as(f64, 2), decoded.body.add[1].neg.num);
}

test "toSchema makes optional types nullable" {
    const Product = struct {
        discount: Field(?f64, .{ .minimum = 0 }),
        note: ?[]const u8,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try toSchema(Product, arena.allocator(), .{});
    const props = schema.object.get("properties").?.object;

    const discount = props.get("discount").?.object;
    const types = discount.get("type").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), types.len);
    try std.testing.expectEqualStrings("number", types[0].string);
    try std.testing.expectEqualStrings("null", types[1].string);
    try std.testing.expectEqual(@as(f64, 0), discount.get("minimum").?.float);

    try std.testing.expectEqualStrings("null", props.get("note").?.object.get("type").?.array.items[1].string);
    // Optional fields may also be omitted.
    try std.testing.expect(schema.object.get("required") == null);
}

test "unknown_fields = .deny rejects unknown keys at every level unless a Field allows them" {
    const Inner = struct { zip: []const u8 };
    const Product = struct {
        name: []const u8,
        billing: ?Inner,
        items: []const Inner,
        extras: Field(struct { source: []const u8 }, .{ .additionalProperties = true }),
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deny: SchemaOptions = .{ .unknown_fields = .deny };

    const ok =
        \\{"name": "W", "billing": null, "items": [{"zip": "1"}], "extras": {"source": "s", "free": 1}}
    ;
    try std.testing.expect((try fromJson(Product, a, ok, deny)).value != null);

    const bad =
        \\{"name": "W", "top": 1, "billing": {"zip": "1", "city": "X"}, "items": [{"zip": "1", "n": 2}], "extras": {"source": "s"}}
    ;
    const result = try fromJson(Product, a, bad, deny);
    try std.testing.expect(result.value == null);
    try std.testing.expectEqual(@as(usize, 3), result.errors.items.len);
    try std.testing.expectEqualStrings("top", result.errors.items[0].path);
    try std.testing.expectEqualStrings("billing.city", result.errors.items[1].path);
    try std.testing.expectEqualStrings("items.0.n", result.errors.items[2].path);

    // The default still ignores unknown keys.
    try std.testing.expect((try fromJson(Product, a, bad, .{})).value != null);

    // Inlined, so the nested objects can be inspected directly.
    const schema = try toSchema(Product, a, .{ .unknown_fields = .deny, .reuse_definitions = false });
    try std.testing.expectEqual(false, schema.object.get("additionalProperties").?.bool);
    const props = schema.object.get("properties").?.object;
    try std.testing.expectEqual(false, props.get("billing").?.object.get("additionalProperties").?.bool);
    try std.testing.expectEqual(true, props.get("extras").?.object.get("additionalProperties").?.bool);
}

test "an explicit additionalProperties = false also applies to optional objects" {
    const Product = struct {
        billing: Field(?struct { zip: []const u8 }, .{ .additionalProperties = false }),
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try fromJson(Product, a, "{\"billing\": null}", .{})).value != null);
    try std.testing.expect((try fromJson(Product, a, "{\"billing\": {\"zip\": \"1\", \"x\": 1}}", .{})).value == null);
}

test "an explicit additionalProperties on the root struct overrides unknown_fields" {
    const Address = struct { zip: []const u8 };
    const Fields = struct { name: []const u8, address: Address };
    // Root explicitly open, while the options deny unknown keys elsewhere.
    const Open = Field(Fields, .{ .additionalProperties = true });
    // Root explicitly closed, while the options allow unknown keys elsewhere.
    const Closed = Field(Fields, .{ .additionalProperties = false });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deny: SchemaOptions = .{ .unknown_fields = .deny };
    const allow: SchemaOptions = .{ .unknown_fields = .allow };

    const root_extra =
        \\{"name": "W", "address": {"zip": "1"}, "extra": 1}
    ;
    const nested_extra =
        \\{"name": "W", "address": {"zip": "1", "city": "X"}}
    ;

    // fromJson: the root follows its explicit setting, the unlabelled
    // nested struct follows the options.
    try std.testing.expect((try fromJson(Open, a, root_extra, deny)).value != null);
    const open_nested = try fromJson(Open, a, nested_extra, deny);
    try std.testing.expect(open_nested.value == null);
    try std.testing.expectEqualStrings("address.city", open_nested.errors.items[0].path);

    const closed_root = try fromJson(Closed, a, root_extra, allow);
    try std.testing.expect(closed_root.value == null);
    try std.testing.expectEqualStrings("extra", closed_root.errors.items[0].path);
    try std.testing.expect((try fromJson(Closed, a, nested_extra, allow)).value != null);

    // toSchema emits the same decisions.
    // Inlined, so the nested objects can be inspected directly.
    const open_schema = try toSchema(Open, a, .{ .unknown_fields = .deny, .reuse_definitions = false });
    try std.testing.expectEqual(true, open_schema.object.get("additionalProperties").?.bool);
    const open_address = open_schema.object.get("properties").?.object.get("address").?.object;
    try std.testing.expectEqual(false, open_address.get("additionalProperties").?.bool);

    const closed_schema = try toSchema(Closed, a, .{ .unknown_fields = .allow, .reuse_definitions = false });
    try std.testing.expectEqual(false, closed_schema.object.get("additionalProperties").?.bool);
    const closed_address = closed_schema.object.get("properties").?.object.get("address").?.object;
    try std.testing.expect(closed_address.get("additionalProperties") == null);

    // And the runtime validator agrees with fromJson on the generated schemas.
    var v = Validator.init(std.testing.allocator, .{});
    defer v.deinit();
    const cases = [_]struct { schema: std.json.Value, options: SchemaOptions, text: []const u8, open: bool }{
        .{ .schema = open_schema, .options = deny, .text = root_extra, .open = true },
        .{ .schema = open_schema, .options = deny, .text = nested_extra, .open = true },
        .{ .schema = closed_schema, .options = allow, .text = root_extra, .open = false },
        .{ .schema = closed_schema, .options = allow, .text = nested_extra, .open = false },
    };
    for (cases) |c| {
        const compiled = try v.compile(c.schema);
        const instance = try std.json.parseFromSliceLeaky(std.json.Value, a, c.text, .{});
        const via_comptime = if (c.open)
            (try fromJson(Open, a, c.text, c.options)).value != null
        else
            (try fromJson(Closed, a, c.text, c.options)).value != null;
        try std.testing.expectEqual(via_comptime, try compiled.isValid(instance));
    }
}

test "non-exhaustive enums are integer newtypes" {
    const UserId = enum(u32) { _ };
    const Level = enum(i8) { low = 0, high = 10, _ };
    const Order = struct {
        buyer: UserId,
        seller: Field(UserId, .{ .minimum = 1, .description = "Seller account" }),
        level: Field(Level, .{ .default = 10 }),
        watchers: Field([]const UserId, .{ .uniqueItems = true }),
        referrer: ?UserId,
    };
    const Plain = Unwrap(Order);

    // The newtype survives Unwrap, so ids cannot be mixed up with plain integers.
    try std.testing.expect(@FieldType(Plain, "buyer") == UserId);
    try std.testing.expect(@FieldType(Plain, "referrer") == ?UserId);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ok = try fromJson(Order, a,
        \\{"buyer": 7, "seller": 3, "watchers": [1, 2], "referrer": null}
    , .{});
    try std.testing.expectEqual(@as(usize, 0), ok.errors.items.len);
    const order = ok.value.?;
    try std.testing.expectEqual(@as(UserId, @enumFromInt(7)), order.buyer);
    try std.testing.expectEqual(Level.high, order.level); // Field default
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(order.watchers[1]));

    const bad = try fromJson(Order, a,
        \\{"buyer": -1, "seller": 0, "watchers": [1, 1], "referrer": "x"}
    , .{});
    try std.testing.expect(bad.value == null);
    // uniqueItems is checked on the JSON items while decoding, so it is
    // reported alongside structural errors.
    try std.testing.expectEqual(@as(usize, 3), bad.errors.items.len);
    try std.testing.expectEqualStrings("buyer", bad.errors.items[0].path); // does not fit in u32
    try std.testing.expectEqualStrings("watchers", bad.errors.items[1].path); // uniqueItems
    try std.testing.expectEqualStrings("referrer", bad.errors.items[2].path); // not an integer

    const constraint = try fromJson(Order, a,
        \\{"buyer": 1, "seller": 0, "watchers": [1, 1]}
    , .{});
    try std.testing.expectEqual(@as(usize, 2), constraint.errors.items.len);
    try std.testing.expectEqualStrings("watchers", constraint.errors.items[0].path); // uniqueItems
    try std.testing.expectEqualStrings("seller", constraint.errors.items[1].path); // minimum

    const schema = try toSchema(Order, a, .{});
    const props = schema.object.get("properties").?.object;
    try std.testing.expectEqualStrings("integer", props.get("buyer").?.object.get("type").?.string);
    try std.testing.expectEqual(@as(f64, 1), props.get("seller").?.object.get("minimum").?.float);
    try std.testing.expectEqual(@as(f64, 10), props.get("level").?.object.get("default").?.float);
    try std.testing.expectEqualStrings("integer", props.get("watchers").?.object.get("items").?.object.get("type").?.string);
}

const reuse_test_types = struct {
    const Address = struct {
        zip: Field([]const u8, .{ .minLength = 1 }),
    };
    fn List(comptime T: type) type {
        return struct { entries: []const T };
    }
    const other = struct {
        /// Same short name as `Address` above.
        const Address = struct { line: []const u8 };
    };
    const Customer = struct {
        home: Address,
        work: Field(Address, .{ .description = "Office" }),
        billing: ?Address,
        strict: Field(Address, .{ .additionalProperties = false }),
        history: List(Address),
        legacy: other.Address,
    };
    const TreeNode = struct {
        name: []const u8,
        children: []const TreeNode,
    };
    const Category = struct {
        name: []const u8,
        items: []const Item,
    };
    const Item = struct {
        title: []const u8,
        related: []const Category,
    };
};

test "reuse_definitions emits each named struct once and refers to it" {
    const T = reuse_test_types;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const schema = try toSchema(T.Customer, a, .{});
    const defs = schema.object.get("$defs").?.object;
    try std.testing.expectEqual(@as(usize, 3), defs.count());
    try std.testing.expect(defs.get("Address") != null);
    try std.testing.expect(defs.get("List_Address") != null); // generic instance
    try std.testing.expect(defs.get("Address_2") != null); // other.Address, renamed

    const props = schema.object.get("properties").?.object;
    try std.testing.expectEqualStrings("#/$defs/Address", props.get("home").?.object.get("$ref").?.string);
    // Use-site keywords are layered over the reference with allOf.
    const work = props.get("work").?.object;
    try std.testing.expectEqualStrings("Office", work.get("description").?.string);
    try std.testing.expectEqualStrings("#/$defs/Address", work.get("allOf").?.array.items[0].object.get("$ref").?.string);
    // Optional references accept null through anyOf.
    const billing = props.get("billing").?.object.get("anyOf").?.array.items;
    try std.testing.expectEqualStrings("#/$defs/Address", billing[0].object.get("$ref").?.string);
    try std.testing.expectEqualStrings("null", billing[1].object.get("type").?.string);
    // An explicit additionalProperties changes the shape, so it is inlined.
    const strict = props.get("strict").?.object;
    try std.testing.expect(strict.get("$ref") == null);
    try std.testing.expectEqual(false, strict.get("additionalProperties").?.bool);
    try std.testing.expectEqualStrings("#/$defs/Address_2", props.get("legacy").?.object.get("$ref").?.string);

    // Drafts before 2019-09 use `definitions`.
    const d7 = try toSchema(T.Customer, a, .{ .draft = .draft7 });
    try std.testing.expect(d7.object.get("$defs") == null);
    try std.testing.expect(d7.object.get("definitions").?.object.get("Address") != null);
    try std.testing.expectEqualStrings("#/definitions/Address", d7.object.get("properties").?.object.get("home").?.object.get("$ref").?.string);

    // With reuse off, every non-recursive struct is inlined.
    const inlined = try toSchema(T.Customer, a, .{ .reuse_definitions = false });
    try std.testing.expect(inlined.object.get("$defs") == null);
    try std.testing.expectEqualStrings("object", inlined.object.get("properties").?.object.get("home").?.object.get("type").?.string);
}

test "structs without Field labels are kept as-is by Unwrap (including recursive ones)" {
    const T = reuse_test_types;
    const WithMethod = struct {
        x: u8,
        fn double(self: @This()) u8 {
            return self.x * 2;
        }
    };
    try std.testing.expect(Unwrap(WithMethod) == WithMethod);
    try std.testing.expectEqual(@as(u8, 6), (Unwrap(WithMethod){ .x = 3 }).double());
    try std.testing.expect(Unwrap(T.TreeNode) == T.TreeNode);
    try std.testing.expect(Unwrap(T.Category) == T.Category);
}

test "recursive types reference themselves in every mode" {
    const T = reuse_test_types;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_]bool{ true, false }) |reuse| {
        const tree = try toSchema(T.TreeNode, a, .{ .reuse_definitions = reuse });
        const children = tree.object.get("properties").?.object.get("children").?.object;
        try std.testing.expectEqualStrings("#", children.get("items").?.object.get("$ref").?.string);
        try std.testing.expect(tree.object.get("$defs") == null);
    }

    // Mutual recursion through the root: `Item` can be inlined, since its
    // way back to `Category` is the root ("#").
    const cat = try toSchema(T.Category, a, .{ .reuse_definitions = false });
    try std.testing.expect(cat.object.get("$defs") == null);
    const item = cat.object.get("properties").?.object.get("items").?.object.get("items").?.object;
    const related = item.get("properties").?.object.get("related").?.object;
    try std.testing.expectEqualStrings("#", related.get("items").?.object.get("$ref").?.string);

    // Recursion below the root: even with reuse off, the recursive type
    // becomes a definition so the schema stays finite.
    const Wrapper = struct { root: T.Category };
    const wrapped = try toSchema(Wrapper, a, .{ .reuse_definitions = false });
    const defs = wrapped.object.get("$defs").?.object;
    const cat_items = defs.get("Category").?.object.get("properties").?.object.get("items").?.object;
    try std.testing.expectEqualStrings("#/$defs/Item", cat_items.get("items").?.object.get("$ref").?.string);
    const item_related = defs.get("Item").?.object.get("properties").?.object.get("related").?.object;
    try std.testing.expectEqualStrings("#/$defs/Category", item_related.get("items").?.object.get("$ref").?.string);

    const decoded = try fromJson(T.TreeNode, a,
        \\{"name": "root", "children": [{"name": "a", "children": []}, {"name": "b", "children": [{"name": "c", "children": []}]}]}
    , .{});
    try std.testing.expectEqual(@as(usize, 0), decoded.errors.items.len);
    try std.testing.expectEqualStrings("c", decoded.value.?.children[1].children[0].name);
}

test "shared definitions and recursive schemas agree with fromJson on every draft" {
    const T = reuse_test_types;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const customer_cases = [_][]const u8{
        \\{"home": {"zip": "1"}, "work": {"zip": "2"}, "billing": null, "strict": {"zip": "3"}, "history": {"entries": [{"zip": "4"}]}, "legacy": {"line": "x"}}
        ,
        \\{"home": {"zip": ""}, "work": {"zip": "2"}, "strict": {"zip": "3"}, "history": {"entries": []}, "legacy": {"line": "x"}}
        ,
        \\{"home": {"zip": "1"}, "work": {"zip": "2"}, "strict": {"zip": "3", "extra": 1}, "history": {"entries": []}, "legacy": {"line": "x"}}
        ,
        \\{"home": {"zip": "1"}, "work": {"zip": "2"}, "billing": {"zip": ""}, "strict": {"zip": "3"}, "history": {"entries": []}, "legacy": {"line": "x"}}
        ,
        \\{"home": {"zip": "1"}, "work": {"zip": "2"}, "strict": {"zip": "3"}, "history": {"entries": [{"zip": ""}]}, "legacy": {}}
        ,
    };
    const tree_cases = [_][]const u8{
        \\{"name": "r", "children": [{"name": "a", "children": []}]}
        ,
        \\{"name": "r", "children": [{"name": "a", "children": [{"name": 1, "children": []}]}]}
        ,
        \\{"name": "r", "children": [{"name": "a"}]}
        ,
    };

    inline for (std.meta.fields(Draft)) |f| {
        for ([_]bool{ true, false }) |reuse| {
            const options: SchemaOptions = .{ .draft = @enumFromInt(f.value), .reuse_definitions = reuse };
            var v = Validator.init(std.testing.allocator, .{});
            defer v.deinit();

            const customer = try toSchema(T.Customer, a, options);
            try std.testing.expect(try v.isValidSchema(customer));
            const customer_schema = try v.compile(customer);
            for (customer_cases) |text| {
                const expected = (try fromJson(T.Customer, a, text, options)).value != null;
                const instance = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
                try std.testing.expectEqual(expected, try customer_schema.isValid(instance));
            }

            const tree = try toSchema(T.TreeNode, a, options);
            try std.testing.expect(try v.isValidSchema(tree));
            const tree_schema = try v.compile(tree);
            for (tree_cases) |text| {
                const expected = (try fromJson(T.TreeNode, a, text, options)).value != null;
                const instance = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
                try std.testing.expectEqual(expected, try tree_schema.isValid(instance));
            }
        }
    }
}
