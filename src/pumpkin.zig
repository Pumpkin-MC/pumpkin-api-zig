//! Zig bindings for Pumpkin's plugin API.
//!
//! The namespaces below mirror the WIT interfaces one to one and are generated.
//! What's written by hand here is the glue a plugin needs to get going:
//! `register`, typed event and task handlers, `cmd` for commands, `msg` for
//! text components, `menu` for inventory menus and `std.log` support.
//!
//! Whatever the API hands out is only good until the current callback returns:
//! strings, slices and records live in a per-call arena and handles are
//! released along with it. Call `keep` on a handle to hold on to it, from then
//! on it is yours to `deinit`. Functions that take a handle over are marked
//! "Consumes" in their docs.

const std = @import("std");

pub const abi = @import("abi.zig");
pub const cmd = @import("cmd.zig");
pub const msg = @import("msg.zig");
pub const menu = @import("menu.zig");
const net_io = @import("net.zig");
const wit = @import("wit.zig");

pub const advancement = wit.advancement;
pub const attributes = wit.attributes;
pub const bedrock_packets = wit.bedrock_packets;
pub const biomes = wit.biomes;
pub const block_entity = wit.block_entity;
pub const boss_bar = wit.boss_bar;
pub const command = wit.command;
pub const common = wit.common;
pub const context = wit.context;
pub const damage_types = wit.damage_types;
pub const data_components = wit.data_components;
pub const datapack = wit.datapack;
pub const display = wit.display;
pub const enchantments = wit.enchantments;
pub const entity = wit.entity;
pub const entity_statuses = wit.entity_statuses;
pub const entity_types = wit.entity_types;
pub const event = wit.event;
pub const forms = wit.forms;
pub const game_events = wit.game_events;
pub const game_rules = wit.game_rules;
pub const gui = wit.gui;
pub const i18n = wit.i18n;
pub const inventory = wit.inventory;
pub const ipc = wit.ipc;
pub const item_stack = wit.item_stack;
pub const java_dialogs = wit.java_dialogs;
pub const java_packets = wit.java_packets;
pub const logging = wit.logging;
pub const particles = wit.particles;
pub const permission = wit.permission;
pub const player = wit.player;
pub const potions = wit.potions;
pub const recipe = wit.recipe;
pub const scheduler = wit.scheduler;
pub const scoreboard = wit.scoreboard;
pub const screens = wit.screens;
pub const server = wit.server;
pub const sounds = wit.sounds;
pub const statistics = wit.statistics;
pub const status_effect = wit.status_effect;
pub const text = wit.text;
pub const uuid = wit.uuid;
pub const world = wit.world;

pub const Context = context.Context;
pub const Server = server.Server;
pub const Player = player.Player;
pub const Entity = world.Entity;
pub const World = world.World;
pub const TextComponent = text.TextComponent;
pub const Event = event.Event;
pub const EventType = event.EventType;
pub const EventPriority = event.EventPriority;
pub const CommandSender = command.CommandSender;
pub const ConsumedArgs = command.ConsumedArgs;
pub const CommandError = command.CommandError;
pub const CommandResult = abi.Result(i32, CommandError);

pub const Metadata = struct {
    name: []const u8,
    version: []const u8,
    authors: []const []const u8 = &.{},
    description: []const u8 = "",
    dependencies: []const []const u8 = &.{},
    permissions: []const []const u8 = &.{},
};

var threaded: std.Io.Threaded = .init_single_threaded;
var vtable: ?std.Io.VTable = null;

pub const net = struct {
    pub const ready = net_io.ready;
};

/// The `std.Io` to pass to file and network calls.
pub fn io() std.Io {
    if (vtable == null) {
        vtable = threaded.io().vtable.*;
        net_io.install(&vtable.?);
    }
    return .{ .userdata = &threaded, .vtable = &vtable.? };
}

/// Plug this into `std_options.logFn` to route `std.log` to the server console.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    const message = std.fmt.allocPrint(abi.arena(), prefix ++ format, args) catch return;
    logging.log(switch (level) {
        .err => .@"error",
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    }, message);
}

pub const EventOptions = struct {
    priority: EventPriority = .normal,
    /// Whether the server waits for the handler before carrying on.
    /// Changes made to the event are only seen when this is set.
    blocking: bool = true,
};

pub fn EventData(comptime event_type: EventType) type {
    return @FieldType(Event, @tagName(event_type));
}

