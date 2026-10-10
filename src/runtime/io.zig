//! The `std.Io` behind `pumpkin.io()`. Files go through Zig's own WASI support,
//! networking is built on wasi:sockets, which Zig's `std.Io` lacks on WASI.

const std = @import("std");
const abi = @import("abi.zig");
const wasi = @import("../bindings/wasi.zig");

const Io = std.Io;
const net = Io.net;
const network = wasi.network;
const streams = wasi.streams;
const tcp = wasi.tcp;
const udp = wasi.udp;
const Pollable = wasi.poll.Pollable;

const Accepted = struct { socket: tcp.TcpSocket, input: streams.InputStream, output: streams.OutputStream };
const Datagram = struct { from: net.IpAddress, data: []u8 };

/// `pending` holds what `ready` took in to find out whether anything is
/// there. A pollable stays ready until a read comes up empty, so asking it
/// alone would make the next read wait.
const Entry = union(enum) {
    stream: struct {
        socket: tcp.TcpSocket,
        input: streams.InputStream,
        output: streams.OutputStream,
        pending: std.ArrayList(u8) = .empty,
        ended: bool = false,
    },
    listener: struct { socket: tcp.TcpSocket, pending: std.ArrayList(Accepted) = .empty },
    datagram: struct {
        socket: udp.UdpSocket,
        incoming: udp.IncomingDatagramStream,
        outgoing: udp.OutgoingDatagramStream,
        pending: std.ArrayList(Datagram) = .empty,
    },
};

/// Socket handles start here so they can't be mistaken for WASI file descriptors.
const first_handle = 1 << 20;

var entries: std.ArrayList(?Entry) = .empty;
var instance: ?network.Network = null;
var fallback_operate: @FieldType(Io.VTable, "operate") = undefined;

var threaded: Io.Threaded = .init_single_threaded;
var custom: ?Io.VTable = null;

pub fn current() Io {
    if (custom == null) {
        custom = threaded.io().vtable.*;
        install(&custom.?);
    }
    return .{ .userdata = &threaded, .vtable = &custom.? };
}

fn install(vtable: *Io.VTable) void {
    fallback_operate = vtable.operate;
    vtable.operate = operate;
    vtable.netConnectIp = connectIp;
    vtable.netListenIp = listenIp;
    vtable.netAccept = accept;
    vtable.netBindIp = bindIp;
    vtable.netSend = send;
    vtable.netRead = read;
    vtable.netWrite = write;
    vtable.netClose = close;
    vtable.netShutdown = shutdown;
    vtable.netLookup = lookup;
}

/// Whether `handle` has something waiting: a connection for a server, data
/// for a stream or a datagram for a UDP socket. Polling this from a task lets
/// a plugin accept and receive without blocking the server.
pub fn ready(handle: net.Socket.Handle) bool {
    return switch (get(handle) orelse return false) {
        .stream => |st| st.pending.items.len > 0 or st.ended or takeBytes(handle, st.input),
        .listener => |l| l.pending.items.len > 0 or takeConnection(handle, l.socket),
        .datagram => |d| d.pending.items.len > 0 or takeDatagrams(handle, d.incoming),
    };
}

// The take functions look the entry up again after calling the host, which
// may run another callback of the plugin that adds sockets and moves entries.

fn takeBytes(handle: net.Socket.Handle, input: streams.InputStream) bool {
    const result = input.read(64 * 1024);
    const st = &(entryOf(handle) orelse return false).stream;
    switch (result) {
        .ok => |bytes| {
            if (bytes.len == 0) return false;
            st.pending.appendSlice(abi.heap, bytes) catch @panic("OOM");
        },
        .err => |err| {
            if (err == .last_operation_failed) err.last_operation_failed.deinit();
            st.ended = true;
        },
    }
    return true;
}

fn takeConnection(handle: net.Socket.Handle, socket: tcp.TcpSocket) bool {
    const client, const input, const output = switch (socket.accept()) {
        .ok => |accepted| accepted,
        .err => return false,
    };
    client.keep();
    input.keep();
    output.keep();
    const l = &(entryOf(handle) orelse return false).listener;
    l.pending.append(abi.heap, .{ .socket = client, .input = input, .output = output }) catch @panic("OOM");
    return true;
}

