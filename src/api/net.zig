//! TCP and UDP sockets driven by callbacks. All sockets are polled once per
//! tick, so callbacks run only when something has arrived and never block the
//! game. Sockets still open when the plugin unloads are closed automatically.
//!
//!     _ = try pumpkin.net.listen(.{ .port = 25580, .callbacks = .{ .on_line = onLine } });

const std = @import("std");
const abi = @import("../runtime/abi.zig");
const runtime_io = @import("../runtime/io.zig");
const scheduler = @import("../bindings/pumpkin.zig").scheduler;
const Server = @import("../bindings/pumpkin.zig").server.Server;

const net = std.Io.net;

pub const Address = net.IpAddress;

/// Reports whether a raw `std.Io.net` socket has a connection, data or a
/// datagram waiting, without blocking.
pub const ready = runtime_io.ready;

/// The default number of bytes a connection may have queued before it is
/// closed for reading too slowly.
pub const default_max_outgoing = 1024 * 1024;

/// The receive buffer size used when a connection doesn't choose its own.
pub const default_read_buffer_size = 4096;

pub const Framing = enum {
    /// Callbacks receive one line at a time, without the line ending.
    lines,
    /// Callbacks receive the bytes in the chunks they arrive in.
    raw,
};

/// The slices passed to these callbacks are valid only until the callback returns.
pub const Callbacks = struct {
    framing: Framing = .lines,
    on_line: ?*const fn (*Connection, []const u8) void = null,
    on_data: ?*const fn (*Connection, []const u8) void = null,
    /// Runs when the connection closes, from either side. The connection
    /// pointer must not be used after this returns.
    on_close: ?*const fn (*Connection) void = null,

    fn any(c: Callbacks) bool {
        return c.on_line != null or c.on_data != null or c.on_close != null;
    }
};

pub const Connection = struct {
    stream: net.Stream,
    reader: net.Stream.Reader,
    callbacks: Callbacks,
    /// Polled connections queue outgoing data instead of waiting for the
    /// other end to read it.
    polled: bool,
    read_timeout_ms: u32,
    max_outgoing: usize,
    /// Free for the plugin to use, for example to tell connections apart.
    data: usize = 0,
    closed: bool = false,
    outgoing: std.ArrayList(u8) = .empty,
    buffer: []u8,

    pub fn address(conn: *const Connection) Address {
        return conn.stream.socket.address;
    }

    /// Sends `bytes`. On a polled connection this never blocks: data the other
    /// end isn't ready for yet is sent on later ticks, and the connection is
    /// closed once more than `max_outgoing` bytes are waiting.
    pub fn send(conn: *Connection, bytes: []const u8) !void {
        if (conn.closed) return error.Closed;
        if (!conn.polled) {
            var writer = conn.stream.writer(runtime_io.current(), &.{});
            writer.interface.writeAll(bytes) catch return writer.err orelse error.WriteFailed;
            return;
        }
        if (conn.outgoing.items.len + bytes.len > conn.max_outgoing) {
            conn.close();
            return error.TooSlow;
        }
        conn.outgoing.appendSlice(abi.heap, bytes) catch @panic("OOM");
        if (!conn.flush()) {
            conn.close();
            return error.ConnectionResetByPeer;
        }
    }

    pub fn print(conn: *Connection, comptime format: []const u8, args: anytype) !void {
        try conn.send(try std.fmt.allocPrint(abi.arena(), format, args));
    }

    /// Waits up to `read_timeout_ms` for the next line and returns it without
    /// the line ending. Use it on connections without callbacks; connections
    /// with callbacks receive their lines through `on_line`.
    pub fn readLine(conn: *Connection) ![]const u8 {
        if (conn.closed) return error.Closed;
        const reader = &conn.reader.interface;
        const timeout: std.Io.Timeout = (std.Io.Timeout{ .duration = .{
            .raw = .fromMilliseconds(conn.read_timeout_ms),
            .clock = .awake,
        } }).toDeadline(runtime_io.current());
        while (std.mem.indexOfScalar(u8, reader.buffered(), '\n') == null) {
            if (reader.bufferedLen() == conn.buffer.len) return error.LineTooLong;
            if (!runtime_io.waitReady(conn.stream.socket.handle, timeout)) return error.Timeout;
            try reader.fillMore();
        }
        const line = (try reader.takeDelimiter('\n')).?;
        return abi.arena().dupe(u8, std.mem.trimEnd(u8, line, "\r"));
    }

    /// Sends whatever queued data the stream accepts right away, closes the
    /// connection and runs `on_close`. The pointer becomes invalid on the next tick.
    pub fn close(conn: *Connection) void {
        if (conn.closed) return;
        _ = conn.flush();
        conn.closed = true;
        if (conn.callbacks.on_close) |on_close| on_close(conn);
        conn.outgoing.deinit(abi.heap);
        conn.stream.close(runtime_io.current());
    }

    /// Sends as much queued data as the stream accepts without blocking.
    /// Returns false if the stream failed.
    fn flush(conn: *Connection) bool {
        while (conn.outgoing.items.len > 0) {
            const n = runtime_io.writeNow(conn.stream.socket.handle, conn.outgoing.items) catch {
                conn.outgoing.clearRetainingCapacity();
                return false;
            };
            if (n == 0) return true;
            conn.outgoing.replaceRangeAssumeCapacity(0, n, &.{});
        }
        return true;
    }
};

