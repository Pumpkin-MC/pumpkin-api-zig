//! Cheques: paper that holds coins, which anyone holding it cashes with a
//! right click.

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const item = pumpkin.item;
const msg = pumpkin.msg;
const coins = @import("coins.zig");

/// The key the amount is stored under on the item.
const key = "cheque";

pub fn command(sender: cmd.Sender, _: pumpkin.Server, args: struct { amount: u32 }) cmd.Result {
    const player = sender.asPlayer() orelse return cmd.fail("only players can write cheques");
    const cheque = build(args.amount, player.getName());
    if (item.room(player, cheque) == 0) return cmd.fail("you have no room for a cheque");
    const enough = coins.withdraw(player, args.amount) catch return cmd.fail(coins.unreadable);
    if (!enough) return cmd.failWith(msg.fmt(.red, "You don't have {s}.", .{coins.format(args.amount)}));
    _ = item.give(player, cheque);
    coins.tell(player, .green, "You wrote a cheque for {s}.", .{coins.format(args.amount)});
    return cmd.ok(1);
}

fn build(amount: u32, signer: []const u8) item.ItemStack {
    return item.build(.{
        .id = "minecraft:paper",
        .name = &.{
            .{ .text = "Cheque · ", .color = .gold, .bold = true },
            .{ .text = coins.format(amount), .color = .yellow },
        },
        .lore = &.{
            &.{.{ .text = std.fmt.allocPrint(pumpkin.abi.arena(), "Signed by {s}", .{signer}) catch @panic("OOM"), .color = .gray }},
            &.{},
            &.{
                .{ .text = "Right click ", .color = .yellow },
                .{ .text = "to cash it", .color = .white },
            },
        },
        .glint = true,
        .rarity = .uncommon,
        .max_stack_size = 1,
        .data = &.{.{ .key = key, .value = .{ .int = amount } }},
    });
}

pub fn onInteract(_: pumpkin.Server, ev: *pumpkin.EventData(.player_interact_event)) void {
    if (ev.action != .right_click_air and ev.action != .right_click_block) return;
    const stack = item.held(ev.player) orelse return;
    const value = item.get(stack, key) orelse return;
    ev.cancelled = true;
    if (value != .int or value.int <= 0) return;

    // Paid before the cheque is taken, so a failed payment leaves it in the hand.
    const total = coins.deposit(ev.player, @intCast(value.int)) catch {
        coins.tell(ev.player, .red, "Your coins can't be read, the cheque stays as it is.", .{});
        return;
    };
    stack.setCount(stack.getCount() - 1);
    item.setHeld(ev.player, if (stack.getCount() == 0) null else stack);

    coins.tell(ev.player, .green, "Cashed {s}, you have {s} now.", .{ coins.format(@intCast(value.int)), coins.format(total) });
    const x, const y, const z = ev.player.getPosition();
    ev.player.spawnParticles(.happy_villager, .{ x, y + 1, z }, 12, .{ 0.4, 0.4, 0.4 }, 0.05);
}
