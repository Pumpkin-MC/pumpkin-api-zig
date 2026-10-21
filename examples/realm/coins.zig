//! The coins of every player, the sidebar that shows them and the daily reward.

const std = @import("std");
const pumpkin = @import("pumpkin");
const msg = pumpkin.msg;
const settings = @import("settings.zig");

pub const Profile = struct {
    coins: u64 = 0,
    /// Whether the player has had their starting coins.
    welcomed: bool = false,
    streak: u32 = 0,
    /// The day of the last daily reward, counted in UTC days since 1970.
    last_daily: i64 = 0,
};

/// One TOML file per player in `plugins/data/example-realm/players/`.
pub var profiles: pumpkin.store.Store(Profile) = .{ .dir = "players", .codec = pumpkin.store.toml(Profile) };

/// The server, kept from `onLoad` for code that isn't handed one.
pub var game: pumpkin.Server = undefined;

pub const Error = pumpkin.store.Error;

/// What commands answer when a profile can't be read.
pub const unreadable = "your coins can't be read, see the server log";

pub fn balance(player: pumpkin.Player) Error!u64 {
    return (try profiles.player(player)).coins;
}

/// Adds `amount` to the player's coins and returns their new balance.
pub fn deposit(player: pumpkin.Player, amount: u64) Error!u64 {
    const profile = try profiles.player(player);
    profile.coins +|= amount;
    showOnSidebar(player.getName(), profile.coins);
    return profile.coins;
}

/// Takes `amount` from the player's coins. If they have less, takes nothing
/// and returns false.
pub fn withdraw(player: pumpkin.Player, amount: u64) Error!bool {
    const profile = try profiles.player(player);
    if (profile.coins < amount) return false;
    profile.coins -= amount;
    showOnSidebar(player.getName(), profile.coins);
    return true;
}

/// An amount with the currency's name, such as "250 coins".
pub fn format(amount: u64) []const u8 {
    return std.fmt.allocPrint(pumpkin.abi.arena(), "{d} {s}", .{ amount, settings.get().currency }) catch @panic("OOM");
}

pub const tag: msg.Span = .{ .text = "[Realm] ", .color = .gold, .bold = true };

/// A chat line that starts with the plugin's tag.
pub fn note(color: msg.Color, comptime fmt: []const u8, args: anytype) pumpkin.TextComponent {
    const text = std.fmt.allocPrint(pumpkin.abi.arena(), fmt, args) catch @panic("OOM");
    return msg.build(&.{ tag, .{ .text = text, .color = color } });
}

pub fn tell(player: pumpkin.Player, color: msg.Color, comptime fmt: []const u8, args: anytype) void {
    player.sendSystemMessage(note(color, fmt, args), false);
}

/// Sends a `note` to everyone online.
pub fn announce(color: msg.Color, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(pumpkin.abi.arena(), fmt, args) catch @panic("OOM");
    for (game.getAllPlayers()) |player| tell(player, color, "{s}", .{text});
}

const objective = "realm_coins";

/// Whether the worlds have the objective yet. The worlds may not exist
/// while the plugin loads, so it is added on first use.
var sidebar_ready = false;

pub fn showOnSidebar(name: []const u8, coins: u64) void {
    const worlds = game.getAllWorlds();
    for (worlds) |world| {
        const board = world.getScoreboard();
        if (!sidebar_ready) {
            const title = std.fmt.allocPrint(pumpkin.abi.arena(), "Realm {s}", .{settings.get().currency}) catch @panic("OOM");
            board.addObjective(objective, msg.span(.{ .text = title, .color = .gold, .bold = true }), .integer, null);
            board.setDisplaySlot(.sidebar, objective);
        }
        board.updateScore(name, objective, @intCast(@min(coins, std.math.maxInt(i32))), null);
    }
    if (worlds.len > 0) sidebar_ready = true;
}

pub fn hideFromSidebar(name: []const u8) void {
    if (!sidebar_ready) return;
    for (game.getAllWorlds()) |world| world.getScoreboard().removeScore(name, objective);
}

/// Takes the objective off every world, so it doesn't stay behind when the plugin unloads.
pub fn removeSidebar() void {
    if (!sidebar_ready) return;
    for (game.getAllWorlds()) |world| world.getScoreboard().removeObjective(objective);
    sidebar_ready = false;
}

pub const seconds_per_day = 24 * 60 * 60;

/// Seconds since 1970.
pub fn now() i64 {
    return std.Io.Clock.real.now(pumpkin.io()).toSeconds();
}

pub fn today() i64 {
    return @divFloor(now(), seconds_per_day);
}

pub const Claim = struct { streak: u32, coins: u64 };

/// Returns the daily reward for claiming on `day`, or null if it was claimed
/// already. Claiming the day after the last claim continues the streak, any
/// later day starts it over.
pub fn claimDaily(rules: settings.Daily, streak: u32, last_day: i64, day: i64) ?Claim {
    if (last_day >= day) return null;
    const next = if (last_day == day - 1) streak +| 1 else 1;
    const capped = @min(next, @max(rules.max_streak, 1));
    return .{ .streak = capped, .coins = rules.coins + @as(u64, rules.streak_bonus) * (capped - 1) };
}

test "daily streaks continue on the next day, start over after a gap and stop at the cap" {
    const rules: settings.Daily = .{ .coins = 50, .streak_bonus = 10, .max_streak = 3 };
    try std.testing.expectEqual(@as(?Claim, null), claimDaily(rules, 2, 100, 100));
    try std.testing.expectEqual(@as(?Claim, null), claimDaily(rules, 2, 101, 100));
    try std.testing.expectEqual(@as(?Claim, .{ .streak = 1, .coins = 50 }), claimDaily(rules, 0, 0, 100));
    try std.testing.expectEqual(@as(?Claim, .{ .streak = 2, .coins = 60 }), claimDaily(rules, 1, 99, 100));
    try std.testing.expectEqual(@as(?Claim, .{ .streak = 1, .coins = 50 }), claimDaily(rules, 2, 98, 100));
    try std.testing.expectEqual(@as(?Claim, .{ .streak = 3, .coins = 70 }), claimDaily(rules, 3, 99, 100));
}
