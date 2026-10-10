//! Looking up the addresses of a host name.

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const msg = pumpkin.msg;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const Dns = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-dns",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Shows the addresses of a host with /lookup <host>.",
        .permissions = &.{"network.dns"},
    };

    pub const commands: []const cmd.Spec = &.{.{
        .names = &.{"lookup"},
        .description = "Shows the IP addresses of a host name.",
        .permission = "example-dns:command.lookup",
        .then = &.{
            .argument("host", .{ .string = .single_word }, .{ .run = cmd.typed(lookup) }),
        },
    }};

    fn lookup(sender: cmd.Sender, _: pumpkin.Server, args: struct { host: []const u8 }) cmd.Result {
        const io = pumpkin.io();
        const host = std.Io.net.HostName.init(args.host) catch return cmd.fail("that isn't a valid host name");

        var buffer: [16]std.Io.net.HostName.LookupResult = undefined;
        var results: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&buffer);
        host.lookup(io, &results, .{ .port = 0 }) catch |err| return cmd.fail(@errorName(err));

        var count: i32 = 0;
        while (results.getOne(io)) |result| switch (result) {
            .address => |address| {
                sender.sendMessage(msg.fmt(.aqua, "{f}", .{address}));
                count += 1;
            },
            .canonical_name => {},
        } else |_| {}
        return cmd.ok(count);
    }
};

comptime {
    pumpkin.register(Dns);
}
