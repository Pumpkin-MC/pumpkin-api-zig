//! Inventory menus with a click handler per slot, on top of the generated `gui`.
//!
//!     pumpkin.menu.listen(ctx); // once, in onLoad
//!
//!     pumpkin.menu.open(player, .{
//!         .title = &.{.{ .text = "Shop", .color = .gold }},
//!         .buttons = &.{.{
//!             .slot = 13,
//!             .icon = .{ .id = "minecraft:diamond", .name = &.{.{ .text = "Buy", .color = .aqua }} },
//!             .on_click = buy,
//!         }},
//!     });

const std = @import("std");
const abi = @import("../runtime/abi.zig");
const msg = @import("msg.zig");
const pumpkin = @import("../pumpkin.zig");
const wit = @import("../bindings/pumpkin.zig");

const Context = wit.context.Context;
const Server = wit.server.Server;
const Player = wit.player.Player;
const Uuid = wit.uuid.Uuid;
const Gui = wit.gui.Gui;
const ItemStack = wit.item_stack.ItemStack;
const TextComponent = wit.text.TextComponent;

pub const Screen = wit.screens.Screen;
pub const ClickType = wit.common.ClickType;

pub const Icon = struct {
    id: []const u8,
    count: u8 = 1,
    name: ?[]const msg.Span = null,
    lore: []const []const msg.Span = &.{},
};

pub const Click = struct {
    server: Server,
    player: Player,
    slot: u32,
    type: ClickType,
    /// The clicked button's `data`.
    data: usize,
};

pub const ClickHandler = fn (Click) void;
pub const CloseHandler = fn (Server, Player) void;

pub const Button = struct {
    slot: u32,
    icon: Icon,
    on_click: ?*const ClickHandler = null,
    /// Tells apart buttons that share a handler.
    data: usize = 0,
};

pub const Spec = struct {
    screen: Screen = .generic_9x3,
    title: []const msg.Span,
    buttons: []const Button = &.{},
    /// Goes in every slot without a button.
    fill: ?Icon = null,
    /// Also runs when another menu replaces this one or the player leaves.
    on_close: ?*const CloseHandler = null,
};

const Action = struct { handler: *const ClickHandler, data: usize };

const Session = struct {
    screen: Screen,
    actions: []?Action,
    on_close: ?*const CloseHandler,
};

var sessions: std.AutoHashMapUnmanaged(Uuid, Session) = .empty;
var listening = false;

/// Registers the events menus run on.
pub fn listen(ctx: Context) void {
    if (listening) return;
    listening = true;
    pumpkin.on(ctx, .inventory_click_event, onClick, .{});
    pumpkin.on(ctx, .inventory_close_event, onClose, .{});
    pumpkin.on(ctx, .player_leave_event, onLeave, .{});
}

/// Opens `spec` for `player`, closing whatever they had open.
pub fn open(player: Player, spec: Spec) void {
    if (!listening) std.log.err("menu.open before menu.listen, clicks won't do anything", .{});

    const gui: Gui = .init(spec.screen, msg.build(spec.title));
    gui.setAllowGrabItems(false);
    gui.setAllowPutItems(false);

    const size = gui.getSize();
    const actions = abi.heap.alloc(?Action, size) catch @panic("OOM");
    @memset(actions, null);
    const taken = abi.arena().alloc(bool, size) catch @panic("OOM");
    @memset(taken, false);

    for (spec.buttons) |button| {
        if (button.slot >= size) {
            std.log.warn("menu button in slot {d}, the menu has {d}", .{ button.slot, size });
            continue;
        }
        gui.setItem(button.slot, item(button.icon));
        taken[button.slot] = true;
        if (button.on_click) |handler| actions[button.slot] = .{ .handler = handler, .data = button.data };
    }
    if (spec.fill) |icon| {
        for (taken, 0..) |t, slot| if (!t) gui.setItem(@intCast(slot), item(icon));
    }

    const id = player.getId();
    // Closes the previous menu, which ends its session from inside this call.
    player.openGui(gui);

    const entry = sessions.getOrPut(abi.heap, id) catch @panic("OOM");
    if (entry.found_existing) abi.heap.free(entry.value_ptr.actions);
    entry.value_ptr.* = .{ .screen = spec.screen, .actions = actions, .on_close = spec.on_close };
}

pub fn isOpen(player: Player) bool {
    return sessions.contains(player.getId());
}

fn onClick(srv: Server, ev: *pumpkin.EventData(.inventory_click_event)) void {
    const session = sessions.get(ev.player.getId()) orelse return;
    if (ev.window_type != session.screen) return;

    ev.cancelled = true;
    if (ev.slot < 0 or ev.slot >= session.actions.len) return;
    const action = session.actions[@intCast(ev.slot)] orelse return;
    action.handler(.{
        .server = srv,
        .player = ev.player,
        .slot = @intCast(ev.slot),
        .type = ev.click_type,
        .data = action.data,
    });
}

fn onClose(srv: Server, ev: *pumpkin.EventData(.inventory_close_event)) void {
    end(srv, ev.player);
}

fn onLeave(srv: Server, ev: *pumpkin.EventData(.player_leave_event)) void {
    end(srv, ev.player);
}

fn end(srv: Server, player: Player) void {
    const session = (sessions.fetchRemove(player.getId()) orelse return).value;
    abi.heap.free(session.actions);
    if (session.on_close) |handler| handler(srv, player);
}

fn item(icon: Icon) ItemStack {
    const stack: ItemStack = .init(icon.id, icon.count);
    if (icon.name) |name| stack.setCustomName(upright(name));
    for (icon.lore) |line| stack.addLore(upright(line));
    return stack;
}

/// Item names and lore are italic unless told otherwise.
fn upright(spans: []const msg.Span) TextComponent {
    const root: TextComponent = .text("");
    root.italic(false);
    for (spans) |s| root.addChild(msg.span(s));
    return root;
}
