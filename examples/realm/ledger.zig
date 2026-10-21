//! Balances for the world outside the game: a read-only ledger over TCP on
//! 127.0.0.1, which `nc 127.0.0.1 25581` can talk to, and answers to other
//! plugins over IPC.

const std = @import("std");
const pumpkin = @import("pumpkin");
const net = pumpkin.net;
const coins = @import("coins.zig");
const rush = @import("rush.zig");
const settings = @import("settings.zig");

var listener: ?*net.Listener = null;

/// Opens, moves or closes the ledger as the config says.
pub fn apply() void {
    const port = settings.get().ledger_port;
    if (listener) |l| {
        if (l.options.port == port) return;
        l.close();
        listener = null;
    }
    if (port == 0) return;
    listener = net.listen(.{
        .port = port,
        .on_connect = greet,
        .callbacks = .{ .on_line = answer },
    }) catch |err| {
        std.log.err("can't open the ledger on port {d} ({t}), it needs the network.tcp.bind permission", .{ port, err });
        return;
    };
    std.log.info("the ledger listens on {f}", .{listener.?.address()});
}

fn greet(conn: *net.Connection) void {
    conn.send("realm ledger, type help\n") catch {};
}

fn answer(conn: *net.Connection, line: []const u8) void {
    const command = std.mem.trim(u8, line, " \t");
    if (std.mem.eql(u8, command, "online")) {
        for (coins.game.getAllPlayers()) |player| {
            const balance = coins.balance(player) catch continue;
            conn.print("{s} {d}\n", .{ player.getName(), balance }) catch return;
        }
        conn.send("end\n") catch {};
    } else if (std.mem.eql(u8, command, "rush")) {
        conn.send(if (rush.isRunning()) "rush on\n" else "rush off\n") catch {};
    } else if (std.mem.eql(u8, command, "quit")) {
        conn.close();
    } else {
        conn.send("commands: online, rush, quit\n") catch {};
    }
}

/// Answers "balance <uuid>" with the player's coins.
pub fn onIpcMessage(_: pumpkin.ipc.PluginId, message: pumpkin.ipc.IpcMessage) pumpkin.abi.Result(pumpkin.ipc.IpcMessage, []const u8) {
    const prefix = "balance ";
    if (!std.mem.startsWith(u8, message, prefix)) return .{ .err = "expected \"balance <uuid>\"" };
    const id = pumpkin.uuid.parse(std.mem.trim(u8, message[prefix.len..], " ")) orelse return .{ .err = "not a UUID" };
    // Profiles are named after the UUID as the server prints it, so any
    // other spelling of it is printed that way first.
    const key = pumpkin.uuid.toString(id);
    if (!coins.profiles.exists(key)) return .{ .err = "no such player" };
    const profile = coins.profiles.get(key) catch return .{ .err = "that player's coins can't be read" };
    return .{ .ok = std.fmt.allocPrint(pumpkin.abi.arena(), "{d}", .{profile.coins}) catch @panic("OOM") };
}
