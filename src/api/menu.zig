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
const item = @import("item.zig");
const pumpkin = @import("../pumpkin.zig");
const wit = @import("../bindings/pumpkin.zig");

const Context = wit.context.Context;
const Server = wit.server.Server;
const Player = wit.player.Player;
const Uuid = wit.uuid.Uuid;
const Gui = wit.gui.Gui;
const Inventory = wit.inventory.Inventory;

pub const Screen = wit.screens.Screen;
pub const ClickType = wit.common.ClickType;

/// Any item `pumpkin.item.build` can make.
pub const Icon = item.Spec;

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
    /// Without a handler the button is only there to look at.
    on_click: ?*const ClickHandler = null,
    /// Tells apart buttons that share a handler.
    data: usize = 0,
};

/// An existing item to put in a slot, such as one the plugin saved earlier.
pub const Stack = struct {
    slot: u32,
    /// Consumed by `open`.
    item: item.ItemStack,
};

pub const Spec = struct {
    screen: Screen = .generic_9x3,
    title: []const msg.Span,
    buttons: []const Button = &.{},
    /// Put in their slots after the buttons, usually free ones.
    stacks: []const Stack = &.{},
    /// Goes in every slot that has no button and isn't free.
    fill: ?Icon = null,
    /// Slots that work like chest slots: players can take what is in them and
    /// put their own items in. A button on a free slot is only its starting
    /// item. While a menu has free slots, shift clicks from the player's
    /// inventory, double clicks and drags are blocked, since they would reach
    /// the other slots too. Read what is in the slots with `items`.
    free: []const u32 = &.{},
    /// Also runs when another menu replaces this one or the player leaves.
    on_close: ?*const CloseHandler = null,
};

const Action = struct { handler: *const ClickHandler, data: usize };

const Session = struct {
    screen: Screen,
    /// Which slots are free, or empty when none are.
    free: []bool,
    actions: []?Action,
    /// The menu's slots, shared with the open screen.
    items: Inventory,
    on_close: ?*const CloseHandler,

    fn deinit(session: Session) void {
        abi.heap.free(session.actions);
        abi.heap.free(session.free);
        session.items.deinit();
    }
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
    gui.setAllowGrabItems(spec.free.len > 0);
    gui.setAllowPutItems(spec.free.len > 0);

    const size = gui.getSize();
    const actions = abi.heap.alloc(?Action, size) catch @panic("OOM");
    @memset(actions, null);
    const free = abi.heap.alloc(bool, size) catch @panic("OOM");
    @memset(free, false);
    const taken = abi.arena().alloc(bool, size) catch @panic("OOM");
    @memset(taken, false);

    for (spec.free) |slot| {
        if (slot >= size) {
            std.log.warn("free menu slot {d}, the menu has {d}", .{ slot, size });
            continue;
        }
        free[slot] = true;
        taken[slot] = true;
    }

    for (spec.buttons) |button| {
        if (button.slot >= size) {
            std.log.warn("menu button in slot {d}, the menu has {d}", .{ button.slot, size });
            continue;
        }
        gui.setItem(button.slot, item.build(button.icon));
        taken[button.slot] = true;
        if (free[button.slot]) continue;
        if (button.on_click) |handler| actions[button.slot] = .{ .handler = handler, .data = button.data };
    }
    for (spec.stacks) |stack| {
        if (stack.slot >= size) {
            std.log.warn("menu item in slot {d}, the menu has {d}", .{ stack.slot, size });
            continue;
        }
        gui.setItem(stack.slot, stack.item);
        taken[stack.slot] = true;
    }
    if (spec.fill) |icon| {
        for (taken, 0..) |t, slot| if (!t) gui.setItem(@intCast(slot), item.build(icon));
    }

    const slots = gui.getInventory();
    slots.keep();
    const id = player.getId();
    // Closes the previous menu, which ends its session from inside this call.
    player.openGui(gui);

    const entry = sessions.getOrPut(abi.heap, id) catch @panic("OOM");
    if (entry.found_existing) entry.value_ptr.deinit();
    entry.value_ptr.* = .{
        .screen = spec.screen,
        .free = if (spec.free.len > 0) free else blk: {
            abi.heap.free(free);
            break :blk &.{};
        },
        .actions = actions,
        .items = slots,
        .on_close = spec.on_close,
    };
}

pub fn isOpen(player: Player) bool {
    return sessions.contains(player.getId());
}

/// Returns the slots of the player's open menu, including items in free
/// slots. It also works inside `on_close`, so a plugin can see
/// what was left in the menu before it goes away.
pub fn items(player: Player) ?Inventory {
    if (sessions.get(player.getId())) |session| return session.items;
    if (closing) |c| if (std.meta.eql(c.player, player.getId())) return c.items;
    return null;
}

/// The menu whose `on_close` is running, which is already out of `sessions`.
var closing: ?struct { player: Uuid, items: Inventory } = null;

fn onClick(srv: Server, ev: *pumpkin.EventData(.inventory_click_event)) void {
    const session = sessions.get(ev.player.getId()) orelse return;
    if (ev.window_type != session.screen) return;

    const in_menu = ev.slot >= 0 and ev.slot < session.actions.len;
    const action = if (in_menu) session.actions[@intCast(ev.slot)] else null;
    if (action == null and allowed(session, ev, in_menu)) return;
    ev.cancelled = true;
    const a = action orelse return;
    a.handler(.{
        .server = srv,
        .player = ev.player,
        .slot = @intCast(ev.slot),
        .type = ev.click_type,
        .data = a.data,
    });
}

/// Decides whether a click that isn't on a button may go through.
fn allowed(session: Session, ev: *const pumpkin.EventData(.inventory_click_event), in_menu: bool) bool {
    if (session.free.len == 0) return false;
    switch (ev.click_type) {
        .double_click, .unknown => return false,
        .shift_left, .shift_right => if (!in_menu) return false,
        else => {},
    }
    return !in_menu or session.free[@intCast(ev.slot)];
}

fn onClose(srv: Server, ev: *pumpkin.EventData(.inventory_close_event)) void {
    end(srv, ev.player);
}

fn onLeave(srv: Server, ev: *pumpkin.EventData(.player_leave_event)) void {
    end(srv, ev.player);
}

fn end(srv: Server, player: Player) void {
    const session = (sessions.fetchRemove(player.getId()) orelse return).value;
    defer session.deinit();
    const handler = session.on_close orelse return;
    const previous = closing;
    closing = .{ .player = player.getId(), .items = session.items };
    defer closing = previous;
    handler(srv, player);
}
