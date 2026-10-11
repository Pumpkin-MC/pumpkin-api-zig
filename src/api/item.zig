//! Building and editing item stacks from struct literals, and the inventory
//! work plugins usually do with them: giving items to players, checking the
//! held item, and counting or taking items by id or by a value the plugin
//! stored on them.
//!
//!     const sword = pumpkin.item.build(.{ .id = "minecraft:diamond_sword", .enchants = &.{.{ .sharpness, 5 }} });

const std = @import("std");
const msg = @import("msg.zig");
const pumpkin = @import("../pumpkin.zig");
const wit = @import("../bindings/pumpkin.zig");

pub const ItemStack = wit.item_stack.ItemStack;
pub const Enchantment = wit.enchantments.Enchantment;
pub const Attribute = wit.attributes.Attribute;
pub const Operation = wit.attributes.ModifierOperation;
pub const Slot = wit.enchantments.AttributeModifierSlot;
const Player = wit.player.Player;
const TextComponent = wit.text.TextComponent;

/// A value a plugin stores on an item, for example to recognize its own items later.
pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,

    pub fn eql(a: Value, b: Value) bool {
        return switch (a) {
            .string => |v| b == .string and std.mem.eql(u8, v, b.string),
            .int => |v| b == .int and v == b.int,
            .float => |v| b == .float and v == b.float,
            .bool => |v| b == .bool and v == b.bool,
        };
    }
};

pub const Data = struct {
    key: []const u8,
    value: Value,
};

pub const Rarity = enum(u8) { common, uncommon, rare, epic };

/// An attribute modifier, such as extra attack damage in the main hand.
pub const Modifier = struct {
    attribute: Attribute,
    amount: f64,
    operation: Operation = .add,
    slot: Slot = .main_hand,
};

pub const Spec = struct {
    /// The item's registry key, such as "minecraft:diamond_sword".
    id: []const u8,
    count: u8 = 1,
    name: ?[]const msg.Span = null,
    /// The lore, one list of spans per line.
    lore: []const []const msg.Span = &.{},
    enchants: []const struct { Enchantment, u32 } = &.{},
    /// Enchantments added by data packs, given by their id.
    custom_enchants: []const struct { []const u8, u32 } = &.{},
    modifiers: []const Modifier = &.{},
    unbreakable: bool = false,
    /// Makes the item shimmer as if it were enchanted.
    glint: bool = false,
    /// The item's rarity, which decides the color of its name.
    rarity: ?Rarity = null,
    max_stack_size: ?u8 = null,
    /// How much durability the item has before it breaks.
    max_damage: ?u32 = null,
    /// How much of `max_damage` is already used up.
    damage: ?u32 = null,
    /// Picks a model from a resource pack.
    custom_model_data: ?f32 = null,
    /// Values stored on the item under the plugin's name. Read them back with `get`.
    data: []const Data = &.{},
};

/// Builds the item described by `spec`. Names and lore aren't italic unless
/// a span asks for it, unlike vanilla custom names.
pub fn build(spec: Spec) ItemStack {
    const stack: ItemStack = .init(spec.id, spec.count);
    edit(stack, .{
        .name = spec.name,
        .add_lore = spec.lore,
        .enchants = spec.enchants,
        .custom_enchants = spec.custom_enchants,
        .modifiers = spec.modifiers,
        .unbreakable = if (spec.unbreakable) true else null,
        .glint = if (spec.glint) true else null,
        .rarity = spec.rarity,
        .max_stack_size = spec.max_stack_size,
        .max_damage = spec.max_damage,
        .damage = spec.damage,
        .custom_model_data = spec.custom_model_data,
        .data = spec.data,
    });
    return stack;
}

/// Changes to make to an existing item. Fields left at their defaults keep
/// what the item already has.
pub const Edit = struct {
    count: ?u8 = null,
    name: ?[]const msg.Span = null,
    /// Replaces the whole lore, one list of spans per line.
    lore: ?[]const []const msg.Span = null,
    /// Adds lines after the existing lore.
    add_lore: []const []const msg.Span = &.{},
    /// Adds enchantments or changes their level. Level 0 removes one.
    enchants: []const struct { Enchantment, u32 } = &.{},
    custom_enchants: []const struct { []const u8, u32 } = &.{},
    modifiers: []const Modifier = &.{},
    /// Removes every modifier of these attributes, including ones from other plugins.
    remove_modifiers: []const Attribute = &.{},
    unbreakable: ?bool = null,
    glint: ?bool = null,
    rarity: ?Rarity = null,
    max_stack_size: ?u8 = null,
    max_damage: ?u32 = null,
    /// How much durability is used up. 0 repairs the item completely.
    damage: ?u32 = null,
    custom_model_data: ?f32 = null,
    data: []const Data = &.{},
    /// Removes values this plugin stored under these keys.
    remove_data: []const []const u8 = &.{},
};

