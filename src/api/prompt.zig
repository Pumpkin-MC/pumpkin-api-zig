//! Questions asked in chat. `ask` takes the player's next chat message as the
//! answer instead of sending it, and `choose` shows options to click.
//!
//!     try pumpkin.prompt.listen(ctx); // once, in onLoad
//!
//!     pumpkin.prompt.ask(player, .{
//!         .question = &.{.{ .text = "How many diamonds?", .color = .aqua }},
//!         .on_answer = buy,
//!     });

const std = @import("std");
const abi = @import("../runtime/abi.zig");
const cmd = @import("cmd.zig");
const msg = @import("msg.zig");
const tasks = @import("tasks.zig");
const pumpkin = @import("../pumpkin.zig");
const wit = @import("../bindings/pumpkin.zig");

const Context = wit.context.Context;
const Server = wit.server.Server;
const Player = wit.player.Player;
const Uuid = wit.uuid.Uuid;

/// Why a question ended without an answer.
pub const End = enum {
    timeout,
    /// The player typed the cancel word, or the plugin called `cancel`.
    cancelled,
    left,
    /// Another question was asked before this one was answered.
    replaced,
};

pub const EndHandler = fn (Server, Player, End, usize) void;

pub const Answer = struct {
    server: Server,
    player: Player,
    /// The chat message, valid until the handler returns.
    text: []const u8,
    /// The question's `data`.
    data: usize,

    /// Reads the answer as a number of type `T`, or returns null if it isn't one.
    pub fn number(answer: Answer, comptime T: type) ?T {
        return switch (@typeInfo(T)) {
            .int => std.fmt.parseInt(T, answer.text, 10) catch null,
            .float => std.fmt.parseFloat(T, answer.text) catch null,
            else => @compileError("Answer.number reads integers and floats"),
        };
    }
};

/// What a handler returns to decide whether its question stays open.
pub const Reply = union(enum) {
    done,
    /// Keeps the question open. The choices of a `choose` message keep working.
    keep,
    /// Keeps the question open and sends the player this message.
    retry: []const msg.Span,
};

pub fn done() Reply {
    return .done;
}

pub fn keep() Reply {
    return .keep;
}

pub fn retry(message: []const msg.Span) Reply {
    return .{ .retry = message };
}

pub const Ask = struct {
    question: []const msg.Span,
    on_answer: *const fn (Answer) Reply,
    on_end: ?*const EndHandler = null,
    /// How long the question stays open. With null it stays open until the
    /// handler returns `done` or the plugin calls `cancel`.
    timeout: ?tasks.Duration = .seconds(60),
    /// Typing this ends the question with `.cancelled`.
    cancel_word: []const u8 = "cancel",
    data: usize = 0,
};

pub const Choice = struct {
    /// What the player clicks. Clicking picks the choice, so a `click` set
    /// here is replaced, while the other styles and `hover` are kept.
    label: []const msg.Span,
    on_pick: *const PickHandler,
    /// Typing this in chat picks the choice too. Bedrock players can't click
    /// chat messages, so they need it.
    word: ?[]const u8 = null,
    data: usize = 0,
};

/// A piece of a `choose` message, so choices can sit anywhere in it.
pub const Part = union(enum) {
    text: msg.Span,
    choice: Choice,
};

pub const PickHandler = fn (Server, Player, usize) Reply;

pub const Choose = struct {
    message: []const Part,
    on_end: ?*const EndHandler = null,
    /// Works as in `Ask`.
    timeout: ?tasks.Duration = .seconds(60),
    /// Passed to `on_end`.
    data: usize = 0,
};

const Picked = struct {
    on_pick: *const PickHandler,
    word: ?[]const u8,
    data: usize,
};

const Session = struct {
    token: u32,
    timeout: ?tasks.Task,
    on_end: ?*const EndHandler,
    data: usize,
    kind: union(enum) {
        ask: struct { on_answer: *const fn (Answer) Reply, cancel_word: []const u8 },
        choose: []const Picked,
    },
};