fn takeDatagrams(handle: net.Socket.Handle, incoming: udp.IncomingDatagramStream) bool {
    const datagrams = switch (incoming.receive(16)) {
        .ok => |datagrams| datagrams,
        .err => return false,
    };
    const d = &(entryOf(handle) orelse return false).datagram;
    for (datagrams) |datagram| {
        const data = abi.heap.dupe(u8, datagram.data) catch @panic("OOM");
        d.pending.append(abi.heap, .{ .from = fromWasiSocket(datagram.remote_address), .data = data }) catch @panic("OOM");
    }
    return datagrams.len > 0;
}

fn instanceNetwork() network.Network {
    if (instance) |n| return n;
    const n = wasi.instance_network.instanceNetwork();
    n.keep();
    instance = n;
    return n;
}

fn wait(pollable: Pollable) void {
    pollable.block();
    pollable.deinit();
}

/// Waits for `pollable` until `timeout` runs out, false if it did.
fn waitTimeout(pollable: Pollable, timeout: Io.Timeout) bool {
    defer pollable.deinit();
    const deadline = timeout.toTimestamp(current()) orelse {
        pollable.block();
        return true;
    };
    const left = deadline.durationFromNow(current()).raw.nanoseconds;
    if (left <= 0) return pollable.ready();
    const timer = wasi.monotonic_clock.subscribeDuration(@intCast(left));
    defer timer.deinit();
    for (wasi.poll.poll(&.{ abi.borrow(pollable), abi.borrow(timer) })) |i| {
        if (i == 0) return true;
    }
    return false;
}

fn add(entry: Entry) net.Socket.Handle {
    for (entries.items, 0..) |*slot, i| {
        if (slot.* == null) {
            slot.* = entry;
            return @intCast(first_handle + i);
        }
    }
    entries.append(abi.heap, entry) catch @panic("OOM");
    return @intCast(first_handle + entries.items.len - 1);
}

fn get(handle: net.Socket.Handle) ?Entry {
    return (entryOf(handle) orelse return null).*;
}

fn entryOf(handle: net.Socket.Handle) ?*Entry {
    const i = std.math.sub(usize, @intCast(handle), first_handle) catch return null;
    if (i >= entries.items.len) return null;
    return if (entries.items[i]) |*entry| entry else null;
}

fn toWasi(address: net.IpAddress) network.IpSocketAddress {
    return switch (address) {
        .ip4 => |a| .{ .ipv4 = .{ .port = a.port, .address = .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] } } },
        .ip6 => |a| blk: {
            var words: [8]u16 = undefined;
            for (&words, 0..) |*word, i| word.* = std.mem.readInt(u16, a.bytes[2 * i ..][0..2], .big);
            break :blk .{ .ipv6 = .{
                .port = a.port,
                .flow_info = a.flow,
                .address = .{ words[0], words[1], words[2], words[3], words[4], words[5], words[6], words[7] },
                .scope_id = a.interface.index,
            } };
        },
    };
}

fn fromWasi(address: network.IpAddress, port: u16) net.IpAddress {
    return switch (address) {
        .ipv4 => |a| .{ .ip4 = .{ .bytes = .{ a[0], a[1], a[2], a[3] }, .port = port } },
        .ipv6 => |a| blk: {
            var bytes: [16]u8 = undefined;
            inline for (0..8) |i| std.mem.writeInt(u16, bytes[2 * i ..][0..2], a[i], .big);
            break :blk .{ .ip6 = .{ .bytes = bytes, .port = port } };
        },
    };
}

fn fromWasiSocket(address: network.IpSocketAddress) net.IpAddress {
    return switch (address) {
        .ipv4 => |a| fromWasi(.{ .ipv4 = a.address }, a.port),
        .ipv6 => |a| blk: {
            var ip = fromWasi(.{ .ipv6 = a.address }, a.port);
            ip.ip6.flow = a.flow_info;
            ip.ip6.interface = .{ .index = a.scope_id };
            break :blk ip;
        },
    };
}

fn family(address: net.IpAddress) network.IpAddressFamily {
    return switch (address) {
        .ip4 => .ipv4,
        .ip6 => .ipv6,
    };
}