/// Applies `changes` to `stack`. An item taken from an inventory is a copy,
/// so put it back afterwards, or use `editHeld` for the main hand.
pub fn edit(stack: ItemStack, changes: Edit) void {
    if (changes.count) |n| stack.setCount(n);
    if (changes.name) |name| stack.setCustomName(upright(name));
    if (changes.lore) |lore| {
        const lines = pumpkin.abi.arena().alloc(TextComponent, lore.len) catch @panic("OOM");
        for (lines, lore) |*line, spans| line.* = upright(spans);
        stack.setLore(lines);
    }
    for (changes.add_lore) |line| stack.addLore(upright(line));
    for (changes.enchants) |e| {
        if (e[1] == 0) stack.removeEnchantment(e[0]) else stack.addEnchantment(e[0], e[1]);
    }
    for (changes.custom_enchants) |e| {
        if (e[1] == 0) stack.removeCustomEnchantment(e[0]) else stack.addCustomEnchantment(e[0], e[1]);
    }
    for (changes.remove_modifiers) |attribute| stack.removeAttributeModifiers(attribute);
    for (changes.modifiers) |m| {
        const id = std.fmt.allocPrint(pumpkin.abi.arena(), "{s}:{t}", .{ pumpkin.plugin_name, m.attribute }) catch @panic("OOM");
        stack.addAttributeModifier(.{
            .attribute = m.attribute,
            .modifier = .{ .id = id, .amount = m.amount, .operation = m.operation },
            .slot = m.slot,
        });
    }

    // Turning a flag off removes the component, so the item still stacks with plain ones.
    if (changes.unbreakable) |on| {
        if (on) setComponent(stack, .unbreakable, .{}) else stack.removeComponent(.unbreakable);
    }
    if (changes.glint) |on| {
        if (on) setComponent(stack, .enchantment_glint_override, .{true}) else stack.removeComponent(.enchantment_glint_override);
    }
    if (changes.rarity) |r| setComponent(stack, .rarity, .{varInt(@intFromEnum(r))});
    if (changes.max_stack_size) |n| setComponent(stack, .max_stack_size, .{varInt(n)});
    if (changes.max_damage) |n| setComponent(stack, .max_damage, .{varInt(n)});
    if (changes.damage) |n| {
        if (n == 0) stack.removeComponent(.damage) else setComponent(stack, .damage, .{varInt(n)});
    }
    if (changes.custom_model_data) |f| setComponent(stack, .custom_model_data, .{ varInt(1), f, varInt(0), varInt(0), varInt(0) });

    for (changes.remove_data) |key| stack.removeCustomData(pumpkin.plugin_name, key);
    for (changes.data) |d| set(stack, d.key, d.value);
}

/// Applies `changes` to the held item. Returns false if the hand is empty.
pub fn editHeld(player: Player, changes: Edit) bool {
    const stack = held(player) orelse return false;
    edit(stack, changes);
    setHeld(player, stack);
    return true;
}

/// Returns the level of `enchantment` on `stack`, or 0 if it doesn't have it.
pub fn enchantLevel(stack: ItemStack, enchantment: Enchantment) u32 {
    for (stack.getEnchantments()) |e| {
        if (e.enchantment == enchantment) return e.level;
    }
    return 0;
}

/// Returns the level of a data pack enchantment on `stack`, or 0 if it doesn't have it.
pub fn customEnchantLevel(stack: ItemStack, id: []const u8) u32 {
    return stack.getCustomEnchantmentLevel(id) orelse 0;
}

/// Returns how much of the item's durability is used up.
pub fn damage(stack: ItemStack) u32 {
    return readVarInt(componentValue(stack, .damage) orelse return 0) orelse 0;
}

/// Returns the durability set with `max_damage`. Items that keep their
/// default durability return null, since the server doesn't report it.
pub fn maxDamage(stack: ItemStack) ?u32 {
    return readVarInt(componentValue(stack, .max_damage) orelse return null);
}

fn componentValue(stack: ItemStack, id: wit.data_components.DataComponent) ?[]const u8 {
    for (stack.getComponents()) |c| {
        if (c.component == id) return c.value;
    }
    return null;
}

