//! A config file with `pumpkin.config`. The first start writes
//! `plugins/data/example-config/config.toml` with the defaults below, edit it
//! and run `/welcome reload` to apply the changes without a restart.

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const msg = pumpkin.msg;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const Config = struct {
    message: []const u8 = "Welcome to the server!",
    color: msg.Color = .gold,
    /// Shown above the hotbar instead of in the chat.
    action_bar: bool = false,
    title: struct {
        enabled: bool = true,
        text: []const u8 = "Welcome",
        subtitle: []const u8 = "Have fun!",
        /// How long the title stays on screen, in ticks.
        stay: i32 = 60,
    } = .{},
};

const ConfigPlugin = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-config",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Greets joining players with a message and a title from its config.",
        .permissions = &.{ "fs.read.data", "fs.write.data" },
    };

    pub const events = .{
        .player_join_event = onJoin,
    };

    pub const commands: []const cmd.Spec = &.{.{
        .names = &.{"welcome"},
        .description = "Shows or reloads the welcome message.",
        .permission = "example-config:command.welcome",
        .run = show,
        .then = &.{
            .literal("reload", .{ .run = reload }),
        },
    }};

    var config: pumpkin.config.File(Config) = .{ .path = "config.toml" };

    pub fn onLoad(_: pumpkin.Context) !void {
        try config.load();
    }

    fn onJoin(_: pumpkin.Server, ev: *pumpkin.EventData(.player_join_event)) void {
        const c = config.value;
        ev.player.sendSystemMessage(msg.fmt(c.color, "{s}", .{c.message}), c.action_bar);
        if (c.title.enabled) {
            ev.player.sendTitleAnimation(10, c.title.stay, 20);
            ev.player.showTitle(msg.fmt(c.color, "{s}", .{c.title.text}));
            ev.player.showSubtitle(msg.plain(c.title.subtitle));
        }
    }

    fn show(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        sender.sendMessage(msg.fmt(config.value.color, "{s}", .{config.value.message}));
        return cmd.ok(1);
    }

    fn reload(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        config.load() catch return cmd.fail("the config has an error, see the server log");
        sender.sendMessage(msg.fmt(.green, "Reloaded {s}.", .{config.path}));
        return cmd.ok(1);
    }
};

comptime {
    pumpkin.register(ConfigPlugin);
}
