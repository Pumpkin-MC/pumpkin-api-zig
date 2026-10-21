//! `/pay`, which asks for the amount when it is left out and has the payer
//! confirm in chat.

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const prompt = pumpkin.prompt;
const coins = @import("coins.zig");

pub const max_amount = 1_000_000;

const Payment = struct { target: pumpkin.uuid.Uuid, amount: u64 };

/// Payments waiting for an amount or a confirmation, by payer.
var pending: std.AutoHashMapUnmanaged(pumpkin.uuid.Uuid, Payment) = .empty;

pub fn command(sender: cmd.Sender, _: pumpkin.Server, args: struct { target: pumpkin.Player, amount: ?u32 }) cmd.Result {
    const player = sender.asPlayer() orelse return cmd.fail("only players can pay");
    if (std.meta.eql(args.target.getId(), player.getId())) return cmd.fail("you can't pay yourself");

    if (args.amount) |amount| {
        confirm(player, args.target.getName(), amount);
    } else prompt.ask(player, .{
        .question = &.{
            coins.tag,
            .{ .text = std.fmt.allocPrint(pumpkin.abi.arena(), "How much do you want to give {s}? ", .{args.target.getName()}) catch @panic("OOM"), .color = .aqua },
            .{ .text = "Type a number, or cancel.", .color = .gray },
        },
        .on_answer = gotAmount,
        .on_end = ended,
        .timeout = .seconds(30),
    });
    // After asking, since that ends the player's previous question, and
    // `ended` removes its payment.
    pending.put(pumpkin.abi.heap, player.getId(), .{ .target = args.target.getId(), .amount = args.amount orelse 0 }) catch @panic("OOM");
    return cmd.ok(1);
}

fn gotAmount(answer: prompt.Answer) prompt.Reply {
    const payment = pending.getPtr(answer.player.getId()) orelse return prompt.done();
    const amount = answer.number(u64) orelse 0;
    if (amount == 0 or amount > max_amount) {
        return prompt.retry(&.{.{ .text = std.fmt.comptimePrint("That has to be a whole number from 1 to {d}.", .{max_amount}), .color = .red }});
    }
    const have = coins.balance(answer.player) catch return stop(answer.player, coins.unreadable);
    if (amount > have) {
        const text = std.fmt.allocPrint(pumpkin.abi.arena(), "You only have {s}.", .{coins.format(have)}) catch @panic("OOM");
        return prompt.retry(&.{.{ .text = text, .color = .red }});
    }
    const target = answer.server.getPlayerByUuid(payment.target) orelse return stop(answer.player, "that player isn't online anymore");
    payment.amount = amount;
    confirm(answer.player, target.getName(), amount);
    return prompt.done();
}

/// Ends the question without paying. `done` doesn't run `on_end`, so the
/// payment is removed here.
fn stop(player: pumpkin.Player, reason: []const u8) prompt.Reply {
    _ = pending.remove(player.getId());
    coins.tell(player, .red, "{s}", .{reason});
    return prompt.done();
}

fn confirm(player: pumpkin.Player, name: []const u8, amount: u64) void {
    prompt.choose(player, .{
        .message = &.{
            .{ .text = coins.tag },
            .{ .text = .{ .text = "Give " } },
            .{ .text = .{ .text = coins.format(amount), .color = .gold, .bold = true } },
            .{ .text = .{ .text = " to " } },
            .{ .text = .{ .text = name, .color = .yellow } },
            .{ .text = .{ .text = "?  " } },
            .{ .choice = .{
                .label = &.{.{ .text = "[✔ Pay]", .color = .green, .hover = "Sends the coins" }},
                .on_pick = paid,
                .word = "pay",
            } },
            .{ .text = .{ .text = " " } },
            .{ .choice = .{
                .label = &.{.{ .text = "[✘ Cancel]", .color = .red }},
                .on_pick = declined,
                .word = "cancel",
            } },
        },
        .on_end = ended,
    });
}

fn paid(srv: pumpkin.Server, player: pumpkin.Player, _: usize) prompt.Reply {
    const payment = (pending.fetchRemove(player.getId()) orelse return prompt.done()).value;
    const target = srv.getPlayerByUuid(payment.target) orelse return stop(player, "that player isn't online anymore");
    const enough = coins.withdraw(player, payment.amount) catch return stop(player, coins.unreadable);
    if (!enough) return stop(player, "you don't have that much anymore");
    _ = coins.deposit(target, payment.amount) catch {
        _ = coins.deposit(player, payment.amount) catch {};
        return stop(player, "their coins can't be read, nothing was sent");
    };
    coins.tell(player, .green, "Sent {s} to {s}.", .{ coins.format(payment.amount), target.getName() });
    coins.tell(target, .green, "{s} sent you {s}.", .{ player.getName(), coins.format(payment.amount) });
    return prompt.done();
}

fn declined(_: pumpkin.Server, player: pumpkin.Player, _: usize) prompt.Reply {
    _ = pending.remove(player.getId());
    coins.tell(player, .gray, "Payment cancelled.", .{});
    return prompt.done();
}

fn ended(_: pumpkin.Server, player: pumpkin.Player, reason: prompt.End, _: usize) void {
    _ = pending.remove(player.getId());
    switch (reason) {
        .timeout => coins.tell(player, .gray, "The payment timed out.", .{}),
        .cancelled => coins.tell(player, .gray, "Payment cancelled.", .{}),
        .left, .replaced => {},
    }
}
