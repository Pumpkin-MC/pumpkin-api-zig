//! Web requests with `pumpkin.http`, one command per method.
//!
//! HTTPS needs the system's certificates in the data folder, for example:
//!
//!     cp /etc/ssl/certs/ca-certificates.crt plugins/data/example-https/
//!
//! Try `/web get https://httpbin.org/get` or `/web post https://httpbin.org/post hello`.

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const msg = pumpkin.msg;
const http = pumpkin.http;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const Https = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-https",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Sends web requests with /web <method> <url> [body].",
        .permissions = &.{ "network.dns", "network.tcp.connect", "fs.read.data" },
    };

    const url_arg: cmd.ArgumentType = .{ .string = .quotable };
    const body_arg: cmd.ArgumentType = .{ .string = .greedy };

    pub const commands: []const cmd.Spec = &.{.{
        .names = &.{"web"},
        .description = "Sends a web request and shows the response.",
        .permission = "example-https:command.web",
        .default = .{ .op = .two },
        .then = &.{
            .literal("get", .{ .then = &.{.argument("url", url_arg, .{ .run = cmd.typed(get) })} }),
            .literal("head", .{ .then = &.{.argument("url", url_arg, .{ .run = cmd.typed(head) })} }),
            .literal("delete", .{ .then = &.{.argument("url", url_arg, .{ .run = cmd.typed(delete) })} }),
            .literal("post", .{ .then = &.{.argument("url", url_arg, .{ .then = &.{.argument("body", body_arg, .{ .run = cmd.typed(post) })} })} }),
            .literal("put", .{ .then = &.{.argument("url", url_arg, .{ .then = &.{.argument("body", body_arg, .{ .run = cmd.typed(put) })} })} }),
            .literal("patch", .{ .then = &.{.argument("url", url_arg, .{ .then = &.{.argument("body", body_arg, .{ .run = cmd.typed(patch) })} })} }),
        },
    }};

    const Url = struct { url: []const u8 };
    const UrlAndBody = struct { url: []const u8, body: []const u8 };

    fn get(sender: cmd.Sender, _: pumpkin.Server, args: Url) cmd.Result {
        return show(sender, http.get(args.url, .{}));
    }

    fn head(sender: cmd.Sender, _: pumpkin.Server, args: Url) cmd.Result {
        return show(sender, http.head(args.url, .{}));
    }

    fn delete(sender: cmd.Sender, _: pumpkin.Server, args: Url) cmd.Result {
        return show(sender, http.delete(args.url, .{}));
    }

    fn post(sender: cmd.Sender, _: pumpkin.Server, args: UrlAndBody) cmd.Result {
        return show(sender, http.post(args.url, args.body, .{ .content_type = "text/plain" }));
    }

    fn put(sender: cmd.Sender, _: pumpkin.Server, args: UrlAndBody) cmd.Result {
        return show(sender, http.put(args.url, args.body, .{ .content_type = "text/plain" }));
    }

    fn patch(sender: cmd.Sender, _: pumpkin.Server, args: UrlAndBody) cmd.Result {
        return show(sender, http.patch(args.url, args.body, .{ .content_type = "text/plain" }));
    }

    fn show(sender: cmd.Sender, result: http.Error!http.Response) cmd.Result {
        const res = result catch |err| return cmd.fail(@errorName(err));
        sender.sendMessage(msg.fmt(if (res.ok()) .green else .red, "{d} {s}, {d} bytes", .{
            @intFromEnum(res.status),
            res.status.phrase() orelse "",
            res.body.len,
        }));
        if (res.body.len > 0) sender.sendMessage(msg.fmt(.gray, "{s}", .{res.body[0..@min(res.body.len, 256)]}));
        return cmd.ok(@intFromEnum(res.status));
    }
};

comptime {
    pumpkin.register(Https);
}
