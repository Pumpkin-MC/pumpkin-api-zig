//! A config file in the plugin's data folder, written with defaults on first start.

const std = @import("std");
const pumpkin = @import("pumpkin");
const msg = pumpkin.msg;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const Config = struct {
    welcome: []const u8 = "Welcome! Edit plugins/data/example-config/config.json to change this.",
    color: msg.Color = .gold,
};

const ConfigPlugin = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-config",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Greets joining players with a message from its config.",
        .permissions = &.{ "fs.read.data", "fs.write.data" },
    };

    pub const events = .{
        .player_join_event = onJoin,
    };

    var config: Config = .{};

    pub fn onLoad(_: pumpkin.Context) !void {
        config = try load();
    }

    fn load() !Config {
        const io = pumpkin.io();
        const dir = std.Io.Dir.cwd();
        const text = dir.readFileAlloc(io, "config.json", pumpkin.abi.heap, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                const default = try std.json.Stringify.valueAlloc(pumpkin.abi.arena(), Config{}, .{ .whitespace = .indent_2 });
                try dir.writeFile(io, .{ .sub_path = "config.json", .data = default });
                return .{};
            },
            else => return err,
        };
        return std.json.parseFromSliceLeaky(Config, pumpkin.abi.heap, text, .{ .ignore_unknown_fields = true });
    }

    fn onJoin(_: pumpkin.Server, ev: *pumpkin.EventData(.player_join_event)) void {
        ev.player.sendSystemMessage(msg.fmt(config.color, "{s}", .{config.welcome}), false);
    }
};

comptime {
    pumpkin.register(ConfigPlugin);
}
