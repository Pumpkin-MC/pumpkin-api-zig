//! The shop menu and `/buy`, which sell the offers in the config.

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const item = pumpkin.item;
const menu = pumpkin.menu;
const msg = pumpkin.msg;
const coins = @import("coins.zig");
const settings = @import("settings.zig");

const balance_slot = 31;
/// How many times an offer is bought with a shift click.
const bulk = 8;
pub const max_bundles = 64;

pub const BuyError = error{ EmptyOffer, NotEnoughCoins, NoRoom } || coins.Error;

/// Buys `offer` `bundles` times and returns what it cost.
pub fn buy(player: pumpkin.Player, offer: settings.Offer, bundles: u32) BuyError!u64 {
    if (offer.count == 0) return error.EmptyOffer;
    const cost = @as(u64, offer.price) * bundles;
    if (try coins.balance(player) < cost) return error.NotEnoughCoins;
    if (item.room(player, item.build(.{ .id = offer.id })) < @as(u32, offer.count) * bundles) return error.NoRoom;
    _ = try coins.withdraw(player, cost);
    for (0..bundles) |_| _ = item.give(player, item.build(.{ .id = offer.id, .count = offer.count }));
    return cost;
}

fn problem(err: BuyError) []const u8 {
    return switch (err) {
        error.EmptyOffer => "that offer has a count of 0, see the shop in config.toml",
        error.NotEnoughCoins => std.fmt.allocPrint(pumpkin.abi.arena(), "you don't have enough {s}", .{settings.get().currency}) catch @panic("OOM"),
        error.NoRoom => "your inventory is full",
        else => coins.unreadable,
    };
}

fn bought(player: pumpkin.Player, offer: settings.Offer, bundles: u32, cost: u64) void {
    coins.tell(player, .green, "Bought {d} {s} for {s}.", .{ @as(u32, offer.count) * bundles, offer.key, coins.format(cost) });
}

pub fn open(player: pumpkin.Player) !void {
    const arena = pumpkin.abi.arena();
    const offers = settings.offers();
    var buttons: std.ArrayList(menu.Button) = .empty;
    for (offers, 0..) |offer, i| {
        if (offer.count == 0) continue;
        const name = try arena.dupe(msg.Span, &.{.{ .text = offer.key, .color = .yellow }});
        const price = try arena.dupe(msg.Span, &.{
            .{ .text = "Price: ", .color = .gray },
            .{ .text = coins.format(offer.price), .color = .gold },
        });
        const lore = try arena.dupe([]const msg.Span, &.{
            price,
            &.{},
            &.{.{ .text = "Click to buy one", .color = .dark_gray }},
            &.{.{ .text = std.fmt.comptimePrint("Shift click to buy {d}", .{bulk}), .color = .dark_gray }},
        });
        try buttons.append(arena, .{
            .slot = @intCast(i),
            .icon = .{ .id = offer.id, .count = offer.count, .name = name, .lore = lore },
            .on_click = clicked,
            .data = i,
        });
    }
    const wallet = try std.fmt.allocPrint(arena, "You have {s}", .{coins.format(try coins.balance(player))});
    try buttons.append(arena, .{
        .slot = balance_slot,
        .icon = .{ .id = "minecraft:sunflower", .name = try arena.dupe(msg.Span, &.{.{ .text = wallet, .color = .gold }}) },
    });
    menu.open(player, .{
        .screen = .generic_9x4,
        .title = &.{.{ .text = "Realm Shop", .color = .dark_green }},
        .buttons = buttons.items,
        .fill = .{ .id = "minecraft:black_stained_glass_pane", .name = &.{} },
    });
}

fn clicked(click: menu.Click) void {
    const offers = settings.offers();
    // The config may have been reloaded with fewer offers since the menu opened.
    if (click.data >= offers.len) return;
    const offer = offers[click.data];
    const bundles: u32 = switch (click.type) {
        .shift_left, .shift_right => bulk,
        else => 1,
    };
    if (buy(click.player, offer, bundles)) |cost| {
        bought(click.player, offer, bundles, cost);
    } else |err| {
        coins.tell(click.player, .red, "{s}.", .{problem(err)});
    }
    // Opened again so the balance is up to date.
    open(click.player) catch |err| std.log.err("can't open the shop ({t})", .{err});
}

pub fn command(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
    const player = sender.asPlayer() orelse return cmd.fail("only players can shop");
    open(player) catch return cmd.fail(coins.unreadable);
    return cmd.ok(1);
}

pub fn buyCommand(sender: cmd.Sender, _: pumpkin.Server, args: struct { offer: []const u8, bundles: u32 = 1 }) cmd.Result {
    const player = sender.asPlayer() orelse return cmd.fail("only players can shop");
    const offer = for (settings.offers()) |o| {
        if (std.mem.eql(u8, o.key, args.offer)) break o;
    } else return cmd.fail("the shop has no such offer, see /shop");
    const cost = buy(player, offer, args.bundles) catch |err| return cmd.fail(problem(err));
    bought(player, offer, args.bundles, cost);
    return cmd.ok(@intCast(args.bundles));
}

pub fn suggestOffers(_: cmd.Sender, _: pumpkin.Server, request: pumpkin.command.SuggestionRequest) pumpkin.command.CommandSuggestions {
    const offers = settings.offers();
    const keys = pumpkin.abi.arena().alloc([]const u8, offers.len) catch @panic("OOM");
    for (keys, offers) |*key, offer| key.* = offer.key;
    return cmd.suggestions(request, keys);
}
