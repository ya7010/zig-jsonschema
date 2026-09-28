//! zig-jsonschema: comptime JSON Schema and validator generation from Zig
//! structs, with a declaration style close to pydantic's `Field()`, plus a
//! runtime `Validator` for arbitrary JSON Schema documents (drafts 4, 6, 7,
//! 2019-09 and 2020-12), verified against the official
//! JSON-Schema-Test-Suite (`zig build test-suite`).
//!
//! Supported kinds: number (int/float), string, boolean, array (Zig slice),
//! and object (Zig struct), each with its own constraint set.
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

    minLength: ?usize = null,
    maxLength: ?usize = null,
    /// Emitted into the generated schema, but NOT enforced by `validate`/
    /// `fromJson`: Zig's standard library has no regex engine. Validate this
    /// externally if you need it enforced.
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
    /// Enforced only for item types with an obvious notion of equality
    /// (numbers, bools, strings); anything else is a compile error.
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
            @compileError("zig-jsonschema: unsupported Field inner type " ++ @typeName(T));
        },
        .@"struct" => ObjectConstraints,
        else => @compileError("zig-jsonschema: unsupported Field inner type " ++ @typeName(T)),
    };
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
        .int, .float, .bool => Schema,
        .@"enum" => blk: {
            requireOpenEnum(Schema);
            break :blk Schema; // the newtype itself is kept, for type safety
        },
        .optional => |info| ?Unwrap(info.child),
        .pointer => |info| blk: {
            if (info.size == .slice and info.child == u8) break :blk Schema; // string
            if (info.size == .slice) break :blk []const Unwrap(info.child); // array
            @compileError("zig-jsonschema: unsupported pointer type " ++ @typeName(Schema));
        },
        // Structs without any `Field()` label are already plain: keep the
        // user's type (and its methods), which also makes recursive types work.
        .@"struct" => if (!hasLabels(Schema, &.{})) Schema else if (reaches(Schema, Schema, &.{}))
            @compileError("zig-jsonschema: recursive type " ++ @typeName(Schema) ++
                " cannot contain Field() labels (Zig cannot build a self-referential unwrapped type); use plain field types in it")
        else
            unwrapStruct(Schema),
        else => @compileError("zig-jsonschema: unsupported type " ++ @typeName(Schema)),
    };
}

/// Types `T` refers to that `Unwrap` descends into.
fn containedTypes(comptime T: type) []const type {
    return switch (@typeInfo(T)) {
        .optional => |o| &.{o.child},
        .pointer => |p| if (p.size == .slice and p.child != u8) &.{p.child} else &.{},
        .@"struct" => |s| blk: {
            if (isField(T)) break :blk &.{T.zjs_inner};
            var types: [s.fields.len]type = undefined;
            for (s.fields, 0..) |f, i| types[i] = f.type;
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
    /// JSON Schema version (dialect) to generate. Generation only.
    draft: Draft = .draft2020_12,
    /// Emit `$schema` at the root, so consumers know which dialect the
    /// schema is written in. Generation only.
    emit_schema_uri: bool = true,
    /// How JSON object keys that match no struct field are treated, for
    /// every object whose `Field()` does not set `additionalProperties`
    /// explicitly (an explicit setting always wins).
    unknown_fields: UnknownFields = .allow,
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
        const schema = try buildObjectSchema(T, .{}, gen);
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

/// Whether the root of `Schema` (below `Field()` and `?`) is a struct.
fn rootIsStruct(comptime Schema: type) bool {
    if (isField(Schema)) return rootIsStruct(Schema.zjs_inner);
    return switch (@typeInfo(Schema)) {
        .optional => |o| rootIsStruct(o.child),
        .@"struct" => true,
        else => false,
    };
}

/// Whether `T` is a struct with a user-given name (anonymous `struct {}`
/// literals are always inlined).
fn isNamedStruct(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and !isField(T) and
        std.mem.indexOf(u8, @typeName(T), "__struct_") == null;
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
            @compileError("zig-jsonschema: unsupported pointer type " ++ @typeName(T));
        },
        .@"struct" => return buildStructUse(T, constraints, gen),
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
    if (comptime !isNamedStruct(T)) return buildObjectSchema(T, constraints, gen);
    if (constraints.additionalProperties != null) return buildInlineStruct(T, constraints, gen);
    const ref = (try gen.refFor(T)) orelse return buildInlineStruct(T, constraints, gen);

    var ref_obj: std.json.ObjectMap = .empty;
    try ref_obj.put(allocator, "$ref", .{ .string = ref });
    const has_siblings = constraints.title != null or constraints.description != null or
        constraints.minProperties != null or constraints.maxProperties != null;
    if (!has_siblings) return .{ .object = ref_obj };

    // Drafts up to 7 ignore keywords next to `$ref`, so wrap it in `allOf`
    // (valid in every draft).
    var all_of: std.json.Array = .init(allocator);
    try all_of.append(.{ .object = ref_obj });
    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "allOf", .{ .array = all_of });
    if (constraints.title) |v| try obj.put(allocator, "title", .{ .string = v });
    if (constraints.description) |v| try obj.put(allocator, "description", .{ .string = v });
    if (constraints.minProperties) |v| try obj.put(allocator, "minProperties", .{ .integer = @intCast(v) });
    if (constraints.maxProperties) |v| try obj.put(allocator, "maxProperties", .{ .integer = @intCast(v) });
    return .{ .object = obj };
}

fn buildInlineStruct(comptime T: type, constraints: ObjectConstraints, gen: *Gen) Allocator.Error!std.json.Value {
    try gen.inlining.put(gen.allocator, @typeName(T), {});
    defer _ = gen.inlining.remove(@typeName(T));
    return buildObjectSchema(T, constraints, gen);
}

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
    if (gen.options.draft == .draft4) {
        // Draft 4 has a single bound per side, made exclusive by a boolean.
        try putDraft4Bound(&obj, allocator, "minimum", "exclusiveMinimum", constraints.minimum, constraints.exclusiveMinimum, .lower);
        try putDraft4Bound(&obj, allocator, "maximum", "exclusiveMaximum", constraints.maximum, constraints.exclusiveMaximum, .upper);
    } else {
        if (constraints.minimum) |v| try obj.put(allocator, "minimum", .{ .float = v });
        if (constraints.maximum) |v| try obj.put(allocator, "maximum", .{ .float = v });
        if (constraints.exclusiveMinimum) |v| try obj.put(allocator, "exclusiveMinimum", .{ .float = v });
        if (constraints.exclusiveMaximum) |v| try obj.put(allocator, "exclusiveMaximum", .{ .float = v });
    }
    if (constraints.multipleOf) |v| try obj.put(allocator, "multipleOf", .{ .float = v });
    return .{ .object = obj };
}

