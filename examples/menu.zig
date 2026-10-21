//! Inventory menus: /colors has a button for each color, and /trash has free
//! slots that delete whatever is left in them when it closes.

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const menu = pumpkin.menu;
const msg = pumpkin.msg;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const Menu = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-menu",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Lets players pick a color with /colors and throw items away with /trash.",
    };

    pub const commands: []const cmd.Spec = &.{ .{
        .names = &.{"colors"},
        .description = "Opens a menu to pick a color.",
        .permission = "example-menu:command.colors",
        .run = openColors,
    }, .{
        .names = &.{"trash"},
        .description = "Opens a trash can. Whatever is in it when it closes is deleted.",
        .permission = "example-menu:command.trash",
        .run = openTrash,
    } };

    pub fn onLoad(ctx: pumpkin.Context) !void {
        menu.listen(ctx);
    }

    const colors = [_]struct { wool: []const u8, color: msg.Color }{
        .{ .wool = "minecraft:red_wool", .color = .red },
        .{ .wool = "minecraft:lime_wool", .color = .green },
        .{ .wool = "minecraft:light_blue_wool", .color = .aqua },
        .{ .wool = "minecraft:yellow_wool", .color = .yellow },
    };

    fn openColors(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("only players can pick a color");
        var names: [colors.len][1]msg.Span = undefined;
        var buttons: [colors.len]menu.Button = undefined;
        for (&buttons, &names, colors, 0..) |*button, *name, c, i| {
            name.* = .{.{ .text = @tagName(c.color), .color = c.color }};
            button.* = .{
                .slot = @intCast(10 + 2 * i),
                .icon = .{ .id = c.wool, .name = name },
                .on_click = pickColor,
                .data = i,
            };
        }
        menu.open(player, .{
            .title = &.{.{ .text = "Pick a color" }},
            .buttons = &buttons,
            .fill = .{ .id = "minecraft:gray_stained_glass_pane", .name = &.{} },
        });
        return cmd.ok(1);
    }

    fn pickColor(click: menu.Click) void {
        const c = colors[click.data];
        click.player.sendSystemMessage(msg.fmt(c.color, "You picked {s}.", .{@tagName(c.color)}), false);
    }

    /// The top two rows of the trash can.
    const trash_slots = blk: {
        var slots: [18]u32 = undefined;
        for (&slots, 0..) |*slot, i| slot.* = i;
        break :blk slots;
    };

    fn openTrash(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("only players can use the trash");
        menu.open(player, .{
            .title = &.{.{ .text = "Trash", .color = .dark_red }},
            .free = &trash_slots,
            .buttons = &.{.{ .slot = 22, .icon = .{
                .id = "minecraft:lava_bucket",
                .name = &.{.{ .text = "Trash", .color = .red, .bold = true }},
                .lore = &.{&.{.{ .text = "Items left above are deleted on close", .color = .gray }}},
            } }},
            .fill = .{ .id = "minecraft:black_stained_glass_pane", .name = &.{} },
            .on_close = emptyTrash,
        });
        return cmd.ok(1);
    }

    fn emptyTrash(_: pumpkin.Server, player: pumpkin.Player) void {
        const slots = menu.items(player) orelse return;
        var deleted: u32 = 0;
        for (trash_slots) |slot| {
            if (slots.getItem(slot)) |stack| deleted += stack.getCount();
        }
        if (deleted > 0) player.sendSystemMessage(msg.fmt(.gray, "Deleted {d} items.", .{deleted}), false);
    }
};

comptime {
    pumpkin.register(Menu);
}
