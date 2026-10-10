//! A TCP server that bridges the chat: lines sent to it show up in the game,
//! and chat messages are sent to everyone connected.
//!
//! Try it with `nc 127.0.0.1 25580`.

const std = @import("std");
const pumpkin = @import("pumpkin");
const net = pumpkin.net;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const TcpServer = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-tcp-server",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Bridges the chat to TCP clients on port 25580.",
        .permissions = &.{"network.tcp.bind"},
    };

    pub const events = .{
        .player_chat_event = .{ onChat, pumpkin.EventOptions{ .blocking = false } },
    };

    var server: *net.Listener = undefined;
    var game: pumpkin.Server = undefined;

    pub fn onLoad(ctx: pumpkin.Context) !void {
        game = ctx.getServer();
        game.keep();
        server = try net.listen(.{
            .port = 25580,
            .on_connect = onConnect,
            .callbacks = .{ .on_line = onLine },
        });
        std.log.info("listening on {f}", .{server.address()});
    }

    fn onConnect(conn: *net.Connection) void {
        conn.send("connected to the Minecraft chat\n") catch {};
    }

    fn onLine(_: *net.Connection, line: []const u8) void {
        game.broadcast(std.fmt.allocPrint(pumpkin.abi.arena(), "[tcp] {s}", .{line}) catch return);
    }

    fn onChat(_: pumpkin.Server, ev: *pumpkin.EventData(.player_chat_event)) void {
        server.broadcast(std.fmt.allocPrint(pumpkin.abi.arena(), "<{s}> {s}\n", .{ ev.player.getName(), ev.message }) catch return);
    }
};

comptime {
    pumpkin.register(TcpServer);
}