var sessions: std.AutoHashMapUnmanaged(Uuid, Session) = .empty;
var listening = false;
var server: Server = undefined;
var next_token: u32 = 1;
var command_name: []const u8 = "";

/// Registers the events and the command that questions run on.
pub fn listen(ctx: Context) !void {
    if (listening) return;
    command_name = try std.fmt.allocPrint(abi.heap, "{s}-choose", .{pumpkin.plugin_name});
    try cmd.register(ctx, .{
        .names = &.{command_name},
        .description = "Picks an option from a chat message.",
        .permission = try std.fmt.allocPrint(abi.arena(), "{s}:command.choose", .{pumpkin.plugin_name}),
        .then = &.{.argument("token", .{ .long = .{ 0, null } }, .{ .then = &.{
            .argument("choice", .{ .long = .{ 0, null } }, .{ .run = click }),
        } })},
    });
    pumpkin.on(ctx, .player_chat_event, onChat, .{});
    pumpkin.on(ctx, .player_leave_event, onLeave, .{});
    server = ctx.getServer();
    server.keep();
    listening = true;
}

/// Asks `player` a question and passes their next chat message to
/// `spec.on_answer`. A question still open for the player ends with `.replaced`.
pub fn ask(player: Player, spec: Ask) void {
    _ = begin(player, spec.timeout, spec.on_end, spec.data, .{ .ask = .{
        .on_answer = spec.on_answer,
        .cancel_word = dupe(spec.cancel_word),
    } });
    player.sendSystemMessage(msg.build(spec.question), false);
}

/// Shows `player` a message with choices to click. Chat messages that match
/// no choice's `word` are sent as usual.
pub fn choose(player: Player, spec: Choose) void {
    const arena = abi.arena();
    var picked: std.ArrayList(Picked) = .empty;
    for (spec.message) |part| switch (part) {
        .text => {},
        .choice => |c| picked.append(abi.heap, .{
            .on_pick = c.on_pick,
            .word = if (c.word) |w| dupe(w) else null,
            .data = c.data,
        }) catch @panic("OOM"),
    };
    const token = begin(player, spec.timeout, spec.on_end, spec.data, .{
        .choose = picked.toOwnedSlice(abi.heap) catch @panic("OOM"),
    });

    var spans: std.ArrayList(msg.Span) = .empty;
    var index: usize = 0;
    for (spec.message) |part| switch (part) {
        .text => |span| spans.append(arena, span) catch @panic("OOM"),
        .choice => |c| {
            const command = std.fmt.allocPrint(arena, "/{s} {d} {d}", .{ command_name, token, index }) catch @panic("OOM");
            for (c.label) |label| {
                var span = label;
                span.click = .{ .run_command = command };
                spans.append(arena, span) catch @panic("OOM");
            }
            index += 1;
        },
    };
    player.sendSystemMessage(msg.build(spans.items), false);
}

/// Ends the player's open question, if any, with `.cancelled`.
pub fn cancel(player: Player) void {
    end(player, .cancelled);
}

/// Reports whether the player has a question open.
pub fn isAsking(player: Player) bool {
    return sessions.contains(player.getId());
}

fn begin(player: Player, timeout: ?tasks.Duration, on_end: ?*const EndHandler, data: usize, kind: @FieldType(Session, "kind")) u32 {
    if (!listening) std.log.err("prompt question before prompt.listen, answers won't arrive", .{});
    end(player, .replaced);

    const token = next_token;
    next_token +%= 1;
    const id = player.getId();
    sessions.put(abi.heap, id, .{
        .token = token,
        .timeout = if (timeout) |t| tasks.after(t, expire, Key{ .player = id, .token = token }) else null,
        .on_end = on_end,
        .data = data,
        .kind = kind,
    }) catch @panic("OOM");
    return token;
}

const Key = struct { player: Uuid, token: u32 };