fn denied(comptime permission: []const u8) void {
    std.log.err("the server denied this, the plugin needs the " ++ permission ++ " permission", .{});
}

fn connectError(code: network.ErrorCode) net.IpAddress.ConnectError {
    return switch (code) {
        .access_denied => blk: {
            denied("network.tcp.connect");
            break :blk error.AccessDenied;
        },
        .not_supported => error.AddressFamilyUnsupported,
        .out_of_memory, .new_socket_limit => error.SystemResources,
        .timeout => error.Timeout,
        .address_not_bindable, .address_in_use => error.AddressUnavailable,
        .remote_unreachable => error.HostUnreachable,
        .connection_refused => error.ConnectionRefused,
        .connection_reset, .connection_aborted => error.ConnectionResetByPeer,
        else => error.Unexpected,
    };
}

fn bindError(code: network.ErrorCode, comptime permission: []const u8) net.IpAddress.BindError {
    return switch (code) {
        .access_denied => blk: {
            denied(permission);
            break :blk error.Unexpected;
        },
        .not_supported => error.AddressFamilyUnsupported,
        .out_of_memory, .new_socket_limit => error.SystemResources,
        .address_in_use => error.AddressInUse,
        .address_not_bindable => error.AddressUnavailable,
        else => error.Unexpected,
    };
}

fn connectIp(_: ?*anyopaque, address: *const net.IpAddress, options: net.IpAddress.ConnectOptions) net.IpAddress.ConnectError!net.Socket {
    if (options.mode != .stream) return error.SocketModeUnsupported;
    if (options.protocol) |protocol| if (protocol != .tcp) return error.ProtocolUnsupportedByAddressFamily;

    const socket = switch (wasi.tcp_create_socket.createTcpSocket(family(address.*))) {
        .ok => |socket| socket,
        .err => |code| return connectError(code),
    };
    errdefer socket.deinit();

    switch (socket.startConnect(instanceNetwork(), toWasi(address.*))) {
        .ok => {},
        .err => |code| return connectError(code),
    }
    const input, const output = while (true) {
        switch (socket.finishConnect()) {
            .ok => |pair| break pair,
            .err => |code| {
                if (code != .would_block) return connectError(code);
                if (!waitTimeout(socket.subscribe(), options.timeout)) return error.Timeout;
            },
        }
    };

    socket.keep();
    input.keep();
    output.keep();
    return .{
        .handle = add(.{ .stream = .{ .socket = socket, .input = input, .output = output } }),
        .address = address.*,
    };
}

fn listenIp(_: ?*anyopaque, address: *const net.IpAddress, options: net.IpAddress.ListenOptions) net.IpAddress.ListenError!net.Socket {
    if (options.mode != .stream) return error.SocketModeUnsupported;
    if (options.protocol != .tcp) return error.ProtocolUnsupportedByAddressFamily;

    const socket = switch (wasi.tcp_create_socket.createTcpSocket(family(address.*))) {
        .ok => |socket| socket,
        .err => |code| return bindError(code, "network.tcp.bind"),
    };
    errdefer socket.deinit();

    switch (socket.startBind(instanceNetwork(), toWasi(address.*))) {
        .ok => {},
        .err => |code| return bindError(code, "network.tcp.bind"),
    }
    while (true) switch (socket.finishBind()) {
        .ok => break,
        .err => |code| if (code == .would_block) wait(socket.subscribe()) else return bindError(code, "network.tcp.bind"),
    };
    _ = socket.setListenBacklogSize(options.kernel_backlog);
    switch (socket.startListen()) {
        .ok => {},
        .err => |code| return bindError(code, "network.tcp.bind"),
    }
    while (true) switch (socket.finishListen()) {
        .ok => break,
        .err => |code| if (code == .would_block) wait(socket.subscribe()) else return bindError(code, "network.tcp.bind"),
    };

    const local = switch (socket.localAddress()) {
        .ok => |local| fromWasiSocket(local),
        .err => address.*,
    };
    socket.keep();
    return .{ .handle = add(.{ .listener = .{ .socket = socket } }), .address = local };
}

