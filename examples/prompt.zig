//! Questions in chat with `pumpkin.prompt`: /diamonds asks for a number and
//! then for confirmation, and /kit offers kits to click until the player is done.

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const item = pumpkin.item;
const msg = pumpkin.msg;
const prompt = pumpkin.prompt;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const Kit = struct {
    name: []const u8,
    color: msg.Color,
    items: []const item.Spec,
};

const kits = [_]Kit{
    .{ .name = "Warrior", .color = .red, .items = &.{
        .{ .id = "minecraft:iron_sword" },
        .{ .id = "minecraft:shield" },
    } },
    .{ .name = "Archer", .color = .green, .items = &.{
        .{ .id = "minecraft:bow" },
        .{ .id = "minecraft:arrow", .count = 32 },
    } },
    .{ .name = "Miner", .color = .gold, .items = &.{
        .{ .id = "minecraft:iron_pickaxe" },
        .{ .id = "minecraft:torch", .count = 32 },
    } },
};

const PromptPlugin = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-prompt",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Asks how many diamonds to give with /diamonds and offers kits with /kit.",
    };

    pub const commands: []const cmd.Spec = &.{ .{
        .names = &.{"diamonds"},
        .description = "Asks how many diamonds you want.",
        .permission = "example-prompt:command.diamonds",
        .default = .{ .op = .two },
        .run = askAmount,
    }, .{
        .names = &.{"kit"},
        .description = "Lets you pick a kit.",
        .permission = "example-prompt:command.kit",
        .run = offerKits,
    } };

    pub fn onLoad(ctx: pumpkin.Context) !void {
        try prompt.listen(ctx, .{});
    }

    fn askAmount(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("only players can get diamonds");
        prompt.ask(player, .{
            .question = &.{
                .{ .text = "How many diamonds do you want? ", .color = .aqua },
                .{ .text = "Type a number from 1 to 64, or cancel.", .color = .gray },
            },
            .on_answer = gotAmount,
            .on_end = ended,
            .timeout = .seconds(30),
        });
        return cmd.ok(1);
    }

    fn gotAmount(answer: prompt.Answer) prompt.Reply {
        const amount = answer.number(u8) orelse 0;
        if (amount < 1 or amount > 64) return prompt.retry(&.{.{ .text = "That has to be a number from 1 to 64.", .color = .red }});

        const amount_text = std.fmt.allocPrint(pumpkin.abi.arena(), "{d}", .{amount}) catch return prompt.done();
        prompt.choose(answer.player, .{
            .message = &.{
                .{ .text = .{ .text = "Give yourself " } },
                .{ .text = .{ .text = amount_text, .color = .aqua, .bold = true } },
                .{ .text = .{ .text = " diamonds?  " } },
                .{ .choice = .{
                    .label = &.{.{ .text = "[✔ Give]", .color = .green, .hover = "Puts the diamonds in your inventory" }},
                    .on_pick = giveDiamonds,
                    .word = "give",
                    .data = amount,
                } },
                .{ .text = .{ .text = " " } },
                .{ .choice = .{
                    .label = &.{.{ .text = "[✘ Never mind]", .color = .red }},
                    .on_pick = declined,
                    .word = "no",
                } },
            },
            .on_end = ended,
        });
        return prompt.done();
    }

    fn giveDiamonds(_: pumpkin.Server, player: pumpkin.Player, amount: usize) prompt.Reply {
        const left = item.give(player, item.build(.{ .id = "minecraft:diamond", .count = @intCast(amount) }));
        player.sendSystemMessage(msg.fmt(.green, "Here are {d} diamonds.", .{amount - left}), false);
        return prompt.done();
    }

    fn declined(_: pumpkin.Server, player: pumpkin.Player, _: usize) prompt.Reply {
        player.sendSystemMessage(msg.fmt(.gray, "No diamonds then.", .{}), false);
        return prompt.done();
    }

    /// The kits each player has taken from their open /kit message, one bit per kit.
    var taken: std.AutoHashMapUnmanaged(pumpkin.uuid.Uuid, u8) = .empty;

    fn offerKits(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("only players can get a kit");
        var labels: [kits.len][1]msg.Span = undefined;
        var parts: [1 + kits.len * 2 + 2]prompt.Part = undefined;
        parts[0] = .{ .text = .{ .text = "Pick your kits:", .color = .yellow, .bold = true } };
        for (kits, 0..) |kit, i| {
            labels[i] = .{.{ .text = kit.name, .color = kit.color, .underlined = true, .hover = "Click to take this kit" }};
            parts[1 + i * 2] = .{ .text = .{ .text = "\n  " } };
            parts[2 + i * 2] = .{ .choice = .{
                .label = &labels[i],
                .on_pick = giveKit,
                .word = kit.name,
                .data = i,
            } };
        }
        parts[parts.len - 2] = .{ .text = .{ .text = "\n  " } };
        parts[parts.len - 1] = .{ .choice = .{
            .label = &.{.{ .text = "[Done]", .color = .gray, .bold = true }},
            .on_pick = doneWithKits,
            .word = "done",
        } };
        // After `choose`, which ends an open /kit message and with it its entry.
        prompt.choose(player, .{ .message = &parts, .on_end = ended, .timeout = null });
        taken.put(pumpkin.abi.heap, player.getId(), 0) catch return cmd.fail("out of memory");
        return cmd.ok(1);
    }

    fn giveKit(_: pumpkin.Server, player: pumpkin.Player, index: usize) prompt.Reply {
        const kit = kits[index];
        const bits = taken.getPtr(player.getId()) orelse return prompt.done();
        const bit = @as(u8, 1) << @intCast(index);
        if (bits.* & bit != 0) return prompt.retry(&.{.{ .text = "You already took that kit.", .color = .red }});
        bits.* |= bit;

        for (kit.items) |spec| _ = item.give(player, item.build(spec));
        player.sendSystemMessage(msg.fmt(kit.color, "You took the {s} kit.", .{kit.name}), false);
        return prompt.keep();
    }

    fn doneWithKits(_: pumpkin.Server, player: pumpkin.Player, _: usize) prompt.Reply {
        _ = taken.remove(player.getId());
        player.sendSystemMessage(msg.fmt(.gray, "Enjoy your kits.", .{}), false);
        return prompt.done();
    }

    fn ended(_: pumpkin.Server, player: pumpkin.Player, reason: prompt.End, _: usize) void {
        _ = taken.remove(player.getId());
        switch (reason) {
            .timeout => player.sendSystemMessage(msg.fmt(.gray, "You took too long to answer.", .{}), false),
            .cancelled => player.sendSystemMessage(msg.fmt(.gray, "Cancelled.", .{}), false),
            .left, .replaced => {},
        }
    }
};

comptime {
    pumpkin.register(PromptPlugin);
}
