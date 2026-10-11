//! Tasks that carry a value, with `pumpkin.tasks`: a countdown that keeps its
//! state in the task and stops itself, and a reminder that runs once.

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const msg = pumpkin.msg;
const tasks = pumpkin.tasks;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const Countdown = struct {
    player: pumpkin.uuid.Uuid,
    left: u32,
};

const Reminder = struct {
    player: pumpkin.uuid.Uuid,
    /// Allocated with `pumpkin.abi.heap`, since it has to outlive the command.
    message: []const u8,
};

const Tasks = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-tasks",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Counts down with /countdown and reminds players with /remind.",
    };

    pub const commands: []const cmd.Spec = &.{ .{
        .names = &.{"countdown"},
        .description = "Counts down on your screen.",
        .permission = "example-tasks:command.countdown",
        .then = &.{
            .argument("seconds", .{ .integer = .{ 1, 60 } }, .{ .run = cmd.typed(startCountdown) }),
        },
    }, .{
        .names = &.{"remind"},
        .description = "Reminds you of something later.",
        .permission = "example-tasks:command.remind",
        .then = &.{
            .argument("seconds", .{ .integer = .{ 1, 3600 } }, .{
                .then = &.{.argument("message", .{ .string = .greedy }, .{ .run = cmd.typed(startReminder) })},
            }),
        },
    } };

    fn startCountdown(sender: cmd.Sender, _: pumpkin.Server, args: struct { seconds: u32 }) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("only players can count down");
        _ = tasks.repeat(.fromTicks(0), .seconds(1), tick, Countdown{ .player = player.getId(), .left = args.seconds });
        return cmd.ok(1);
    }

    fn tick(srv: pumpkin.Server, countdown: *Countdown, task: tasks.Task) void {
        const player = srv.getPlayerByUuid(countdown.player) orelse return task.cancel();
        if (countdown.left == 0) {
            player.showTitle(msg.fmt(.green, "Go!", .{}));
            return task.cancel();
        }
        player.showTitle(msg.fmt(.gold, "{d}", .{countdown.left}));
        countdown.left -= 1;
    }

    fn startReminder(sender: cmd.Sender, _: pumpkin.Server, args: struct { seconds: u32, message: []const u8 }) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("only players can be reminded");
        const message = pumpkin.abi.heap.dupe(u8, args.message) catch return cmd.fail("out of memory");
        _ = tasks.after(.seconds(args.seconds), remind, Reminder{ .player = player.getId(), .message = message });
        sender.sendMessage(msg.fmt(.gray, "I'll remind you in {d} seconds.", .{args.seconds}));
        return cmd.ok(1);
    }

    fn remind(srv: pumpkin.Server, reminder: Reminder) void {
        defer pumpkin.abi.heap.free(reminder.message);
        const player = srv.getPlayerByUuid(reminder.player) orelse return;
        player.sendSystemMessage(msg.fmt(.aqua, "Reminder: {s}", .{reminder.message}), false);
    }
};

comptime {
    pumpkin.register(Tasks);
}
