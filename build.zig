const std = @import("std");
const manifest: struct {
    name: @EnumLiteral(),
    version: []const u8,
    fingerprint: u64,
    minimum_zig_version: []const u8,
    paths: []const []const u8,
} = @import("build.zig.zon");

pub const PluginOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    optimize: std.builtin.OptimizeMode = .ReleaseSmall,
    imports: []const std.Build.Module.Import = &.{},
};

pub const Plugin = struct {
    /// The plugin's root module, for adding imports, C sources or libc.
    module: *std.Build.Module,
    install: *std.Build.Step.InstallFile,
};

fn buildOptions(b: *std.Build) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);
    return options;
}

/// The target plugins and their dependencies are built for.
pub fn target(b: *std.Build) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
}

/// Builds a plugin and installs `<name>.wasm`, ready to be dropped into the
/// server's `plugins` folder. Needs `wasm-tools` in PATH.
///
/// `api` is this package as the caller sees it:
///   const api = b.dependency("pumpkin_api_zig", .{});
pub fn addPlugin(b: *std.Build, api: *std.Build.Dependency, options: PluginOptions) Plugin {
    return addPluginFrom(b, api.builder, options);
}

fn addPluginFrom(b: *std.Build, api: *std.Build, options: PluginOptions) Plugin {
    const wasi = target(b);

    const pumpkin = api.createModule(.{
        .root_source_file = api.path("src/pumpkin.zig"),
        .target = wasi,
        .optimize = options.optimize,
    });
    pumpkin.addOptions("build_options", buildOptions(api));

    const plugin_module = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = wasi,
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
    embed.addFileArg(api.path("src/bindings/plugin.wit"));
    embed.addFileArg(core.getEmittedBin());
    embed.addArg("-o");
    const with_plugin = embed.addOutputFileArg("plugin.wasm");

    const embed_wasi = b.addSystemCommand(&.{ "wasm-tools", "component", "embed", "--world", "sockets" });
    embed_wasi.addFileArg(api.path("src/bindings/wasi/wasi.wit"));
    embed_wasi.addFileArg(with_plugin);
    embed_wasi.addArg("-o");
    const embedded = embed_wasi.addOutputFileArg("embedded.wasm");

    // Zig emits WASI preview 1, the server provides preview 2.
    const new = b.addSystemCommand(&.{ "wasm-tools", "component", "new", "--adapt" });
    new.addPrefixedFileArg("wasi_snapshot_preview1=", api.path("adapter/wasi_snapshot_preview1.reactor.wasm"));
    new.addFileArg(embedded);
    new.addArg("-o");
    const component = new.addOutputFileArg(b.fmt("{s}.wasm", .{options.name}));

    const install = b.addInstallFile(component, b.fmt("{s}.wasm", .{options.name}));
    b.getInstallStep().dependOn(&install.step);
    return .{ .module = plugin_module, .install = install };
}

pub fn build(b: *std.Build) void {
    for ([_][]const u8{ "hello", "heal", "menu", "config", "dns", "http", "https", "tcp-server", "udp", "tasks", "items", "store" }) |example| {
        _ = addPluginFrom(b, b, .{
            .name = b.fmt("example-{s}", .{example}),
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example})),
        });
    }
    _ = addPluginFrom(b, b, .{ .name = "nettest", .root_source_file = b.path("tests/network.zig") });

    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/pumpkin.zig", "tools/gen.zig" }) |path| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = b.graph.host,
            }),
        });
        tests.root_module.addOptions("build_options", buildOptions(b));
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    const check = b.addObject(.{
        .name = "check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/check.zig"),
            .target = target(b),
            .optimize = .ReleaseSmall,
        }),
    });
    b.step("check", "Compile every generated binding").dependOn(&check.step);

    // zig build gen: src/bindings/ from the wit submodule and wasi/.
    // Directory inputs aren't hashed, so these always rerun.
    const generator = b.addExecutable(.{
        .name = "gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen.zig"),
            .target = b.graph.host,
        }),
    });
    const fmt = b.addFmt(.{ .paths = &.{"src/bindings"} });

    const wasi_license = b.addUpdateSourceFiles();
    wasi_license.addCopyFileToSource(b.path("wasi/LICENSE.md"), "src/bindings/wasi/LICENSE.md");

    const sources = [_]struct { dir: std.Build.LazyPath, name: []const u8, wit: []const u8 }{
        .{ .dir = b.path("wit/v0.1"), .name = "pumpkin", .wit = "src/bindings/plugin.wit" },
        .{ .dir = b.path("wasi"), .name = "wasi", .wit = "src/bindings/wasi/wasi.wit" },
    };
    for (sources) |source| {
        const dump = b.addSystemCommand(&.{ "wasm-tools", "component", "wit", "--json" });
        dump.addDirectoryArg(source.dir);
        dump.has_side_effects = true;

        const merge = b.addSystemCommand(&.{ "wasm-tools", "component", "wit", "-o", source.wit });
        merge.addDirectoryArg(source.dir);
        merge.setCwd(b.path("."));
        merge.has_side_effects = true;

        const generate = b.addRunArtifact(generator);
        generate.addFileArg(dump.captureStdOut(.{}));
        generate.addArgs(&.{ "src/bindings", source.name, "../../runtime/abi.zig" });
        generate.setCwd(b.path("."));
        generate.has_side_effects = true;

        merge.step.dependOn(&generate.step);
        fmt.step.dependOn(&merge.step);
        if (std.mem.eql(u8, source.name, "wasi")) wasi_license.step.dependOn(&generate.step);
    }
    fmt.step.dependOn(&wasi_license.step);
    b.step("gen", "Regenerate src/bindings from wit/v0.1 and wasi").dependOn(&fmt.step);

    // zig build fixtures: rewrites what the generator test compares against.
    // demo.json comes from `wasm-tools component wit tools/testdata/wit --json`.
    const fixtures = b.addRunArtifact(generator);
    fixtures.addFileArg(b.path("tools/testdata/demo.json"));
    fixtures.addArg("tools/testdata/expected");
    fixtures.setCwd(b.path("."));
    fixtures.has_side_effects = true;
    b.step("fixtures", "Update the generator test snapshots").dependOn(&fixtures.step);
}
