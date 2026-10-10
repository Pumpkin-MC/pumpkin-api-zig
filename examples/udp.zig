//! A UDP socket that posts datagrams to the chat and answers each one.
//!
//! Try it with `echo hello | nc -u -w1 127.0.0.1 25581`.

const std = @import("std");
const pumpkin = @import("pumpkin");

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const port = 25581;

const Udp = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-udp",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Posts UDP datagrams sent to port 25581 to the chat.",
        .permissions = &.{"network.udp"},
    };

    var socket: std.Io.net.Socket = undefined;

    pub fn onLoad(_: pumpkin.Context) !void {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        socket = try address.bind(pumpkin.io(), .{ .mode = .dgram });
        _ = pumpkin.runEvery(poll, 0, 1);
        std.log.info("listening on {f}", .{socket.address});
    }

    pub fn onUnload(_: pumpkin.Context) !void {
        socket.close(pumpkin.io());
    }

    /// Runs every tick and only receives when a datagram is waiting.
    fn poll(srv: pumpkin.Server) void {
        const io = pumpkin.io();
        while (pumpkin.net.ready(socket.handle)) {
            var buffer: [512]u8 = undefined;
            const message = socket.receive(io, &buffer) catch return;
            const text = std.mem.trimEnd(u8, message.data, "\r\n");
            const line = std.fmt.allocPrint(pumpkin.abi.arena(), "[udp {f}] {s}", .{ message.from, text }) catch return;
            srv.broadcast(line);
            socket.send(io, &message.from, "got it\n") catch |err| std.log.warn("reply failed: {t}", .{err});
        }
    }
};

comptime {
    pumpkin.register(Udp);
}
