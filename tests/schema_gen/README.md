# Schema generation snapshots

`<case>/<draft>.schema.json` is the output of `toSchema` for the
case `<case>` defined in [`../schema_gen.zig`](../schema_gen.zig), generated
for `<draft>` (`draft4`, `draft6`, `draft7`, `draft2019-09`, `draft2020-12`).

- `zig build test-schema-gen` (also part of `zig build test`) fails if the
  generator output differs from these files, or if a file is not a valid
  schema for its draft's metaschema.
- After an intentional generator change, run
  `zig build test-schema-gen -Dupdate-snapshots` and review the diff here.

Draft differences worth checking in review: draft 4 expresses
`exclusiveMinimum` / `exclusiveMaximum` as booleans next to `minimum` /
`maximum` (the stricter bound wins), every file starts with the draft's
`$schema` URI, and a root id (`with_id`) is spelled `id` in draft 4 and
`$id` from draft 6 on.
