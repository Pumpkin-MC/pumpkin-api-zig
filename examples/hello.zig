//! Events, a command and styled text.

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const msg = pumpkin.msg;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const Hello = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-hello",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Greets players and keeps spoilers out of the chat.",
    };

    pub const events = .{
        .player_join_event = onJoin,
        .player_chat_event = .{ onChat, pumpkin.EventOptions{ .priority = .high } },
    };

    pub const commands: []const cmd.Spec = &.{.{
        .names = &.{ "greet", "hi" },
        .description = "Says hello, to you or to other players.",
        .permission = "example-hello:command.greet",
        .run = greetSender,
        .then = &.{
            .argument("targets", .players, .{ .run = greetTargets }),
        },
    }};

    pub fn onLoad(_: pumpkin.Context) !void {
        std.log.info("Hello from Zig, built with pumpkin-api-zig {s}!", .{pumpkin.version});
    }

    fn onJoin(_: pumpkin.Server, ev: *pumpkin.EventData(.player_join_event)) void {
        ev.join_message = msg.build(&.{
            .{ .text = "+ ", .color = .green, .bold = true },
            .{ .text = ev.player.getName(), .color = .yellow },
        });
    }

    fn onChat(_: pumpkin.Server, ev: *pumpkin.EventData(.player_chat_event)) void {
        if (std.mem.indexOf(u8, ev.message, "spoiler") != null) ev.cancelled = true;
    }

    fn greetSender(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        sender.sendMessage(msg.build(&.{
            .{ .text = "Hello from Zig! ", .color = .gold },
            .{ .text = "[again]", .color = .gray, .click = .{ .run_command = "/greet" }, .hover = "Runs /greet" },
        }));
        return cmd.ok(1);
    }

    fn greetTargets(sender: cmd.Sender, _: pumpkin.Server, args: cmd.Args) cmd.Result {
        const targets = cmd.get(args, "targets", .players) orelse return cmd.fail("nobody to greet");
        for (targets) |target| {
            target.sendSystemMessage(msg.fmt(.aqua, "{s} says hello", .{sender.getName()}), false);
        }
        sender.sendMessage(msg.fmt(null, "Greeted {d} player(s).", .{targets.len}));
        return cmd.ok(@intCast(targets.len));
    }
};

comptime {
    pumpkin.register(Hello);
}
