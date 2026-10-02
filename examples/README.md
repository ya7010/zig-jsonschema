# Examples

Each example is a small program that prints what it does. Run one with
`zig build run-<name>`, or all of them with `zig build examples`.

| Example | What it shows |
|---|---|
| [`schema.zig`](schema.zig) | Declaring constraints with `Schema()` and generating a schema, for 2020-12 and draft 7. |
| [`deserialize.zig`](deserialize.zig) | `fromJson`: decoding into a plain struct, defaults, and collecting every error. |
| [`validate.zig`](validate.zig) | `validate`: checking a value built in Zig against its declaration. |
| [`objects.zig`](objects.zig) | Nested structs, arrays of structs, optional objects, `minProperties`, `unknown_fields`, explicit `additionalProperties: true` / `false` (also on the root) against `unknown_fields` with a table of what is accepted, shared `$defs` against inlining, recursive types, flattened structs (`.flatten`). |
| [`unions.zig`](unions.zig) | Tagged unions as `oneOf`: std.json-style `{"variant": payload}`, internally tagged unions (`json_discriminator`), both also as `if` / `then` (`union_encoding`), untagged unions as `anyOf` (`json_untagged`), void variants, a recursive expression tree. |
| [`extra.zig`](extra.zig) | `.extra` for keywords the constraint fields don't cover: conditional requirements with `allOf` + `if` / `then`, `enum`, enforced by `fromJson` through the runtime validator, reusing the compiled schema across documents with a `Decoder`. |
| [`custom.zig`](custom.zig) | A type that writes its own schema (`pub fn jsonSchema`) and decodes it (`jsonParseFromValue`): a color as `"#rrggbb"`, a pair embedding another type's schema with `schemaFor`. |
| [`types.zig`](types.zig) | Integer ranges (`u8` is 0..255), reusable constrained types (`const Email = Schema(...)`), integer newtypes (`enum(u64) { _ }`), defaults, how numbers and strings are checked. |
| [`options.zig`](options.zig) | `SchemaOptions` shared by `toSchema` and `fromJson`: `field_naming`, `unknown_fields`, `$id`, other drafts, `emit_schema_uri`, `reuse_definitions` (`union_encoding` is shown in `unions.zig`). |
| [`runtime.zig`](runtime.zig) | The runtime `Validator` for any schema document: `$ref` to registered documents, `isValid` / `validate` with error locations, the `flag` / `basic` / `detailed` output formats, metaschema checks, draft 4, and the regex step limit. |
