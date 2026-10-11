//! Items with `pumpkin.item`: a sword the plugin recognizes by a value it
//! stored on it and upgrades in place, bread that spreads over several slots,
//! and a trade that takes items from the player.

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const item = pumpkin.item;
const msg = pumpkin.msg;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const max_sharpness = 10;

const Items = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-items",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Gives a healing sword that can be upgraded, gives bread and trades bread for diamonds.",
    };

    pub const events = .{
        .player_interact_event = onInteract,
    };

    pub const commands: []const cmd.Spec = &.{ .{
        .names = &.{"excalibur"},
        .description = "Gives you a sword that heals you when you right click with it.",
        .permission = "example-items:command.excalibur",
        .default = .{ .op = .two },
        .run = giveSword,
    }, .{
        .names = &.{"upgrade"},
        .description = "Raises the sharpness of the Excalibur in your hand.",
        .permission = "example-items:command.upgrade",
        .default = .{ .op = .two },
        .run = upgrade,
    }, .{
        .names = &.{"bread"},
        .description = "Gives you 100 bread.",
        .permission = "example-items:command.bread",
        .run = giveBread,
    }, .{
        .names = &.{"trade"},
        .description = "Trades 5 bread for a diamond.",
        .permission = "example-items:command.trade",
        .run = trade,
    } };

    fn giveSword(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("only players can hold a sword");
        const gold: msg.Rgb = .{ .r = 0xff, .g = 0xc8, .b = 0x3d };
        const sword = item.build(.{
            .id = "minecraft:diamond_sword",
            .name = &.{
                .{ .text = "✦ ", .rgb = gold },
                .{ .text = "Excalibur", .rgb = gold, .bold = true },
                .{ .text = " ✦", .rgb = gold },
            },
            .lore = &.{
                &.{.{ .text = "Drawn from the stone by the", .color = .gray, .italic = true }},
                &.{.{ .text = "one true king of Britain.", .color = .gray, .italic = true }},
                &.{},
                &.{
                    .{ .text = "Right click ", .color = .yellow },
                    .{ .text = "to restore your health", .color = .white },
                },
                &.{
                    .{ .text = "/upgrade ", .color = .yellow },
                    .{ .text = "to sharpen the blade", .color = .white },
                },
                &.{},
                &.{
                    .{ .text = "◆ ", .color = .light_purple },
                    .{ .text = "LEGENDARY", .color = .light_purple, .bold = true },
                    .{ .text = " ◆", .color = .light_purple },
                },
            },
            .enchants = &.{.{ .sharpness, 5 }},
            .modifiers = &.{.{ .attribute = .attack_damage, .amount = 10 }},
            .unbreakable = true,
            .rarity = .epic,
            .data = &.{.{ .key = "id", .value = .{ .string = "excalibur" } }},
        });
        if (item.give(player, sword) != 0) return cmd.fail("your inventory is full");
        return cmd.ok(1);
    }

    fn upgrade(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("only players can upgrade a sword");
        const sword = item.held(player) orelse return cmd.fail("hold Excalibur to upgrade it");
        if (!item.is(sword, "id", "excalibur")) return cmd.fail("hold Excalibur to upgrade it");

        const level = item.enchantLevel(sword, .sharpness);
        if (level >= max_sharpness) return cmd.fail("Excalibur can't get any sharper");
        item.edit(sword, .{ .enchants = &.{.{ .sharpness, level + 1 }} });
        item.setHeld(player, sword);
        sender.sendMessage(msg.fmt(.gold, "Excalibur now has Sharpness {d}.", .{level + 1}));
        return cmd.ok(1);
    }

    fn giveBread(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("only players can eat");
        const left = item.give(player, item.build(.{ .id = "minecraft:bread", .count = 100 }));
        if (left > 0) sender.sendMessage(msg.fmt(.yellow, "{d} bread didn't fit.", .{left}));
        return cmd.ok(100 - left);
    }

    fn trade(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("only players can trade");
        if (!item.take(player, .{ .id = "minecraft:bread" }, 5)) {
            return cmd.fail("you need 5 bread");
        }
        _ = item.give(player, item.build(.{ .id = "minecraft:diamond" }));
        sender.sendMessage(msg.fmt(.aqua, "Traded 5 bread for a diamond, {d} bread left.", .{
            item.count(player, .{ .id = "minecraft:bread" }),
        }));
        return cmd.ok(1);
    }

    fn onInteract(_: pumpkin.Server, ev: *pumpkin.EventData(.player_interact_event)) void {
        if (ev.action != .right_click_air and ev.action != .right_click_block) return;
        const held = item.held(ev.player) orelse return;
        if (!item.is(held, "id", "excalibur")) return;
        ev.player.setHealth(ev.player.getMaxHealth());
        ev.player.sendSystemMessage(msg.fmt(.gold, "Excalibur heals you.", .{}), true);
    }
};

comptime {
    pumpkin.register(Items);
}