/// Emits the stricter of an inclusive and an exclusive bound in draft 4
/// form (`minimum` + `exclusiveMinimum: true`, or the maximum equivalent).
fn putDraft4Bound(
    obj: *std.json.ObjectMap,
    allocator: Allocator,
    comptime bound_key: []const u8,
    comptime exclusive_key: []const u8,
    inclusive: ?f64,
    exclusive: ?f64,
    comptime side: enum { lower, upper },
) Allocator.Error!void {
    const use_exclusive = blk: {
        const ex = exclusive orelse break :blk false;
        const in = inclusive orelse break :blk true;
        break :blk if (side == .lower) ex >= in else ex <= in;
    };
    if (use_exclusive) {
        try obj.put(allocator, bound_key, .{ .float = exclusive.? });
        try obj.put(allocator, exclusive_key, .{ .bool = true });
    } else if (inclusive) |in| {
        try obj.put(allocator, bound_key, .{ .float = in });
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

fn buildObjectSchema(comptime StructT: type, constraints: ObjectConstraints, gen: *Gen) Allocator.Error!std.json.Value {
    const allocator = gen.allocator;
    const info = @typeInfo(StructT).@"struct";
    var props: std.json.ObjectMap = .empty;
    var required: std.json.Array = .init(allocator);

    inline for (info.fields) |f| {
        const field_schema = try buildSchema(f.type, gen);
        try props.put(allocator, f.name, field_schema);
        if (!isOptionalField(f)) {
            try required.append(.{ .string = f.name });
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
    try validatePath(Schema, value, "", allocator, errors);
}

fn validatePath(
    comptime Schema: type,
    value: Unwrap(Schema),
    path: []const u8,
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
) Allocator.Error!void {
    if (comptime isField(Schema)) {
        try checkConstraints(Schema.zjs_inner, value, Schema.zjs_constraints, path, allocator, errors);
        try validatePath(Schema.zjs_inner, value, path, allocator, errors);
        return;
    }

    switch (@typeInfo(Schema)) {
        .int, .float, .bool, .@"enum" => {}, // leaf types: constraints (if any) were already applied above
        .optional => |info| {
            if (value) |inner| try validatePath(info.child, inner, path, allocator, errors);
        },
        .pointer => |info| {
            if (info.size == .slice and info.child == u8) return; // string leaf
            for (value, 0..) |elem, i| {
                const idx_path = try childPath(path, try std.fmt.allocPrint(allocator, "{d}", .{i}), allocator);
                try validatePath(info.child, elem, idx_path, allocator, errors);
            }
        },
        .@"struct" => |info| {
            inline for (info.fields) |f| {
                const child_path = try childPath(path, f.name, allocator);
                try validatePath(f.type, @field(value, f.name), child_path, allocator, errors);
            }
        },
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
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
) Allocator.Error!void {
    if (comptime @typeInfo(Inner) == .optional) {
        if (value) |v| try checkConstraints(@typeInfo(Inner).optional.child, v, constraints, path, allocator, errors);
        return;
    }

    switch (@typeInfo(Inner)) {
        .int, .float => try checkNumberConstraints(Inner, value, constraints, path, allocator, errors),
        .@"enum" => |e| try checkNumberConstraints(e.tag_type, @intFromEnum(value), constraints, path, allocator, errors),
        .bool => {}, // no assertion keywords for booleans in this MVP
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                try checkStringConstraints(value, constraints, path, allocator, errors);
            } else {
                try checkArrayConstraints(p.child, value, constraints, path, allocator, errors);
            }
        },
        .@"struct" => try checkObjectConstraints(Inner, constraints, path, allocator, errors),
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
    if (constraints.minLength) |min| {
        if (value.len < min) try addError(errors, allocator, path, "string length {d} is less than minLength {d}", .{ value.len, min });
    }
    if (constraints.maxLength) |max| {
        if (value.len > max) try addError(errors, allocator, path, "string length {d} is greater than maxLength {d}", .{ value.len, max });
    }
    // `pattern` is emitted into the schema but not enforced here; see the
    // doc comment on `StringConstraints.pattern`.
}

fn checkArrayConstraints(
    comptime Item: type,
    value: []const Unwrap(Item),
    constraints: ArrayConstraints,
    path: []const u8,
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
) Allocator.Error!void {
    if (constraints.minItems) |min| {
        if (value.len < min) try addError(errors, allocator, path, "array has {d} items, less than minItems {d}", .{ value.len, min });
    }
    if (constraints.maxItems) |max| {
        if (value.len > max) try addError(errors, allocator, path, "array has {d} items, more than maxItems {d}", .{ value.len, max });
    }
    if (constraints.uniqueItems orelse false) {
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

fn valuesEqual(comptime T: type, a: T, b: T) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum" => a == b,
        .optional => |info| if (a == null or b == null) (a == null and b == null) else valuesEqual(info.child, a.?, b.?),
        .pointer => |p| blk: {
            if (p.size == .slice and p.child == u8) break :blk std.mem.eql(u8, a, b);
            @compileError("zig-jsonschema: uniqueItems is not supported for array item type " ++ @typeName(T));
        },
        else => @compileError("zig-jsonschema: uniqueItems is not supported for array item type " ++ @typeName(T)),
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
        try validatePath(Schema, value, "", allocator, &errors);
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
        return decodeValue(Schema.zjs_inner, value, path, explicit, options, allocator, errors);
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
        .@"enum" => |e| {
            switch (value) {
                .integer => |i| {
                    const tag = std.math.cast(e.tag_type, i) orelse {
                        try addError(errors, allocator, path, "{d} does not fit in {s}", .{ i, @typeName(Schema) });
                        return error.Invalid;
                    };
                    return @enumFromInt(tag);
                },
                else => {
                    try addError(errors, allocator, path, "expected an integer, got {s}", .{@tagName(value)});
                    return error.Invalid;
                },
            }
        },
        .int => {
            switch (value) {
                .integer => |i| return std.math.cast(Schema, i) orelse {
                    try addError(errors, allocator, path, "{d} does not fit in {s}", .{ i, @typeName(Schema) });
                    return error.Invalid;
                },
                else => {
                    try addError(errors, allocator, path, "expected an integer, got {s}", .{@tagName(value)});
                    return error.Invalid;
                },
            }
        },
        .float => {
            switch (value) {
                .float => |f| return @as(Schema, @floatCast(f)),
                .integer => |i| return @as(Schema, @floatFromInt(i)),
                else => {
                    try addError(errors, allocator, path, "expected a number, got {s}", .{@tagName(value)});
                    return error.Invalid;
                },
            }
        },
        .pointer => |info| {
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
                any_failed = try reportAdditionalProperties(Schema, value.object, path, allocator, errors);
            }

            inline for (info.fields) |f| {
                const child_path = try childPath(path, f.name, allocator);
                if (value.object.get(f.name)) |sub_value| {
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
        else => @compileError("zig-jsonschema: unsupported type " ++ @typeName(Schema)),
    }
}

fn reportAdditionalProperties(
    comptime StructT: type,
    obj: std.json.ObjectMap,
    path: []const u8,
    allocator: Allocator,
    errors: *std.ArrayList(ValidationError),
) Allocator.Error!bool {
    const info = @typeInfo(StructT).@"struct";
    var found = false;
    var it = obj.iterator();
    while (it.next()) |entry| {
        var known = false;
        inline for (info.fields) |f| {
            if (std.mem.eql(u8, f.name, entry.key_ptr.*)) known = true;
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
    try std.testing.expectEqualStrings("buyer", bad.errors.items[0].path); // does not fit in u32
    try std.testing.expectEqualStrings("referrer", bad.errors.items[1].path); // not an integer

    const constraint = try fromJson(Order, a,
        \\{"buyer": 1, "seller": 0, "watchers": [1, 1]}
    , .{});
    try std.testing.expectEqual(@as(usize, 2), constraint.errors.items.len);
    try std.testing.expectEqualStrings("seller", constraint.errors.items[0].path); // minimum
    try std.testing.expectEqualStrings("watchers", constraint.errors.items[1].path); // uniqueItems

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