pub const ConnectOptions = struct {
    /// The time limit for the whole connect, across all addresses of a host name.
    timeout_ms: u32 = 10_000,
    /// How long `readLine` waits for a line.
    read_timeout_ms: u32 = 10_000,
    /// Receive buffer capacity. A line, including its ending, has to fit.
    read_buffer_size: usize = default_read_buffer_size,
    /// The outgoing queue limit, used only when the connection is polled.
    max_outgoing: usize = default_max_outgoing,
    /// If any callback is set, the connection is polled like the connections
    /// of a server.
    callbacks: Callbacks = .{},
};

/// Connects to `host`, a host name or an IP address, trying its addresses in
/// order until one accepts. Needs the "network.dns" and "network.tcp.connect"
/// permissions.
pub fn connect(host: []const u8, port: u16, options: ConnectOptions) !*Connection {
    if (options.read_buffer_size == 0) return error.InvalidBufferSize;
    const io = runtime_io.current();
    const timeout: std.Io.Timeout = (std.Io.Timeout{ .duration = .{
        .raw = .fromMilliseconds(options.timeout_ms),
        .clock = .awake,
    } }).toDeadline(io);

    const stream = if (Address.parse(host, port)) |ip|
        try ip.connect(io, .{ .mode = .stream, .timeout = timeout })
    else |_|
        try connectHost(try net.HostName.init(host), port, timeout);
    errdefer stream.close(io);

    const polled = options.callbacks.any();
    const conn = try newConnection(stream, options, polled);
    clients.append(abi.heap, conn) catch @panic("OOM");
    if (polled) startPolling();
    return conn;
}

/// Unlike `HostName.connect`, which tries every address before it returns,
/// this stops at the first address that accepts the connection.
fn connectHost(host: net.HostName, port: u16, timeout: std.Io.Timeout) !net.Stream {
    const io = runtime_io.current();
    var buffer: [16]net.HostName.LookupResult = undefined;
    var results: std.Io.Queue(net.HostName.LookupResult) = .init(&buffer);
    try host.lookup(io, &results, .{ .port = port });

    var last: anyerror = error.UnknownHostName;
    while (results.getOne(io)) |result| switch (result) {
        .address => |address| return address.connect(io, .{ .mode = .stream, .timeout = timeout }) catch |err| {
            if (err == error.Timeout) return err;
            last = err;
            continue;
        },
        .canonical_name => {},
    } else |_| {}
    return last;
}

