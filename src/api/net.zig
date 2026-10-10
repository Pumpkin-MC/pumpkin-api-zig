//! TCP and UDP with callbacks, polled once per tick so they never block the
//! game. Everything still open is closed when the plugin unloads.
//!
//!     _ = try pumpkin.net.listen(.{ .port = 25580, .callbacks = .{ .on_line = onLine } });

const std = @import("std");
const abi = @import("../runtime/abi.zig");
const runtime_io = @import("../runtime/io.zig");
const scheduler = @import("../bindings/pumpkin.zig").scheduler;
const Server = @import("../bindings/pumpkin.zig").server.Server;

const net = std.Io.net;

pub const Address = net.IpAddress;

/// Whether a raw `std.Io.net` socket has a connection, data or a datagram waiting.
pub const ready = runtime_io.ready;

pub const Framing = enum {
    /// Callbacks get one line at a time, without the line ending.
    lines,
    /// Callbacks get whatever arrived.
    raw,
};

pub const Callbacks = struct {
    framing: Framing = .lines,
    on_line: ?*const fn (*Connection, []const u8) void = null,
    on_data: ?*const fn (*Connection, []const u8) void = null,
    on_close: ?*const fn (*Connection) void = null,

    fn any(c: Callbacks) bool {
        return c.on_line != null or c.on_data != null or c.on_close != null;
    }
};

pub const Connection = struct {
    stream: net.Stream,
    reader: net.Stream.Reader,
    callbacks: Callbacks,
    server: ?*Listener,
    /// Free for the plugin to use, for example to tell connections apart.
    data: usize = 0,
    closed: bool = false,
    buffer: [4096]u8,

    pub fn address(conn: *const Connection) Address {
        return conn.stream.socket.address;
    }

    pub fn send(conn: *Connection, bytes: []const u8) !void {
        if (conn.closed) return error.Closed;
        var writer = conn.stream.writer(runtime_io.current(), &.{});
        writer.interface.writeAll(bytes) catch return writer.err orelse error.WriteFailed;
    }

    pub fn print(conn: *Connection, comptime format: []const u8, args: anytype) !void {
        try conn.send(try std.fmt.allocPrint(abi.arena(), format, args));
    }

    /// Waits for the next line. For connections without callbacks, since the
    /// others get their lines handed to them.
    pub fn readLine(conn: *Connection) ![]const u8 {
        if (conn.closed) return error.Closed;
        const line = (try conn.reader.interface.takeDelimiter('\n')) orelse return error.EndOfStream;
        return abi.arena().dupe(u8, std.mem.trimEnd(u8, line, "\r"));
    }

    /// Closes the connection, `on_close` runs as well.
    pub fn close(conn: *Connection) void {
        if (conn.closed) return;
        conn.closed = true;
        if (conn.callbacks.on_close) |on_close| on_close(conn);
        conn.stream.close(runtime_io.current());
    }
};

pub const ConnectOptions = struct {
    timeout_ms: u32 = 10_000,
    /// With any callback set, the connection is polled like a server's.
    callbacks: Callbacks = .{},
};

/// Connects to `host`, a name or an IP address. Needs the "network.dns" and
/// "network.tcp.connect" permissions.
pub fn connect(host: []const u8, port: u16, options: ConnectOptions) !*Connection {
    const io = runtime_io.current();
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(options.timeout_ms), .clock = .awake } };
    const stream = if (Address.parse(host, port)) |ip|
        try ip.connect(io, .{ .mode = .stream, .timeout = timeout })
    else |_|
        try (try net.HostName.init(host)).connect(io, port, .{ .mode = .stream, .timeout = timeout });

    const conn = newConnection(stream, options.callbacks, null);
    clients.append(abi.heap, conn) catch @panic("OOM");
    if (options.callbacks.any()) startPolling();
    return conn;
}

pub const ListenOptions = struct {
    port: u16,
    /// The address to listen on. "0.0.0.0" accepts connections from anywhere,
    /// which the server config may forbid.
    host: []const u8 = "127.0.0.1",
    on_connect: ?*const fn (*Connection) void = null,
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

    /// Sends `bytes` to every open connection.
    pub fn broadcast(listener: *Listener, bytes: []const u8) void {
        for (listener.connections.items) |conn| conn.send(bytes) catch conn.close();
    }

    /// Stops listening and closes every connection.
    pub fn close(listener: *Listener) void {
        if (listener.closed) return;
        listener.closed = true;
        for (listener.connections.items) |conn| conn.close();
        listener.server.deinit(runtime_io.current());
    }
};

/// Accepts TCP connections on `options.port`. Needs the "network.tcp.bind" permission.
pub fn listen(options: ListenOptions) !*Listener {
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

    pub fn close(u: *Udp) void {
        if (u.closed) return;
        u.closed = true;
        u.socket.close(runtime_io.current());
    }
};

/// Binds a UDP socket to `options.port`. Needs the "network.udp" permissions.
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

fn newConnection(stream: net.Stream, callbacks: Callbacks, server: ?*Listener) *Connection {
    const conn = abi.heap.create(Connection) catch @panic("OOM");
    conn.* = .{ .stream = stream, .reader = undefined, .callbacks = callbacks, .server = server, .buffer = undefined };
    conn.reader = stream.reader(runtime_io.current(), &conn.buffer);
    return conn;
}

fn startPolling() void {
    if (task == null) task = scheduler.scheduleRepeatingTask(@intFromPtr(&pollTask), 0, 1);
}

fn pollTask(_: Server) void {
    poll();
}

/// Handles everything that is waiting. Runs every tick by itself, call it to
/// get things handled right away.
pub fn poll() void {
    var i: usize = 0;
    while (i < listeners.items.len) : (i += 1) {
        const listener = listeners.items[i];
        while (!listener.closed and ready(listener.server.socket.handle)) {
            const stream = listener.server.accept(runtime_io.current()) catch break;
            const conn = newConnection(stream, listener.options.callbacks, listener);
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
    if (conn.closed or !conn.callbacks.any() or !ready(conn.stream.socket.handle)) return;
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
            // A line longer than the buffer can never complete.
            if (reader.bufferedLen() == conn.buffer.len) conn.close();
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
        if (list.items[i].closed) abi.heap.destroy(list.swapRemove(i)) else i += 1;
    }
}

/// Closes everything, done by `register` when the plugin unloads.
pub fn closeAll() void {
    for (listeners.items) |listener| listener.close();
    for (clients.items) |conn| conn.close();
    for (sockets.items) |u| u.close();
    sweep();
    if (task) |id| scheduler.cancelTask(id);
    task = null;
}
