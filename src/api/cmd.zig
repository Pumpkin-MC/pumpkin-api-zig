//! Declarative commands on top of the generated `command` interface.
//!
//!     try pumpkin.cmd.register(ctx, .{
//!         .names = &.{ "greet", "hi" },
//!         .description = "Greets players.",
//!         .permission = "my-plugin:command.greet",
//!         .run = greetSelf,
//!         .then = &.{
//!             .argument("targets", .players, .{ .run = greetTargets }),
//!         },
//!     });

const std = @import("std");
const abi = @import("../runtime/abi.zig");
const wit = @import("../bindings/pumpkin.zig");

const command = wit.command;
const Context = wit.context.Context;
const Server = wit.server.Server;
const Player = wit.player.Player;
const TextComponent = wit.text.TextComponent;

pub const Sender = command.CommandSender;
pub const Args = command.ConsumedArgs;
pub const Arg = command.Arg;
pub const ArgumentType = command.ArgumentType;
pub const Result = abi.Result(i32, command.CommandError);

pub const Handler = fn (Sender, Server, Args) Result;
pub const Suggester = fn (Sender, Server, command.SuggestionRequest) command.CommandSuggestions;

pub const Node = struct {
    kind: union(enum) {
        literal: []const u8,
        argument: struct { name: []const u8, type: ArgumentType },
    },
    options: Options,

    pub const Options = struct {
        run: ?*const Handler = null,
        /// Only meaningful on arguments.
        suggest: ?*const Suggester = null,
        then: []const Node = &.{},
    };

    pub fn literal(name: []const u8, options: Options) Node {
        return .{ .kind = .{ .literal = name }, .options = options };
    }

    pub fn argument(name: []const u8, arg_type: ArgumentType, options: Options) Node {
        return .{ .kind = .{ .argument = .{ .name = name, .type = arg_type } }, .options = options };
    }

    fn build(node: Node) command.CommandNode {
        const built: command.CommandNode = switch (node.kind) {
            .literal => |name| .literal(name),
            .argument => |arg| .argument(arg.name, arg.type),
        };
        if (node.options.run) |handler| built.executeWithHandlerId(@intFromPtr(handler));
        if (node.options.suggest) |suggester| built.suggestWithHandlerId(@intFromPtr(suggester));
        for (node.options.then) |child| built.then(child.build());
        return built;
    }
};

pub const Spec = struct {
    /// The command's name followed by its aliases.
    names: []const []const u8,
    description: []const u8 = "",
    /// Has to start with "<plugin name>:". A node the server has never heard
    /// of denies everyone, so `register` registers it as well.
    permission: []const u8,
    /// Turn this off when the node is registered elsewhere, for example with
    /// children of its own. `description` and `default` are then unused.
    register_permission: bool = true,
    default: wit.permission.PermissionDefault = .allow,
    run: ?*const Handler = null,
    then: []const Node = &.{},
};

/// Reports whether the server can register an argument of this type. The
/// v0.1 plugin API rejects the others, such as `.message`; to read the rest of
/// the line, use `.{ .string = .greedy }` instead.
pub fn isSupported(arg_type: ArgumentType) bool {
    return switch (arg_type) {
        .bool, .float, .double, .integer, .long, .string, .entities, .entity, .players, .game_profile => true,
        .block_pos, .position3d, .position2d, .block_state, .block_predicate, .item, .item_predicate => true,
        .component, .rotation, .resource_location, .resource, .entity_anchor, .gamemode, .difficulty, .time => true,
        else => false,
    };
}

/// Returns the first argument under `nodes` whose type the server can't register.
pub fn findUnsupported(nodes: []const Node) ?Node {
    for (nodes) |node| {
        if (node.kind == .argument and !isSupported(node.kind.argument.type)) return node;
        if (findUnsupported(node.options.then)) |found| return found;
    }
    return null;
}

