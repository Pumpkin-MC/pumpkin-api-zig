//! Questions asked in chat. `ask` takes the player's next chat message as the
//! answer instead of sending it, and `choose` shows options to click.
//!
//!     try pumpkin.prompt.listen(ctx, .{}); // once, in onLoad
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

/// The messages `prompt` sends on its own. Change them to translate or restyle them.
pub const Texts = struct {
    /// The command behind the choices was run by something other than a player.
    not_a_player: []const u8 = "only players can choose",
    /// A choice was clicked in a message whose question is over.
    question_over: []const u8 = "that question is over",
};

pub var texts: Texts = .{};

/// Decides whether a chat message counts as typing `word`.
pub const Matcher = fn (message: []const u8, word: []const u8) bool;

/// The default `Matcher`: the message without surrounding spaces equals
/// `word`, ignoring case.
pub fn sameWord(message: []const u8, word: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, message, " "), word);
}

pub const Answer = struct {
    server: Server,
    player: Player,
    /// The chat message as the player sent it, valid until the handler returns.
    text: []const u8,
    /// The question's `data`.
    data: usize,

    /// Reads the answer as a number of type `T`, ignoring surrounding spaces,
    /// or returns null if it isn't one.
    pub fn number(answer: Answer, comptime T: type) ?T {
        const text = std.mem.trim(u8, answer.text, " ");
        return switch (@typeInfo(T)) {
            .int => std.fmt.parseInt(T, text, 10) catch null,
            .float => std.fmt.parseFloat(T, text) catch null,
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
    /// Typing this ends the question with `.cancelled`. Null turns it off.
    cancel_word: ?[]const u8 = "cancel",
    match: *const Matcher = sameWord,
    /// Decides which chat messages are answers. The others are sent as
    /// usual. Null takes every message.
    capture: ?*const fn (Answer) bool = null,
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
    /// Decides whether a chat message types a choice's `word`.
    match: *const Matcher = sameWord,
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
        ask: struct {
            on_answer: *const fn (Answer) Reply,
            cancel_word: ?[]const u8,
            match: *const Matcher,
            capture: ?*const fn (Answer) bool,
        },
        choose: struct { choices: []const Picked, match: *const Matcher },
    },
};

var sessions: std.AutoHashMapUnmanaged(Uuid, Session) = .empty;
var listening = false;
var server: Server = undefined;
var next_token: u32 = 1;
var command_name: []const u8 = "";

pub const Options = struct {
    /// The command that clicking a choice runs. Null names it "<plugin>-choose".
    command: ?[]const u8 = null,
    /// The command's permission node. Null makes it "<plugin>:command.choose".
    permission: ?[]const u8 = null,
    description: []const u8 = "Picks an option from a chat message.",
    /// Options for the chat handler that takes the answers.
    chat: pumpkin.EventOptions = .{},
};

/// Registers the events and the command that questions run on.
pub fn listen(ctx: Context, options: Options) !void {
    if (listening) return;
    command_name = if (options.command) |name|
        try abi.heap.dupe(u8, name)
    else
        try std.fmt.allocPrint(abi.heap, "{s}-choose", .{pumpkin.plugin_name});
    try cmd.register(ctx, .{
        .names = &.{command_name},
        .description = options.description,
        .permission = options.permission orelse try std.fmt.allocPrint(abi.arena(), "{s}:command.choose", .{pumpkin.plugin_name}),
        .then = &.{.argument("token", .{ .long = .{ 0, null } }, .{ .then = &.{
            .argument("choice", .{ .long = .{ 0, null } }, .{ .run = click }),
        } })},
    });
    pumpkin.on(ctx, .player_chat_event, onChat, options.chat);
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
        .cancel_word = if (spec.cancel_word) |w| dupe(w) else null,
        .match = spec.match,
        .capture = spec.capture,
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
    const token = begin(player, spec.timeout, spec.on_end, spec.data, .{ .choose = .{
        .choices = picked.toOwnedSlice(abi.heap) catch @panic("OOM"),
        .match = spec.match,
    } });

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
        .ask => |a| if (a.cancel_word) |w| abi.heap.free(w),
        .choose => |c| {
            for (c.choices) |choice| if (choice.word) |w| abi.heap.free(w);
            abi.heap.free(c.choices);
        },
    }
}

fn onChat(srv: Server, ev: *pumpkin.EventData(.player_chat_event)) void {
    const open = sessions.get(ev.player.getId()) orelse return;
    const text = ev.message;

    switch (open.kind) {
        .ask => |a| {
            const answer: Answer = .{ .server = srv, .player = ev.player, .text = text, .data = open.data };
            if (a.capture) |capture| if (!capture(answer)) return;
            ev.cancelled = true;
            if (a.cancel_word) |word| if (a.match(text, word)) return end(ev.player, .cancelled);
            respond(ev.player, answerText, .{answer});
        },
        .choose => |c| for (c.choices, 0..) |choice, i| {
            const word = choice.word orelse continue;
            if (!c.match(text, word)) continue;
            ev.cancelled = true;
            return pick(srv, ev.player, i);
        },
    }
}

fn answerText(session: Session, answer: Answer) Reply {
    return session.kind.ask.on_answer(answer);
}

fn pick(srv: Server, player: Player, index: usize) void {
    respond(player, pickChoice, .{ srv, player, index });
}

fn pickChoice(session: Session, srv: Server, player: Player, index: usize) Reply {
    const choice = session.kind.choose.choices[index];
    return choice.on_pick(srv, player, choice.data);
}

/// Each click carries the token of its message, so clicking an old message
/// does nothing.
fn click(sender: cmd.Sender, srv: Server, args: cmd.Args) cmd.Result {
    const player = sender.asPlayer() orelse return cmd.fail(texts.not_a_player);
    const token = cmd.int(args, "token") orelse return cmd.fail(texts.question_over);
    const index = cmd.int(args, "choice") orelse return cmd.fail(texts.question_over);
    const session = sessions.get(player.getId()) orelse return cmd.fail(texts.question_over);
    if (session.kind != .choose or session.token != token or index >= session.kind.choose.choices.len) {
        return cmd.fail(texts.question_over);
    }
    pick(srv, player, @intCast(index));
    return cmd.ok(1);
}

fn onLeave(_: Server, ev: *pumpkin.EventData(.player_leave_event)) void {
    end(ev.player, .left);
}
