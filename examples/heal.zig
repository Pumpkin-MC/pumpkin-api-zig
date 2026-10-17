//! A command whose arguments arrive as a struct, through `cmd.typed`.

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const msg = pumpkin.msg;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const Heal = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-heal",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Heals you with /heal, or other players with /heal <target> [amount].",
    };

    pub const commands: []const cmd.Spec = &.{.{
        .names = &.{"heal"},
        .description = "Heals a player, fully or by the given amount.",
        .permission = "example-heal:command.heal",
        .default = .{ .op = .two },
        .run = healSelf,
        .then = &.{
            .argument("target", .players, .{
                .run = cmd.typed(heal),
                .then = &.{.argument("amount", .{ .float = .{ 0.5, null } }, .{ .run = cmd.typed(heal) })},
            }),
        },
    }};

    fn healSelf(sender: cmd.Sender, srv: pumpkin.Server, _: cmd.Args) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("say who to heal, for example /heal Steve");
        return heal(sender, srv, .{ .target = player, .amount = null });
    }

    fn heal(sender: cmd.Sender, _: pumpkin.Server, args: struct { target: pumpkin.Player, amount: ?f32 }) cmd.Result {
        const target = args.target;
        if (args.amount) |amount| target.heal(amount) else target.setHealth(target.getMaxHealth());
        sender.sendMessage(msg.fmt(.green, "{s} is at {d:.1} health.", .{ target.getName(), target.getHealth() }));
        return cmd.ok(1);
    }
};

comptime {
    pumpkin.register(Heal);
}