fn accept(_: ?*anyopaque, handle: net.Socket.Handle, _: net.Server.AcceptOptions) net.Server.AcceptError!net.Socket {
    const listener = switch ((entryOf(handle) orelse return error.SocketNotListening).*) {
        .listener => |*l| l,
        else => return error.SocketNotListening,
    };
    if (listener.pending.items.len > 0) {
        const accepted = listener.pending.orderedRemove(0);
        return addAccepted(accepted.socket, accepted.input, accepted.output);
    }
    const server = listener.socket;
    const socket, const input, const output = while (true) {
        switch (server.accept()) {
            .ok => |accepted| break accepted,
            .err => |code| switch (code) {
                .would_block => wait(server.subscribe()),
                .new_socket_limit, .out_of_memory => return error.SystemResources,
                .invalid_state => return error.SocketNotListening,
                .connection_aborted, .connection_reset => return error.ConnectionAborted,
                else => return error.Unexpected,
            },
        }
    };

    socket.keep();
    input.keep();
    output.keep();
    return addAccepted(socket, input, output);
}

fn addAccepted(socket: tcp.TcpSocket, input: streams.InputStream, output: streams.OutputStream) net.Server.AcceptError!net.Socket {
    const remote = switch (socket.remoteAddress()) {
        .ok => |remote| fromWasiSocket(remote),
        .err => {
            input.deinit();
            output.deinit();
            socket.deinit();
            return error.Unexpected;
        },
    };
    return .{
        .handle = add(.{ .stream = .{ .socket = socket, .input = input, .output = output } }),
        .address = remote,
    };
}

fn bindIp(_: ?*anyopaque, address: *const net.IpAddress, options: net.IpAddress.BindOptions) net.IpAddress.BindError!net.Socket {
    if (options.mode != .dgram) return error.SocketModeUnsupported;
    if (options.protocol) |protocol| if (protocol != .udp) return error.ProtocolUnsupportedByAddressFamily;

    const socket = switch (wasi.udp_create_socket.createUdpSocket(family(address.*))) {
        .ok => |socket| socket,
        .err => |code| return bindError(code, "network.udp.bind"),
    };
    errdefer socket.deinit();

    switch (socket.startBind(instanceNetwork(), toWasi(address.*))) {
        .ok => {},
        .err => |code| return bindError(code, "network.udp.bind"),
    }
    while (true) switch (socket.finishBind()) {
        .ok => break,
        .err => |code| if (code == .would_block) wait(socket.subscribe()) else return bindError(code, "network.udp.bind"),
    };
    const incoming, const outgoing = switch (socket.stream(null)) {
        .ok => |pair| pair,
        .err => |code| return bindError(code, "network.udp.bind"),
    };

    const local = switch (socket.localAddress()) {
        .ok => |local| fromWasiSocket(local),
        .err => address.*,
    };
    socket.keep();
    incoming.keep();
    outgoing.keep();
    return .{
        .handle = add(.{ .datagram = .{ .socket = socket, .incoming = incoming, .outgoing = outgoing } }),
        .address = local,
    };
}

fn send(_: ?*anyopaque, handle: net.Socket.Handle, messages: []net.OutgoingMessage, _: net.SendFlags) struct { ?net.Socket.SendError, usize } {
    const outgoing = switch (get(handle) orelse return .{ error.SocketUnconnected, 0 }) {
        .datagram => |d| d.outgoing,
        else => return .{ error.SocketUnconnected, 0 },
    };
    for (messages, 0..) |*message, i| {
        while (true) {
            switch (outgoing.checkSend()) {
                .ok => |permits| if (permits > 0) break else wait(outgoing.subscribe()),
                .err => return .{ error.Unexpected, i },
            }
        }
        const datagram: udp.OutgoingDatagram = .{
            .data = message.data_ptr[0..message.data_len],
            .remote_address = toWasi(message.address.*),
        };
        switch (outgoing.send(&.{datagram})) {
            .ok => {},
            .err => |code| return .{ switch (code) {
                .access_denied => blk: {
                    denied("network.udp.connect");
                    break :blk error.AccessDenied;
                },
                .datagram_too_large => error.MessageOversize,
                .remote_unreachable => error.HostUnreachable,
                .connection_refused => error.ConnectionRefused,
                else => error.Unexpected,
            }, i },
        }
    }
    return .{ null, messages.len };
}

fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    if (operation != .net_receive) return fallback_operate(userdata, operation);
    return .{ .net_receive = receive(operation.net_receive) };
}

fn receive(op: Io.Operation.NetReceive) Io.Operation.NetReceive.Result {
    const socket = switch ((entryOf(op.socket_handle) orelse return .{ error.SocketUnconnected, 0 }).*) {
        .datagram => |*d| d,
        else => return .{ error.SocketUnconnected, 0 },
    };
    if (socket.pending.items.len > 0) {
        var used: usize = 0;
        var count: usize = 0;
        while (count < op.message_buffer.len and socket.pending.items.len > 0) : (count += 1) {
            const datagram = socket.pending.orderedRemove(0);
            defer abi.heap.free(datagram.data);
            const message = &op.message_buffer[count];
            const n = @min(datagram.data.len, op.data_buffer.len - used);
            @memcpy(op.data_buffer[used..][0..n], datagram.data[0..n]);
            message.from = datagram.from;
            message.data = op.data_buffer[used..][0..n];
            message.flags = .{ .eor = true, .trunc = n < datagram.data.len, .ctrunc = false, .oob = false, .errqueue = false };
            used += n;
        }
        return .{ null, count };
    }
    const incoming = socket.incoming;
    const datagrams = while (true) {
        switch (incoming.receive(op.message_buffer.len)) {
            .ok => |datagrams| if (datagrams.len > 0) break datagrams else wait(incoming.subscribe()),
            .err => return .{ error.Unexpected, 0 },
        }
    };

    var used: usize = 0;
    for (datagrams, op.message_buffer[0..datagrams.len]) |datagram, *message| {
        const n = @min(datagram.data.len, op.data_buffer.len - used);
        @memcpy(op.data_buffer[used..][0..n], datagram.data[0..n]);
        message.from = fromWasiSocket(datagram.remote_address);
        message.data = op.data_buffer[used..][0..n];
        message.flags = .{ .eor = true, .trunc = n < datagram.data.len, .ctrunc = false, .oob = false, .errqueue = false };
        used += n;
    }
    return .{ null, datagrams.len };
}

fn read(_: ?*anyopaque, handle: net.Socket.Handle, data: [][]u8) net.Stream.Reader.Error!usize {
    const stream = switch ((entryOf(handle) orelse return error.SocketUnconnected).*) {
        .stream => |*s| s,
        else => return error.SocketUnconnected,
    };
    var len: usize = 0;
    for (data) |buffer| len += buffer.len;

    if (stream.pending.items.len > 0) {
        const n = copyInto(data, stream.pending.items);
        stream.pending.replaceRangeAssumeCapacity(0, n, &.{});
        return n;
    }
    if (stream.ended) return 0;

    const bytes = switch (stream.input.blockingRead(len)) {
        .ok => |bytes| bytes,
        .err => |err| switch (err) {
            .closed => return 0,
            .last_operation_failed => |e| {
                e.deinit();
                return error.ConnectionResetByPeer;
            },
        },
    };
    return copyInto(data, bytes);
}

fn copyInto(data: [][]u8, bytes: []const u8) usize {
    var copied: usize = 0;
    for (data) |buffer| {
        const n = @min(buffer.len, bytes.len - copied);
        @memcpy(buffer[0..n], bytes[copied..][0..n]);
        copied += n;
    }
    return copied;
}

fn fill(buffer: []u8, len: usize, bytes: []const u8) usize {
    const n = @min(buffer.len - len, bytes.len);
    @memcpy(buffer[len..][0..n], bytes[0..n]);
    return len + n;
}

