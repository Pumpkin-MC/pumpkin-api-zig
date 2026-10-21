//! Realm, a small economy built with every helper of the package. Players
//! earn coins by mining ores, from a daily reward with a streak and on
//! payday, and spend them in a shop menu or with `/buy`. They pay each other
//! with `/pay`, confirmed in chat, and turn coins into cheques that cash with
//! a right click. Operators start coin rushes, during which ores pay more and
//! a boss bar counts down. A sidebar shows everyone's coins, a ledger answers
//! over TCP, an optional webhook hears about rushes, and other plugins can
//! ask for balances over IPC. Everything is set in
//! `plugins/data/example-realm/config.toml`.

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const menu = pumpkin.menu;
const msg = pumpkin.msg;
const prompt = pumpkin.prompt;
const tasks = pumpkin.tasks;

const cheque = @import("cheque.zig");
const coins = @import("coins.zig");
const ledger = @import("ledger.zig");
const pay = @import("pay.zig");
const rush = @import("rush.zig");
const settings = @import("settings.zig");
const shop = @import("shop.zig");

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const Realm = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-realm",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "A small economy with a shop, daily rewards, payments, cheques and coin rushes.",
        .permissions = &.{ "fs.read.data", "fs.write.data", "network.dns", "network.tcp.connect", "network.tcp.bind" },
    };

    pub const events = .{
        .player_join_event = onJoin,
        .player_leave_event = onLeave,
        .block_break_event = onBreak,
        .player_interact_event = cheque.onInteract,
    };

    pub const commands: []const cmd.Spec = &.{ .{
        .names = &.{"realm"},
        .description = "Shows your coins and what you can do with them.",
        .permission = "example-realm:command.realm",
        .run = overview,
    }, .{
        .names = &.{ "balance", "bal" },
        .description = "Shows your coins or another player's.",
        .permission = "example-realm:command.balance",
        .run = cmd.typed(showBalance),
        .then = &.{.argument("target", .players, .{ .run = cmd.typed(showBalance) })},
    }, .{
        .names = &.{"daily"},
        .description = "Claims your daily reward.",
        .permission = "example-realm:command.daily",
        .run = daily,
    }, .{
        .names = &.{"pay"},
        .description = "Gives coins to another player.",
        .permission = "example-realm:command.pay",
        .then = &.{.argument("target", .players, .{
            .run = cmd.typed(pay.command),
            .then = &.{.argument("amount", .{ .integer = .{ 1, pay.max_amount } }, .{ .run = cmd.typed(pay.command) })},
        })},
    }, .{
        .names = &.{"shop"},
        .description = "Opens the shop.",
        .permission = "example-realm:command.shop",
        .run = shop.command,
    }, .{
        .names = &.{"buy"},
        .description = "Buys an offer from the shop without opening it.",
        .permission = "example-realm:command.buy",
        .then = &.{.argument("offer", .{ .string = .single_word }, .{
            .run = cmd.typed(shop.buyCommand),
            .suggest = shop.suggestOffers,
            .then = &.{.argument("bundles", .{ .integer = .{ 1, shop.max_bundles } }, .{ .run = cmd.typed(shop.buyCommand) })},
        })},
    }, .{
        .names = &.{"cheque"},
        .description = "Turns coins into a cheque you can hand to someone.",
        .permission = "example-realm:command.cheque",
        .then = &.{.argument("amount", .{ .integer = .{ 1, pay.max_amount } }, .{ .run = cmd.typed(cheque.command) })},
    }, .{
        .names = &.{"realmadmin"},
        .description = "Reloads the config, starts a coin rush or grants coins.",
        .permission = "example-realm:command.admin",
        .default = .{ .op = .two },
        .then = &.{
            .literal("reload", .{ .run = reload }),
            .literal("rush", .{
                .run = cmd.typed(startRush),
                .then = &.{.argument("seconds", .{ .integer = .{ 10, 3600 } }, .{ .run = cmd.typed(startRush) })},
            }),
            .literal("grant", .{ .then = &.{.argument("targets", .players, .{
                .then = &.{.argument("amount", .{ .integer = .{ 1, pay.max_amount } }, .{ .run = cmd.typed(grant) })},
            })} }),
        },
    } };

    pub const onIpcMessage = ledger.onIpcMessage;

    var payday_task: ?tasks.Task = null;

    pub fn onLoad(ctx: pumpkin.Context) !void {
        coins.game = ctx.getServer();
        coins.game.keep();
        try settings.file.load();
        menu.listen(ctx);
        try prompt.listen(ctx, .{});
        apply();
    }

    pub fn onUnload(_: pumpkin.Context) !void {
        rush.stop();
        coins.removeSidebar();
    }

    /// Starts what the config asks for, again after every reload.
    fn apply() void {
        if (payday_task) |task| task.cancel();
        const minutes = settings.get().payday.minutes;
        payday_task = if (minutes > 0) tasks.every(.minutes(minutes), payday, {}) else null;
        ledger.apply();
    }

    fn payday(srv: pumpkin.Server) void {
        const amount = settings.get().payday.coins;
        if (amount == 0) return;
        for (srv.getAllPlayers()) |player| {
            _ = coins.deposit(player, amount) catch continue;
            player.sendSystemMessage(msg.fmt(.gold, "Payday! +{s}", .{coins.format(amount)}), true);
        }
    }

    fn onJoin(srv: pumpkin.Server, ev: *pumpkin.EventData(.player_join_event)) void {
        const player = ev.player;
        const profile = coins.profiles.player(player) catch return;
        if (!profile.welcomed) {
            profile.welcomed = true;
            const start = settings.get().starting_coins;
            profile.coins +|= start;
            coins.tell(player, .green, "Welcome to the realm! Here are {s} to start with.", .{coins.format(start)});
        }
        coins.showOnSidebar(player.getName(), profile.coins);
        rush.show(srv, player.getId());
        _ = tasks.after(.seconds(3), remindDaily, player.getId());
    }

    fn remindDaily(srv: pumpkin.Server, id: pumpkin.uuid.Uuid) void {
        const player = srv.getPlayerByUuid(id) orelse return;
        const profile = coins.profiles.player(player) catch return;
        if (coins.claimDaily(settings.get().daily, profile.streak, profile.last_daily, coins.today()) == null) return;
        player.sendSystemMessage(msg.build(&.{
            coins.tag,
            .{ .text = "Your daily reward is ready. ", .color = .yellow },
            .{ .text = "[Claim]", .color = .green, .bold = true, .click = .{ .run_command = "/daily" }, .hover = "Runs /daily" },
        }), false);
    }

    fn onLeave(_: pumpkin.Server, ev: *pumpkin.EventData(.player_leave_event)) void {
        coins.hideFromSidebar(ev.player.getName());
    }

    fn onBreak(_: pumpkin.Server, ev: *pumpkin.EventData(.block_break_event)) void {
        if (ev.cancelled) return;
        const player = ev.player orelse return;
        const reward = for (settings.get().ores) |ore| {
            if (std.mem.eql(u8, ore.block, ev.block)) break ore.coins;
        } else return;
        const earned = @as(u64, reward) * rush.multiplier();
        if (earned == 0) return;
        const total = coins.deposit(player, earned) catch return;
        player.sendSystemMessage(msg.build(&.{
            .{ .text = std.fmt.allocPrint(pumpkin.abi.arena(), "+{s}", .{coins.format(earned)}) catch @panic("OOM"), .color = .gold },
            .{ .text = std.fmt.allocPrint(pumpkin.abi.arena(), "  ({d})", .{total}) catch @panic("OOM"), .color = .gray },
        }), true);
    }

    fn overview(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("only players have coins");
        const profile = coins.profiles.player(player) catch return cmd.fail(coins.unreadable);
        const streak = std.fmt.allocPrint(pumpkin.abi.arena(), "  ·  daily streak {d}", .{profile.streak}) catch @panic("OOM");
        sender.sendMessage(msg.build(&.{
            coins.tag,
            .{ .text = coins.format(profile.coins), .color = .gold },
            .{ .text = streak, .color = .gray },
            .{ .text = "\n  " },
            .{ .text = "[Shop]", .color = .aqua, .click = .{ .run_command = "/shop" }, .hover = "Opens the shop" },
            .{ .text = "  " },
            .{ .text = "[Daily]", .color = .green, .click = .{ .run_command = "/daily" }, .hover = "Claims your daily reward" },
            .{ .text = "  " },
            .{ .text = "[Pay]", .color = .yellow, .click = .{ .suggest_command = "/pay " }, .hover = "Gives coins to another player" },
            .{ .text = "  " },
            .{ .text = "[Cheque]", .color = .light_purple, .click = .{ .suggest_command = "/cheque " }, .hover = "Turns coins into an item" },
        }));
        return cmd.ok(1);
    }

    fn showBalance(sender: cmd.Sender, _: pumpkin.Server, args: struct { target: ?pumpkin.Player }) cmd.Result {
        const target = args.target orelse sender.asPlayer() orelse return cmd.fail("say whose coins to show, for example /balance Steve");
        const balance = coins.balance(target) catch return cmd.fail(coins.unreadable);
        sender.sendMessage(coins.note(.gold, "{s} has {s}.", .{ target.getName(), coins.format(balance) }));
        return cmd.ok(@intCast(@min(balance, std.math.maxInt(i32))));
    }

    fn daily(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("only players get a daily reward");
        const profile = coins.profiles.player(player) catch return cmd.fail(coins.unreadable);
        const now = coins.now();
        const today = @divFloor(now, coins.seconds_per_day);
        const claim = coins.claimDaily(settings.get().daily, profile.streak, profile.last_daily, today) orelse {
            const wait = coins.seconds_per_day - @mod(now, coins.seconds_per_day);
            return cmd.failWith(msg.fmt(.red, "You already claimed today, come back in {d}h {d}m.", .{ @divFloor(wait, 3600), @divFloor(@mod(wait, 3600), 60) }));
        };
        profile.streak = claim.streak;
        profile.last_daily = today;
        const total = coins.deposit(player, claim.coins) catch return cmd.fail(coins.unreadable);
        sender.sendMessage(coins.note(.green, "You got {s} on day {d} of your streak, and have {s} now.", .{ coins.format(claim.coins), claim.streak, coins.format(total) }));
        const x, const y, const z = player.getPosition();
        player.spawnParticles(.happy_villager, .{ x, y + 1, z }, 20, .{ 0.5, 0.5, 0.5 }, 0.1);
        return cmd.ok(1);
    }

    fn reload(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        settings.file.load() catch return cmd.fail("the config has an error, see the server log");
        apply();
        sender.sendMessage(coins.note(.green, "Reloaded {s}.", .{settings.file.path}));
        return cmd.ok(1);
    }

    fn startRush(sender: cmd.Sender, srv: pumpkin.Server, args: struct { seconds: ?u32 }) cmd.Result {
        rush.start(srv, args.seconds orelse settings.get().rush.seconds) catch return cmd.fail("a coin rush is already running");
        sender.sendMessage(coins.note(.green, "Started a coin rush.", .{}));
        return cmd.ok(1);
    }

    fn grant(sender: cmd.Sender, _: pumpkin.Server, args: struct { targets: []const pumpkin.Player, amount: u32 }) cmd.Result {
        var granted: i32 = 0;
        for (args.targets) |target| {
            _ = coins.deposit(target, args.amount) catch continue;
            coins.tell(target, .green, "You were granted {s}.", .{coins.format(args.amount)});
            granted += 1;
        }
        sender.sendMessage(coins.note(.green, "Granted {s} to {d} player(s).", .{ coins.format(args.amount), granted }));
        return cmd.ok(granted);
    }
};

comptime {
    if (!@import("builtin").is_test) pumpkin.register(Realm);
}

test {
    _ = coins;
}
