//! Runtime JSON Schema validator.
//!
//! Supports drafts 4, 6, 7, 2019-09 and 2020-12, including `$ref` /
//! `$dynamicRef` / `$recursiveRef`, embedded and remote resources,
//! `$anchor`, `unevaluatedProperties` / `unevaluatedItems`, `$vocabulary`,
//! ECMA-262 `pattern`s and (optionally asserted) `format`s.
//!
//! ```zig
//! var v = Validator.init(gpa, .{});
//! defer v.deinit();
//! const schema = try v.compileJson(
//!     \\{"type": "object", "properties": {"age": {"type": "integer", "minimum": 0}}}
//! );
//! const ok = try schema.isValid(instance_value);
//! ```

const std = @import("std");
const enumFields = @import("type_fields.zig").enumFields;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const uri = @import("uri.zig");
const Regex = @import("regex.zig").Regex;
const formats = @import("format.zig");

pub const Draft = enum {
    draft4,
    draft6,
    draft7,
    draft2019_09,
    draft2020_12,

    pub fn metaschemaUri(d: Draft) []const u8 {
        return switch (d) {
            .draft4 => "http://json-schema.org/draft-04/schema",
            .draft6 => "http://json-schema.org/draft-06/schema",
            .draft7 => "http://json-schema.org/draft-07/schema",
            .draft2019_09 => "https://json-schema.org/draft/2019-09/schema",
            .draft2020_12 => "https://json-schema.org/draft/2020-12/schema",
        };
    }

    /// Maps a `$schema` URI of one of the official metaschemas to its draft.
    pub fn fromMetaschemaUri(s: []const u8) ?Draft {
        const base = uri.splitFragment(s).base;
        inline for (enumFields(Draft)) |f| {
            const d: Draft = @fromBackingInt(@intCast(f.value));
            if (std.mem.eql(u8, base, d.metaschemaUri())) return d;
            // Tolerate the http/https mix-up that is common in the wild.
            const m = d.metaschemaUri();
            const alt_prefix = if (std.mem.startsWith(u8, m, "https:")) "http:" else "https:";
            const colon = std.mem.indexOfScalar(u8, m, ':').?;
            if (std.mem.startsWith(u8, base, alt_prefix) and std.mem.eql(u8, base[alt_prefix.len..], m[colon + 1 ..])) return d;
        }
        return null;
    }

    fn atLeast(d: Draft, other: Draft) bool {
        return @backingInt(d) >= @backingInt(other);
    }
};

pub const Options = struct {
    /// Draft used for schemas that have no (recognised) `$schema`.
    default_draft: Draft = .draft2020_12,
    /// Treat `format` as an assertion rather than an annotation. (It is
    /// always asserted when a metaschema enables the 2020-12
    /// format-assertion vocabulary.)
    format_assertion: bool = false,
    /// Draft 7 and earlier: treat `contentEncoding` / `contentMediaType` as
    /// assertions (they are annotations in 2019-09 and later).
    content_assertion: bool = false,
    /// Maximum nesting of schema evaluation before giving up (guards against
    /// infinitely recursive `$ref`s).
    max_depth: usize = 1000,
    /// Budget of regex steps for each `pattern` / `patternProperties` match
    /// (see `Regex.isMatchLimited`). Exceeding it fails validation with
    /// `error.RegexLimitExceeded` rather than guessing an answer, so a
    /// hostile pattern or input cannot stall the validator.
    regex_step_limit: usize = @import("regex.zig").default_step_limit,
};

pub const CompileError = error{
    InvalidSchema,
    UnknownMetaschema,
    UnsupportedVocabulary,
    UnresolvableReference,
} || Allocator.Error;

pub const ValidateError = error{
    UnresolvableReference,
    RecursionLimitExceeded,
    InvalidSchema,
    UnknownMetaschema,
    UnsupportedVocabulary,
    /// A regex match exceeded `Options.regex_step_limit` (or the regex
    /// engine's memory bound).
    RegexLimitExceeded,
} || Allocator.Error;

/// A single validation failure.
pub const Error = struct {
    /// JSON Pointer to the offending part of the instance.
    instance_location: []const u8,
    /// JSON Pointer to the failing keyword along the evaluation path from
    /// the root schema, through `$ref`s (e.g. `/properties/a/$ref/type`).
    keyword_location: []const u8,
    /// Absolute URI of the failing keyword: its schema resource plus a JSON
    /// Pointer fragment (e.g. `https://example.com/s.json#/$defs/a/type`).
    absolute_keyword_location: []const u8,
    message: []const u8,
};

/// Standard output formats of JSON Schema 2019-09 / 2020-12 (section 12 of
/// the 2020-12 core specification), produced by `Schema.output`.
pub const OutputFormat = enum {
    /// `{"valid": bool}`
    flag,
    /// The root unit, with every error (when invalid) or every annotation
    /// (when valid) in a flat list.
    basic,
    /// A tree following the schema structure, with only the units that
    /// explain the result (failures or annotations), single-child chains
    /// collapsed.
    detailed,
    /// The full tree of every evaluated subschema.
    verbose,
};

pub const Result = struct {
    valid: bool,
    errors: []const Error,
};

const Vocab = struct {
    core: bool = true,
    applicator: bool = true,
    unevaluated: bool = true,
    validation: bool = true,
    meta_data: bool = true,
    format_annotation: bool = true,
    format_assertion: bool = false,
    content: bool = true,
};

const known_vocabularies = [_]struct { uri: []const u8, field: []const u8 }{
    .{ .uri = "https://json-schema.org/draft/2020-12/vocab/core", .field = "core" },
    .{ .uri = "https://json-schema.org/draft/2020-12/vocab/applicator", .field = "applicator" },
    .{ .uri = "https://json-schema.org/draft/2020-12/vocab/unevaluated", .field = "unevaluated" },
    .{ .uri = "https://json-schema.org/draft/2020-12/vocab/validation", .field = "validation" },
    .{ .uri = "https://json-schema.org/draft/2020-12/vocab/meta-data", .field = "meta_data" },
    .{ .uri = "https://json-schema.org/draft/2020-12/vocab/format-annotation", .field = "format_annotation" },
    .{ .uri = "https://json-schema.org/draft/2020-12/vocab/format-assertion", .field = "format_assertion" },
    .{ .uri = "https://json-schema.org/draft/2020-12/vocab/content", .field = "content" },
    .{ .uri = "https://json-schema.org/draft/2019-09/vocab/core", .field = "core" },
    .{ .uri = "https://json-schema.org/draft/2019-09/vocab/applicator", .field = "applicator" },
    .{ .uri = "https://json-schema.org/draft/2019-09/vocab/validation", .field = "validation" },
    .{ .uri = "https://json-schema.org/draft/2019-09/vocab/meta-data", .field = "meta_data" },
    .{ .uri = "https://json-schema.org/draft/2019-09/vocab/format", .field = "format_annotation" },
    .{ .uri = "https://json-schema.org/draft/2019-09/vocab/content", .field = "content" },
};

