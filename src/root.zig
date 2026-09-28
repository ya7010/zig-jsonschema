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
//! const result = try fromJson(Product, allocator, json_text);
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
    if (comptime isField(Schema)) return Unwrap(Schema.zjs_inner);

    return switch (@typeInfo(Schema)) {
        .int, .float, .bool => Schema,
        .optional => |info| ?Unwrap(info.child),
        .pointer => |info| blk: {
            if (info.size == .slice and info.child == u8) break :blk Schema; // string
            if (info.size == .slice) break :blk []const Unwrap(info.child); // array
            @compileError("zig-jsonschema: unsupported pointer type " ++ @typeName(Schema));
        },
        .@"struct" => unwrapStruct(Schema),
        else => @compileError("zig-jsonschema: unsupported type " ++ @typeName(Schema)),
    };
}

fn unwrapStruct(comptime Schema: type) type {
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

/// Options for `toSchemaWithOptions`.
/// Options shared by schema generation (`toSchemaWithOptions`) and
/// decoding (`fromJsonWithOptions`), so that a generated schema accepts
/// exactly what `fromJson` accepts when both use the same options.
pub const SchemaOptions = struct {
    /// JSON Schema version (dialect) to generate. Generation only.
    draft: Draft = .draft2020_12,
    /// Emit `$schema` at the root, so consumers know which dialect the
    /// schema is written in. Generation only.
    emit_schema_uri: bool = true,
    /// How JSON object keys that match no struct field are treated, for
    /// every object whose `Field()` does not set `additionalProperties`
    /// explicitly (an explicit setting always wins).
    unknown_fields: UnknownFields = .allow,
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

/// Builds a JSON Schema (draft 2020-12, without `$schema`) from type
/// `Schema` at comptime. Every `std.json.Value` in the result is owned by
/// `allocator` (using an `ArenaAllocator` at the call site is recommended).
/// Use `toSchemaWithOptions` to pick another draft.
pub fn toSchema(comptime Schema: type, allocator: Allocator) Allocator.Error!std.json.Value {
    return toSchemaWithOptions(Schema, allocator, .{ .emit_schema_uri = false });
}

/// Like `toSchema`, but generates the dialect selected by `options.draft`
/// (e.g. draft 4 expresses `exclusiveMinimum` as a boolean modifier of
/// `minimum`).
pub fn toSchemaWithOptions(comptime Schema: type, allocator: Allocator, options: SchemaOptions) Allocator.Error!std.json.Value {
    var root = try buildSchema(Schema, options, allocator);
    if (options.emit_schema_uri) {
        const schema_uri = switch (options.draft) {
            // Drafts up to 7 conventionally reference their metaschema with an empty fragment.
            .draft4, .draft6, .draft7 => try std.fmt.allocPrint(allocator, "{s}#", .{options.draft.metaschemaUri()}),
            .draft2019_09, .draft2020_12 => options.draft.metaschemaUri(),
        };
        // Put `$schema` first so it reads naturally in the serialized output.
        var obj: std.json.ObjectMap = .empty;
        try obj.put(allocator, "$schema", .{ .string = schema_uri });
        var it = root.object.iterator();
        while (it.next()) |e| try obj.put(allocator, e.key_ptr.*, e.value_ptr.*);
        root = .{ .object = obj };
    }
    return root;
}

fn buildSchema(comptime Schema: type, options: SchemaOptions, allocator: Allocator) Allocator.Error!std.json.Value {
    if (comptime isField(Schema)) {
        return buildSchemaFor(Schema.zjs_inner, Schema.zjs_constraints, options, allocator);
    }
    return buildSchemaFor(Schema, ConstraintsFor(Schema){}, options, allocator);
}

fn buildSchemaFor(comptime T: type, constraints: ConstraintsFor(T), options: SchemaOptions, allocator: Allocator) Allocator.Error!std.json.Value {
    if (comptime @typeInfo(T) == .optional) {
        // `?T` accepts `null` (as `fromJson` does): widen `type` to
        // `[<type>, "null"]`. The other keywords only constrain their own
        // instance type, so they keep applying to non-null values unchanged.
        var schema = try buildSchemaFor(@typeInfo(T).optional.child, constraints, options, allocator);
        const type_name = schema.object.get("type").?.string;
        var types: std.json.Array = .init(allocator);
        try types.append(.{ .string = type_name });
        try types.append(.{ .string = "null" });
        try schema.object.put(allocator, "type", .{ .array = types });
        return schema;
    }
    switch (@typeInfo(T)) {
        .int, .float => return buildNumberSchema(T, constraints, options, allocator),
        .bool => return buildBoolSchema(constraints, allocator),
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return buildStringSchema(constraints, allocator);
            if (p.size == .slice) return buildArraySchema(p.child, constraints, options, allocator);
            @compileError("zig-jsonschema: unsupported pointer type " ++ @typeName(T));
        },
        .@"struct" => return buildObjectSchema(T, constraints, options, allocator),
        else => @compileError("zig-jsonschema: unsupported type " ++ @typeName(T)),
    }
}

fn buildNumberSchema(comptime T: type, constraints: NumberConstraints, options: SchemaOptions, allocator: Allocator) Allocator.Error!std.json.Value {
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
    if (options.draft == .draft4) {
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

fn buildArraySchema(comptime Item: type, constraints: ArrayConstraints, options: SchemaOptions, allocator: Allocator) Allocator.Error!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "type", .{ .string = "array" });
    if (constraints.title) |v| try obj.put(allocator, "title", .{ .string = v });
    if (constraints.description) |v| try obj.put(allocator, "description", .{ .string = v });
    if (constraints.minItems) |v| try obj.put(allocator, "minItems", .{ .integer = @intCast(v) });
    if (constraints.maxItems) |v| try obj.put(allocator, "maxItems", .{ .integer = @intCast(v) });
    if (constraints.uniqueItems) |v| try obj.put(allocator, "uniqueItems", .{ .bool = v });
    try obj.put(allocator, "items", try buildSchema(Item, options, allocator));
    return .{ .object = obj };
}

fn buildObjectSchema(comptime StructT: type, constraints: ObjectConstraints, options: SchemaOptions, allocator: Allocator) Allocator.Error!std.json.Value {
    const info = @typeInfo(StructT).@"struct";
    var props: std.json.ObjectMap = .empty;
    var required: std.json.Array = .init(allocator);

    inline for (info.fields) |f| {
        const field_schema = try buildSchema(f.type, options, allocator);
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
    if (additionalPropertiesFor(constraints.additionalProperties, options)) |v| {
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
        .int, .float, .bool => {}, // leaf types: constraints (if any) were already applied above
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
        .int, .float, .bool => a == b,
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

pub fn fromJson(comptime Schema: type, allocator: Allocator, json_text: []const u8) Allocator.Error!FromJsonResult(Unwrap(Schema)) {
    return fromJsonWithOptions(Schema, allocator, json_text, .{});
}

/// Like `fromJson`, but honours `options.unknown_fields` (the generation-only
/// fields of `SchemaOptions` are ignored).
pub fn fromJsonWithOptions(
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
    const schema = try toSchema(Product, arena.allocator());

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
    const schema = try toSchema(Product, arena.allocator());
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
    );

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
    );

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
    );

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
    );

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
    );

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
    );

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
    );

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

    const result = try fromJson(Product, allocator, "{not valid json");

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

    const generated = try toSchema(Product, allocator);
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
        const via_comptime = (try fromJson(Product, allocator, text)).value != null;
        const instance = try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
        try std.testing.expectEqual(via_comptime, try schema.isValid(instance));
    }
}

