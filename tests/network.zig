//! Runs every networking path of `pumpkin.io()` with /nettest and reports each one.
//! Everything but the timeout and DNS tests stays on the loopback interface.

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const msg = pumpkin.msg;

const net = std.Io.net;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const NetTest = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "nettest",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Tests the networking support with /nettest.",
        .permissions = &.{ "network.tcp", "network.udp", "network.dns" },
    };

    pub const commands: []const cmd.Spec = &.{.{
        .names = &.{"nettest"},
        .description = "Runs the networking tests.",
        .permission = "nettest:command.nettest",
        .default = .{ .op = .two },
        .run = run,
    }};

    const tests = .{
        .{ "tcp ipv4: 100 KiB both ways, shutdown, EOF", tcpRoundTrip4 },
        .{ "tcp ipv6: 100 KiB both ways, shutdown, EOF", tcpRoundTrip6 },
        .{ "tcp: listening on port 0 picks a port", ephemeralPort },
        .{ "tcp: ready() only once data is there", streamReady },
        .{ "tcp: closed port refuses", connectionRefused },
        .{ "tcp: connect timeout after 1s", connectTimeout },
        .{ "udp ipv4: datagrams both ways", udpRoundTrip4 },
        .{ "udp ipv6: datagrams both ways", udpRoundTrip6 },
        .{ "udp: datagram bigger than the buffer is cut", udpTruncation },
        .{ "dns: localhost resolves", lookupLocalhost },
        .{ "dns: unknown host fails", lookupUnknown },
    };

    fn run(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        var passed: i32 = 0;
        inline for (tests) |t| {
            if (t[1]()) |_| {
                passed += 1;
                report(sender, .green, "pass", t[0], "");
            } else |err| {
                report(sender, .red, "FAIL", t[0], @errorName(err));
            }
        }
        sender.sendMessage(msg.fmt(.gold, "{d}/{d} passed", .{ passed, tests.len }));
        return cmd.ok(passed);
    }

    fn report(sender: cmd.Sender, color: msg.Color, status: []const u8, name: []const u8, detail: []const u8) void {
        std.log.info("{s} {s} {s}", .{ status, name, detail });
        sender.sendMessage(msg.build(&.{
            .{ .text = status, .color = color, .bold = true },
            .{ .text = " " },
            .{ .text = name },
            .{ .text = if (detail.len > 0) std.fmt.allocPrint(pumpkin.abi.arena(), " ({s})", .{detail}) catch "" else "", .color = .gray },
        }));
    }

    fn pattern(len: usize, seed: u8) ![]u8 {
        const data = try pumpkin.abi.arena().alloc(u8, len);
        for (data, 0..) |*b, i| b.* = @truncate(i *% 31 +% seed);
        return data;
    }

    fn writeAll(stream: net.Stream, data: []const u8) !void {
        var buffer: [1024]u8 = undefined;
        var writer = stream.writer(pumpkin.io(), &buffer);
        try writer.interface.writeAll(data);
        try writer.interface.flush();
    }

    fn readAll(stream: net.Stream) ![]u8 {
        var buffer: [1500]u8 = undefined;
        var reader = stream.reader(pumpkin.io(), &buffer);
        return reader.interface.allocRemaining(pumpkin.abi.arena(), .unlimited);
    }

    fn tcpRoundTrip(local: net.IpAddress) !void {
        const io = pumpkin.io();
        var server = try local.listen(io, .{});
        defer server.deinit(io);

        const client = try server.socket.address.connect(io, .{ .mode = .stream });
        defer client.close(io);
        const accepted = try server.accept(io);
        defer accepted.close(io);

        const request = try pattern(100 * 1024, 1);
        try writeAll(client, request);
        try client.shutdown(io, .send);
        if (!std.mem.eql(u8, request, try readAll(accepted))) return error.RequestMismatch;

        const response = try pattern(100 * 1024, 7);
        try writeAll(accepted, response);
        try accepted.shutdown(io, .send);
        if (!std.mem.eql(u8, response, try readAll(client))) return error.ResponseMismatch;
    }

    fn tcpRoundTrip4() !void {
        try tcpRoundTrip(.{ .ip4 = .loopback(0) });
    }

    fn tcpRoundTrip6() !void {
        try tcpRoundTrip(.{ .ip6 = .loopback(0) });
    }

    fn ephemeralPort() !void {
        const io = pumpkin.io();
        const address: net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try address.listen(io, .{});
        defer server.deinit(io);
        if (server.socket.address.getPort() == 0) return error.NoPortAssigned;
    }

    fn streamReady() !void {
        const io = pumpkin.io();
        const address: net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try address.listen(io, .{});
        defer server.deinit(io);

        if (pumpkin.net.ready(server.socket.handle)) return error.ReadyWithoutClient;
        const client = try server.socket.address.connect(io, .{ .mode = .stream });
        defer client.close(io);
        if (!waitReady(server.socket.handle)) return error.NotReadyWithClient;

        const accepted = try server.accept(io);
        defer accepted.close(io);
        if (pumpkin.net.ready(accepted.socket.handle)) return error.ReadyWithoutData;
        try writeAll(client, "ping");
        if (!waitReady(accepted.socket.handle)) return error.NotReadyWithData;
    }

    /// The other end runs in the same process, give the kernel a moment.
    fn waitReady(handle: net.Socket.Handle) bool {
        for (0..100) |_| {
            if (pumpkin.net.ready(handle)) return true;
            pumpkin.io().sleep(.fromMilliseconds(10), .awake) catch {};
        }
        return false;
    }

    fn connectionRefused() !void {
        const io = pumpkin.io();
        const address: net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try address.listen(io, .{});
        const closed = server.socket.address;
        server.deinit(io);

        const stream = closed.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
            error.ConnectionRefused => return,
            else => |e| return e,
        };
        stream.close(io);
        return error.Connected;
    }

    fn connectTimeout() !void {
        const io = pumpkin.io();
        const unroutable: net.IpAddress = .{ .ip4 = .{ .bytes = .{ 10, 255, 255, 1 }, .port = 80 } };
        const start = std.Io.Clock.awake.now(io);
        const stream = unroutable.connect(io, .{
            .mode = .stream,
            .timeout = .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } },
        }) catch |err| switch (err) {
            error.Timeout => {
                const took = start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
                if (took < 900 or took > 3000) return error.WrongDuration;
                return;
            },
            else => |e| return e,
        };
        stream.close(io);
        return error.Connected;
    }

    fn udpRoundTrip(local: net.IpAddress) !void {
        const io = pumpkin.io();
        const a = try local.bind(io, .{ .mode = .dgram });
        defer a.close(io);
        const b = try local.bind(io, .{ .mode = .dgram });
        defer b.close(io);

        for ([_][]const u8{ "one", "two", "three" }) |text| try a.send(io, &b.address, text);
        var buffer: [64]u8 = undefined;
        for ([_][]const u8{ "one", "two", "three" }) |text| {
            const message = try b.receive(io, &buffer);
            if (!std.mem.eql(u8, text, message.data)) return error.DatagramMismatch;
            if (message.from.getPort() != a.address.getPort()) return error.WrongSender;
        }

        try b.send(io, &a.address, "reply");
        const reply = try a.receive(io, &buffer);
        if (!std.mem.eql(u8, "reply", reply.data)) return error.ReplyMismatch;
        if (pumpkin.net.ready(a.handle)) return error.ReadyWhenEmpty;
    }

    fn udpRoundTrip4() !void {
        try udpRoundTrip(.{ .ip4 = .loopback(0) });
    }

    fn udpRoundTrip6() !void {
        try udpRoundTrip(.{ .ip6 = .loopback(0) });
    }

    fn udpTruncation() !void {
        const io = pumpkin.io();
        const local: net.IpAddress = .{ .ip4 = .loopback(0) };
        const a = try local.bind(io, .{ .mode = .dgram });
        defer a.close(io);
        const b = try local.bind(io, .{ .mode = .dgram });
        defer b.close(io);

        try a.send(io, &b.address, try pattern(2000, 3));
        var buffer: [512]u8 = undefined;
        const message = try b.receive(io, &buffer);
        if (message.data.len != buffer.len) return error.WrongLength;
        if (!message.flags.trunc) return error.NotMarkedTruncated;
    }

    fn lookup(name: []const u8) !usize {
        const io = pumpkin.io();
        const host: net.HostName = try .init(name);
        var buffer: [16]net.HostName.LookupResult = undefined;
        var results: std.Io.Queue(net.HostName.LookupResult) = .init(&buffer);
        try host.lookup(io, &results, .{ .port = 0 });
        var count: usize = 0;
        while (results.getOne(io)) |result| {
            if (result == .address) count += 1;
        } else |_| {}
        return count;
    }

    fn lookupLocalhost() !void {
        if (try lookup("localhost") == 0) return error.NoAddresses;
    }

    fn lookupUnknown() !void {
        const count = lookup("does-not-exist.invalid") catch |err| switch (err) {
            error.UnknownHostName => return,
            else => |e| return e,
        };
        _ = count;
        return error.Resolved;
    }
};

comptime {
    pumpkin.register(NetTest);
}