const builtin_metaschemas = [_]struct { uri: []const u8, text: []const u8 }{
    .{ .uri = "http://json-schema.org/draft-04/schema", .text = @embedFile("metaschemas/draft-04.json") },
    .{ .uri = "http://json-schema.org/draft-06/schema", .text = @embedFile("metaschemas/draft-06.json") },
    .{ .uri = "http://json-schema.org/draft-07/schema", .text = @embedFile("metaschemas/draft-07.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/schema", .text = @embedFile("metaschemas/2019-09/schema.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/meta/core", .text = @embedFile("metaschemas/2019-09/meta/core.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/meta/applicator", .text = @embedFile("metaschemas/2019-09/meta/applicator.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/meta/validation", .text = @embedFile("metaschemas/2019-09/meta/validation.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/meta/meta-data", .text = @embedFile("metaschemas/2019-09/meta/meta-data.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/meta/format", .text = @embedFile("metaschemas/2019-09/meta/format.json") },
    .{ .uri = "https://json-schema.org/draft/2019-09/meta/content", .text = @embedFile("metaschemas/2019-09/meta/content.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/schema", .text = @embedFile("metaschemas/2020-12/schema.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/core", .text = @embedFile("metaschemas/2020-12/meta/core.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/applicator", .text = @embedFile("metaschemas/2020-12/meta/applicator.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/unevaluated", .text = @embedFile("metaschemas/2020-12/meta/unevaluated.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/validation", .text = @embedFile("metaschemas/2020-12/meta/validation.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/meta-data", .text = @embedFile("metaschemas/2020-12/meta/meta-data.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/format-annotation", .text = @embedFile("metaschemas/2020-12/meta/format-annotation.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/format-assertion", .text = @embedFile("metaschemas/2020-12/meta/format-assertion.json") },
    .{ .uri = "https://json-schema.org/draft/2020-12/meta/content", .text = @embedFile("metaschemas/2020-12/meta/content.json") },
};

const Resource = struct {
    uri: []const u8,
    value: *const Value,
    root: ?*Node = null,
    draft: Draft,
    vocab: Vocab,
    anchors: std.StringHashMapUnmanaged(*Node) = .empty,
    dynamic_anchors: std.StringHashMapUnmanaged(*Node) = .empty,
    recursive_anchor: bool = false,
};

const TypeSet = packed struct(u8) {
    null: bool = false,
    boolean: bool = false,
    object: bool = false,
    array: bool = false,
    number: bool = false,
    string: bool = false,
    integer: bool = false,
    _pad: u1 = 0,
};

/// A JSON number. Integers (including those beyond i64, such as u64
/// bounds) are kept exact; anything else is an f64.
const Num = union(enum) {
    int: i256,
    float: f64,

    fn toF64(n: Num) f64 {
        return switch (n) {
            .int => |i| intToF64(i),
            .float => |f| f,
        };
    }

    pub fn format(n: Num, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (n) {
            .int => |i| try w.print("{d}", .{i}),
            .float => |f| try w.print("{d}", .{f}),
        }
    }
};

const Ref = struct {
    uri: []const u8,
    target: ?*Node = null,
};

const DynamicRef = struct {
    ref: Ref,
    /// The plain-name fragment, if the reference has one.
    anchor: ?[]const u8,
};

const NamedNode = struct { name: []const u8, node: *Node };
const PatternNode = struct { source: []const u8, regex: Regex, node: *Node };
const NamedList = struct { name: []const u8, list: []const []const u8 };

const Keyword = union(enum) {
    ref: *Ref,
    dynamic_ref: *DynamicRef,
    recursive_ref: *Ref,
    type: TypeSet,
    @"enum": []const Value,
    @"const": *const Value,
    multiple_of: Num,
    maximum: struct { limit: Num, exclusive: bool },
    minimum: struct { limit: Num, exclusive: bool },
    max_length: u64,
    min_length: u64,
    pattern: struct { source: []const u8, regex: Regex },
    format: []const u8,
    content: struct { encoding: ?[]const u8, media_type: ?[]const u8 },
    /// `prefix` = `prefixItems` (or array-form `items`), `rest` = `items`
    /// (or `additionalItems`) applied to every index past `prefix`.
    items: struct {
        prefix: []const *Node,
        rest: ?*Node,
        /// Keyword names, for output: `prefixItems` / `items` (2020-12),
        /// or `items` / `additionalItems`.
        prefix_keyword: []const u8,
        rest_keyword: []const u8,
    },
    contains: struct { node: *Node, min: u64, max: ?u64 },
    max_items: u64,
    min_items: u64,
    unique_items,
    properties: []const NamedNode,
    pattern_properties: []const PatternNode,
    additional_properties: struct { node: *Node, names: []const []const u8, patterns: []const Regex },
    property_names: *Node,
    required: []const []const u8,
    /// `dependentRequired`, or the array form of `dependencies`.
    dependent_required: struct { keyword: []const u8, deps: []const NamedList },
    dependent_schemas: []const NamedNode,
    max_properties: u64,
    min_properties: u64,
    all_of: []const *Node,
    any_of: []const *Node,
    one_of: []const *Node,
    not: *Node,
    conditional: struct { @"if": *Node, then: ?*Node, @"else": ?*Node },
    unevaluated_items: *Node,
    unevaluated_properties: *Node,
};

const Node = struct {
    kind: enum { always_true, always_false, object },
    resource: *Resource,
    /// JSON Pointer of this schema within its document, used in errors.
    location: []const u8,
    keywords: []const Keyword = &.{},
    /// Whether some keyword here needs sibling annotations
    /// (`unevaluated*`).
    uses_unevaluated: bool = false,
    /// Keywords whose value is an annotation (`title`, `readOnly`, unknown
    /// keywords, ...), reported by `Schema.output`.
    annotations: []const AnnotationKeyword = &.{},
};

const AnnotationKeyword = struct { keyword: []const u8, value: *const Value };

/// Keywords that only annotate: their value is the annotation.
const annotation_keywords = std.StaticStringMap(void).initComptime(.{
    .{"title"},           .{"description"},      .{"default"},       .{"examples"},
    .{"deprecated"},      .{"readOnly"},         .{"writeOnly"},     .{"format"},
    .{"contentEncoding"}, .{"contentMediaType"}, .{"contentSchema"},
});

/// Every keyword of drafts 4 to 2020-12 that is not an annotation keyword;
/// any other key of a 2019-09+ schema is an unknown keyword, collected as an
/// annotation.
const known_keywords = std.StaticStringMap(void).initComptime(.{
    .{"$schema"},          .{"$id"},                   .{"id"},                .{"$ref"},                 .{"$anchor"},
    .{"$dynamicAnchor"},   .{"$dynamicRef"},           .{"$recursiveRef"},     .{"$recursiveAnchor"},     .{"$vocabulary"},
    .{"$comment"},         .{"$defs"},                 .{"definitions"},       .{"type"},                 .{"enum"},
    .{"const"},            .{"multipleOf"},            .{"maximum"},           .{"exclusiveMaximum"},     .{"minimum"},
    .{"exclusiveMinimum"}, .{"maxLength"},             .{"minLength"},         .{"pattern"},              .{"maxItems"},
    .{"minItems"},         .{"uniqueItems"},           .{"maxContains"},       .{"minContains"},          .{"maxProperties"},
    .{"minProperties"},    .{"required"},              .{"dependentRequired"}, .{"allOf"},                .{"anyOf"},
    .{"oneOf"},            .{"not"},                   .{"if"},                .{"then"},                 .{"else"},
    .{"dependentSchemas"}, .{"dependencies"},          .{"prefixItems"},       .{"items"},                .{"additionalItems"},
    .{"contains"},         .{"properties"},            .{"patternProperties"}, .{"additionalProperties"}, .{"propertyNames"},
    .{"unevaluatedItems"}, .{"unevaluatedProperties"},
});

/// Holds compiled schemas and every resource (remote documents, embedded
/// `$id`s, built-in metaschemas) they may reference.
pub const Validator = struct {
    arena: std.heap.ArenaAllocator,
    gpa: Allocator,
    options: Options,
    /// Registered but not yet compiled documents, by URI (no fragment).
    documents: std.StringHashMapUnmanaged(*const Value) = .empty,
    resources: std.StringHashMapUnmanaged(*Resource) = .empty,
    nodes: std.AutoHashMapUnmanaged(*const Value, *Node) = .empty,
    anonymous_count: usize = 0,

    pub fn init(gpa: Allocator, options: Options) Validator {
        return .{ .arena = .init(gpa), .gpa = gpa, .options = options };
    }

    pub fn deinit(self: *Validator) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn alloc(self: *Validator) Allocator {
        return self.arena.allocator();
    }

    /// Registers a schema document under `id` so `$ref`s can reach it
    /// (e.g. a remote `http://example.com/schema.json`). The value is
    /// referenced, not copied, and must outlive the validator.
    pub fn addDocument(self: *Validator, id: []const u8, document: Value) Allocator.Error!void {
        const a = self.alloc();
        const doc = try a.create(Value);
        doc.* = document;
        const key = try a.dupe(u8, uri.splitFragment(id).base);
        try self.documents.put(a, key, doc);
    }

    /// Like `addDocument`, but parses `json_text` (copied into the validator).
    pub fn addDocumentJson(self: *Validator, id: []const u8, json_text: []const u8) (Allocator.Error || error{InvalidJson})!void {
        const doc = std.json.parseFromSliceLeaky(Value, self.alloc(), json_text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJson,
        };
        try self.addDocument(id, doc);
    }

    /// Compiles `schema`. The value is referenced, not copied, and must
    /// outlive the validator. The returned handle is owned by the validator.
    pub fn compile(self: *Validator, schema: Value) CompileError!Schema {
        const a = self.alloc();
        const doc = try a.create(Value);
        doc.* = schema;
        self.anonymous_count += 1;
        const base = try std.fmt.allocPrint(a, "urn:jsonschema:anonymous:{d}", .{self.anonymous_count});
        const res = try self.compileDocument(base, doc);
        return .{ .validator = self, .root = res.root.? };
    }

    /// Like `compile`, but parses `json_text` (copied into the validator).
    pub fn compileJson(self: *Validator, json_text: []const u8) (CompileError || error{InvalidJson})!Schema {
        const doc = std.json.parseFromSliceLeaky(Value, self.alloc(), json_text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJson,
        };
        return self.compile(doc);
    }

    /// Compiles the schema registered (or built in) under `id`, e.g. an
    /// official metaschema URI, and returns a handle to it.
    pub fn compileUri(self: *Validator, id: []const u8) CompileError!Schema {
        const a = self.alloc();
        const target = try self.resolveUri(try uri.resolve(a, id, ""));
        return .{ .validator = self, .root = target };
    }

    /// Checks `schema` itself against the metaschema of its dialect (its
    /// `$schema`, or the default draft's).
    pub fn isValidSchema(self: *Validator, schema: Value) (CompileError || ValidateError)!bool {
        var meta_uri = self.options.default_draft.metaschemaUri();
        if (schema == .object) {
            if (schema.object.get("$schema")) |s| if (s == .string) {
                meta_uri = s.string;
            };
        }
        const meta = try self.compileUri(meta_uri);
        return meta.isValid(schema);
    }

    // -----------------------------------------------------------------
    // Compilation
    // -----------------------------------------------------------------

    const Scope = struct {
        resource: *Resource,
        base: []const u8,
        draft: Draft,
        vocab: Vocab,
        location: []const u8,
    };

    fn compileDocument(self: *Validator, base: []const u8, doc: *const Value) CompileError!*Resource {
        const a = self.alloc();
        const dialect = try self.dialectOf(doc, null);
        const res = try a.create(Resource);
        res.* = .{ .uri = base, .value = doc, .draft = dialect.draft, .vocab = dialect.vocab };
        try self.resources.put(a, base, res);
        const scope: Scope = .{ .resource = res, .base = base, .draft = dialect.draft, .vocab = dialect.vocab, .location = "" };
        const root = try self.compileSchema(doc, scope, true);
        // The document root may have changed the resource via `$id`.
        if (res.root == null) res.root = root;
        return res;
    }

    const Dialect = struct { draft: Draft, vocab: Vocab };

    /// Determines the dialect of a (resource root) schema from `$schema`,
    /// falling back to `inherited` or the default draft.
    fn dialectOf(self: *Validator, value: *const Value, inherited: ?Dialect) CompileError!Dialect {
        const fallback: Dialect = inherited orelse .{ .draft = self.options.default_draft, .vocab = .{} };
        if (value.* != .object) return fallback;
        const s = value.object.get("$schema") orelse return fallback;
        if (s != .string) return error.InvalidSchema;
        if (Draft.fromMetaschemaUri(s.string)) |d| return .{ .draft = d, .vocab = .{} };

        // A custom metaschema: its own dialect decides the keyword
        // semantics, and its `$vocabulary` decides which are enabled.
        const a = self.alloc();
        const ms_uri = try uri.resolve(a, s.string, "");
        const meta = self.resolveUri(ms_uri) catch |err| switch (err) {
            error.UnresolvableReference => return error.UnknownMetaschema,
            else => |e| return e,
        };
        const meta_value = meta.resource.value;
        var dialect: Dialect = .{ .draft = meta.resource.draft, .vocab = meta.resource.vocab };
        if (meta_value.* == .object) {
            if (meta_value.object.get("$vocabulary")) |vocabs| {
                if (vocabs != .object) return error.InvalidSchema;
                var v: Vocab = .{
                    .core = false,
                    .applicator = false,
                    .unevaluated = false,
                    .validation = false,
                    .meta_data = false,
                    .format_annotation = false,
                    .format_assertion = false,
                    .content = false,
                };
                var it = vocabs.object.iterator();
                while (it.next()) |e| {
                    var known = false;
                    inline for (known_vocabularies) |kv| {
                        if (std.mem.eql(u8, kv.uri, e.key_ptr.*)) {
                            @field(v, kv.field) = true;
                            known = true;
                        }
                    }
                    if (!known and e.value_ptr.* == .bool and e.value_ptr.bool) return error.UnsupportedVocabulary;
                }
                // 2019-09's applicator vocabulary also carries the
                // `unevaluated*` keywords.
                if (dialect.draft == .draft2019_09) v.unevaluated = v.applicator;
                dialect.vocab = v;
            }
        }
        return dialect;
    }

    fn childScope(self: *Validator, scope: Scope, segments: []const []const u8) Allocator.Error!Scope {
        var s = scope;
        var loc: std.ArrayList(u8) = .empty;
        try loc.appendSlice(self.alloc(), scope.location);
        for (segments) |seg| {
            try loc.append(self.alloc(), '/');
            try appendPointerSegment(self.alloc(), &loc, seg);
        }
        s.location = loc.items;
        return s;
    }

    fn compileSchema(self: *Validator, value: *const Value, parent: Scope, is_document_root: bool) CompileError!*Node {
        if (self.nodes.get(value)) |existing| return existing;
        const a = self.alloc();

        switch (value.*) {
            .bool => |b| {
                const node = try a.create(Node);
                node.* = .{ .kind = if (b) .always_true else .always_false, .resource = parent.resource, .location = parent.location };
                try self.nodes.put(a, value, node);
                return node;
            },
            .object => {},
            else => return error.InvalidSchema,
        }
        const obj = value.object;
        var scope = parent;

        // --- identification: $id / id, anchors, dialect ---
        const id_key = if (scope.draft == .draft4) "id" else "$id";
        const ref_overrides = !scope.draft.atLeast(.draft2019_09) and obj.get("$ref") != null;
        var new_resource: ?*Resource = null;
        // Legacy (draft 7 and earlier) `$id: "#name"` anchors, registered
        // once the node exists.
        var legacy_anchor: ?struct { resource: *Resource, name: []const u8 } = null;
        if (!ref_overrides) {
            if (obj.get(id_key)) |idv| {
                if (idv != .string) return error.InvalidSchema;
                const id = idv.string;
                if (!scope.draft.atLeast(.draft2019_09) and id.len > 0 and id[0] == '#') {
                    // Location-independent identifier (draft 7 and earlier).
                    legacy_anchor = .{ .resource = scope.resource, .name = id[1..] };
                } else {
                    const resolved = try uri.resolve(a, scope.base, id);
                    const split = uri.splitFragment(resolved);
                    const base = split.base;
                    if (is_document_root and std.mem.eql(u8, base, scope.resource.uri)) {
                        // Same URI as the document itself: no new resource.
                    } else {
                        const dialect = try self.dialectOf(value, .{ .draft = scope.draft, .vocab = scope.vocab });
                        const res = try a.create(Resource);
                        res.* = .{ .uri = base, .value = value, .draft = dialect.draft, .vocab = dialect.vocab };
                        const gop = try self.resources.getOrPut(a, base);
                        if (!gop.found_existing or gop.value_ptr.*.root == null or is_document_root) gop.value_ptr.* = res;
                        if (is_document_root) {
                            // Also reachable under the document's own URI.
                            scope.resource.root = null;
                            try self.resources.put(a, scope.resource.uri, res);
                        }
                        new_resource = res;
                        scope.resource = res;
                        scope.base = base;
                        scope.draft = dialect.draft;
                        scope.vocab = dialect.vocab;
                    }
                    if (!scope.draft.atLeast(.draft2019_09) and split.fragment.len > 0) {
                        legacy_anchor = .{ .resource = scope.resource, .name = split.fragment };
                    }
                }
            }
        }

        const node = try a.create(Node);
        node.* = .{ .kind = .object, .resource = scope.resource, .location = scope.location };
        try self.nodes.put(a, value, node);
        if (new_resource) |r| r.root = node;
        if (legacy_anchor) |la| try la.resource.anchors.put(a, la.name, node);
        if (is_document_root and scope.resource.root == null) scope.resource.root = node;

        if (scope.draft.atLeast(.draft2019_09) and scope.vocab.core) {
            if (obj.get("$anchor")) |av| {
                if (av != .string) return error.InvalidSchema;
                try scope.resource.anchors.put(a, av.string, node);
            }
            if (scope.draft == .draft2020_12) {
                if (obj.get("$dynamicAnchor")) |av| {
                    if (av != .string) return error.InvalidSchema;
                    try scope.resource.anchors.put(a, av.string, node);
                    try scope.resource.dynamic_anchors.put(a, av.string, node);
                }
            }
            if (scope.draft == .draft2019_09) {
                if (obj.get("$recursiveAnchor")) |av| {
                    if (av == .bool and av.bool and scope.resource.root == node) scope.resource.recursive_anchor = true;
                }
            }
        }

        var kws: std.ArrayList(Keyword) = .empty;
        const d = scope.draft;
        const v = scope.vocab;

        // Definitions are not keywords, but compiling them registers their
        // identifiers and anchors.
        inline for (.{ "definitions", "$defs" }) |defs_key| {
            if (obj.getPtr(defs_key)) |defs| {
                if (defs.* == .object and (defs_key[0] != '$' or d.atLeast(.draft2019_09))) {
                    var it = defs.object.iterator();
                    while (it.next()) |e| {
                        _ = try self.compileSchema(e.value_ptr, try self.childScope(scope, &.{ defs_key, e.key_ptr.* }), false);
                    }
                }
            }
        }

        if (obj.get("$ref")) |rv| {
            if (rv != .string) return error.InvalidSchema;
            const r = try a.create(Ref);
            r.* = .{ .uri = try uri.resolve(a, scope.base, rv.string) };
            try kws.append(a, .{ .ref = r });
        }
        if (ref_overrides) {
            node.keywords = kws.items;
            return node;
        }

        var annots: std.ArrayList(AnnotationKeyword) = .empty;
        {
            var it = obj.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                const unknown = !known_keywords.has(k) and !annotation_keywords.has(k);
                if (annotation_keywords.has(k) or (unknown and scope.draft.atLeast(.draft2019_09))) {
                    try annots.append(a, .{ .keyword = k, .value = e.value_ptr });
                }
            }
        }
        node.annotations = annots.items;

        if (d == .draft2020_12 and v.core) {
            if (obj.get("$dynamicRef")) |rv| {
                if (rv != .string) return error.InvalidSchema;
                const r = try a.create(DynamicRef);
                const resolved = try uri.resolve(a, scope.base, rv.string);
                const frag = uri.splitFragment(resolved).fragment;
                r.* = .{
                    .ref = .{ .uri = resolved },
                    .anchor = if (frag.len > 0 and frag[0] != '/') frag else null,
                };
                try kws.append(a, .{ .dynamic_ref = r });
            }
        }
        if (d == .draft2019_09 and v.core) {
            if (obj.get("$recursiveRef")) |rv| {
                if (rv != .string) return error.InvalidSchema;
                const r = try a.create(Ref);
                r.* = .{ .uri = try uri.resolve(a, scope.base, rv.string) };
                try kws.append(a, .{ .recursive_ref = r });
            }
        }

        // --- validation vocabulary ---
        if (v.validation) {
            if (obj.get("type")) |tv| try kws.append(a, .{ .type = try parseTypes(tv) });
            if (obj.get("enum")) |ev| {
                if (ev != .array) return error.InvalidSchema;
                try kws.append(a, .{ .@"enum" = ev.array.items });
            }
            if (d.atLeast(.draft6)) {
                if (obj.getPtr("const")) |cv| try kws.append(a, .{ .@"const" = cv });
            }
            if (obj.get("multipleOf")) |mv| {
                const n = try parseNum(mv);
                if (n.toF64() <= 0) return error.InvalidSchema;
                try kws.append(a, .{ .multiple_of = n });
            }
            if (d == .draft4) {
                const ex_max = if (obj.get("exclusiveMaximum")) |e| (e == .bool and e.bool) else false;
                const ex_min = if (obj.get("exclusiveMinimum")) |e| (e == .bool and e.bool) else false;
                if (obj.get("maximum")) |mv| try kws.append(a, .{ .maximum = .{ .limit = try parseNum(mv), .exclusive = ex_max } });
                if (obj.get("minimum")) |mv| try kws.append(a, .{ .minimum = .{ .limit = try parseNum(mv), .exclusive = ex_min } });
            } else {
                if (obj.get("maximum")) |mv| try kws.append(a, .{ .maximum = .{ .limit = try parseNum(mv), .exclusive = false } });
                if (obj.get("minimum")) |mv| try kws.append(a, .{ .minimum = .{ .limit = try parseNum(mv), .exclusive = false } });
                if (obj.get("exclusiveMaximum")) |mv| try kws.append(a, .{ .maximum = .{ .limit = try parseNum(mv), .exclusive = true } });
                if (obj.get("exclusiveMinimum")) |mv| try kws.append(a, .{ .minimum = .{ .limit = try parseNum(mv), .exclusive = true } });
            }
            if (obj.get("maxLength")) |x| try kws.append(a, .{ .max_length = try parseCount(x) });
            if (obj.get("minLength")) |x| try kws.append(a, .{ .min_length = try parseCount(x) });
            if (obj.get("pattern")) |pv| {
                if (pv != .string) return error.InvalidSchema;
                try kws.append(a, .{ .pattern = .{ .source = pv.string, .regex = try compileRegex(a, pv.string) } });
            }
            if (obj.get("maxItems")) |x| try kws.append(a, .{ .max_items = try parseCount(x) });
            if (obj.get("minItems")) |x| try kws.append(a, .{ .min_items = try parseCount(x) });
            if (obj.get("uniqueItems")) |x| {
                if (x != .bool) return error.InvalidSchema;
                if (x.bool) try kws.append(a, .unique_items);
            }
            if (obj.get("maxProperties")) |x| try kws.append(a, .{ .max_properties = try parseCount(x) });
            if (obj.get("minProperties")) |x| try kws.append(a, .{ .min_properties = try parseCount(x) });
            if (obj.get("required")) |x| try kws.append(a, .{ .required = try parseStringList(a, x) });
            if (d.atLeast(.draft2019_09)) {
                if (obj.get("dependentRequired")) |x| {
                    if (x != .object) return error.InvalidSchema;
                    var list: std.ArrayList(NamedList) = .empty;
                    var it = x.object.iterator();
                    while (it.next()) |e| try list.append(a, .{ .name = e.key_ptr.*, .list = try parseStringList(a, e.value_ptr.*) });
                    try kws.append(a, .{ .dependent_required = .{ .keyword = "dependentRequired", .deps = list.items } });
                }
            }
        }

        const format_asserts = self.options.format_assertion or v.format_assertion;
        if (obj.get("format")) |fv| {
            if (fv != .string) return error.InvalidSchema;
            if (format_asserts) {
                try kws.append(a, .{ .format = fv.string });
            }
        }
        if (!d.atLeast(.draft2019_09) and self.options.content_assertion and d.atLeast(.draft7)) {
            const enc = obj.get("contentEncoding");
            const mt = obj.get("contentMediaType");
            if (enc != null or mt != null) {
                try kws.append(a, .{ .content = .{
                    .encoding = if (enc) |e| (if (e == .string) e.string else null) else null,
                    .media_type = if (mt) |m| (if (m == .string) m.string else null) else null,
                } });
            }
        }

        // --- applicator vocabulary ---
        if (v.applicator) {
            // Arrays.
            var prefix: []const *Node = &.{};
            var rest: ?*Node = null;
            var has_items = false;
            var prefix_keyword: []const u8 = "prefixItems";
            var rest_keyword: []const u8 = "items";
            if (d == .draft2020_12) {
                if (obj.getPtr("prefixItems")) |pv| {
                    prefix = try self.compileSchemaArray(pv, scope, "prefixItems");
                    has_items = true;
                }
                if (obj.getPtr("items")) |iv| {
                    rest = try self.compileSchema(iv, try self.childScope(scope, &.{"items"}), false);
                    has_items = true;
                }
            } else if (obj.getPtr("items")) |iv| {
                has_items = true;
                if (iv.* == .array) {
                    prefix_keyword = "items";
                    rest_keyword = "additionalItems";
                    prefix = try self.compileSchemaArray(iv, scope, "items");
                    if (obj.getPtr("additionalItems")) |av| {
                        rest = try self.compileSchema(av, try self.childScope(scope, &.{"additionalItems"}), false);
                    }
                } else {
                    rest = try self.compileSchema(iv, try self.childScope(scope, &.{"items"}), false);
                }
            }
            if (d != .draft2020_12 and (obj.get("items") == null or obj.get("items").? != .array)) {
                // Ignored `additionalItems`: compile only to register identifiers.
                if (obj.getPtr("additionalItems")) |av| {
                    _ = try self.compileSchema(av, try self.childScope(scope, &.{"additionalItems"}), false);
                }
            }
            if (has_items) try kws.append(a, .{ .items = .{
                .prefix = prefix,
                .rest = rest,
                .prefix_keyword = prefix_keyword,
                .rest_keyword = rest_keyword,
            } });

            if (d.atLeast(.draft6)) {
                if (obj.getPtr("contains")) |cv| {
                    var min: u64 = 1;
                    var max: ?u64 = null;
                    if (d.atLeast(.draft2019_09) and v.validation) {
                        if (obj.get("minContains")) |x| min = try parseCount(x);
                        if (obj.get("maxContains")) |x| max = try parseCount(x);
                    }
                    try kws.append(a, .{ .contains = .{
                        .node = try self.compileSchema(cv, try self.childScope(scope, &.{"contains"}), false),
                        .min = min,
                        .max = max,
                    } });
                }
            }

            // Objects.
            var prop_names: std.ArrayList([]const u8) = .empty;
            var prop_patterns: std.ArrayList(Regex) = .empty;
            if (obj.getPtr("properties")) |pv| {
                if (pv.* != .object) return error.InvalidSchema;
                var list: std.ArrayList(NamedNode) = .empty;
                var it = pv.object.iterator();
                while (it.next()) |e| {
                    try list.append(a, .{
                        .name = e.key_ptr.*,
                        .node = try self.compileSchema(e.value_ptr, try self.childScope(scope, &.{ "properties", e.key_ptr.* }), false),
                    });
                    try prop_names.append(a, e.key_ptr.*);
                }
                try kws.append(a, .{ .properties = list.items });
            }
            if (obj.getPtr("patternProperties")) |pv| {
                if (pv.* != .object) return error.InvalidSchema;
                var list: std.ArrayList(PatternNode) = .empty;
                var it = pv.object.iterator();
                while (it.next()) |e| {
                    const re = try compileRegex(a, e.key_ptr.*);
                    try list.append(a, .{
                        .source = e.key_ptr.*,
                        .regex = re,
                        .node = try self.compileSchema(e.value_ptr, try self.childScope(scope, &.{ "patternProperties", e.key_ptr.* }), false),
                    });
                    try prop_patterns.append(a, re);
                }
                try kws.append(a, .{ .pattern_properties = list.items });
            }
            if (obj.getPtr("additionalProperties")) |av| {
                try kws.append(a, .{ .additional_properties = .{
                    .node = try self.compileSchema(av, try self.childScope(scope, &.{"additionalProperties"}), false),
                    .names = prop_names.items,
                    .patterns = prop_patterns.items,
                } });
            }
            if (d.atLeast(.draft6)) {
                if (obj.getPtr("propertyNames")) |pv| {
                    try kws.append(a, .{ .property_names = try self.compileSchema(pv, try self.childScope(scope, &.{"propertyNames"}), false) });
                }
            }
            if (d.atLeast(.draft2019_09)) {
                if (obj.getPtr("dependentSchemas")) |dv| {
                    if (dv.* != .object) return error.InvalidSchema;
                    var list: std.ArrayList(NamedNode) = .empty;
                    var it = dv.object.iterator();
                    while (it.next()) |e| {
                        try list.append(a, .{
                            .name = e.key_ptr.*,
                            .node = try self.compileSchema(e.value_ptr, try self.childScope(scope, &.{ "dependentSchemas", e.key_ptr.* }), false),
                        });
                    }
                    try kws.append(a, .{ .dependent_schemas = list.items });
                }
            }
            // `dependencies` was split into `dependentRequired` /
            // `dependentSchemas` in 2019-09; keep honouring it for
            // compatibility.
            if (obj.getPtr("dependencies")) |dv| {
                if (dv.* != .object) return error.InvalidSchema;
                var reqs: std.ArrayList(NamedList) = .empty;
                var schemas: std.ArrayList(NamedNode) = .empty;
                var it = dv.object.iterator();
                while (it.next()) |e| {
                    if (e.value_ptr.* == .array) {
                        try reqs.append(a, .{ .name = e.key_ptr.*, .list = try parseStringList(a, e.value_ptr.*) });
                    } else {
                        try schemas.append(a, .{
                            .name = e.key_ptr.*,
                            .node = try self.compileSchema(e.value_ptr, try self.childScope(scope, &.{ "dependencies", e.key_ptr.* }), false),
                        });
                    }
                }
                if (reqs.items.len > 0) try kws.append(a, .{ .dependent_required = .{ .keyword = "dependencies", .deps = reqs.items } });
                if (schemas.items.len > 0) try kws.append(a, .{ .dependent_schemas = schemas.items });
            }

            // Combinators.
            if (obj.getPtr("allOf")) |x| try kws.append(a, .{ .all_of = try self.compileSchemaArray(x, scope, "allOf") });
            if (obj.getPtr("anyOf")) |x| try kws.append(a, .{ .any_of = try self.compileSchemaArray(x, scope, "anyOf") });
            if (obj.getPtr("oneOf")) |x| try kws.append(a, .{ .one_of = try self.compileSchemaArray(x, scope, "oneOf") });
            if (obj.getPtr("not")) |x| try kws.append(a, .{ .not = try self.compileSchema(x, try self.childScope(scope, &.{"not"}), false) });
            if (d.atLeast(.draft7)) {
                // `then` / `else` without `if` do nothing, but are still
                // compiled so that identifiers inside them are registered.
                var then_node: ?*Node = null;
                var else_node: ?*Node = null;
                if (obj.getPtr("then")) |t| then_node = try self.compileSchema(t, try self.childScope(scope, &.{"then"}), false);
                if (obj.getPtr("else")) |e| else_node = try self.compileSchema(e, try self.childScope(scope, &.{"else"}), false);
                if (obj.getPtr("if")) |x| {
                    const if_node = try self.compileSchema(x, try self.childScope(scope, &.{"if"}), false);
                    try kws.append(a, .{ .conditional = .{ .@"if" = if_node, .then = then_node, .@"else" = else_node } });
                }
            }
        }

        // --- unevaluated vocabulary (must run after everything else) ---
        if (d.atLeast(.draft2019_09) and v.unevaluated) {
            if (obj.getPtr("unevaluatedItems")) |x| {
                try kws.append(a, .{ .unevaluated_items = try self.compileSchema(x, try self.childScope(scope, &.{"unevaluatedItems"}), false) });
                node.uses_unevaluated = true;
            }
            if (obj.getPtr("unevaluatedProperties")) |x| {
                try kws.append(a, .{ .unevaluated_properties = try self.compileSchema(x, try self.childScope(scope, &.{"unevaluatedProperties"}), false) });
                node.uses_unevaluated = true;
            }
        }

        node.keywords = kws.items;
        return node;
    }

    fn compileSchemaArray(self: *Validator, value: *const Value, scope: Scope, key: []const u8) CompileError![]const *Node {
        if (value.* != .array) return error.InvalidSchema;
        const out = try self.alloc().alloc(*Node, value.array.items.len);
        var buf: [20]u8 = undefined;
        for (value.array.items, 0..) |*item, i| {
            const idx = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            out[i] = try self.compileSchema(item, try self.childScope(scope, &.{ key, idx }), false);
        }
        return out;
    }

    // -----------------------------------------------------------------
    // Reference resolution
    // -----------------------------------------------------------------

    fn findResource(self: *Validator, base: []const u8) CompileError!?*Resource {
        if (self.resources.get(base)) |r| return r;
        if (self.documents.get(base)) |doc| {
            _ = self.documents.remove(base);
            return try self.compileDocument(base, doc);
        }
        for (builtin_metaschemas) |m| {
            if (std.mem.eql(u8, m.uri, base)) {
                const doc = try self.alloc().create(Value);
                doc.* = std.json.parseFromSliceLeaky(Value, self.alloc(), m.text, .{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => unreachable,
                };
                return try self.compileDocument(base, doc);
            }
        }
        return null;
    }

    fn resolveUri(self: *Validator, absolute: []const u8) CompileError!*Node {
        const a = self.alloc();
        const split = uri.splitFragment(absolute);
        const res = (try self.findResource(split.base)) orelse return error.UnresolvableReference;
        const fragment = try uri.percentDecode(a, split.fragment);
        if (fragment.len == 0) return res.root orelse error.UnresolvableReference;
        if (fragment[0] != '/') return res.anchors.get(fragment) orelse error.UnresolvableReference;

        // JSON Pointer: walk the resource's raw JSON, tracking `$id`
        // changes so on-demand compiled targets get the right base URI.
        var cur: *const Value = res.value;
        var scope: Scope = .{ .resource = res, .base = res.uri, .draft = res.draft, .vocab = res.vocab, .location = "" };
        if (res.root) |r| scope.location = r.location;
        var it = std.mem.splitScalar(u8, fragment[1..], '/');
        while (it.next()) |raw| {
            const seg = try unescapePointerSegment(a, raw);
            switch (cur.*) {
                .object => |o| {
                    if (self.nodes.get(cur)) |n| {
                        scope.resource = n.resource;
                        scope.base = n.resource.uri;
                        scope.draft = n.resource.draft;
                        scope.vocab = n.resource.vocab;
                    }
                    cur = o.getPtr(seg) orelse return error.UnresolvableReference;
                },
                .array => |arr| {
                    const idx = std.fmt.parseInt(usize, seg, 10) catch return error.UnresolvableReference;
                    if (idx >= arr.items.len) return error.UnresolvableReference;
                    cur = &arr.items[idx];
                },
                else => return error.UnresolvableReference,
            }
            scope = try self.childScope(scope, &.{seg});
        }
        if (self.nodes.get(cur)) |n| return n;
        return self.compileSchema(cur, scope, false);
    }

    fn resolveRef(self: *Validator, r: *Ref) ValidateError!*Node {
        if (r.target) |t| return t;
        const t = try self.resolveUri(r.uri);
        r.target = t;
        return t;
    }
};

/// A compiled schema. Owned by (and valid as long as) its `Validator`.
pub const Schema = struct {
    validator: *Validator,
    root: *Node,

    /// Returns whether `instance` is valid, stopping at the first failure.
    pub fn isValid(self: Schema, instance: Value) ValidateError!bool {
        var arena = std.heap.ArenaAllocator.init(self.validator.gpa);
        defer arena.deinit();
        var ctx: Ctx = .{ .allocator = arena.allocator(), .validator = self.validator, .collect = false };
        return ctx.eval(self.root, &instance, null);
    }

    /// Validates `instance` and collects every error. All returned memory
    /// is owned by `allocator` (an arena is recommended).
    pub fn validate(self: Schema, allocator: Allocator, instance: Value) ValidateError!Result {
        var ctx: Ctx = .{ .allocator = allocator, .validator = self.validator, .collect = true };
        const ok = try ctx.eval(self.root, &instance, null);
        return .{ .valid = ok, .errors = ctx.errors.items };
    }

    /// Validates `instance` and describes the result in one of the standard
    /// output formats, as a JSON value (every output unit has `valid`,
    /// `keywordLocation`, `absoluteKeywordLocation` and `instanceLocation`,
    /// plus `error` or `annotation`). All returned memory is owned by
    /// `allocator` (an arena is recommended).
    pub fn output(self: Schema, allocator: Allocator, instance: Value, format: OutputFormat) ValidateError!Value {
        if (format == .flag) {
            var obj: std.json.ObjectMap = .empty;
            try obj.put(allocator, "valid", .{ .bool = try self.isValid(instance) });
            return .{ .object = obj };
        }
        var ctx: Ctx = .{ .allocator = allocator, .validator = self.validator, .collect = true, .output = true };
        var holder: Unit = .{ .keyword_location = "", .absolute_keyword_location = "", .instance_location = "" };
        ctx.unit = &holder;
        _ = try ctx.eval(self.root, &instance, null);
        const root = holder.children.items[0];
        return switch (format) {
            .flag => unreachable,
            .basic => basicOutput(allocator, root),
            .detailed => (try detailedOutput(allocator, root, true)).?,
            .verbose => verboseOutput(allocator, root),
        };
    }
};

fn unitJson(allocator: Allocator, u: *const Unit, children: ?[]const Value) Allocator.Error!Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(allocator, "valid", .{ .bool = u.valid });
    try obj.put(allocator, "keywordLocation", .{ .string = u.keyword_location });
    try obj.put(allocator, "absoluteKeywordLocation", .{ .string = u.absolute_keyword_location });
    try obj.put(allocator, "instanceLocation", .{ .string = u.instance_location });
    if (u.@"error") |e| try obj.put(allocator, "error", .{ .string = e });
    if (u.annotation) |an| try obj.put(allocator, "annotation", an);
    if (children) |list| if (list.len > 0) {
        var arr: std.json.Array = .init(allocator);
        try arr.appendSlice(list);
        try obj.put(allocator, if (u.valid) "annotations" else "errors", .{ .array = arr });
    };
    return .{ .object = obj };
}

/// The root unit with a flat list: every error of a failed evaluation, or
/// every annotation of a successful one.
fn basicOutput(allocator: Allocator, root: *const Unit) Allocator.Error!Value {
    var list: std.ArrayList(Value) = .empty;
    if (root.valid) try collectAnnotations(allocator, root, &list) else try collectErrors(allocator, root, &list);
    return unitJson(allocator, root, list.items);
}

fn collectErrors(allocator: Allocator, u: *const Unit, list: *std.ArrayList(Value)) Allocator.Error!void {
    if (u.@"error" != null) try list.append(allocator, try unitJson(allocator, u, null));
    // Only failures that caused this one: not those of valid subschemas
    // (e.g. a failed `anyOf` branch next to a passing one) or of `if`.
    for (u.children.items) |c| if (!c.valid and !c.probe_only) try collectErrors(allocator, c, list);
}

fn collectAnnotations(allocator: Allocator, u: *const Unit, list: *std.ArrayList(Value)) Allocator.Error!void {
    for (u.children.items) |c| {
        if (c.annotation != null) {
            try list.append(allocator, try unitJson(allocator, c, null));
        } else if (c.valid) {
            // Failed subschemas keep no annotations.
            try collectAnnotations(allocator, c, list);
        }
    }
}

/// The unit tree reduced to what explains the result, or null if `u`
/// contributes nothing.
fn detailedOutput(allocator: Allocator, u: *const Unit, is_root: bool) Allocator.Error!?Value {
    if (u.annotation != null) return try unitJson(allocator, u, null);
    var kept: std.ArrayList(Value) = .empty;
    for (u.children.items) |c| {
        const relevant = if (u.valid) c.valid else !c.valid and !c.probe_only;
        if (!relevant) continue;
        if (try detailedOutput(allocator, c, false)) |v| try kept.append(allocator, v);
    }
    if (!is_root) {
        if (u.@"error" == null and kept.items.len == 0) return null;
        // A unit that only wraps one other is collapsed into it.
        if (u.@"error" == null and kept.items.len == 1) return kept.items[0];
    }
    return try unitJson(allocator, u, kept.items);
}

fn verboseOutput(allocator: Allocator, u: *const Unit) Allocator.Error!Value {
    var children: std.ArrayList(Value) = .empty;
    for (u.children.items) |c| try children.append(allocator, try verboseOutput(allocator, c));
    return unitJson(allocator, u, children.items);
}

// ---------------------------------------------------------------------------
// Evaluation
// ---------------------------------------------------------------------------

/// Annotations gathered for the current instance location, as needed by
/// `unevaluatedProperties` / `unevaluatedItems`.
const Annotations = struct {
    props: std.StringHashMapUnmanaged(void) = .empty,
    all_props: bool = false,
    items_prefix: usize = 0,
    all_items: bool = false,
    items_set: std.AutoHashMapUnmanaged(usize, void) = .empty,

    fn merge(self: *Annotations, allocator: Allocator, other: *const Annotations) Allocator.Error!void {
        var it = other.props.keyIterator();
        while (it.next()) |k| try self.props.put(allocator, k.*, {});
        self.all_props = self.all_props or other.all_props;
        self.items_prefix = @max(self.items_prefix, other.items_prefix);
        self.all_items = self.all_items or other.all_items;
        var it2 = other.items_set.keyIterator();
        while (it2.next()) |k| try self.items_set.put(allocator, k.*, {});
    }

    fn hasProp(self: *const Annotations, name: []const u8) bool {
        return self.all_props or self.props.contains(name);
    }

    fn hasItem(self: *const Annotations, i: usize) bool {
        return self.all_items or i < self.items_prefix or self.items_set.contains(i);
    }
};

/// One node of the output tree built by `Schema.output`: the evaluation of
/// a subschema (errors and annotations below it), a failed keyword
/// (`error`) or an annotation.
const Unit = struct {
    valid: bool = true,
    keyword_location: []const u8,
    absolute_keyword_location: []const u8,
    instance_location: []const u8,
    @"error": ?[]const u8 = null,
    annotation: ?Value = null,
    children: std.ArrayList(*Unit) = .empty,
    /// A subschema whose failure is not an error of its parent (`if`).
    probe_only: bool = false,
};

const Ctx = struct {
    allocator: Allocator,
    validator: *Validator,
    collect: bool,
    errors: std.ArrayList(Error) = .empty,
    scope: std.ArrayList(*Resource) = .empty,
    path: std.ArrayList(PathSeg) = .empty,
    depth: usize = 0,
    /// Build the `Unit` tree (`Schema.output`): no short-circuiting, and
    /// every applicable subschema is evaluated.
    output: bool = false,
    /// The unit of the subschema being evaluated (output mode).
    unit: ?*Unit = null,
    /// Evaluation path of the subschema being evaluated (when collecting).
    kw_loc: []const u8 = "",
    /// The subschema whose keywords are being evaluated.
    cur_node: ?*const Node = null,
    /// Set by a reference keyword just before evaluating its target.
    via_ref: ?[]const u8 = null,

    fn tracking(ctx: *const Ctx) bool {
        return ctx.collect or ctx.output;
    }

    /// Evaluation path of `node`, entered from the current subschema.
    fn childKwLoc(ctx: *Ctx, node: *const Node) Allocator.Error![]const u8 {
        if (ctx.via_ref) |r| return std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ctx.kw_loc, r });
        const parent = ctx.cur_node orelse return "";
        // Every other applicator reaches a syntactic subschema, whose
        // location extends the parent's.
        if (std.mem.startsWith(u8, node.location, parent.location)) {
            return std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ ctx.kw_loc, node.location[parent.location.len..] });
        }
        return node.location;
    }

    /// Absolute URI of `node` (or of its `keyword`).
    fn absoluteLocation(ctx: *Ctx, node: *const Node, keyword: []const u8) Allocator.Error![]const u8 {
        const res = node.resource;
        var rel = node.location;
        if (res.root) |root| {
            if (std.mem.startsWith(u8, rel, root.location)) rel = rel[root.location.len..];
        }
        if (keyword.len == 0) return std.fmt.allocPrint(ctx.allocator, "{s}#{s}", .{ res.uri, rel });
        return std.fmt.allocPrint(ctx.allocator, "{s}#{s}/{s}", .{ res.uri, rel, keyword });
    }

    fn keywordLocation(ctx: *Ctx, keyword: []const u8) Allocator.Error![]const u8 {
        if (keyword.len == 0) return ctx.kw_loc;
        return std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ctx.kw_loc, keyword });
    }

    /// Adds an annotation unit for `keyword` of `node` (output mode).
    fn annotate(ctx: *Ctx, node: *const Node, keyword: []const u8, value: Value) Allocator.Error!void {
        const parent = ctx.unit orelse return;
        const u = try ctx.allocator.create(Unit);
        u.* = .{
            .keyword_location = try ctx.keywordLocation(keyword),
            .absolute_keyword_location = try ctx.absoluteLocation(node, keyword),
            .instance_location = try ctx.instanceLocation(),
            .annotation = value,
        };
        try parent.children.append(ctx.allocator, u);
    }

    /// Marks the unit of the subschema evaluated last as `probe_only`.
    fn markLastProbeOnly(ctx: *Ctx) void {
        const parent = ctx.unit orelse return;
        if (parent.children.items.len > 0) parent.children.items[parent.children.items.len - 1].probe_only = true;
    }

    fn namesValue(ctx: *Ctx, names: []const []const u8) Allocator.Error!Value {
        var arr: std.json.Array = .init(ctx.allocator);
        for (names) |n| try arr.append(.{ .string = n });
        return .{ .array = arr };
    }

    const PathSeg = union(enum) { key: []const u8, index: usize };

    fn instanceLocation(ctx: *Ctx) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (ctx.path.items) |seg| {
            try out.append(ctx.allocator, '/');
            switch (seg) {
                .key => |k| try appendPointerSegment(ctx.allocator, &out, k),
                .index => |i| try out.print(ctx.allocator, "{d}", .{i}),
            }
        }
        return out.items;
    }

    fn fail(ctx: *Ctx, node: *const Node, keyword: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        if (ctx.output) {
            const parent = ctx.unit orelse return;
            const message = try std.fmt.allocPrint(ctx.allocator, fmt, args);
            if (keyword.len == 0) {
                // The subschema itself (the `false` schema) failed.
                parent.@"error" = message;
                return;
            }
            const u = try ctx.allocator.create(Unit);
            u.* = .{
                .valid = false,
                .keyword_location = try ctx.keywordLocation(keyword),
                .absolute_keyword_location = try ctx.absoluteLocation(node, keyword),
                .instance_location = try ctx.instanceLocation(),
                .@"error" = message,
            };
            try parent.children.append(ctx.allocator, u);
            return;
        }
        if (!ctx.collect) return;
        try ctx.errors.append(ctx.allocator, .{
            .instance_location = try ctx.instanceLocation(),
            .keyword_location = try ctx.keywordLocation(keyword),
            .absolute_keyword_location = try ctx.absoluteLocation(node, keyword),
            .message = try std.fmt.allocPrint(ctx.allocator, fmt, args),
        });
    }

    /// Evaluates `node` against `inst` without recording errors (used for
    /// subschemas whose failure is not itself an error, e.g. in `anyOf`).
    /// In output mode everything is recorded; the output formats decide
    /// what to report.
    fn probe(ctx: *Ctx, node: *Node, inst: *const Value, annot: ?*Annotations) ValidateError!bool {
        const saved = ctx.collect;
        if (!ctx.output) ctx.collect = false;
        defer ctx.collect = saved;
        return ctx.eval(node, inst, annot);
    }

    fn evalAt(ctx: *Ctx, seg: PathSeg, node: *Node, inst: *const Value) ValidateError!bool {
        try ctx.path.append(ctx.allocator, seg);
        defer _ = ctx.path.pop();
        return ctx.eval(node, inst, null);
    }

    fn eval(ctx: *Ctx, node: *Node, inst: *const Value, annot: ?*Annotations) ValidateError!bool {
        // Where this subschema sits on the evaluation path.
        const kw_loc = if (ctx.tracking()) try ctx.childKwLoc(node) else "";
        ctx.via_ref = null;
        const saved_kw_loc = ctx.kw_loc;
        const saved_node = ctx.cur_node;
        const saved_unit = ctx.unit;
        ctx.kw_loc = kw_loc;
        ctx.cur_node = node;
        defer {
            ctx.kw_loc = saved_kw_loc;
            ctx.cur_node = saved_node;
            ctx.unit = saved_unit;
        }
        var unit: ?*Unit = null;
        if (ctx.output) {
            const u = try ctx.allocator.create(Unit);
            u.* = .{
                .keyword_location = kw_loc,
                .absolute_keyword_location = try ctx.absoluteLocation(node, ""),
                .instance_location = try ctx.instanceLocation(),
            };
            if (saved_unit) |parent| try parent.children.append(ctx.allocator, u);
            ctx.unit = u;
            unit = u;
        }
        const valid = try ctx.evalNode(node, inst, annot);
        if (unit) |u| {
            u.valid = valid;
            if (valid) for (node.annotations) |an| try ctx.annotate(node, an.keyword, an.value.*);
        }
        return valid;
    }

    fn evalNode(ctx: *Ctx, node: *Node, inst: *const Value, annot: ?*Annotations) ValidateError!bool {
        switch (node.kind) {
            .always_true => return true,
            .always_false => {
                try ctx.fail(node, "", "no value is allowed here (false schema)", .{});
                return false;
            },
            .object => {},
        }

        ctx.depth += 1;
        defer ctx.depth -= 1;
        if (ctx.depth > ctx.validator.options.max_depth) return error.RecursionLimitExceeded;

        const pushed = ctx.scope.items.len == 0 or ctx.scope.items[ctx.scope.items.len - 1] != node.resource;
        if (pushed) try ctx.scope.append(ctx.allocator, node.resource);
        defer if (pushed) {
            _ = ctx.scope.pop();
        };

        const structured = inst.* == .object or inst.* == .array;
        const need_annot = structured and (annot != null or node.uses_unevaluated);
        var local: Annotations = .{};
        const la: ?*Annotations = if (need_annot) &local else null;

        var valid = true;
        for (node.keywords) |kw| {
            const ok = try ctx.evalKeyword(node, kw, inst, la);
            if (!ok) {
                valid = false;
                if (!ctx.collect) return false;
            }
        }
        if (valid) {
            if (annot) |out| if (need_annot) try out.merge(ctx.allocator, &local);
        }
        return valid;
    }

    fn evalKeyword(ctx: *Ctx, node: *Node, kw: Keyword, inst: *const Value, annot: ?*Annotations) ValidateError!bool {
        const a = ctx.allocator;
        switch (kw) {
            .ref => |r| {
                const target = try ctx.validator.resolveRef(r);
                ctx.via_ref = "$ref";
                return ctx.evalInPlace(target, inst, annot);
            },
            .dynamic_ref => |dr| {
                var target = try ctx.validator.resolveRef(&dr.ref);
                if (dr.anchor) |name| {
                    // Only "bookended" references are dynamic: the initial
                    // target must itself declare the dynamic anchor.
                    if (target.resource.dynamic_anchors.get(name)) |n| {
                        if (n == target) {
                            for (ctx.scope.items) |res| {
                                if (res.dynamic_anchors.get(name)) |found| {
                                    target = found;
                                    break;
                                }
                            }
                        }
                    }
                }
                ctx.via_ref = "$dynamicRef";
                return ctx.evalInPlace(target, inst, annot);
            },
            .recursive_ref => |r| {
                var target = try ctx.validator.resolveRef(r);
                if (target.resource.recursive_anchor and target.resource.root == target) {
                    for (ctx.scope.items) |res| {
                        if (res.recursive_anchor) {
                            target = res.root.?;
                            break;
                        }
                    }
                }
                ctx.via_ref = "$recursiveRef";
                return ctx.evalInPlace(target, inst, annot);
            },
            .type => |ts| {
                if (typeMatches(ts, inst.*, node.resource.draft)) return true;
                try ctx.fail(node, "type", "expected {s}, got {s}", .{ try typeSetName(a, ts), jsonTypeName(inst.*) });
                return false;
            },
            .@"enum" => |values| {
                for (values) |ev| if (jsonEqual(ev, inst.*)) return true;
                try ctx.fail(node, "enum", "value is not one of the allowed values", .{});
                return false;
            },
            .@"const" => |cv| {
                if (jsonEqual(cv.*, inst.*)) return true;
                try ctx.fail(node, "const", "value does not equal the constant", .{});
                return false;
            },
            .multiple_of => |m| {
                const n = numOf(inst.*) orelse return true;
                if (isMultipleOf(n, m)) return true;
                try ctx.fail(node, "multipleOf", "{f} is not a multiple of {f}", .{ n, m });
                return false;
            },
            .maximum => |m| {
                const n = numOf(inst.*) orelse return true;
                const ord = compareNum(n, m.limit);
                if (ord == .lt or (ord == .eq and !m.exclusive)) return true;
                if (m.exclusive) {
                    try ctx.fail(node, "exclusiveMaximum", "{f} is not less than {f}", .{ n, m.limit });
                } else {
                    try ctx.fail(node, "maximum", "{f} is greater than the maximum {f}", .{ n, m.limit });
                }
                return false;
            },
            .minimum => |m| {
                const n = numOf(inst.*) orelse return true;
                const ord = compareNum(n, m.limit);
                if (ord == .gt or (ord == .eq and !m.exclusive)) return true;
                if (m.exclusive) {
                    try ctx.fail(node, "exclusiveMinimum", "{f} is not greater than {f}", .{ n, m.limit });
                } else {
                    try ctx.fail(node, "minimum", "{f} is less than the minimum {f}", .{ n, m.limit });
                }
                return false;
            },
            .max_length => |max| {
                if (inst.* != .string) return true;
                const len = codepointLength(inst.string);
                if (len <= max) return true;
                try ctx.fail(node, "maxLength", "string is longer than {d} characters", .{max});
                return false;
            },
            .min_length => |min| {
                if (inst.* != .string) return true;
                const len = codepointLength(inst.string);
                if (len >= min) return true;
                try ctx.fail(node, "minLength", "string is shorter than {d} characters", .{min});
                return false;
            },
            .pattern => |p| {
                if (inst.* != .string) return true;
                if (try p.regex.isMatchLimited(a, inst.string, ctx.validator.options.regex_step_limit)) return true;
                try ctx.fail(node, "pattern", "string does not match pattern \"{s}\"", .{p.source});
                return false;
            },
            .format => |f| {
                if (try formats.check(a, f, inst.*)) return true;
                try ctx.fail(node, "format", "value is not a valid \"{s}\"", .{f});
                return false;
            },
            .content => |c| {
                if (inst.* != .string) return true;
                var decoded: []const u8 = inst.string;
                if (c.encoding) |enc| {
                    if (std.ascii.eqlIgnoreCase(enc, "base64")) {
                        decoded = formats.decodeBase64(a, inst.string) catch {
                            try ctx.fail(node, "contentEncoding", "string is not valid base64", .{});
                            return false;
                        };
                    }
                }
                if (c.media_type) |mt| {
                    if (std.ascii.eqlIgnoreCase(mt, "application/json")) {
                        _ = std.json.parseFromSliceLeaky(Value, a, decoded, .{}) catch {
                            try ctx.fail(node, "contentMediaType", "string is not valid JSON", .{});
                            return false;
                        };
                    }
                }
                return true;
            },
            .items => |it| {
                if (inst.* != .array) return true;
                const items = inst.array.items;
                var ok = true;
                for (it.prefix, 0..) |p, i| {
                    if (i >= items.len) break;
                    if (!try ctx.evalAt(.{ .index = i }, p, &items[i])) {
                        ok = false;
                        if (!ctx.collect) return false;
                    }
                }
                if (it.rest) |rest| {
                    var i = it.prefix.len;
                    while (i < items.len) : (i += 1) {
                        if (!try ctx.evalAt(.{ .index = i }, rest, &items[i])) {
                            ok = false;
                            if (!ctx.collect) return false;
                        }
                    }
                }
                if (ok) if (annot) |an| {
                    an.items_prefix = @max(an.items_prefix, @min(items.len, it.prefix.len));
                    if (it.rest != null) an.all_items = true;
                };
                if (ok and ctx.output) {
                    // The largest index the prefix applied to, or true if
                    // it applied to every item; true if `rest` applied.
                    const applied = @min(items.len, it.prefix.len);
                    if (applied > 0) {
                        const all = applied == items.len;
                        try ctx.annotate(node, it.prefix_keyword, if (all) .{ .bool = true } else .{ .integer = @intCast(applied - 1) });
                    }
                    if (it.rest != null and items.len > it.prefix.len) try ctx.annotate(node, it.rest_keyword, .{ .bool = true });
                }
                return ok;
            },
            .contains => |c| {
                if (inst.* != .array) return true;
                var count: u64 = 0;
                var matching: std.json.Array = .init(a);
                for (inst.array.items, 0..) |*item, i| {
                    try ctx.path.append(a, .{ .index = i });
                    defer _ = ctx.path.pop();
                    if (try ctx.probe(c.node, item, null)) {
                        count += 1;
                        if (ctx.output) try matching.append(.{ .integer = @intCast(i) });
                        if (annot) |an| {
                            if (node.resource.draft == .draft2020_12) try an.items_set.put(a, i, {});
                        }
                    }
                }
                // 2020-12: the indices `contains` matched.
                if (ctx.output and node.resource.draft == .draft2020_12 and count >= c.min and (c.max == null or count <= c.max.?)) {
                    try ctx.annotate(node, "contains", .{ .array = matching });
                }
                if (count < c.min) {
                    if (c.min == 1) {
                        try ctx.fail(node, "contains", "array does not contain a matching item", .{});
                    } else {
                        try ctx.fail(node, "minContains", "array contains {d} matching items, fewer than {d}", .{ count, c.min });
                    }
                    return false;
                }
                if (c.max) |max| if (count > max) {
                    try ctx.fail(node, "maxContains", "array contains {d} matching items, more than {d}", .{ count, max });
                    return false;
                };
                return true;
            },
            .max_items => |max| {
                if (inst.* != .array or inst.array.items.len <= max) return true;
                try ctx.fail(node, "maxItems", "array has more than {d} items", .{max});
                return false;
            },
            .min_items => |min| {
                if (inst.* != .array or inst.array.items.len >= min) return true;
                try ctx.fail(node, "minItems", "array has fewer than {d} items", .{min});
                return false;
            },
            .unique_items => {
                if (inst.* != .array) return true;
                const items = inst.array.items;
                for (items, 0..) |x, i| {
                    for (items[i + 1 ..], i + 1..) |y, j| {
                        if (jsonEqual(x, y)) {
                            try ctx.fail(node, "uniqueItems", "items at {d} and {d} are equal", .{ i, j });
                            return false;
                        }
                    }
                }
                return true;
            },
            .properties => |props| {
                if (inst.* != .object) return true;
                var ok = true;
                var applied: std.ArrayList([]const u8) = .empty;
                for (props) |p| {
                    const child = inst.object.getPtr(p.name) orelse continue;
                    if (ctx.output) try applied.append(a, p.name);
                    if (try ctx.evalAt(.{ .key = p.name }, p.node, child)) {
                        if (annot) |an| try an.props.put(a, p.name, {});
                    } else {
                        ok = false;
                        if (!ctx.collect) return false;
                    }
                }
                if (ok and ctx.output) try ctx.annotate(node, "properties", try ctx.namesValue(applied.items));
                return ok;
            },
            .pattern_properties => |pats| {
                if (inst.* != .object) return true;
                var ok = true;
                var applied: std.ArrayList([]const u8) = .empty;
                var it = inst.object.iterator();
                while (it.next()) |e| {
                    var counted = false;
                    for (pats) |p| {
                        if (!try p.regex.isMatchLimited(a, e.key_ptr.*, ctx.validator.options.regex_step_limit)) continue;
                        if (ctx.output and !counted) {
                            try applied.append(a, e.key_ptr.*);
                            counted = true;
                        }
                        if (try ctx.evalAt(.{ .key = e.key_ptr.* }, p.node, e.value_ptr)) {
                            if (annot) |an| try an.props.put(a, e.key_ptr.*, {});
                        } else {
                            ok = false;
                            if (!ctx.collect) return false;
                        }
                    }
                }
                if (ok and ctx.output) try ctx.annotate(node, "patternProperties", try ctx.namesValue(applied.items));
                return ok;
            },
            .additional_properties => |ap| {
                if (inst.* != .object) return true;
                var ok = true;
                var applied: std.ArrayList([]const u8) = .empty;
                var it = inst.object.iterator();
                outer: while (it.next()) |e| {
                    const key = e.key_ptr.*;
                    for (ap.names) |n| if (std.mem.eql(u8, n, key)) continue :outer;
                    for (ap.patterns) |*re| if (try re.isMatchLimited(a, key, ctx.validator.options.regex_step_limit)) continue :outer;
                    if (ctx.output) try applied.append(a, key);
                    if (ap.node.kind == .always_false) {
                        try ctx.fail(node, "additionalProperties", "additional property \"{s}\" is not allowed", .{key});
                    } else if (try ctx.evalAt(.{ .key = key }, ap.node, e.value_ptr)) {
                        if (annot) |an| try an.props.put(a, key, {});
                        continue;
                    }
                    ok = false;
                    if (!ctx.collect) return false;
                }
                if (ok and ctx.output) try ctx.annotate(node, "additionalProperties", try ctx.namesValue(applied.items));
                return ok;
            },
            .property_names => |pn| {
                if (inst.* != .object) return true;
                var ok = true;
                for (inst.object.keys()) |key| {
                    const key_value: Value = .{ .string = key };
                    if (!try ctx.probe(pn, &key_value, null)) {
                        try ctx.fail(node, "propertyNames", "property name \"{s}\" is invalid", .{key});
                        ok = false;
                        if (!ctx.collect) return false;
                    }
                }
                return ok;
            },
            .required => |names| {
                if (inst.* != .object) return true;
                var ok = true;
                for (names) |n| {
                    if (!inst.object.contains(n)) {
                        try ctx.fail(node, "required", "required property \"{s}\" is missing", .{n});
                        ok = false;
                        if (!ctx.collect) return false;
                    }
                }
                return ok;
            },
            .dependent_required => |dr| {
                if (inst.* != .object) return true;
                var ok = true;
                for (dr.deps) |dep| {
                    if (!inst.object.contains(dep.name)) continue;
                    for (dep.list) |n| {
                        if (!inst.object.contains(n)) {
                            try ctx.fail(node, dr.keyword, "property \"{s}\" is required when \"{s}\" is present", .{ n, dep.name });
                            ok = false;
                            if (!ctx.collect) return false;
                        }
                    }
                }
                return ok;
            },
            .dependent_schemas => |deps| {
                if (inst.* != .object) return true;
                var ok = true;
                for (deps) |dep| {
                    if (!inst.object.contains(dep.name)) continue;
                    if (!try ctx.evalInPlace(dep.node, inst, annot)) {
                        ok = false;
                        if (!ctx.collect) return false;
                    }
                }
                return ok;
            },
            .max_properties => |max| {
                if (inst.* != .object or inst.object.count() <= max) return true;
                try ctx.fail(node, "maxProperties", "object has more than {d} properties", .{max});
                return false;
            },
            .min_properties => |min| {
                if (inst.* != .object or inst.object.count() >= min) return true;
                try ctx.fail(node, "minProperties", "object has fewer than {d} properties", .{min});
                return false;
            },
            .all_of => |nodes| {
                var ok = true;
                for (nodes) |n| {
                    if (!try ctx.evalInPlace(n, inst, annot)) {
                        ok = false;
                        if (!ctx.collect) return false;
                    }
                }
                return ok;
            },
            .any_of => |nodes| {
                var ok = false;
                for (nodes) |n| {
                    if (try ctx.probeInPlace(n, inst, annot)) {
                        ok = true;
                        // Keep going only if later branches may still add
                        // annotations (for `unevaluated*`, or the output).
                        if (annot == null and !ctx.output) break;
                    }
                }
                if (!ok) try ctx.fail(node, "anyOf", "value does not match any of the anyOf schemas", .{});
                return ok;
            },
            .one_of => |nodes| {
                var matched: usize = 0;
                var first: usize = 0;
                var second: usize = 0;
                for (nodes, 0..) |n, i| {
                    if (try ctx.probeInPlace(n, inst, annot)) {
                        matched += 1;
                        if (matched == 1) first = i else if (matched == 2) second = i;
                        if (matched > 1 and annot == null and !ctx.output) break;
                    }
                }
                if (matched == 1) return true;
                if (matched == 0) {
                    try ctx.fail(node, "oneOf", "value does not match any of the oneOf schemas", .{});
                } else {
                    try ctx.fail(node, "oneOf", "value matches more than one oneOf schema ({d} and {d})", .{ first, second });
                }
                return false;
            },
            .not => |n| {
                if (!try ctx.probe(n, inst, null)) return true;
                try ctx.fail(node, "not", "value must not match the \"not\" schema", .{});
                return false;
            },
            .conditional => |c| {
                var if_annot: Annotations = .{};
                const if_valid = try ctx.probe(c.@"if", inst, if (annot != null) &if_annot else null);
                ctx.markLastProbeOnly();
                if (if_valid) {
                    if (annot) |an| try an.merge(a, &if_annot);
                    if (c.then) |t| return ctx.evalInPlace(t, inst, annot);
                } else {
                    if (c.@"else") |e| return ctx.evalInPlace(e, inst, annot);
                }
                return true;
            },
            .unevaluated_items => |ui| {
                if (inst.* != .array) return true;
                const an = annot.?;
                var ok = true;
                for (inst.array.items, 0..) |*item, i| {
                    if (an.hasItem(i)) continue;
                    if (ui.kind == .always_false) {
                        try ctx.fail(node, "unevaluatedItems", "unevaluated item {d} is not allowed", .{i});
                    } else if (try ctx.evalAt(.{ .index = i }, ui, item)) continue;
                    ok = false;
                    if (!ctx.collect) return false;
                }
                if (ok) an.all_items = true;
                if (ok and ctx.output) try ctx.annotate(node, "unevaluatedItems", .{ .bool = true });
                return ok;
            },
            .unevaluated_properties => |up| {
                if (inst.* != .object) return true;
                const an = annot.?;
                var ok = true;
                var applied: std.ArrayList([]const u8) = .empty;
                var it = inst.object.iterator();
                while (it.next()) |e| {
                    if (an.hasProp(e.key_ptr.*)) continue;
                    if (ctx.output) try applied.append(a, e.key_ptr.*);
                    if (up.kind == .always_false) {
                        try ctx.fail(node, "unevaluatedProperties", "unevaluated property \"{s}\" is not allowed", .{e.key_ptr.*});
                    } else if (try ctx.evalAt(.{ .key = e.key_ptr.* }, up, e.value_ptr)) continue;
                    ok = false;
                    if (!ctx.collect) return false;
                }
                if (ok) an.all_props = true;
                if (ok and ctx.output) try ctx.annotate(node, "unevaluatedProperties", try ctx.namesValue(applied.items));
                return ok;
            },
        }
    }

    /// Applies `target` to the same instance location, merging its
    /// annotations on success.
    fn evalInPlace(ctx: *Ctx, target: *Node, inst: *const Value, annot: ?*Annotations) ValidateError!bool {
        var child: Annotations = .{};
        const ok = try ctx.eval(target, inst, if (annot != null) &child else null);
        if (ok) if (annot) |an| try an.merge(ctx.allocator, &child);
        return ok;
    }

    fn probeInPlace(ctx: *Ctx, target: *Node, inst: *const Value, annot: ?*Annotations) ValidateError!bool {
        const saved = ctx.collect;
        ctx.collect = false;
        defer ctx.collect = saved;
        return ctx.evalInPlace(target, inst, annot);
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn compileRegex(allocator: Allocator, pattern: []const u8) CompileError!Regex {
    return Regex.compile(allocator, pattern) catch |err| switch (err) {
        error.InvalidRegex => error.InvalidSchema,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn parseTypes(v: Value) CompileError!TypeSet {
    var ts: TypeSet = .{};
    switch (v) {
        .string => |s| try addType(&ts, s),
        .array => |arr| for (arr.items) |item| {
            if (item != .string) return error.InvalidSchema;
            try addType(&ts, item.string);
        },
        else => return error.InvalidSchema,
    }
    return ts;
}

fn addType(ts: *TypeSet, name: []const u8) CompileError!void {
    inline for (.{ "null", "boolean", "object", "array", "number", "string", "integer" }) |t| {
        if (std.mem.eql(u8, name, t)) {
            @field(ts, t) = true;
            return;
        }
    }
    return error.InvalidSchema;
}

fn typeSetName(allocator: Allocator, ts: TypeSet) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    inline for (.{ "null", "boolean", "object", "array", "number", "string", "integer" }) |t| {
        if (@field(ts, t)) {
            if (out.items.len > 0) try out.appendSlice(allocator, " or ");
            try out.appendSlice(allocator, t);
        }
    }
    return out.items;
}

fn jsonTypeName(v: Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "boolean",
        .integer, .float, .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn isInteger(v: Value) bool {
    return switch (v) {
        .integer => true,
        .float => |f| std.math.isFinite(f) and @floor(f) == f,
        .number_string => |s| blk: {
            if (std.mem.indexOfAny(u8, s, ".eE") == null) break :blk true;
            const f = std.fmt.parseFloat(f64, s) catch break :blk false;
            break :blk std.math.isFinite(f) and @floor(f) == f;
        },
        else => false,
    };
}

fn typeMatches(ts: TypeSet, v: Value, draft: Draft) bool {
    return switch (v) {
        .null => ts.null,
        .bool => ts.boolean,
        // Draft 4 predates "1.0 is an integer"; only integer literals count.
        .float => ts.number or (ts.integer and draft != .draft4 and isInteger(v)),
        .integer, .number_string => ts.number or (ts.integer and isInteger(v)),
        .string => ts.string,
        .array => ts.array,
        .object => ts.object,
    };
}

fn parseNum(v: Value) CompileError!Num {
    return numOf(v) orelse error.InvalidSchema;
}

fn numOf(v: Value) ?Num {
    return switch (v) {
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        // Integers beyond i64 (std.json keeps them as strings) stay exact
        // while they fit in 256 bits.
        .number_string => |s| if (std.fmt.parseInt(i256, s, 10)) |i|
            .{ .int = i }
        else |_|
            .{ .float = std.fmt.parseFloat(f64, s) catch return null },
        else => null,
    };
}

fn parseCount(v: Value) CompileError!u64 {
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else error.InvalidSchema,
        .float => |f| if (f >= 0 and @floor(f) == f) @intFromFloat(@min(f, 1.8e19)) else error.InvalidSchema,
        else => error.InvalidSchema,
    };
}

fn parseStringList(allocator: Allocator, v: Value) CompileError![]const []const u8 {
    if (v != .array) return error.InvalidSchema;
    const out = try allocator.alloc([]const u8, v.array.items.len);
    for (v.array.items, 0..) |item, i| {
        if (item != .string) return error.InvalidSchema;
        out[i] = item.string;
    }
    return out;
}

fn compareNum(a: Num, b: Num) std.math.Order {
    return switch (a) {
        .int => |x| switch (b) {
            .int => |y| std.math.order(x, y),
            .float => |y| compareIntFloat(x, y),
        },
        .float => |x| switch (b) {
            .int => |y| compareIntFloat(y, x).invert(),
            .float => |y| std.math.order(x, y),
        },
    };
}

/// Exact comparison of an integer with a float (converting the integer to
/// f64 would round, e.g. 2^64 - 1 to 2^64).
pub fn compareIntFloat(x: i256, y: f64) std.math.Order {
    if (std.math.isNan(y)) return .lt; // unreachable for JSON; any stable answer
    // Every i256 lies in [-2^255, 2^255), both ends exact in f64.
    if (y >= 0x1p255) return .lt;
    if (y < -0x1p255) return .gt;
    const floor_y = @floor(y);
    const yi = integralToInt(floor_y);
    if (x != yi) return std.math.order(x, yi);
    return if (floor_y == y) .eq else .lt;
}

// LLVM cannot lower int<->float conversions of 256-bit integers on every
// target, so these two go through i128 or the float's bits.

/// `y` must be an integer value with |y| < 2^255.
pub fn integralToInt(y: f64) i256 {
    if (@abs(y) < 0x1p127) return @as(i128, @intFromFloat(y));
    // |y| >= 2^127: mantissa * 2^(exponent - 52), an exact shift.
    const bits: u64 = @bitCast(y);
    const exponent: u9 = @intCast(((bits >> 52) & 0x7ff) - 1075);
    const mantissa: i256 = @intCast((bits & ((1 << 52) - 1)) | (1 << 52));
    const magnitude = mantissa << @intCast(exponent);
    return if (y < 0) -magnitude else magnitude;
}

/// Nearest f64 (up to a rounding step for values beyond i128).
pub fn intToF64(x: i256) f64 {
    if (std.math.cast(i128, x)) |small| return @floatFromInt(small);
    const shift = 128;
    const high: i128 = @intCast(x >> shift);
    return std.math.ldexp(@as(f64, @floatFromInt(high)), shift);
}

fn isMultipleOf(n: Num, m: Num) bool {
    if (n == .int and m == .int) {
        if (m.int == 1 or m.int == -1) return true; // avoids @rem(minInt, -1)
        return @rem(n.int, m.int) == 0;
    }
    const x = n.toF64();
    const y = m.toF64();
    if (y == 0) return false;
    const q = x / y;
    // The quotient overflowed: fall back to the (exact) floating remainder.
    if (!std.math.isFinite(q)) return std.math.isFinite(x) and @rem(x, y) == 0;
    const r = @round(q);
    return @abs(q - r) <= 1e-9 * @max(1.0, @abs(q));
}

fn codepointLength(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// Structural JSON equality (numbers compare by value, objects ignore
/// key order).
pub fn jsonEqual(a: Value, b: Value) bool {
    const an = numOf(a);
    const bn = numOf(b);
    if (an != null and bn != null) return compareNum(an.?, bn.?) == .eq;
    if (an != null or bn != null) return false;
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (b != .array or b.array.items.len != x.items.len) break :blk false;
            for (x.items, b.array.items) |p, q| if (!jsonEqual(p, q)) break :blk false;
            break :blk true;
        },
        .object => |x| blk: {
            if (b != .object or b.object.count() != x.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |e| {
                const other = b.object.get(e.key_ptr.*) orelse break :blk false;
                if (!jsonEqual(e.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
        .integer, .float, .number_string => unreachable,
    };
}

fn appendPointerSegment(allocator: Allocator, out: *std.ArrayList(u8), seg: []const u8) Allocator.Error!void {
    for (seg) |c| switch (c) {
        '~' => try out.appendSlice(allocator, "~0"),
        '/' => try out.appendSlice(allocator, "~1"),
        else => try out.append(allocator, c),
    };
}

fn unescapePointerSegment(allocator: Allocator, seg: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, seg, '~') == null) return seg;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < seg.len) : (i += 1) {
        if (seg[i] == '~' and i + 1 < seg.len and seg[i + 1] == '0') {
            try out.append(allocator, '~');
            i += 1;
        } else if (seg[i] == '~' and i + 1 < seg.len and seg[i + 1] == '1') {
            try out.append(allocator, '/');
            i += 1;
        } else {
            try out.append(allocator, seg[i]);
        }
    }
    return out.items;
}

test "validator: basic keywords and error collection" {
    var v = Validator.init(std.testing.allocator, .{});
    defer v.deinit();
    const schema = try v.compileJson(
        \\{"type": "object", "required": ["age"],
        \\ "properties": {"age": {"type": "integer", "minimum": 0}, "name": {"type": "string", "minLength": 2}}}
    );
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const good = try std.json.parseFromSliceLeaky(Value, a, "{\"age\": 3, \"name\": \"Bo\"}", .{});
    try std.testing.expect(try schema.isValid(good));

    const bad = try std.json.parseFromSliceLeaky(Value, a, "{\"age\": -1, \"name\": \"B\"}", .{});
    const result = try schema.validate(a, bad);
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(@as(usize, 2), result.errors.len);
    try std.testing.expectEqualStrings("/age", result.errors[0].instance_location);
    try std.testing.expectEqualStrings("/properties/age/minimum", result.errors[0].keyword_location);
}

test "validator: remote documents, metaschema checks and dialects" {
    var v = Validator.init(std.testing.allocator, .{});
    defer v.deinit();
    try v.addDocumentJson("http://example.com/defs.json",
        \\{"$defs": {"positive": {"type": "integer", "exclusiveMinimum": 0}}}
    );
    const schema = try v.compileJson(
        \\{"$id": "http://example.com/root.json", "items": {"$ref": "defs.json#/$defs/positive"}}
    );
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(try schema.isValid(try std.json.parseFromSliceLeaky(Value, a, "[1, 2]", .{})));
    try std.testing.expect(!try schema.isValid(try std.json.parseFromSliceLeaky(Value, a, "[1, 0]", .{})));

    try std.testing.expect(try v.isValidSchema(try std.json.parseFromSliceLeaky(Value, a, "{\"minLength\": 1}", .{})));
    try std.testing.expect(!try v.isValidSchema(try std.json.parseFromSliceLeaky(Value, a, "{\"minLength\": -1}", .{})));

    // Draft 4 semantics are picked up from `$schema`.
    const d4 = try v.compileJson(
        \\{"$schema": "http://json-schema.org/draft-04/schema#", "maximum": 3, "exclusiveMaximum": true}
    );
    try std.testing.expect(!try d4.isValid(.{ .integer = 3 }));
    try std.testing.expect(try d4.isValid(.{ .integer = 2 }));
}

test "validator: output formats and locations through references" {
    var v = Validator.init(std.testing.allocator, .{});
    defer v.deinit();
    const schema = try v.compileJson(
        \\{
        \\  "$id": "https://example.com/order.json",
        \\  "title": "Order",
        \\  "properties": {
        \\    "qty": {"$ref": "#/$defs/count"},
        \\    "code": {"anyOf": [{"type": "integer"}, {"type": "string", "description": "a code"}]},
        \\    "kind": {"if": {"const": "x"}, "then": {"minLength": 5}}
        \\  },
        \\  "$defs": {"count": {"type": "integer", "minimum": 1}}
        \\}
    );
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Errors: the evaluation path goes through `$ref`; the absolute location
    // is where the keyword really is.
    const bad = try std.json.parseFromSliceLeaky(Value, a,
        \\{"qty": 0, "code": "c", "kind": "y"}
    , .{});
    const result = try schema.validate(a, bad);
    try std.testing.expectEqual(@as(usize, 1), result.errors.len);
    try std.testing.expectEqualStrings("/properties/qty/$ref/minimum", result.errors[0].keyword_location);
    try std.testing.expectEqualStrings("https://example.com/order.json#/$defs/count/minimum", result.errors[0].absolute_keyword_location);
    try std.testing.expectEqualStrings("/qty", result.errors[0].instance_location);

    const flag = try schema.output(a, bad, .flag);
    try std.testing.expectEqual(false, flag.object.get("valid").?.bool);
    try std.testing.expectEqual(@as(usize, 1), flag.object.count());

    // basic: only the error that caused the failure (the failed `if` and the
    // failed `anyOf` branch next to a passing one are not errors).
    const basic = try schema.output(a, bad, .basic);
    const errors = basic.object.get("errors").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), errors.len);
    try std.testing.expectEqualStrings("/properties/qty/$ref/minimum", errors[0].object.get("keywordLocation").?.string);
    try std.testing.expect(errors[0].object.get("error") != null);
    try std.testing.expect(basic.object.get("annotations") == null);

    // detailed: the chain properties/qty -> $ref -> minimum is collapsed.
    const detailed = try schema.output(a, bad, .detailed);
    const d_errors = detailed.object.get("errors").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), d_errors.len);
    try std.testing.expectEqualStrings("/properties/qty/$ref/minimum", d_errors[0].object.get("keywordLocation").?.string);

    // verbose: every evaluated subschema, including valid ones.
    const verbose = try schema.output(a, bad, .verbose);
    try std.testing.expect(verbose.object.get("errors").?.array.items.len > 1);

    // Valid: annotations from every passing subschema (here the second
    // `anyOf` branch's description), none from failed ones.
    const good = try std.json.parseFromSliceLeaky(Value, a,
        \\{"qty": 2, "code": "c", "kind": "y"}
    , .{});
    const annotated = try schema.output(a, good, .basic);
    try std.testing.expect(annotated.object.get("valid").?.bool);
    var saw_title = false;
    var saw_description = false;
    var saw_properties = false;
    for (annotated.object.get("annotations").?.array.items) |u| {
        const loc = u.object.get("keywordLocation").?.string;
        if (std.mem.eql(u8, loc, "/title")) saw_title = true;
        if (std.mem.eql(u8, loc, "/properties/code/anyOf/1/description")) {
            saw_description = true;
            try std.testing.expectEqualStrings("/code", u.object.get("instanceLocation").?.string);
        }
        if (std.mem.eql(u8, loc, "/properties")) {
            saw_properties = true;
            try std.testing.expectEqual(@as(usize, 3), u.object.get("annotation").?.array.items.len);
        }
    }
    try std.testing.expect(saw_title and saw_description and saw_properties);
}