fn readVarInt(bytes: []const u8) ?u32 {
    var n: u32 = 0;
    for (bytes[0..@min(bytes.len, 5)], 0..) |b, i| {
        n |= @as(u32, b & 0x7f) << @intCast(i * 7);
        if (b & 0x80 == 0) return n;
    }
    return null;
}

const VarInt = struct { u32 };

fn varInt(n: u32) VarInt {
    return .{n};
}

/// Writes a component value the way the server reads it from the network:
/// VarInts, big-endian floats and single-byte booleans, one after another.
fn setComponent(stack: ItemStack, component: wit.data_components.DataComponent, parts: anytype) void {
    var buffer: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    inline for (parts) |part| {
        switch (@TypeOf(part)) {
            VarInt => {
                var n = part[0];
                while (n >= 0x80) : (n >>= 7) w.writeByte(@as(u8, @truncate(n)) | 0x80) catch unreachable;
                w.writeByte(@truncate(n)) catch unreachable;
            },
            f32 => w.writeInt(u32, @bitCast(part), .big) catch unreachable,
            bool => w.writeByte(@intFromBool(part)) catch unreachable,
            else => @compileError("unsupported component part"),
        }
    }
    stack.setComponent(component, w.buffered());
}

/// Stores `value` on `stack` under `key`, in the plugin's namespace.
pub fn set(stack: ItemStack, key: []const u8, value: Value) void {
    const tag: wit.common.NbtTag = switch (value) {
        .string => |v| .{ .string_tag = v },
        .int => |v| .{ .long = v },
        .float => |v| .{ .double = v },
        .bool => |v| .{ .byte = @intFromBool(v) },
    };
    stack.setCustomData(pumpkin.plugin_name, key, .{ .root = 0, .tags = &.{tag} });
}

/// Returns the value this plugin stored on `stack` under `key`, if any.
pub fn get(stack: ItemStack, key: []const u8) ?Value {
    const tree = stack.getCustomData(pumpkin.plugin_name, key) orelse return null;
    if (tree.root >= tree.tags.len) return null;
    return switch (tree.tags[tree.root]) {
        .string_tag => |v| .{ .string = v },
        .long => |v| .{ .int = v },
        .int => |v| .{ .int = v },
        .double => |v| .{ .float = v },
        .float => |v| .{ .float = v },
        .byte => |v| .{ .bool = v != 0 },
        else => null,
    };
}

/// Reports whether `stack` has the string `value` stored under `key`.
pub fn is(stack: ItemStack, key: []const u8, value: []const u8) bool {
    return matches(stack, .{ .data = .{ .key = key, .value = .{ .string = value } } });
}

/// Selects the items that `count`, `has` and `take` work on.
pub const Match = union(enum) {
    /// Every item with this registry key, such as "minecraft:diamond".
    id: []const u8,
    /// Items that carry this value from this plugin, whatever item they are.
    data: Data,
};

pub fn matches(stack: ItemStack, match: Match) bool {
    return switch (match) {
        .id => |id| sameId(stack.getRegistryKey(), id),
        .data => |d| if (get(stack, d.key)) |v| v.eql(d.value) else false,
    };
}

/// Returns the item in the player's main hand, if any.
pub fn held(player: Player) ?ItemStack {
    const inventory = player.getInventory();
    return inventory.asInventory().getItem(inventory.getSelectedSlot());
}

/// Puts `stack` in the player's main hand, replacing what is there. Consumes `stack`.
pub fn setHeld(player: Player, stack: ?ItemStack) void {
    const inventory = player.getInventory();
    inventory.asInventory().setItem(inventory.getSelectedSlot(), stack);
}

/// Counts the matching items in the player's main inventory and off hand.
pub fn count(player: Player, match: Match) u32 {
    const inventory = player.getInventory();
    const slots = inventory.asInventory();
    var total: u32 = 0;
    var slot: u32 = 0;
    while (slot < slots.getSize()) : (slot += 1) {
        const stack = slots.getItem(slot) orelse continue;
        if (matches(stack, match)) total += stack.getCount();
    }
    if (inventory.getOffHand()) |stack| {
        if (matches(stack, match)) total += stack.getCount();
    }
    return total;
}

pub fn has(player: Player, match: Match, amount: u32) bool {
    return count(player, match) >= amount;
}

/// Takes `amount` matching items in the same order as vanilla's `/clear`.
/// If the player has fewer, takes nothing and returns false.
pub fn take(player: Player, match: Match, amount: u32) bool {
    if (!has(player, match, amount)) return false;
    const inventory = player.getInventory();
    const slots = inventory.asInventory();
    var left = amount;

    var slot: u32 = 0;
    while (slot < slots.getSize() and left > 0) : (slot += 1) {
        left = takeFrom(slots, slot, match, left);
    }
    if (left > 0) {
        if (inventory.getOffHand()) |stack| {
            if (matches(stack, match)) {
                const n: u8 = @intCast(@min(left, stack.getCount()));
                stack.setCount(stack.getCount() - n);
                inventory.setOffHand(if (stack.getCount() == 0) null else stack);
            }
        }
    }
    return true;
}

