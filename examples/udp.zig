//! A UDP socket that posts datagrams to the chat and answers each one.
//!
//! Try it with `echo hello | nc -u -w1 127.0.0.1 25581`.

const std = @import("std");
const pumpkin = @import("pumpkin");
const net = pumpkin.net;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const Udp = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-udp",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Posts UDP datagrams sent to port 25581 to the chat.",
        .permissions = &.{"network.udp"},
    };

    var game: pumpkin.Server = undefined;

    pub fn onLoad(ctx: pumpkin.Context) !void {
        game = ctx.getServer();
        game.keep();
        const socket = try net.udp(.{ .port = 25581, .on_datagram = onDatagram });
        std.log.info("listening on {f}", .{socket.address()});
    }

    fn onDatagram(socket: *net.Udp, from: net.Address, data: []const u8) void {
        const text = std.mem.trimEnd(u8, data, "\r\n");
        game.broadcast(std.fmt.allocPrint(pumpkin.abi.arena(), "[udp {f}] {s}", .{ from, text }) catch return);
        socket.sendTo(from, "got it\n") catch |err| std.log.warn("reply failed: {t}", .{err});
    }
};

comptime {
    pumpkin.register(Udp);
}
