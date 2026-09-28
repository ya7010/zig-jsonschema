//! Runs the official JSON-Schema-Test-Suite
//! (https://github.com/json-schema-org/JSON-Schema-Test-Suite) against the
//! runtime validator, and exits non-zero if any case fails.
//!
//! - Covers drafts 4, 6, 7, 2019-09 and 2020-12: the required tests in
//!   `tests/<draft>/*.json` and the optional ones in `tests/<draft>/optional/`
//!   (with `format` asserted for `optional/format/`).
//! - Remote documents in `remotes/` are registered under
//!   `http://localhost:1234/...`, as the suite expects.
//! - Every case is checked through both `isValid` and `validate`, which must
//!   agree (and `validate` must report at least one error when invalid).
//!
//! Run with `zig build test-suite`; add `-Dsuite-verbose` to list every
//! failing case.

const std = @import("std");
const js = @import("zig_jsonschema");
const suite_options = @import("suite_options");

const Io = std.Io;
const Dir = std.Io.Dir;
const Value = std.json.Value;

const drafts = [_]struct { dir: []const u8, draft: js.Draft }{
    .{ .dir = "draft4", .draft = .draft4 },
    .{ .dir = "draft6", .draft = .draft6 },
    .{ .dir = "draft7", .draft = .draft7 },
    .{ .dir = "draft2019-09", .draft = .draft2019_09 },
    .{ .dir = "draft2020-12", .draft = .draft2020_12 },
};

const Remote = struct { url: []const u8, value: Value };

const Stats = struct {
    passed: usize = 0,
    failed: usize = 0,
};

const Suite = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    root: Dir,
    out: *Io.Writer,
    remotes: []const Remote = &.{},
    /// Failure lines printed so far (capped unless verbose).
    printed: usize = 0,
};

const max_printed_failures = 50;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var out_buf: [4096]u8 = undefined;
    var out_writer = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_writer.interface;

    var s: Suite = .{
        .gpa = gpa,
        .arena = arena_state.allocator(),
        .io = io,
        .root = try Dir.cwd().openDir(io, suite_options.suite_dir, .{}),
        .out = out,
    };
    defer s.root.close(io);
    s.remotes = try loadRemotes(&s);

    var total_failed: usize = 0;
    var total: usize = 0;
    for (drafts) |d| {
        var required: Stats = .{};
        var optional: Stats = .{};
        const base = try std.fmt.allocPrint(s.arena, "tests/{s}", .{d.dir});
        for (try listJson(&s, base)) |name| {
            try runFile(&s, d.dir, name, d.draft, false, &required);
        }
        for ([_][]const u8{ "optional", "optional/format" }) |sub| {
            const sub_dir = try std.fmt.allocPrint(s.arena, "{s}/{s}", .{ base, sub });
            for (try listJson(&s, sub_dir)) |name| {
                const rel = try std.fmt.allocPrint(s.arena, "{s}/{s}", .{ sub, name });
                try runFile(&s, d.dir, rel, d.draft, true, &optional);
            }
        }
        try out.print("{s:<13} required {d:>4}/{d:<4}  optional {d:>4}/{d:<4}\n", .{
            d.dir,
            required.passed,
            required.passed + required.failed,
            optional.passed,
            optional.passed + optional.failed,
        });
        total_failed += required.failed + optional.failed;
        total += required.passed + required.failed + optional.passed + optional.failed;
    }

    if (total_failed > 0) {
        try out.print("JSON-Schema-Test-Suite: {d} of {d} cases FAILED\n", .{ total_failed, total });
        try out.flush();
        std.process.exit(1);
    }
    try out.print("JSON-Schema-Test-Suite: all {d} cases passed\n", .{total});
    try out.flush();
}

fn loadRemotes(s: *Suite) ![]const Remote {
    var list: std.ArrayList(Remote) = .empty;
    var dir = try s.root.openDir(s.io, "remotes", .{ .iterate = true });
    defer dir.close(s.io);
    var walker = try dir.walk(s.gpa);
    defer walker.deinit();
    while (try walker.next(s.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".json")) continue;
        const text = try dir.readFileAlloc(s.io, entry.path, s.arena, .limited(1 << 20));
        const value = try std.json.parseFromSliceLeaky(Value, s.arena, text, .{});
        const rel = try s.arena.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, rel, '\\', '/');
        try list.append(s.arena, .{
            .url = try std.fmt.allocPrint(s.arena, "http://localhost:1234/{s}", .{rel}),
            .value = value,
        });
    }
    return list.items;
}

fn listJson(s: *Suite, sub: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var dir = s.root.openDir(s.io, sub, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => |e| return e,
    };
    defer dir.close(s.io);
    var it = dir.iterate();
    while (try it.next(s.io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
            try names.append(s.arena, try s.arena.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names.items;
}

fn runFile(s: *Suite, draft_dir: []const u8, rel: []const u8, draft: js.Draft, optional: bool, stats: *Stats) !void {
    const path = try std.fmt.allocPrint(s.arena, "tests/{s}/{s}", .{ draft_dir, rel });
    const text = try s.root.readFileAlloc(s.io, path, s.arena, .limited(4 << 20));
    const groups = try std.json.parseFromSliceLeaky(Value, s.arena, text, .{});
    // `optional/format-assertion.json` enables assertion through the
    // metaschema's vocabulary instead.
    const assert_format = std.mem.startsWith(u8, rel, "optional/format/");

    for (groups.array.items) |group| {
        const description = group.object.get("description").?.string;
        var v = js.Validator.init(s.gpa, .{
            .default_draft = draft,
            .format_assertion = assert_format,
            .content_assertion = optional,
        });
        defer v.deinit();
        for (s.remotes) |r| try v.addDocument(r.url, r.value);

        const compiled = v.compile(group.object.get("schema").?);
        for (group.object.get("tests").?.array.items) |case| {
            const expected = case.object.get("valid").?.bool;
            const problem = try checkCase(s, compiled, case.object.get("data").?, expected);
            if (problem == null) {
                stats.passed += 1;
                continue;
            }
            stats.failed += 1;
            if (suite_options.verbose or s.printed < max_printed_failures) {
                s.printed += 1;
                try s.out.print("FAIL {s}/{s}: {s}: {s} (expected {s}: {s})\n", .{
                    draft_dir,
                    rel,
                    description,
                    case.object.get("description").?.string,
                    if (expected) "valid" else "invalid",
                    problem.?,
                });
            }
        }
    }
}

/// Returns null if the case passes, or a description of what went wrong.
fn checkCase(s: *Suite, compiled: js.CompileError!js.CompiledSchema, data: Value, expected: bool) !?[]const u8 {
    const schema = compiled catch |err| return @errorName(err);
    const ok = schema.isValid(data) catch |err| return @errorName(err);
    if (ok != expected) return "wrong result";

    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();
    const res = schema.validate(arena.allocator(), data) catch |err| return @errorName(err);
    if (res.valid != ok) return "validate() disagrees with isValid()";
    if (!res.valid and res.errors.len == 0) return "invalid result without errors";
    return null;
}
