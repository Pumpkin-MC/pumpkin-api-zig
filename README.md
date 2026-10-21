# Pumpkin API for Zig

This package provides Zig bindings for building Pumpkin plugins using WebAssembly (Wasm) components.

## Requirements

- [Zig](https://ziglang.org/download/) 0.16.0
- [`wasm-tools`](https://github.com/bytecodealliance/wasm-tools) in your `PATH`

## Setup

Add a release of the package to your project:

```sh
zig fetch --save git+https://github.com/Pumpkin-MC/pumpkin-api-zig#v0.2.0
```

The [releases](https://github.com/Pumpkin-MC/pumpkin-api-zig/releases) list every version, and to update you run the command again with the new one. `main` contains unreleased changes. If you are working on the API itself, point the dependency at a local checkout instead:

```zig
.dependencies = .{
    .pumpkin_api_zig = .{ .path = "../pumpkin-api-zig" },
},
```

Then create a `build.zig`:

```zig
const std = @import("std");
const pumpkin_api = @import("pumpkin_api_zig");

pub fn build(b: *std.Build) void {
    _ = pumpkin_api.addPlugin(b, b.dependency("pumpkin_api_zig", .{}), .{
        .name = "my-plugin",
        .root_source_file = b.path("src/main.zig"),
    });
}
```

`zig build` produces `zig-out/my-plugin.wasm`. Copy it into the server's `plugins` folder and restart the server.

### Dependencies

Other Zig packages are added through `.imports`. They have to be built for the same target as the plugin, which `pumpkin_api.target(b)` returns:

```zig
const std = @import("std");
const pumpkin_api = @import("pumpkin_api_zig");

pub fn build(b: *std.Build) void {
    const sqlite = b.dependency("sqlite", .{
        .target = pumpkin_api.target(b),
        .optimize = .ReleaseSmall,
    });

    _ = pumpkin_api.addPlugin(b, b.dependency("pumpkin_api_zig", .{}), .{
        .name = "my-plugin",
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{.{ .name = "sqlite", .module = sqlite.module("sqlite") }},
    });
}
```

`addPlugin` also returns the plugin's root module, for anything else the build needs, such as C sources of your own:

```zig
const plugin = pumpkin_api.addPlugin(b, api, .{ ... });
plugin.module.addCSourceFile(.{ .file = b.path("src/helper.c") });
plugin.module.link_libc = true;
```

C libraries work too, including ones that link libc, since Zig builds them against wasi-libc. What a library can't use is anything WASI doesn't provide to plugins, such as threads or child processes.

## A plugin

```zig
const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const msg = pumpkin.msg;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const MyPlugin = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "my-plugin",
        .version = "0.1.0",
        .authors = &.{"You"},
        .description = "Says hello.",
    };

    pub const events = .{
        .player_join_event = onJoin,
    };

    pub const commands: []const cmd.Spec = &.{.{
        .names = &.{ "hello", "hi" },
        .description = "Says hello.",
        .permission = "my-plugin:command.hello",
        .run = hello,
    }};

    pub fn onLoad(_: pumpkin.Context) !void {
        std.log.info("loaded", .{});
    }

    fn onJoin(_: pumpkin.Server, ev: *pumpkin.EventData(.player_join_event)) void {
        ev.join_message = msg.build(&.{
            .{ .text = "+ ", .color = .green, .bold = true },
            .{ .text = ev.player.getName(), .color = .yellow },
        });
    }

    fn hello(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        sender.sendMessage(msg.fmt(.gold, "Hello, {s}!", .{sender.getName()}));
        return cmd.ok(1);
    }
};

comptime {
    pumpkin.register(MyPlugin);
}
```

[`examples/`](examples) has a small plugin for each part of the API, and `zig build` builds them all into `zig-out/`:

| Example | Shows |
| --- | --- |
| [`hello`](examples/hello.zig) | Events, a command and styled text |
| [`heal`](examples/heal.zig) | Command arguments read with `cmd.typed` |
| [`menu`](examples/menu.zig) | Inventory menus with buttons, and a trash can with free slots |
| [`config`](examples/config.zig) | A TOML config file that can be reloaded |
| [`dns`](examples/dns.zig) | Looking up the addresses of a host name |
| [`http`](examples/http.zig) | A TCP connection with a timeout and a plain HTTP request |
| [`https`](examples/https.zig) | HTTPS with `std.http.Client` |
| [`tcp-server`](examples/tcp-server.zig) | A TCP server that bridges the chat, polled from a task |
| [`udp`](examples/udp.zig) | Receiving and answering UDP datagrams |
| [`tasks`](examples/tasks.zig) | Delayed and repeating tasks that carry a value |
| [`items`](examples/items.zig) | Building, editing and recognizing items, and giving and taking them |
| [`store`](examples/store.zig) | Data kept for every player in a file of its own |
| [`prompt`](examples/prompt.zig) | Questions answered in chat and choices to click |
| [`vault`](examples/vault.zig) | Personal storage with a page selector, usage indicators and configurable capacity |
| [`realm`](examples/realm) | An economy built with every helper: shop, daily rewards, payments, cheques and coin rushes |
| [`nettest`](examples/nettest.zig) | Runs every networking path with `/nettest` and reports each one |

## Working on the bindings

```sh
git submodule update --init
zig build test   # unit tests for the ABI layer and the generator
zig build check  # compiles every generated binding
zig build gen    # regenerates src/bindings/
```

[CONTRIBUTING.md](CONTRIBUTING.md) explains how the repository is laid out and what a pull request needs.

The Pumpkin bindings are generated from the `wit` submodule, [pumpkin-plugin-wit](https://github.com/Pumpkin-MC/pumpkin-plugin-wit).

The WASI bindings come from `wasi/`. `wasi/world.wit` lists the WASI interfaces plugins get bindings for, currently `wasi:sockets` and what it depends on. Their definitions in `wasi/deps/` are fetched from the [wasi.dev](https://wasi.dev) registry with [`wkg`](https://github.com/bytecodealliance/wasm-pkg-tools), pinned in `wasi/wkg.lock`. To change them, edit `world.wit` and run `wkg fetch .` inside `wasi/`, then `zig build gen`. The WASI interfaces and everything derived from them in `src/bindings/wasi/` are © the Contributors to the WASI Specification, published by the WebAssembly Community Group under the W3C Community Contributor License Agreement, see [`wasi/LICENSE.md`](wasi/LICENSE.md).

`adapter/wasi_snapshot_preview1.reactor.wasm` is the WASI preview 1 adapter from [Wasmtime](https://github.com/bytecodealliance/wasmtime) 48.0.2 (Apache-2.0 WITH LLVM-exception). Zig emits WASI preview 1, and the adapter maps it onto the preview 2 interfaces the server provides. The WASI version in `wasi/world.wit` has to stay the one the adapter imports.

To make a release, set the new version in `build.zig.zon`, commit it and push a matching tag such as `v0.1.0`. The Release workflow checks that the tag and `build.zig.zon` agree, runs the tests, and publishes a GitHub release with the example plugins and the plugin API revision it was built against.