pub const ListenOptions = struct {
    port: u16,
    /// The address to listen on. "0.0.0.0" also accepts connections from other
    /// machines, which the server config may forbid.
    host: []const u8 = "127.0.0.1",
    on_connect: ?*const fn (*Connection) void = null,
    /// Receive buffer capacity for each accepted connection, including line endings.
    read_buffer_size: usize = default_read_buffer_size,
    max_outgoing: usize = default_max_outgoing,
    callbacks: Callbacks = .{},
};

pub const Listener = struct {
    server: net.Server,
    options: ListenOptions,
    connections: std.ArrayList(*Connection) = .empty,
    closed: bool = false,

    pub fn address(listener: *const Listener) Address {
        return listener.server.socket.address;
    }

    /// Queues `bytes` for every open connection. A slow client can't block it.
    pub fn broadcast(listener: *Listener, bytes: []const u8) void {
        for (listener.connections.items) |conn| conn.send(bytes) catch {};
    }

    /// Stops listening and closes every connection. The pointer becomes
    /// invalid on the next tick.
    pub fn close(listener: *Listener) void {
        if (listener.closed) return;
        listener.closed = true;
        for (listener.connections.items) |conn| conn.close();
        listener.server.deinit(runtime_io.current());
    }
};

/// Listens for TCP connections on `options.port`. Needs the "network.tcp.bind"
/// permission.
pub fn listen(options: ListenOptions) !*Listener {
    if (options.read_buffer_size == 0) return error.InvalidBufferSize;
    const address = try Address.parse(options.host, options.port);
    const listener = abi.heap.create(Listener) catch @panic("OOM");
    errdefer abi.heap.destroy(listener);
    listener.* = .{
        .server = try address.listen(runtime_io.current(), .{ .reuse_address = true }),
        .options = options,
    };
    listeners.append(abi.heap, listener) catch @panic("OOM");
    startPolling();
    return listener;
}

pub const UdpOptions = struct {
    port: u16,
    host: []const u8 = "127.0.0.1",
    /// `data` is valid only until the callback returns.
    on_datagram: ?*const fn (*Udp, Address, []const u8) void = null,
};

pub const Udp = struct {
    socket: net.Socket,
    options: UdpOptions,
    closed: bool = false,

    pub fn address(u: *const Udp) Address {
        return u.socket.address;
    }

    pub fn sendTo(u: *Udp, to: Address, bytes: []const u8) !void {
        if (u.closed) return error.Closed;
        try u.socket.send(runtime_io.current(), &to, bytes);
    }

    /// Closes the socket. The pointer becomes invalid on the next tick.
    pub fn close(u: *Udp) void {
        if (u.closed) return;
        u.closed = true;
        u.socket.close(runtime_io.current());
    }
};

/// Binds a UDP socket to `options.port`. Needs the "network.udp" permission.
pub fn udp(options: UdpOptions) !*Udp {
    const address = try Address.parse(options.host, options.port);
    const u = abi.heap.create(Udp) catch @panic("OOM");
    errdefer abi.heap.destroy(u);
    u.* = .{ .socket = try address.bind(runtime_io.current(), .{ .mode = .dgram }), .options = options };
    sockets.append(abi.heap, u) catch @panic("OOM");
    startPolling();
    return u;
}

var listeners: std.ArrayList(*Listener) = .empty;
var clients: std.ArrayList(*Connection) = .empty;
var sockets: std.ArrayList(*Udp) = .empty;
var task: ?u32 = null;
var datagram_buffer: [65536]u8 = undefined;

fn newConnection(stream: net.Stream, options: ConnectOptions, polled: bool) !*Connection {
    const conn = try abi.heap.create(Connection);
    errdefer abi.heap.destroy(conn);
    conn.* = .{
        .stream = stream,
        .reader = undefined,
        .callbacks = options.callbacks,
        .polled = polled,
        .read_timeout_ms = options.read_timeout_ms,
        .max_outgoing = options.max_outgoing,
        .buffer = try abi.heap.alloc(u8, options.read_buffer_size),
    };
    conn.reader = stream.reader(runtime_io.current(), conn.buffer);
    return conn;
}