/// Registers `handler` for one kind of event. It gets the payload of exactly
/// that event and may edit it in place, e.g. set `cancelled`.
pub fn on(
    ctx: Context,
    comptime event_type: EventType,
    comptime handler: fn (Server, *EventData(event_type)) void,
    options: EventOptions,
) void {
    const tag = comptime std.meta.stringToEnum(std.meta.Tag(Event), @tagName(event_type)).?;
    const glue = struct {
        // Only this event's payload gets lifted. Going through the whole
        // `Event` union would compile code for every event there is.
        fn dispatch(srv: Server, in: [*]const u8, out: [*]u8) void {
            if (abi.loadTag(Event, in) != tag) {
                @memcpy(out[0..abi.sizeOf(Event)], in[0..abi.sizeOf(Event)]);
                return;
            }
            var data = abi.loadCase(Event, tag, in);
            handler(srv, &data);
            abi.storeCase(Event, tag, data, out);
        }
    };
    ctx.registerEvent(handlerId(&glue.dispatch), event_type, options.priority, options.blocking);
}

const EventDispatch = fn (Server, in: [*]const u8, out: [*]u8) void;

pub const CommandHandler = fn (CommandSender, Server, ConsumedArgs) CommandResult;
pub const SuggestionHandler = fn (CommandSender, Server, command.SuggestionRequest) command.CommandSuggestions;
pub const TaskHandler = fn (Server) void;
pub const GenerateHandler = fn (world.GenerationPhase, world.ChunkBuffer) void;

pub const AiGoal = struct {
    canStart: *const fn (Server, Entity) bool,
    shouldContinue: *const fn (Server, Entity) bool,
    start: *const fn (Server, Entity) void = noop,
    tick: *const fn (Server, Entity) void = noop,
    stop: *const fn (Server, Entity) void = noop,

    fn noop(_: Server, _: Entity) void {}
};

/// The server hands ids back untouched, so an id is simply the address of the
/// handler. Works for every `*-with-handler-id` style function in the API,
/// pass a pointer to a function of the matching `*Handler` type or to a
/// static `AiGoal`.
pub fn handlerId(handler: anytype) u32 {
    return @intFromPtr(handler);
}

pub fn runLater(comptime handler: TaskHandler, delay_ticks: u64) u32 {
    return scheduler.scheduleDelayedTask(handlerId(&handler), delay_ticks);
}

pub fn runEvery(comptime handler: TaskHandler, delay_ticks: u64, period_ticks: u64) u32 {
    return scheduler.scheduleRepeatingTask(handlerId(&handler), delay_ticks, period_ticks);
}

/// Registers what `Plugin.events` lists, each entry being `.event_name = handler`
/// or `.event_name = .{ handler, EventOptions{...} }`.
fn registerEvents(comptime Plugin: type, ctx: Context) void {
    const table = Plugin.events;
    inline for (@typeInfo(@TypeOf(table)).@"struct".fields) |field| {
        const event_type = comptime std.meta.stringToEnum(EventType, field.name) orelse
            @compileError("no event called '" ++ field.name ++ "'");
        const entry = @field(table, field.name);
        if (@typeInfo(@TypeOf(entry)) == .@"fn") {
            on(ctx, event_type, entry, .{});
        } else {
            on(ctx, event_type, entry[0], entry[1]);
        }
    }
}

