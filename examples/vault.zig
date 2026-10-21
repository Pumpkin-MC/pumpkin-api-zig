//! A personal vault with `pumpkin.menu` and `pumpkin.store`: /vault opens five
//! pages of storage with free slots and buttons in a locked bottom row, and
//! keeps what is in them in a file for each player.

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const item = pumpkin.item;
const menu = pumpkin.menu;
const msg = pumpkin.msg;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const page_count = 5;
const page_size = 45;

/// An item as it is written to the vault file.
const Saved = struct {
    page: u32,
    slot: u32,
    id: []const u8,
    count: u8,
    /// The item's components, base64 encoded by name, except for the three
    /// below. The server can't read those back from raw bytes, so they are
    /// kept through their own functions.
    components: []const struct { name: []const u8, value: []const u8 } = &.{},
    name: ?[]const u8 = null,
    lore: []const []const u8 = &.{},
    modifiers: []const struct { attribute: item.Attribute, id: []const u8, amount: f64, operation: item.Operation, slot: item.Slot } = &.{},
};

const Vault = struct {
    items: []const Saved = &.{},
};

const VaultPlugin = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-vault",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Gives every player five pages of storage with /vault.",
        .permissions = &.{ "fs.read.data", "fs.write.data" },
    };

    pub const commands: []const cmd.Spec = &.{.{
        .names = &.{"vault"},
        .description = "Opens your vault.",
        .permission = "example-vault:command.vault",
        .run = openVault,
    }};

    var vaults: pumpkin.store.Store(Vault) = .{ .dir = "vaults" };
    /// The page each player has open.
    var open_page: std.AutoHashMapUnmanaged(pumpkin.uuid.Uuid, u32) = .empty;

    const free_slots = blk: {
        var slots: [page_size]u32 = undefined;
        for (&slots, 0..) |*slot, i| slot.* = i;
        break :blk slots;
    };

    pub fn onLoad(ctx: pumpkin.Context) !void {
        menu.listen(ctx);
    }

    fn openVault(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("only players have a vault");
        openPage(player, 0) catch return cmd.fail("your vault can't be read, see the server log");
        return cmd.ok(1);
    }

    fn openPage(player: pumpkin.Player, page: u32) !void {
        // The new page is read from the vault, so the open one is saved first.
        saveOpenPage(player);
        const vault = try vaults.player(player);
        const arena = pumpkin.abi.arena();
        const title = try std.fmt.allocPrint(arena, "Vault, page {d} of {d}", .{ page + 1, page_count });

        var buttons: std.ArrayList(menu.Button) = .empty;
        if (page > 0) try buttons.append(arena, .{
            .slot = 45,
            .icon = .{ .id = "minecraft:arrow", .name = &.{.{ .text = "← Previous", .color = .yellow }} },
            .on_click = turnPage,
            .data = page - 1,
        });
        try buttons.append(arena, .{
            .slot = 49,
            .icon = .{ .id = "minecraft:ender_chest", .name = &.{.{ .text = "Ender Chest", .color = .dark_purple }} },
            .on_click = openEnderChest,
        });
        if (page + 1 < page_count) try buttons.append(arena, .{
            .slot = 53,
            .icon = .{ .id = "minecraft:arrow", .name = &.{.{ .text = "Next →", .color = .yellow }} },
            .on_click = turnPage,
            .data = page + 1,
        });

        var stacks: std.ArrayList(menu.Stack) = .empty;
        for (vault.items) |saved| {
            if (saved.page == page and saved.slot < page_size) try stacks.append(arena, .{ .slot = saved.slot, .item = decode(saved) });
        }

        menu.open(player, .{
            .screen = .generic_9x6,
            .title = &.{.{ .text = title, .color = .dark_gray }},
            .free = &free_slots,
            .buttons = buttons.items,
            .stacks = stacks.items,
            .fill = .{ .id = "minecraft:gray_stained_glass_pane", .name = &.{} },
            .on_close = savePage,
        });
        // After opening, since opening closes the previous page, whose
        // `savePage` still needs to know which page it was.
        try open_page.put(pumpkin.abi.heap, player.getId(), page);
    }

    fn turnPage(click: menu.Click) void {
        openPage(click.player, @intCast(click.data)) catch
            click.player.sendSystemMessage(msg.fmt(.red, "Your vault can't be read.", .{}), false);
    }

    fn openEnderChest(click: menu.Click) void {
        click.player.openEnderChest();
    }

    fn savePage(_: pumpkin.Server, player: pumpkin.Player) void {
        saveOpenPage(player);
    }

    fn saveOpenPage(player: pumpkin.Player) void {
        const page = (open_page.fetchRemove(player.getId()) orelse return).value;
        const slots = menu.items(player) orelse return;
        const vault = vaults.player(player) catch return;
        const memory = vaults.allocator(vault);

        var kept: std.ArrayList(Saved) = .empty;
        for (vault.items) |saved| {
            if (saved.page != page) kept.append(memory, saved) catch return;
        }
        for (free_slots) |slot| {
            const stack = slots.getItem(slot) orelse continue;
            kept.append(memory, encode(memory, page, slot, stack) catch return) catch return;
        }
        vault.items = kept.items;
    }

    fn encode(memory: std.mem.Allocator, page: u32, slot: u32, stack: item.ItemStack) !Saved {
        const Component = @typeInfo(@FieldType(Saved, "components")).pointer.child;
        var components: std.ArrayList(Component) = .empty;
        for (stack.getComponents()) |c| {
            switch (c.component) {
                .custom_name, .lore, .attribute_modifiers => continue,
                else => {},
            }
            const value = try memory.alloc(u8, std.base64.standard.Encoder.calcSize(c.value.len));
            _ = std.base64.standard.Encoder.encode(value, c.value);
            try components.append(memory, .{ .name = try memory.dupe(u8, @tagName(c.component)), .value = value });
        }

        var lore: std.ArrayList([]const u8) = .empty;
        for (stack.getLore()) |line| try lore.append(memory, try memory.dupe(u8, line.toJson()));

        const Modifier = @typeInfo(@FieldType(Saved, "modifiers")).pointer.child;
        var modifiers: std.ArrayList(Modifier) = .empty;
        for (stack.getAttributeModifiers()) |m| try modifiers.append(memory, .{
            .attribute = m.attribute,
            .id = try memory.dupe(u8, m.modifier.id),
            .amount = m.modifier.amount,
            .operation = m.modifier.operation,
            .slot = m.slot,
        });

        return .{
            .page = page,
            .slot = slot,
            .id = try memory.dupe(u8, stack.getRegistryKey()),
            .count = stack.getCount(),
            .components = components.items,
            .name = if (stack.getCustomName()) |name| try memory.dupe(u8, name.toJson()) else null,
            .lore = lore.items,
            .modifiers = modifiers.items,
        };
    }

    fn decode(saved: Saved) item.ItemStack {
        const stack: item.ItemStack = .init(saved.id, saved.count);
        const arena = pumpkin.abi.arena();
        for (saved.components) |c| {
            const component = std.meta.stringToEnum(pumpkin.data_components.DataComponent, c.name) orelse continue;
            const size = std.base64.standard.Decoder.calcSizeForSlice(c.value) catch continue;
            const bytes = arena.alloc(u8, size) catch continue;
            std.base64.standard.Decoder.decode(bytes, c.value) catch continue;
            stack.setComponent(component, bytes);
        }
        if (saved.name) |json| if (text(json)) |name| stack.setCustomName(name);
        if (saved.lore.len > 0) {
            var lines: std.ArrayList(pumpkin.TextComponent) = .empty;
            for (saved.lore) |json| if (text(json)) |line| lines.append(arena, line) catch {};
            stack.setLore(lines.items);
        }
        for (saved.modifiers) |m| stack.addAttributeModifier(.{
            .attribute = m.attribute,
            .modifier = .{ .id = m.id, .amount = m.amount, .operation = m.operation },
            .slot = m.slot,
        });
        return stack;
    }

    fn text(json: []const u8) ?pumpkin.TextComponent {
        return switch (pumpkin.TextComponent.fromJson(json)) {
            .ok => |component| component,
            .err => null,
        };
    }
};

comptime {
    pumpkin.register(VaultPlugin);
}
