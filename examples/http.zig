//! A TCP connection with a timeout, sending a plain HTTP request.

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const msg = pumpkin.msg;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const Http = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-http",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Asks a web server for its status line with /fetch <host>.",
        .permissions = &.{ "network.dns", "network.tcp.connect" },
    };

    pub const commands: []const cmd.Spec = &.{.{
        .names = &.{"fetch"},
        .description = "Sends an HTTP request to a host and shows the status line.",
        .permission = "example-http:command.fetch",
        .default = .{ .op = .two },
        .then = &.{
            .argument("host", .{ .string = .single_word }, .{ .run = cmd.typed(fetch) }),
        },
    }};

    fn fetch(sender: cmd.Sender, _: pumpkin.Server, args: struct { host: []const u8 }) cmd.Result {
        const status = statusLine(args.host) catch |err| return cmd.fail(@errorName(err));
        sender.sendMessage(msg.fmt(.green, "{s}: {s}", .{ args.host, status }));
        return cmd.ok(1);
    }

    fn statusLine(host_name: []const u8) ![]const u8 {
        const io = pumpkin.io();
        const host: std.Io.net.HostName = try .init(host_name);
        const stream = try host.connect(io, 80, .{
            .mode = .stream,
            .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
        });
        defer stream.close(io);

        var write_buffer: [512]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        try writer.interface.print("GET / HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{host_name});
        try writer.interface.flush();

        var read_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        const line = try reader.interface.takeDelimiterExclusive('\n');
        return pumpkin.abi.arena().dupe(u8, std.mem.trimEnd(u8, line, "\r"));
    }
};

comptime {
    pumpkin.register(Http);
}
