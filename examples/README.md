# Examples

Each example is a small program that prints what it does. Run one with
`zig build run-<name>`, or all of them with `zig build examples`.

| Example | What it shows |
|---|---|
| [`schema.zig`](schema.zig) | Declaring constraints with `Schema()` and generating a schema, for 2020-12 and draft 7. |
| [`deserialize.zig`](deserialize.zig) | `fromJson`: decoding into a plain struct, defaults, and collecting every error. |
| [`validate.zig`](validate.zig) | `validate`: checking a value built in Zig against its declaration. |
| [`objects.zig`](objects.zig) | Nested structs, arrays of structs, optional objects, `minProperties`, `unknown_fields`, explicit `additionalProperties: true` / `false` (also on the root) against `unknown_fields` with a table of what is accepted, shared `$defs` against inlining, recursive types. |
| [`unions.zig`](unions.zig) | Tagged unions as `oneOf`: std.json-style `{"variant": payload}`, internally tagged unions (`json_discriminator`), void variants, a recursive expression tree. |
| [`types.zig`](types.zig) | Integer ranges (`u8` is 0..255), reusable constrained types (`const Email = Schema(...)`), integer newtypes (`enum(u64) { _ }`), defaults, how numbers and strings are checked. |
| [`options.zig`](options.zig) | `SchemaOptions` shared by `toSchema` and `fromJson`: `field_naming`, `unknown_fields`, `$id`, other drafts, `emit_schema_uri`, `reuse_definitions`. |
| [`runtime.zig`](runtime.zig) | The runtime `Validator` for any schema document: `$ref` to registered documents, `isValid` / `validate` with error locations, the `flag` / `basic` / `detailed` output formats, metaschema checks, draft 4, and the regex step limit. |
