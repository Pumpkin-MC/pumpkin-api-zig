//! A TCP server that bridges the chat: lines sent to it show up in the game,
//! and chat messages are sent to everyone connected.
//!
//! Try it with `nc 127.0.0.1 25580`.

const std = @import("std");
const pumpkin = @import("pumpkin");

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const port = 25580;

const Client = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    buffer: [1024]u8,
};

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

    var server: std.Io.net.Server = undefined;
    var clients: std.ArrayList(*Client) = .empty;

    pub fn onLoad(_: pumpkin.Context) !void {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        server = try address.listen(pumpkin.io(), .{ .reuse_address = true });
        _ = pumpkin.runEvery(poll, 0, 1);
        std.log.info("listening on {f}", .{server.socket.address});
    }

    pub fn onUnload(_: pumpkin.Context) !void {
        while (clients.items.len > 0) drop(0);
        server.deinit(pumpkin.io());
    }

    /// Runs every tick and only touches sockets that have something waiting,
    /// so it never blocks the server.
    fn poll(srv: pumpkin.Server) void {
        const io = pumpkin.io();
        while (pumpkin.net.ready(server.socket.handle)) {
            const stream = server.accept(io) catch break;
            const client = pumpkin.abi.heap.create(Client) catch @panic("OOM");
            client.stream = stream;
            client.reader = stream.reader(io, &client.buffer);
            clients.append(pumpkin.abi.heap, client) catch @panic("OOM");
            send(client, "connected to the Minecraft chat\n");
        }

        var i: usize = 0;
        while (i < clients.items.len) {
            const client = clients.items[i];
            const reader = &client.reader.interface;
            if (pumpkin.net.ready(client.stream.socket.handle)) {
                reader.fillMore() catch {
                    drop(i);
                    continue;
                };
            }
            while (std.mem.indexOfScalar(u8, reader.buffered(), '\n') != null) {
                const line = (reader.takeDelimiter('\n') catch break) orelse break;
                const text = std.fmt.allocPrint(pumpkin.abi.arena(), "[tcp] {s}", .{std.mem.trimEnd(u8, line, "\r")}) catch return;
                srv.broadcast(text);
            }
            if (reader.bufferedLen() == client.buffer.len) {
                drop(i);
                continue;
            }
            i += 1;
        }
    }

    fn onChat(_: pumpkin.Server, ev: *pumpkin.EventData(.player_chat_event)) void {
        const line = std.fmt.allocPrint(pumpkin.abi.arena(), "<{s}> {s}\n", .{ ev.player.getName(), ev.message }) catch return;
        for (clients.items) |client| send(client, line);
    }

    fn send(client: *Client, line: []const u8) void {
        var writer = client.stream.writer(pumpkin.io(), &.{});
        writer.interface.writeAll(line) catch {};
    }

    fn drop(i: usize) void {
        const client = clients.swapRemove(i);
        client.stream.close(pumpkin.io());
        pumpkin.abi.heap.destroy(client);
    }
};

comptime {
    pumpkin.register(TcpServer);
}
