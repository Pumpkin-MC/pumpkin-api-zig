//! A personal vault with configurable capacity, a page selector and /vault
//! [page]. Items are saved for each player with `pumpkin.store`.

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const item = pumpkin.item;
const menu = pumpkin.menu;
const msg = pumpkin.msg;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const page_size = 45;
const max_pages = 45;

const Config = struct {
    /// The minimum number of pages. Occupied pages stay accessible if lowered.
    pages: u32 = 5,
};

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

    fn pageCount(vault: Vault, minimum: u32) !u32 {
        if (minimum == 0 or minimum > max_pages) return error.InvalidPageCount;
        var count = minimum;
        for (vault.items) |saved| {
            if (saved.page >= max_pages or saved.slot >= page_size) return error.InvalidVaultSlot;
            if (saved.count > 0) count = @max(count, saved.page + 1);
        }
        return count;
    }

    fn usedSlots(vault: Vault, page: u32) u32 {
        var slots: [page_size]bool = @splat(false);
        for (vault.items) |saved| {
            if (saved.page == page and saved.slot < page_size and saved.count > 0) slots[saved.slot] = true;
        }
        return @intCast(std.mem.count(bool, &slots, &.{true}));
    }
};

const VaultPlugin = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-vault",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Personal storage with page navigation and configurable capacity.",
        .permissions = &.{ "fs.read.data", "fs.write.data" },
    };

    pub const commands: []const cmd.Spec = &.{.{
        .names = &.{"vault"},
        .description = "Opens your vault.",
        .permission = "example-vault:command.vault",
        .run = openVault,
        .then = &.{.argument("page", .{ .integer = .{ 1, max_pages } }, .{ .run = cmd.typed(openNumberedPage) })},
    }};

    var config: pumpkin.config.File(Config) = .{ .path = "config.toml" };
    var vaults: pumpkin.store.Store(Vault) = .{ .dir = "vaults" };
    /// The page each player has open.
    var open_page: std.AutoHashMapUnmanaged(pumpkin.uuid.Uuid, u32) = .empty;

    const free_slots = blk: {
        var slots: [page_size]u32 = undefined;
        for (&slots, 0..) |*slot, i| slot.* = i;
        break :blk slots;
    };

    pub fn onLoad(ctx: pumpkin.Context) !void {
        try config.load();
        if (config.value.pages == 0 or config.value.pages > max_pages) {
            std.log.err("config.toml: pages must be between 1 and {d}", .{max_pages});
            return error.InvalidPageCount;
        }
        menu.listen(ctx);
    }

    fn openVault(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("only players have a vault");
        openPage(player, 0) catch return cmd.fail("your vault can't be read, see the server log");
        return cmd.ok(1);
    }

    fn openNumberedPage(sender: cmd.Sender, _: pumpkin.Server, args: struct { page: u32 }) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("only players have a vault");
        const vault = vaults.player(player) catch return cmd.fail("your vault can't be read, see the server log");
        const pages = vault.pageCount(config.value.pages) catch return cmd.fail("your vault has invalid slots, see its saved file");
        if (args.page > pages) return cmd.failWith(msg.fmt(.red, "Your vault has {d} pages.", .{pages}));
        openPage(player, args.page - 1) catch return cmd.fail("your vault can't be opened, see the server log");
        return cmd.ok(1);
    }

    fn openPage(player: pumpkin.Player, requested_page: u32) !void {
        // The new page is read from the vault, so the open one is saved first.
        try saveOpenPage(player);
        const vault = try vaults.player(player);
        const page_count = try vault.pageCount(config.value.pages);
        // Emptying a retained page can reduce the capacity during navigation.
        const page = @min(requested_page, page_count - 1);
        try open_page.ensureUnusedCapacity(pumpkin.abi.heap, 1);
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
            .slot = 47,
            .icon = .{ .id = "minecraft:bookshelf", .name = &.{.{ .text = "All pages", .color = .aqua }} },
            .on_click = selectPage,
            .data = page,
        });
        const usage = try std.fmt.allocPrint(arena, "{d}/{d} slots used", .{ vault.usedSlots(page), page_size });
        try buttons.append(arena, .{
            .slot = 49,
            .icon = .{ .id = "minecraft:paper", .name = &.{.{ .text = title, .color = .gold }}, .lore = &.{&.{.{ .text = usage, .color = .gray }}} },
        });
        try buttons.append(arena, .{
            .slot = 51,
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
        open_page.putAssumeCapacity(player.getId(), page);
    }

    fn selectPage(click: menu.Click) void {
        openSelector(click.player, @intCast(click.data)) catch |err| {
            std.log.err("can't open vault pages ({t})", .{err});
            click.player.sendSystemMessage(msg.plain("Your vault pages can't be opened."), false);
        };
    }

    fn openSelector(player: pumpkin.Player, previous_page: u32) !void {
        try saveOpenPage(player);
        const vault = try vaults.player(player);
        const pages = try vault.pageCount(config.value.pages);
        const arena = pumpkin.abi.arena();
        var buttons: std.ArrayList(menu.Button) = .empty;
        var names: [max_pages][1]msg.Span = undefined;
        var descriptions: [max_pages][1]msg.Span = undefined;
        var lore: [max_pages][1][]const msg.Span = undefined;
        var used: u32 = 0;
        for (0..pages) |page| {
            const occupied = vault.usedSlots(@intCast(page));
            used += occupied;
            names[page] = .{.{ .text = try std.fmt.allocPrint(arena, "Page {d}", .{page + 1}), .color = if (occupied == page_size) .gold else .green }};
            descriptions[page] = .{.{ .text = try std.fmt.allocPrint(arena, "{d}/{d} slots used", .{ occupied, page_size }), .color = .gray }};
            lore[page] = .{&descriptions[page]};
            try buttons.append(arena, .{
                .slot = @intCast(page),
                .icon = .{ .id = if (occupied == 0) "minecraft:barrel" else "minecraft:chest", .count = @intCast(page + 1), .name = &names[page], .lore = &lore[page] },
                .on_click = turnPage,
                .data = page,
            });
        }
        try buttons.append(arena, .{
            .slot = 45,
            .icon = .{ .id = "minecraft:arrow", .name = &.{.{ .text = "Back", .color = .yellow }} },
            .on_click = turnPage,
            .data = @min(previous_page, pages - 1),
        });
        const capacity = try std.fmt.allocPrint(arena, "{d}/{d} slots used across {d} pages", .{ used, pages * page_size, pages });
        try buttons.append(arena, .{
            .slot = 49,
            .icon = .{ .id = "minecraft:ender_chest", .name = &.{.{ .text = capacity, .color = .aqua }} },
        });
        menu.open(player, .{
            .screen = .generic_9x6,
            .title = &.{.{ .text = "Vault pages", .color = .dark_gray }},
            .buttons = buttons.items,
            .fill = .{ .id = "minecraft:gray_stained_glass_pane", .name = &.{} },
        });
    }

    fn turnPage(click: menu.Click) void {
        openPage(click.player, @intCast(click.data)) catch |err| {
            std.log.err("can't open vault page ({t})", .{err});
            click.player.sendSystemMessage(msg.fmt(.red, "Your vault can't be opened.", .{}), false);
        };
    }

    fn openEnderChest(click: menu.Click) void {
        click.player.openEnderChest();
    }

    fn savePage(_: pumpkin.Server, player: pumpkin.Player) void {
        defer _ = open_page.remove(player.getId());
        saveOpenPage(player) catch |err| {
            std.log.err("can't save the open vault page ({t})", .{err});
            return;
        };
    }

    fn saveOpenPage(player: pumpkin.Player) !void {
        const id = player.getId();
        const page = open_page.get(id) orelse return;
        const slots = menu.items(player) orelse return error.NoOpenPage;
        const vault = try vaults.player(player);
        const memory = vaults.allocator(vault);

        var kept: std.ArrayList(Saved) = .empty;
        for (vault.items) |saved| {
            if (saved.page != page) try kept.append(memory, saved);
        }
        for (free_slots) |slot| {
            const stack = slots.getItem(slot) orelse continue;
            try kept.append(memory, try encode(memory, page, slot, stack));
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
    if (!@import("builtin").is_test) pumpkin.register(VaultPlugin);
}

test "lowering capacity keeps occupied pages reachable" {
    const vault: Vault = .{ .items = &.{.{ .page = 4, .slot = 44, .id = "minecraft:diamond", .count = 2 }} };
    try std.testing.expectEqual(@as(u32, 5), try vault.pageCount(1));
    try std.testing.expectEqual(@as(u32, 8), try vault.pageCount(8));
    try std.testing.expectError(error.InvalidPageCount, vault.pageCount(0));
    try std.testing.expectError(error.InvalidPageCount, vault.pageCount(max_pages + 1));
}

test "page usage counts occupied slots rather than items or duplicate records" {
    const vault: Vault = .{ .items = &.{
        .{ .page = 0, .slot = 2, .id = "minecraft:diamond", .count = 64 },
        .{ .page = 0, .slot = 2, .id = "minecraft:diamond", .count = 1 },
        .{ .page = 0, .slot = 3, .id = "minecraft:stone", .count = 0 },
        .{ .page = 1, .slot = 2, .id = "minecraft:stone", .count = 1 },
    } };
    try std.testing.expectEqual(@as(u32, 1), vault.usedSlots(0));
    try std.testing.expectEqual(@as(u32, 0), vault.usedSlots(2));
}
