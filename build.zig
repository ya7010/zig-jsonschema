const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zig_jsonschema", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const examples_step = b.step("examples", "Build and run every example");

    const example_names = [_][]const u8{ "schema", "validate", "deserialize", "objects", "unions", "types", "options", "runtime" };
    for (example_names) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zig_jsonschema", .module = mod },
                },
            }),
        });
        b.installArtifact(exe);

        const run_exe = b.addRunArtifact(exe);
        run_exe.step.dependOn(b.getInstallStep());
        const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example", .{name}));
        run_step.dependOn(&run_exe.step);

        examples_step.dependOn(&run_exe.step);
    }

    const tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests and the JSON-Schema-Test-Suite");
    test_step.dependOn(&run_tests.step);

    // Snapshot tests of the generated schemas (tests/schema_gen/<case>/<draft>.schema.json).
    const update_snapshots = b.option(bool, "update-snapshots", "Rewrite the schema generation snapshots instead of comparing") orelse false;
    const schema_gen_options = b.addOptions();
    schema_gen_options.addOption([]const u8, "snapshot_dir", b.pathFromRoot("tests/schema_gen"));
    schema_gen_options.addOption(bool, "update", update_snapshots);
    const schema_gen_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/schema_gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_jsonschema", .module = mod },
                .{ .name = "schema_gen_options", .module = schema_gen_options.createModule() },
            },
        }),
    });
    const run_schema_gen = b.addRunArtifact(schema_gen_tests);
    // The snapshots are read at run time, so never reuse a cached result.
    run_schema_gen.has_side_effects = true;
    const schema_gen_step = b.step("test-schema-gen", "Compare generated schemas with tests/schema_gen snapshots");
    schema_gen_step.dependOn(&run_schema_gen.step);
    test_step.dependOn(&run_schema_gen.step);

    // Official JSON-Schema-Test-Suite, fetched lazily so that consumers of
    // the library never download it.
    const suite_step = b.step("test-suite", "Run the official JSON-Schema-Test-Suite");
    const suite_verbose = b.option(bool, "suite-verbose", "Print every failing optional test-suite case") orelse false;
    if (b.lazyDependency("JSON-Schema-Test-Suite", .{})) |suite_dep| {
        const suite_options = b.addOptions();
        suite_options.addOptionPath("suite_dir", suite_dep.path(""));
        suite_options.addOption(bool, "verbose", suite_verbose);

        const suite_runner = b.addExecutable(.{
            .name = "test-suite",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/suite.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zig_jsonschema", .module = mod },
                    .{ .name = "suite_options", .module = suite_options.createModule() },
                },
            }),
        });
        const run_suite = b.addRunArtifact(suite_runner);
        suite_step.dependOn(&run_suite.step);
        test_step.dependOn(&run_suite.step);
    }
}