fn expire(srv: Server, key: Key) void {
    const session = sessions.get(key.player) orelse return;
    if (session.token != key.token) return;
    _ = sessions.remove(key.player);
    release(session);
    const player = srv.getPlayerByUuid(key.player) orelse return;
    if (session.on_end) |handler| handler(srv, player, .timeout, session.data);
}

fn end(player: Player, reason: End) void {
    const session = (sessions.fetchRemove(player.getId()) orelse return).value;
    finish(session);
    if (session.on_end) |handler| handler(server, player, reason, session.data);
}

/// Calls a handler of the player's question with the question taken out, so
/// the handler can ask a new one, and puts it back if the handler keeps it
/// open. Kept questions keep their token, so their choices still work.
fn respond(player: Player, comptime handle: anytype, args: anytype) void {
    const id = player.getId();
    const session = (sessions.fetchRemove(id) orelse return).value;
    const reply: Reply = @call(.auto, handle, .{session} ++ args);
    switch (reply) {
        .done => return finish(session),
        .keep => {},
        .retry => |message| player.sendSystemMessage(msg.build(message), false),
    }
    if (sessions.contains(id)) return finish(session);
    sessions.put(abi.heap, id, session) catch @panic("OOM");
}

/// Stops the session's timeout and frees what it owns.
fn finish(session: Session) void {
    if (session.timeout) |task| task.cancel();
    release(session);
}

fn dupe(text: []const u8) []const u8 {
    return abi.heap.dupe(u8, text) catch @panic("OOM");
}

/// Frees the memory a session owns.
fn release(session: Session) void {
    switch (session.kind) {
        .ask => |a| abi.heap.free(a.cancel_word),
        .choose => |choices| {
            for (choices) |c| if (c.word) |w| abi.heap.free(w);
            abi.heap.free(choices);
        },
    }
}

fn onChat(srv: Server, ev: *pumpkin.EventData(.player_chat_event)) void {
    const open = sessions.get(ev.player.getId()) orelse return;
    const text = std.mem.trim(u8, ev.message, " ");

    switch (open.kind) {
        .ask => |a| {
            ev.cancelled = true;
            if (std.ascii.eqlIgnoreCase(text, a.cancel_word)) return end(ev.player, .cancelled);
            respond(ev.player, answerText, .{ srv, ev.player, text });
        },
        .choose => |choices| for (choices, 0..) |c, i| {
            const word = c.word orelse continue;
            if (!std.ascii.eqlIgnoreCase(text, word)) continue;
            ev.cancelled = true;
            return pick(srv, ev.player, i);
        },
    }
}

fn answerText(session: Session, srv: Server, player: Player, text: []const u8) Reply {
    return session.kind.ask.on_answer(.{ .server = srv, .player = player, .text = text, .data = session.data });
}

fn pick(srv: Server, player: Player, index: usize) void {
    respond(player, pickChoice, .{ srv, player, index });
}

fn pickChoice(session: Session, srv: Server, player: Player, index: usize) Reply {
    const c = session.kind.choose[index];
    return c.on_pick(srv, player, c.data);
}

/// Each click carries the token of its message, so clicking an old message
/// does nothing.
fn click(sender: cmd.Sender, srv: Server, args: cmd.Args) cmd.Result {
    const player = sender.asPlayer() orelse return cmd.fail("only players can choose");
    const token = cmd.int(args, "token") orelse return cmd.fail("missing token");
    const index = cmd.int(args, "choice") orelse return cmd.fail("missing choice");
    const session = sessions.get(player.getId()) orelse return cmd.fail("that question is over");
    if (session.kind != .choose or session.token != token or index >= session.kind.choose.len) {
        return cmd.fail("that question is over");
    }
    pick(srv, player, @intCast(index));
    return cmd.ok(1);
}

fn onLeave(_: Server, ev: *pumpkin.EventData(.player_leave_event)) void {
    end(ev.player, .left);
}