pub fn register(ctx: Context, spec: Spec) error{ PermissionRejected, UnsupportedArgument }!void {
    if (findUnsupported(spec.then)) |node| {
        const arg = node.kind.argument;
        std.log.err("/{s}: the server doesn't support the argument type .{t} of '{s}'", .{ spec.names[0], arg.type, arg.name });
        return error.UnsupportedArgument;
    }
    if (spec.register_permission) switch (ctx.registerPermission(.{
        .node = spec.permission,
        .description = spec.description,
        .default = spec.default,
        .children = &.{},
    })) {
        .ok => {},
        .err => |message| {
            std.log.err("permission {s}: {s}", .{ spec.permission, message });
            return error.PermissionRejected;
        },
    };

    const root: command.Command = .init(spec.names, spec.description);
    if (spec.run) |handler| root.executeWithHandlerId(@intFromPtr(handler));
    for (spec.then) |child| root.then(child.build());
    ctx.registerCommand(root, spec.permission);
}

pub fn ok(count: i32) Result {
    return .{ .ok = count };
}

pub fn fail(message: []const u8) Result {
    return failWith(.text(message));
}

/// Like `fail`, with any text component, such as one from `msg.build`.
pub fn failWith(message: wit.text.TextComponent) Result {
    return .{ .err = .{ .command_failed = message } };
}

/// The value of argument `name` if it was parsed as `tag`.
pub fn get(args: Args, name: []const u8, comptime tag: std.meta.Tag(Arg)) ?@FieldType(Arg, @tagName(tag)) {
    const value = args.getValue(name);
    return if (value == tag) @field(value, @tagName(tag)) else null;
}

/// Any numeric argument as an integer, null when missing or out of bounds.
pub fn int(args: Args, name: []const u8) ?i64 {
    return switch ((get(args, name, .num) orelse return null)) {
        .ok => |number| switch (number) {
            .int32 => |v| v,
            .int64 => |v| v,
            .float32 => |v| @intFromFloat(v),
            .float64 => |v| @intFromFloat(v),
        },
        .err => null,
    };
}

pub fn float(args: Args, name: []const u8) ?f64 {
    return switch ((get(args, name, .num) orelse return null)) {
        .ok => |number| switch (number) {
            .int32 => |v| @floatFromInt(v),
            .int64 => |v| @floatFromInt(v),
            .float32 => |v| v,
            .float64 => |v| v,
        },
        .err => null,
    };
}

/// What is wrong with an argument `typed` couldn't fill a field from.
pub const Problem = enum {
    missing,
    out_of_range,
    /// A decimal number was given for an integer field.
    not_whole,
    /// A `Player` field got a selector that matched none or several players.
    not_one_player,
};

pub const BadArgument = fn (sender: Sender, name: []const u8, problem: Problem) Result;

/// Answers a command whose arguments `typed` couldn't read. Replace it to
/// change or translate the messages.
pub var bad_argument: *const BadArgument = defaultBadArgument;

pub fn defaultBadArgument(_: Sender, name: []const u8, problem: Problem) Result {
    return switch (problem) {
        .missing => failFmt("missing argument '{s}'", .{name}),
        .out_of_range => failFmt("'{s}' is out of range", .{name}),
        .not_whole => failFmt("'{s}' has to be a whole number", .{name}),
        .not_one_player => failFmt("'{s}' has to be exactly one player", .{name}),
    };
}

/// Wraps `fn (Sender, Server, T) Result`, filling `T` with the arguments of the same name.
pub fn typed(comptime handler: anytype) *const Handler {
    const params = @typeInfo(@TypeOf(handler)).@"fn".params;
    if (params.len != 3) @compileError("cmd.typed wants a fn (Sender, Server, T) Result");
    const T = params[2].type.?;
    return &struct {
        fn run(sender: Sender, srv: Server, args: Args) Result {
            var out: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const Value = switch (@typeInfo(field.type)) {
                    .optional => |o| o.child,
                    else => field.type,
                };
                @field(out, field.name) = switch (read(Value, args.getValue(field.name))) {
                    .ok => |value| value,
                    .missing => if (field.defaultValue()) |default|
                        default
                    else if (Value != field.type)
                        null
                    else
                        return bad_argument(sender, field.name, .missing),
                    .invalid => |problem| return bad_argument(sender, field.name, problem),
                };
            }
            return handler(sender, srv, out);
        }
    }.run;
}

