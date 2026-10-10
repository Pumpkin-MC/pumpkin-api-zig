//! HTTPS with `std.http.Client`, trusting the certificates in the data folder.
//!
//! The plugin can't read the system's certificates, so copy them into its data
//! folder first, for example:
//!
//!     cp /etc/ssl/certs/ca-certificates.crt plugins/data/example-https/

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const msg = pumpkin.msg;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const Https = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-https",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Fetches a page over HTTPS with /get <url>.",
        .permissions = &.{ "network.dns", "network.tcp.connect", "fs.read.data" },
    };

    pub const commands: []const cmd.Spec = &.{.{
        .names = &.{"get"},
        .description = "Fetches a URL and shows the status and the size of the body.",
        .permission = "example-https:command.get",
        .default = .{ .op = .two },
        .then = &.{
            .argument("url", .{ .string = .greedy }, .{ .run = cmd.typed(get) }),
        },
    }};

    var client: std.http.Client = undefined;

    pub fn onLoad(_: pumpkin.Context) !void {
        const io = pumpkin.io();
        client = .{ .allocator = pumpkin.abi.heap, .io = io };

        const now = std.Io.Clock.real.now(io);
        client.ca_bundle.addCertsFromFilePath(pumpkin.abi.heap, io, now, .cwd(), "ca-certificates.crt") catch |err| {
            std.log.warn("no certificates loaded ({t}), see examples/https.zig", .{err});
        };
        client.now = now;
    }

    pub fn onUnload(_: pumpkin.Context) !void {
        client.deinit();
    }

    fn get(sender: cmd.Sender, _: pumpkin.Server, args: struct { url: []const u8 }) cmd.Result {
        var body: std.Io.Writer.Allocating = .init(pumpkin.abi.arena());
        const result = client.fetch(.{
            .location = .{ .url = args.url },
            .response_writer = &body.writer,
            .keep_alive = false,
        }) catch |err| return cmd.fail(@errorName(err));

        sender.sendMessage(msg.fmt(.green, "{d} {s}, {d} bytes", .{
            @intFromEnum(result.status),
            result.status.phrase() orelse "",
            body.written().len,
        }));
        return cmd.ok(1);
    }
};

comptime {
    pumpkin.register(Https);
}