fn write(_: ?*anyopaque, handle: net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) net.Stream.Writer.Error!usize {
    const output = switch (get(handle) orelse return error.SocketUnconnected) {
        .stream => |s| s.output,
        else => return error.SocketUnconnected,
    };

    // blocking-write-and-flush takes at most 4096 bytes at a time.
    var buffer: [4096]u8 = undefined;
    var len = fill(&buffer, 0, header);
    for (data[0 .. data.len - 1]) |bytes| len = fill(&buffer, len, bytes);
    const pattern = data[data.len - 1];
    for (0..splat) |_| {
        if (len == buffer.len or pattern.len == 0) break;
        len = fill(&buffer, len, pattern);
    }
    if (len == 0) return 0;

    switch (output.blockingWriteAndFlush(buffer[0..len])) {
        .ok => return len,
        .err => |err| switch (err) {
            .closed => return error.ConnectionResetByPeer,
            .last_operation_failed => |e| {
                e.deinit();
                return error.ConnectionResetByPeer;
            },
        },
    }
}

fn close(_: ?*anyopaque, handles: []const net.Socket.Handle) void {
    for (handles) |handle| {
        const entry = get(handle) orelse continue;
        entries.items[@intCast(handle - first_handle)] = null;
        switch (entry) {
            .stream => |s| {
                var pending = s.pending;
                pending.deinit(abi.heap);
                s.input.deinit();
                s.output.deinit();
                s.socket.deinit();
            },
            .listener => |l| {
                var pending = l.pending;
                for (pending.items) |accepted| {
                    accepted.input.deinit();
                    accepted.output.deinit();
                    accepted.socket.deinit();
                }
                pending.deinit(abi.heap);
                l.socket.deinit();
            },
            .datagram => |d| {
                var pending = d.pending;
                for (pending.items) |datagram| abi.heap.free(datagram.data);
                pending.deinit(abi.heap);
                d.incoming.deinit();
                d.outgoing.deinit();
                d.socket.deinit();
            },
        }
    }
}

fn shutdown(_: ?*anyopaque, handle: net.Socket.Handle, how: net.ShutdownHow) net.ShutdownError!void {
    const socket = switch (get(handle) orelse return error.SocketUnconnected) {
        .stream => |s| s.socket,
        else => return error.SocketUnconnected,
    };
    const kind: tcp.ShutdownType = switch (how) {
        .recv => .receive,
        .send => .send,
        .both => .both,
    };
    switch (socket.shutdown(kind)) {
        .ok => {},
        .err => |code| return switch (code) {
            .invalid_state => error.SocketUnconnected,
            else => error.Unexpected,
        },
    }
}

fn lookupError(code: network.ErrorCode) net.HostName.LookupError {
    return switch (code) {
        .access_denied => blk: {
            denied("network.dns");
            break :blk error.Unexpected;
        },
        .name_unresolvable => error.UnknownHostName,
        .temporary_resolver_failure, .permanent_resolver_failure => error.NameServerFailure,
        .out_of_memory => error.SystemResources,
        else => error.Unexpected,
    };
}

fn lookup(
    _: ?*anyopaque,
    host: net.HostName,
    results: *Io.Queue(net.HostName.LookupResult),
    options: net.HostName.LookupOptions,
) net.HostName.LookupError!void {
    const io = current();
    defer results.close(io);

    const stream = switch (wasi.ip_name_lookup.resolveAddresses(instanceNetwork(), host.bytes)) {
        .ok => |stream| stream,
        .err => |code| return lookupError(code),
    };
    defer stream.deinit();

    // Queues of 16 have to be enough, and the canonical name takes one place.
    var found: usize = 0;
    while (found < 15) {
        const address = switch (stream.resolveNextAddress()) {
            .ok => |address| address orelse break,
            .err => |code| if (code == .would_block) {
                wait(stream.subscribe());
                continue;
            } else return lookupError(code),
        };
        const ip = fromWasi(address, options.port);
        if (options.family) |f| if (ip != f) continue;
        results.putOne(io, .{ .address = ip }) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => |e| return e,
        };
        found += 1;
    }
    if (found == 0) return error.NoAddressReturned;

    const name: net.HostName = if (options.canonical_name_buffer) |buffer| blk: {
        @memcpy(buffer[0..host.bytes.len], host.bytes);
        break :blk .{ .bytes = buffer[0..host.bytes.len] };
    } else host;
    results.putOne(io, .{ .canonical_name = name }) catch |err| switch (err) {
        error.Closed => {},
        error.Canceled => |e| return e,
    };
}
