const std = @import("std");

pub const PluginOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    optimize: std.builtin.OptimizeMode = .ReleaseSmall,
    imports: []const std.Build.Module.Import = &.{},
};

const wasi: std.Target.Query = .{ .cpu_arch = .wasm32, .os_tag = .wasi };

/// Builds a plugin and installs `<name>.wasm`, ready to be dropped into the
/// server's `plugins` folder. Needs `wasm-tools` in PATH.
///
/// `api` is this package as the caller sees it:
///   const api = b.dependency("pumpkin_api_zig", .{});
pub fn addPlugin(b: *std.Build, api: *std.Build.Dependency, options: PluginOptions) *std.Build.Step.InstallFile {
    return addPluginFrom(b, api.builder, options);
}

fn addPluginFrom(b: *std.Build, api: *std.Build, options: PluginOptions) *std.Build.Step.InstallFile {
    const target = b.resolveTargetQuery(wasi);

    const pumpkin = api.createModule(.{
        .root_source_file = api.path("src/pumpkin.zig"),
        .target = target,
        .optimize = options.optimize,
    });

    const plugin_module = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = target,
        .optimize = options.optimize,
    });

    plugin_module.addImport("pumpkin", pumpkin);

    for (options.imports) |import| {
        plugin_module.addImport(import.name, import.module);
    }

    const core = b.addExecutable(.{
        .name = options.name,
        .root_module = plugin_module,
    });
    core.entry = .disabled;
    core.rdynamic = true;
    core.wasi_exec_model = .reactor;

    // Zig has no component model target, so the core module gets its WIT
    // attached and is wrapped into a component afterwards.
    const embed = b.addSystemCommand(&.{ "wasm-tools", "component", "embed", "--world", "plugin" });
    embed.addFileArg(api.path("src/plugin.wit"));
    embed.addFileArg(core.getEmittedBin());
    embed.addArg("-o");
    const embedded = embed.addOutputFileArg("embedded.wasm");

    // Zig emits WASI preview 1, the server provides preview 2.
    const new = b.addSystemCommand(&.{ "wasm-tools", "component", "new", "--adapt" });
    new.addPrefixedFileArg("wasi_snapshot_preview1=", api.path("adapter/wasi_snapshot_preview1.reactor.wasm"));
    new.addFileArg(embedded);
    new.addArg("-o");
    const component = new.addOutputFileArg(b.fmt("{s}.wasm", .{options.name}));

    const install = b.addInstallFile(component, b.fmt("{s}.wasm", .{options.name}));
    b.getInstallStep().dependOn(&install.step);
    return install;
}

pub fn build(b: *std.Build) void {
    _ = addPluginFrom(b, b, .{
        .name = "pumpkin-plugin-example",
        .root_source_file = b.path("example/src/main.zig"),
    });

    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/abi.zig", "src/cmd.zig", "tools/gen.zig" }) |path| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = b.graph.host,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    const check = b.addObject(.{
        .name = "check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/check.zig"),
            .target = b.resolveTargetQuery(wasi),
            .optimize = .ReleaseSmall,
        }),
    });
    b.step("check", "Compile every generated binding").dependOn(&check.step);

    // zig build gen: src/wit/ and src/plugin.wit from the wit submodule.
    // Directory inputs aren't hashed, so these always rerun.
    const dump = b.addSystemCommand(&.{ "wasm-tools", "component", "wit", "--json" });
    dump.addDirectoryArg(b.path("wit/v0.1"));
    dump.has_side_effects = true;
    const json = dump.captureStdOut(.{});

    const merge = b.addSystemCommand(&.{ "wasm-tools", "component", "wit", "-o", "src/plugin.wit" });
    merge.addDirectoryArg(b.path("wit/v0.1"));
    merge.setCwd(b.path("."));
    merge.has_side_effects = true;

    const generator = b.addExecutable(.{
        .name = "gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen.zig"),
            .target = b.graph.host,
        }),
    });
    const generate = b.addRunArtifact(generator);
    generate.addFileArg(json);
    generate.addArg("src");
    generate.setCwd(b.path("."));
    generate.has_side_effects = true;

    const fmt = b.addFmt(.{ .paths = &.{ "src/wit", "src/wit.zig" } });
    fmt.step.dependOn(&generate.step);
    fmt.step.dependOn(&merge.step);
    b.step("gen", "Regenerate src/wit from wit/v0.1").dependOn(&fmt.step);

    // zig build fixtures: rewrites what the generator test compares against.
    // demo.json comes from `wasm-tools component wit tools/testdata/wit --json`.
    const fixtures = b.addRunArtifact(generator);
    fixtures.addFileArg(b.path("tools/testdata/demo.json"));
    fixtures.addArg("tools/testdata/expected");
    fixtures.setCwd(b.path("."));
    fixtures.has_side_effects = true;
    b.step("fixtures", "Update the generator test snapshots").dependOn(&fixtures.step);
}
