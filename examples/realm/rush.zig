//! Coin rushes: for a while ores pay more, and a boss bar counts down.

const std = @import("std");
const pumpkin = @import("pumpkin");
const msg = pumpkin.msg;
const tasks = pumpkin.tasks;
const coins = @import("coins.zig");
const settings = @import("settings.zig");

const BossBar = pumpkin.boss_bar.BossBar;

const Timer = struct { left: u32, total: u32 };

var active: ?struct { task: tasks.Task, bar: BossBar } = null;

/// What ore rewards are multiplied by right now.
pub fn multiplier() u32 {
    return if (active != null) settings.get().rush.multiplier else 1;
}

pub fn start(srv: pumpkin.Server, seconds: u32) error{AlreadyRunning}!void {
    if (active != null) return error.AlreadyRunning;
    const length = @max(seconds, 1);
    const times = settings.get().rush.multiplier;

    const bar: BossBar = .init(title(length), .yellow, .notches_10);
    bar.keep();
    for (srv.getAllPlayers()) |player| {
        player.showTitle(msg.span(.{ .text = "Coin Rush!", .color = .gold, .bold = true }));
        player.showSubtitle(msg.fmt(.yellow, "Ores pay {d}× for {d} seconds", .{ times, length }));
        // Last, since the bar takes the handle.
        bar.addPlayer(player);
    }
    active = .{ .task = tasks.every(.seconds(1), tick, Timer{ .left = length, .total = length }), .bar = bar };
    notify(std.fmt.allocPrint(pumpkin.abi.arena(), "A coin rush started: ores pay {d}× for {d} seconds!", .{ times, length }) catch @panic("OOM"));
}

fn tick(_: pumpkin.Server, timer: *Timer, task: tasks.Task) void {
    const rush = active orelse return task.cancel();
    timer.left -|= 1;
    if (timer.left == 0) {
        stop();
        coins.announce(.gold, "The coin rush is over.", .{});
        return;
    }
    rush.bar.setTitle(title(timer.left));
    rush.bar.setHealth(@as(f32, @floatFromInt(timer.left)) / @as(f32, @floatFromInt(timer.total)));
}

fn title(left: u32) pumpkin.TextComponent {
    const rest = std.fmt.allocPrint(pumpkin.abi.arena(), "  {d}× ore rewards, {d}s left", .{ settings.get().rush.multiplier, left }) catch @panic("OOM");
    return msg.build(&.{
        .{ .text = "Coin Rush", .color = .gold, .bold = true },
        .{ .text = rest, .color = .yellow },
    });
}

/// Shows the bar of a running rush to a player who just joined. The bar
/// takes the handle it is given, and the event's handle has to go back to
/// the server, so this looks the player up again.
pub fn show(srv: pumpkin.Server, id: pumpkin.uuid.Uuid) void {
    const rush = active orelse return;
    const player = srv.getPlayerByUuid(id) orelse return;
    rush.bar.addPlayer(player);
}

pub fn isRunning() bool {
    return active != null;
}

/// Ends the rush, if one is running, and hides its bar.
pub fn stop() void {
    const rush = active orelse return;
    rush.task.cancel();
    rush.bar.deinit();
    active = null;
}

/// Posts `text` to the webhook from the config, if there is one. This waits
/// for the response, which is fine for something as rare as a rush.
fn notify(text: []const u8) void {
    const url = settings.get().webhook;
    if (url.len == 0) return;
    const res = pumpkin.http.sendJson(.POST, url, .{ .content = text }, .{}) catch |err| {
        std.log.warn("the webhook failed ({t}), it needs the network.dns and network.tcp.connect permissions", .{err});
        return;
    };
    if (!res.ok()) std.log.warn("the webhook answered {d}", .{@intFromEnum(res.status)});
}
