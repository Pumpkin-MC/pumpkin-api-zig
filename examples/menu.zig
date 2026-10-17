//! An inventory menu where each button does something.

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
        .description = "Lets players pick a color from a menu with /colors.",
    };

    pub const commands: []const cmd.Spec = &.{.{
        .names = &.{"colors"},
        .description = "Opens a menu to pick a color.",
        .permission = "example-menu:command.colors",
        .run = openColors,
    }};

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
};

comptime {
    pumpkin.register(Menu);
}