fn failFmt(comptime format: []const u8, args: anytype) Result {
    return fail(std.fmt.allocPrint(abi.arena(), format, args) catch @panic("OOM"));
}

fn Read(comptime T: type) type {
    return union(enum) { ok: T, missing, invalid: Problem };
}

fn read(comptime T: type, arg: Arg) Read(T) {
    comptime if (!readable(T)) @compileError("no argument type gives a " ++ @typeName(T));
    if (arg == .simple and arg.simple.len == 0) return .missing;

    switch (@typeInfo(T)) {
        .int => if (arg == .num) return switch (arg.num) {
            .err => .{ .invalid = .out_of_range },
            .ok => |number| switch (number) {
                inline .int32, .int64 => |v| if (std.math.cast(T, v)) |c| .{ .ok = c } else .{ .invalid = .out_of_range },
                .float32, .float64 => .{ .invalid = .not_whole },
            },
        },
        .float => if (arg == .num) return switch (arg.num) {
            .err => .{ .invalid = .out_of_range },
            .ok => |number| switch (number) {
                inline .int32, .int64 => |v| .{ .ok = @floatFromInt(v) },
                inline .float32, .float64 => |v| .{ .ok = @floatCast(v) },
            },
        },
        else => {},
    }
    if (T == Player and arg == .players) {
        return if (arg.players.len == 1) .{ .ok = arg.players[0] } else .{ .invalid = .not_one_player };
    }
    inline for (@typeInfo(Arg).@"union".fields) |case| {
        if (case.type == T and arg == @field(std.meta.Tag(Arg), case.name)) return .{ .ok = @field(arg, case.name) };
    }
    return .missing;
}

fn readable(comptime T: type) bool {
    if (T == Player) return true;
    switch (@typeInfo(T)) {
        .int, .float => return true,
        else => {},
    }
    for (@typeInfo(Arg).@"union".fields) |case| {
        if (case.type == T) return true;
    }
    return false;
}

/// Suggests `values` for the word under the cursor.
pub fn suggestions(request: command.SuggestionRequest, values: []const []const u8) command.CommandSuggestions {
    const out = abi.arena().alloc(command.CommandSuggestion, values.len) catch @panic("OOM");
    var n: usize = 0;
    for (values) |value| {
        if (!std.mem.startsWith(u8, value, request.remaining)) continue;
        out[n] = .{ .value = value, .tooltip = null };
        n += 1;
    }
    return .{ .start = request.start, .length = @intCast(request.remaining.len), .values = out[0..n] };
}

test "read" {
    try std.testing.expectEqualDeep(Read(i32){ .ok = 5 }, read(i32, .{ .num = .{ .ok = .{ .int64 = 5 } } }));
    try std.testing.expectEqualDeep(Read(u8){ .invalid = .out_of_range }, read(u8, .{ .num = .{ .ok = .{ .int32 = 300 } } }));
    try std.testing.expectEqualDeep(Read(i32){ .invalid = .not_whole }, read(i32, .{ .num = .{ .ok = .{ .float64 = 1.5 } } }));
    try std.testing.expectEqualDeep(Read(f32){ .ok = 2 }, read(f32, .{ .num = .{ .ok = .{ .int32 = 2 } } }));
    try std.testing.expectEqualDeep(Read(i32){ .ok = 40 }, read(i32, .{ .time = 40 }));
    try std.testing.expectEqualDeep(Read(bool){ .ok = true }, read(bool, .{ .bool = true }));
    try std.testing.expectEqualDeep(Read(bool).missing, read(bool, .{ .simple = "" }));
    try std.testing.expectEqualDeep(Read(bool).missing, read(bool, .{ .time = 1 }));

    const word = read([]const u8, .{ .msg = "hello there" });
    try std.testing.expectEqualStrings("hello there", word.ok);

    const one: Player = @enumFromInt(7);
    try std.testing.expectEqualDeep(Read(Player){ .ok = one }, read(Player, .{ .players = &.{one} }));
    try std.testing.expectEqualDeep(Read(Player){ .invalid = .not_one_player }, read(Player, .{ .players = &.{ one, one } }));
    try std.testing.expectEqualDeep(1, read([]const Player, .{ .players = &.{one} }).ok.len);
}