test "toSchemaWithOptions emits $schema and draft-specific keywords" {
    const Product = struct {
        price: Field(f64, .{ .minimum = 0, .exclusiveMinimum = 0, .maximum = 100 }),
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const d4 = try toSchemaWithOptions(Product, allocator, .{ .draft = .draft4 });
    try std.testing.expectEqualStrings("http://json-schema.org/draft-04/schema#", d4.object.get("$schema").?.string);
    const price4 = d4.object.get("properties").?.object.get("price").?.object;
    try std.testing.expectEqual(@as(f64, 0), price4.get("minimum").?.float);
    try std.testing.expectEqual(true, price4.get("exclusiveMinimum").?.bool);
    try std.testing.expectEqual(@as(f64, 100), price4.get("maximum").?.float);
    try std.testing.expect(price4.get("exclusiveMaximum") == null);

    const d7 = try toSchemaWithOptions(Product, allocator, .{ .draft = .draft7 });
    try std.testing.expectEqualStrings("http://json-schema.org/draft-07/schema#", d7.object.get("$schema").?.string);
    const price7 = d7.object.get("properties").?.object.get("price").?.object;
    try std.testing.expectEqual(@as(f64, 0), price7.get("exclusiveMinimum").?.float);

    const d2020 = try toSchemaWithOptions(Product, allocator, .{});
    try std.testing.expectEqualStrings("https://json-schema.org/draft/2020-12/schema", d2020.object.get("$schema").?.string);
    const plain = try toSchema(Product, allocator);
    try std.testing.expect(plain.object.get("$schema") == null);
}

test "toSchemaWithOptions output is valid for every draft and matches fromJson" {
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
            const generated = try toSchemaWithOptions(Product, allocator, options);

            // The runtime validator picks the dialect up from `$schema`, not from its default.
            var v = Validator.init(std.testing.allocator, .{ .default_draft = .draft2020_12 });
            defer v.deinit();
            try std.testing.expect(try v.isValidSchema(generated));
            const schema = try v.compile(generated);
            for (cases) |text| {
                const via_comptime = (try fromJsonWithOptions(Product, allocator, text, options)).value != null;
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
    const schema = try toSchema(Product, arena.allocator());
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
    try std.testing.expect((try fromJsonWithOptions(Product, a, ok, deny)).value != null);

    const bad =
        \\{"name": "W", "top": 1, "billing": {"zip": "1", "city": "X"}, "items": [{"zip": "1", "n": 2}], "extras": {"source": "s"}}
    ;
    const result = try fromJsonWithOptions(Product, a, bad, deny);
    try std.testing.expect(result.value == null);
    try std.testing.expectEqual(@as(usize, 3), result.errors.items.len);
    try std.testing.expectEqualStrings("top", result.errors.items[0].path);
    try std.testing.expectEqualStrings("billing.city", result.errors.items[1].path);
    try std.testing.expectEqualStrings("items.0.n", result.errors.items[2].path);

    // The default still ignores unknown keys.
    try std.testing.expect((try fromJson(Product, a, bad)).value != null);

    const schema = try toSchemaWithOptions(Product, a, deny);
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
    try std.testing.expect((try fromJson(Product, a, "{\"billing\": null}")).value != null);
    try std.testing.expect((try fromJson(Product, a, "{\"billing\": {\"zip\": \"1\", \"x\": 1}}")).value == null);
}
