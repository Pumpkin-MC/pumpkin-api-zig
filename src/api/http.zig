//! HTTP and HTTPS requests in one call, on top of `std.http.Client`. HTTPS
//! trusts the certificates in `ca-certificates.crt` in the data folder.
//!
//!     const res = try pumpkin.http.get("https://api.example.com/status", .{});

const std = @import("std");
const abi = @import("../runtime/abi.zig");
const pumpkin = @import("../pumpkin.zig");

pub const Method = std.http.Method;
pub const Status = std.http.Status;
pub const Header = std.http.Header;

pub const Options = struct {
    headers: []const Header = &.{},
    /// Sent as the Content-Type header when the request has a body.
    content_type: ?[]const u8 = null,
    authorization: ?[]const u8 = null,
    user_agent: []const u8 = "pumpkin-api-zig",
    /// Responses with a longer body fail with `error.BodyTooLong`.
    max_body: usize = 8 * 1024 * 1024,
};

pub const Response = struct {
    status: Status,
    /// Lives until the current callback returns.
    body: []const u8,

    /// Whether the status is in the 2xx range.
    pub fn ok(res: Response) bool {
        return res.status.class() == .success;
    }

    /// Parses the body as JSON into a `T` that lives until the current callback returns.
    pub fn json(res: Response, comptime T: type) !T {
        return std.json.parseFromSliceLeaky(T, abi.arena(), res.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }
};

pub const Error = std.http.Client.FetchError || error{ BodyTooLong, NoCertificates };

pub fn get(url: []const u8, options: Options) Error!Response {
    return request(.GET, url, null, options);
}

pub fn head(url: []const u8, options: Options) Error!Response {
    return request(.HEAD, url, null, options);
}

pub fn delete(url: []const u8, options: Options) Error!Response {
    return request(.DELETE, url, null, options);
}

pub fn post(url: []const u8, body: []const u8, options: Options) Error!Response {
    return request(.POST, url, body, options);
}

pub fn put(url: []const u8, body: []const u8, options: Options) Error!Response {
    return request(.PUT, url, body, options);
}

pub fn patch(url: []const u8, body: []const u8, options: Options) Error!Response {
    return request(.PATCH, url, body, options);
}

/// Sends `value` as JSON with the given method.
pub fn sendJson(method: Method, url: []const u8, value: anytype, options: Options) Error!Response {
    const body = std.json.Stringify.valueAlloc(abi.arena(), value, .{}) catch return error.OutOfMemory;
    var with_type = options;
    if (with_type.content_type == null) with_type.content_type = "application/json";
    return request(method, url, body, with_type);
}

pub fn request(method: Method, url: []const u8, body: ?[]const u8, options: Options) Error!Response {
    const c = client();
    if (std.mem.startsWith(u8, url, "https://")) try loadCertificates(c);

    var response: std.Io.Writer.Allocating = .init(abi.arena());
    var limited = LimitedWriter.init(&response.writer, options.max_body);
    const result = c.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body,
        .response_writer = &limited.writer,
        .headers = .{
            .content_type = if (body != null and options.content_type != null) .{ .override = options.content_type.? } else .default,
            .authorization = if (options.authorization) |value| .{ .override = value } else .default,
            .user_agent = .{ .override = options.user_agent },
        },
        .extra_headers = options.headers,
    }) catch |err| return if (limited.exceeded) error.BodyTooLong else err;
    return .{ .status = result.status, .body = response.written() };
}

var shared: ?std.http.Client = null;
var certificates_loaded = false;

fn client() *std.http.Client {
    if (shared == null) shared = .{ .allocator = abi.heap, .io = pumpkin.io() };
    return &shared.?;
}

fn loadCertificates(c: *std.http.Client) error{NoCertificates}!void {
    if (certificates_loaded) return;
    const io = pumpkin.io();
    const now = std.Io.Clock.real.now(io);
    c.ca_bundle.addCertsFromFilePath(abi.heap, io, now, .cwd(), "ca-certificates.crt") catch |err| {
        std.log.err(
            "HTTPS needs ca-certificates.crt in the plugin's data folder and the fs.read.data permission ({t})",
            .{err},
        );
        return error.NoCertificates;
    };
    c.now = now;
    certificates_loaded = true;
}

/// Closes the shared client, done by `register` when the plugin unloads.
pub fn deinit() void {
    if (shared) |*c| c.deinit();
    shared = null;
    certificates_loaded = false;
}

/// Passes bytes on until `limit` is reached, then fails the write.
const LimitedWriter = struct {
    inner: *std.Io.Writer,
    left: usize,
    exceeded: bool = false,
    writer: std.Io.Writer,

    fn init(inner: *std.Io.Writer, limit: usize) LimitedWriter {
        return .{ .inner = inner, .left = limit, .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *LimitedWriter = @alignCast(@fieldParentPtr("writer", w));
        var len: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| len += bytes.len;
        len += data[data.len - 1].len * splat;
        if (len > self.left) {
            self.exceeded = true;
            return error.WriteFailed;
        }
        const n = try self.inner.writeSplat(data, splat);
        self.left -= n;
        return n;
    }
};
