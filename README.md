# Pumpkin API for Zig

This package provides Zig bindings for building Pumpkin plugins using WebAssembly (Wasm) components.

## Requirements

- [Zig](https://ziglang.org/download/) 0.16.0
- [`wasm-tools`](https://github.com/bytecodealliance/wasm-tools) in your `PATH`

## Setup

Add the package to your project:

```sh
zig fetch --save git+https://github.com/Pumpkin-MC/pumpkin-api-zig
```

This pins the current commit in your `build.zig.zon`. Run it again to update. If you are working on the API itself, point the dependency at a local checkout instead:

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

C libraries work too, including ones that link libc, since Zig builds them against wasi-libc. What a library can't use is anything WASI doesn't provide to plugins, such as threads, child processes or network sockets.

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

For a complete plugin that uses typed commands, a menu and a config file, see [`example/src/main.zig`](example/src/main.zig).

## Commands

Commands are a tree of literals and arguments, and any node with `run` set can be executed. `cmd.typed` hands the handler its arguments as a struct, with each field filled from the argument of the same name:

```zig
.{
    .names = &.{"give"},
    .permission = "my-plugin:command.give",
    .then = &.{
        .argument("targets", .players, .{
            .run = cmd.typed(give),
            .then = &.{.argument("amount", .{ .integer = .{ 1, 64 } }, .{ .run = cmd.typed(give) })},
        }),
    },
}

fn give(sender: cmd.Sender, _: pumpkin.Server, args: struct { targets: []const pumpkin.Player, amount: i32 = 1 }) cmd.Result {
    // ...
    return cmd.ok(@intCast(args.targets.len));
}
```

Fields that are optional or have a default may be missing, which lets one handler serve both branches above. A field of type `pumpkin.Player` needs the argument to match exactly one player. If a required field is missing or invalid, the command fails with a message and the handler doesn't run. To read arguments by hand, take `cmd.Args` instead and use `cmd.get(args, "targets", .players)`, `cmd.int` and `cmd.float`. A handler finishes with `cmd.ok(n)` or `cmd.fail("...")`.

The permission node has to start with `<plugin name>:`. `register` registers it with the server for you, and `.default` sets who gets it when nobody has configured it.

## Menus

```zig
pub fn onLoad(ctx: pumpkin.Context) !void {
    pumpkin.menu.listen(ctx);
}

fn openShop(player: pumpkin.Player) void {
    pumpkin.menu.open(player, .{
        .title = &.{.{ .text = "Shop", .color = .gold }},
        .buttons = &.{.{
            .slot = 13,
            .icon = .{ .id = "minecraft:diamond", .name = &.{.{ .text = "Buy a diamond", .color = .aqua }} },
            .on_click = buy,
        }},
        .fill = .{ .id = "minecraft:gray_stained_glass_pane" },
    });
}

fn buy(click: pumpkin.menu.Click) void {
    click.player.sendSystemMessage(pumpkin.msg.plain("Bought!"), false);
}
```

Items can't be taken out of a menu or put into it. Buttons that share a handler can be told apart with `.data`. `on_close` runs when the menu is closed, when another menu replaces it, or when the player leaves.

## Files and other system access

Plugins are built for `wasm32-wasi`, so the usual `std.Io` file APIs work. The server only grants what the plugin asks for in `metadata.permissions`:

| Permission | Grants |
| --- | --- |
| `fs.read.data` | Read access to `plugins/data/<name>` |
| `fs.write.data` | Read and write access to `plugins/data/<name>` |
| `network.dns`, `http.outbound`, `sys.env` | DNS lookups, outgoing HTTP, environment variables |

With a data permission, the data folder is the current directory:

```zig
const io = pumpkin.io();
const dir = std.Io.Dir.cwd();
try dir.writeFile(io, .{ .sub_path = "config.json", .data = "{}" });
const config = try dir.readFileAlloc(io, "config.json", pumpkin.abi.heap, .limited(64 * 1024));
```

Server admins can still block permissions in the server config.

## Working on the bindings

```sh
zig build test   # unit tests for the ABI layer and the generator
zig build check  # compiles every generated binding
zig build gen    # regenerates src/wit/ and src/plugin.wit from the wit submodule
```

`adapter/wasi_snapshot_preview1.reactor.wasm` is the WASI preview 1 adapter from [Wasmtime](https://github.com/bytecodealliance/wasmtime) 48.0.2 (Apache-2.0 WITH LLVM-exception). Zig emits WASI preview 1, and the adapter maps it onto the preview 2 interfaces the server provides.