fn startPolling() void {
    if (task == null) task = scheduler.scheduleRepeatingTask(@intFromPtr(&pollTask), 0, 1);
}

fn pollTask(_: Server) void {
    poll();
}

/// Handles everything that is waiting. It runs every tick on its own; call it
/// directly to handle things right away.
pub fn poll() void {
    var i: usize = 0;
    while (i < listeners.items.len) : (i += 1) {
        const listener = listeners.items[i];
        while (!listener.closed and ready(listener.server.socket.handle)) {
            const stream = listener.server.accept(runtime_io.current()) catch break;
            const conn = newConnection(stream, .{
                .callbacks = listener.options.callbacks,
                .read_buffer_size = listener.options.read_buffer_size,
                .max_outgoing = listener.options.max_outgoing,
            }, true) catch @panic("OOM");
            listener.connections.append(abi.heap, conn) catch @panic("OOM");
            if (listener.options.on_connect) |on_connect| on_connect(conn);
        }
        var j: usize = 0;
        while (j < listener.connections.items.len) : (j += 1) pollConnection(listener.connections.items[j]);
    }

    i = 0;
    while (i < clients.items.len) : (i += 1) pollConnection(clients.items[i]);

    i = 0;
    while (i < sockets.items.len) : (i += 1) {
        const u = sockets.items[i];
        while (!u.closed and ready(u.socket.handle)) {
            const message = u.socket.receive(runtime_io.current(), &datagram_buffer) catch break;
            if (u.options.on_datagram) |on_datagram| on_datagram(u, message.from, message.data);
        }
    }

    sweep();
}

fn pollConnection(conn: *Connection) void {
    if (conn.closed or !conn.polled) return;
    if (!conn.flush()) return conn.close();
    if (!ready(conn.stream.socket.handle)) return;
    const reader = &conn.reader.interface;
    reader.fillMore() catch return conn.close();

    switch (conn.callbacks.framing) {
        .raw => {
            const bytes = reader.buffered();
            reader.toss(bytes.len);
            if (conn.callbacks.on_data) |on_data| on_data(conn, bytes);
        },
        .lines => {
            while (!conn.closed and std.mem.indexOfScalar(u8, reader.buffered(), '\n') != null) {
                const line = (reader.takeDelimiter('\n') catch break) orelse break;
                if (conn.callbacks.on_line) |on_line| on_line(conn, std.mem.trimEnd(u8, line, "\r"));
            }
            // A full buffer without a line ending can never complete a line.
            if (!conn.closed and reader.bufferedLen() == conn.buffer.len) conn.close();
        },
    }
}

fn sweep() void {
    var i: usize = 0;
    while (i < listeners.items.len) {
        const listener = listeners.items[i];
        sweepConnections(&listener.connections);
        if (listener.closed) {
            listener.connections.deinit(abi.heap);
            abi.heap.destroy(listeners.swapRemove(i));
        } else i += 1;
    }
    sweepConnections(&clients);
    i = 0;
    while (i < sockets.items.len) {
        if (sockets.items[i].closed) abi.heap.destroy(sockets.swapRemove(i)) else i += 1;
    }
}

fn sweepConnections(list: *std.ArrayList(*Connection)) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (list.items[i].closed) {
            const conn = list.swapRemove(i);
            abi.heap.free(conn.buffer);
            abi.heap.destroy(conn);
        } else i += 1;
    }
}

/// Closes every socket. `register` calls this when the plugin unloads.
pub fn closeAll() void {
    for (listeners.items) |listener| listener.close();
    for (clients.items) |conn| conn.close();
    for (sockets.items) |u| u.close();
    sweep();
    if (task) |id| scheduler.cancelTask(id);
    task = null;
}