/// Exports the plugin world for `Plugin`. Call it from a `comptime` block.
///
/// `Plugin` needs a `pub const metadata: Metadata` and can have any of
///   pub const events = .{ .player_join_event = onJoin, ... }
///   pub const commands: []const cmd.Spec = &.{ ... }
///   pub fn onLoad(ctx: Context) !void
///   pub fn onUnload(ctx: Context) !void
///   pub fn onIpcMessage(sender: ipc.PluginId, message: ipc.IpcMessage) abi.Result(ipc.IpcMessage, []const u8)
///
/// Events and commands are registered before `onLoad` runs.
pub fn register(comptime Plugin: type) void {
    const glue = struct {
        fn initPlugin() void {}

        fn getMetadata() wit.metadata.PluginMetadata {
            const meta: Metadata = Plugin.metadata;
            return .{
                .name = meta.name,
                .version = meta.version,
                .authors = meta.authors,
                .description = meta.description,
                .dependencies = meta.dependencies,
                .permissions = meta.permissions,
            };
        }

        fn onLoad(ctx: Context) abi.Result(void, []const u8) {
            if (@hasDecl(Plugin, "events")) registerEvents(Plugin, ctx);
            if (@hasDecl(Plugin, "commands")) {
                const specs: []const cmd.Spec = Plugin.commands;
                for (specs) |spec| cmd.register(ctx, spec) catch |err| return .{ .err = @errorName(err) };
            }
            return lifecycle("onLoad", ctx);
        }

        fn onUnload(ctx: Context) abi.Result(void, []const u8) {
            return lifecycle("onUnload", ctx);
        }

        fn lifecycle(comptime name: []const u8, ctx: Context) abi.Result(void, []const u8) {
            if (!@hasDecl(Plugin, name)) return .ok;
            @field(Plugin, name)(ctx) catch |err| return .{ .err = @errorName(err) };
            return .ok;
        }

        // Written by hand instead of going through `exports.handleEvent`, see `on`.
        fn handleEvent(raw_args: i32) callconv(.c) i32 {
            const Args = struct { u32, Server, Event };
            comptime std.debug.assert(abi.passedInMemory(Args));

            abi.beginCall();
            const args: [*]const u8 = @ptrFromInt(@as(u32, @bitCast(raw_args)));
            const id = abi.load(u32, args + abi.offsetOf(Args, 0));
            const srv = abi.load(Server, args + abi.offsetOf(Args, 1));
            const out = abi.alloc(Event);

            handlerFromId(EventDispatch, id)(srv, args + abi.offsetOf(Args, 2), out);
            abi.releaseHandles();
            return @bitCast(@as(u32, @intFromPtr(out)));
        }

        fn postHandleEvent(_: i32) callconv(.c) void {
            abi.endCall();
        }

        fn handleCommand(id: u32, sender: CommandSender, srv: Server, args: ConsumedArgs) CommandResult {
            return handlerFromId(CommandHandler, id)(sender, srv, args);
        }

        fn handleCommandSuggestion(
            id: u32,
            sender: CommandSender,
            srv: Server,
            request: command.SuggestionRequest,
        ) command.CommandSuggestions {
            return handlerFromId(SuggestionHandler, id)(sender, srv, request);
        }

        fn handleTask(id: u32, srv: Server) void {
            handlerFromId(TaskHandler, id)(srv);
        }

        fn handleIpcMessage(sender: ipc.PluginId, message: ipc.IpcMessage) abi.Result(ipc.IpcMessage, []const u8) {
            if (@hasDecl(Plugin, "onIpcMessage")) return Plugin.onIpcMessage(sender, message);
            return .{ .err = "this plugin does not take messages" };
        }

        fn aiCanStart(id: u32, srv: Server, mob: Entity) bool {
            return goalFromId(id).canStart(srv, mob);
        }

        fn aiShouldContinue(id: u32, srv: Server, mob: Entity) bool {
            return goalFromId(id).shouldContinue(srv, mob);
        }

        fn aiStart(id: u32, srv: Server, mob: Entity) void {
            goalFromId(id).start(srv, mob);
        }

        fn aiTick(id: u32, srv: Server, mob: Entity) void {
            goalFromId(id).tick(srv, mob);
        }

        fn aiStop(id: u32, srv: Server, mob: Entity) void {
            goalFromId(id).stop(srv, mob);
        }

        fn handleGeneratePhase(id: u32, phase: world.GenerationPhase, chunk: world.ChunkBuffer) void {
            handlerFromId(GenerateHandler, id)(phase, chunk);
        }
    };

    const exports = wit.exports;
    exports.initPlugin(glue.initPlugin);
    exports.getMetadata(glue.getMetadata);
    exports.onLoad(glue.onLoad);
    exports.onUnload(glue.onUnload);
    @export(&glue.handleEvent, .{ .name = "handle-event" });
    @export(&glue.postHandleEvent, .{ .name = "cabi_post_handle-event" });
    exports.handleCommand(glue.handleCommand);
    exports.handleCommandSuggestion(glue.handleCommandSuggestion);
    exports.handleTask(glue.handleTask);
    exports.handleIpcMessage(glue.handleIpcMessage);
    exports.handleAiGoalCanStart(glue.aiCanStart);
    exports.handleAiGoalShouldContinue(glue.aiShouldContinue);
    exports.handleAiGoalStart(glue.aiStart);
    exports.handleAiGoalTick(glue.aiTick);
    exports.handleAiGoalStop(glue.aiStop);
    exports.handleGeneratePhase(glue.handleGeneratePhase);
}

fn handlerFromId(comptime Fn: type, id: u32) *const Fn {
    return @ptrFromInt(id);
}

fn goalFromId(id: u32) *const AiGoal {
    return @ptrFromInt(id);
}

test {
    _ = abi;
}