fn takeFrom(slots: wit.inventory.Inventory, slot: u32, match: Match, left: u32) u32 {
    if (left == 0) return 0;
    const stack = slots.getItem(slot) orelse return left;
    if (!matches(stack, match)) return left;
    const n: u8 = @intCast(@min(left, stack.getCount()));
    stack.setCount(stack.getCount() - n);
    slots.setItem(slot, if (stack.getCount() == 0) null else stack);
    return left - n;
}

/// Puts `stack` into the player's inventory in the same order as vanilla and
/// returns how many items didn't fit. Consumes `stack`.
pub fn give(player: Player, stack: ItemStack) u8 {
    const inventory = player.getInventory();
    const slots = inventory.asInventory();
    const size = slots.getSize();
    const max = stack.getMaxCount();
    var left = stack.getCount();

    const selected: u32 = inventory.getSelectedSlot();
    left = topUp(slots, selected, stack, max, left);
    if (left > 0) {
        if (inventory.getOffHand()) |existing| {
            if (sameItem(existing, stack) and existing.getCount() < max) {
                const moved = @min(max - existing.getCount(), left);
                existing.setCount(existing.getCount() + moved);
                inventory.setOffHand(existing);
                left -= moved;
            }
        }
    }
    var slot: u32 = 0;
    while (slot < size and left > 0) : (slot += 1) {
        if (slot != selected) left = topUp(slots, slot, stack, max, left);
    }

    slot = 0;
    while (slot < size and left > 0) : (slot += 1) {
        if (slots.getItem(slot) != null) continue;
        const moved = @min(max, left);
        left -= moved;
        // The last part takes the stack itself, earlier parts take copies.
        const part = if (left == 0) stack else copy(stack);
        part.setCount(moved);
        slots.setItem(slot, part);
    }
    return left;
}

fn topUp(slots: wit.inventory.Inventory, slot: u32, stack: ItemStack, max: u8, left: u8) u8 {
    if (left == 0) return 0;
    const existing = slots.getItem(slot) orelse return left;
    if (!sameItem(existing, stack) or existing.getCount() >= max) return left;
    const moved = @min(max - existing.getCount(), left);
    existing.setCount(existing.getCount() + moved);
    slots.setItem(slot, existing);
    return left - moved;
}

/// Reports whether two stacks are the same item with the same components,
/// which lets them share a slot.
fn sameItem(a: ItemStack, b: ItemStack) bool {
    if (!sameId(a.getRegistryKey(), b.getRegistryKey())) return false;
    const ca = a.getComponents();
    const cb = b.getComponents();
    if (ca.len != cb.len) return false;
    for (ca, cb) |x, y| {
        if (x.component != y.component or !std.mem.eql(u8, x.value, y.value)) return false;
    }
    return true;
}

/// Compares item ids with or without the "minecraft:" namespace, since the
/// server reports vanilla ids without it.
fn sameId(a: []const u8, b: []const u8) bool {
    const prefix = "minecraft:";
    const x = if (std.mem.startsWith(u8, a, prefix)) a[prefix.len..] else a;
    const y = if (std.mem.startsWith(u8, b, prefix)) b[prefix.len..] else b;
    return std.mem.eql(u8, x, y);
}

/// The server loses these components when they are copied as raw bytes, so
/// `copy` uses their own functions.
const typed_components = [_]wit.data_components.DataComponent{ .custom_name, .lore, .attribute_modifiers };

fn copy(stack: ItemStack) ItemStack {
    const out: ItemStack = .init(stack.getRegistryKey(), stack.getCount());
    for (stack.getComponents()) |c| {
        if (std.mem.indexOfScalar(wit.data_components.DataComponent, &typed_components, c.component) != null) continue;
        out.setComponent(c.component, c.value);
    }
    if (stack.getCustomName()) |name| out.setCustomName(name);
    const lore = stack.getLore();
    if (lore.len > 0) out.setLore(lore);
    for (stack.getAttributeModifiers()) |m| out.addAttributeModifier(m);
    return out;
}

fn upright(spans: []const msg.Span) TextComponent {
    const root: TextComponent = .text("");
    root.italic(false);
    for (spans) |s| root.addChild(msg.span(s));
    return root;
}
