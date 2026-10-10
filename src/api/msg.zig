//! Text components from struct literals instead of a call per style.
//!
//!     sender.sendMessage(pumpkin.msg.build(&.{
//!         .{ .text = "[Shop] ", .color = .gold, .bold = true },
//!         .{ .text = "open", .click = .{ .run_command = "/shop" }, .hover = "Opens the shop" },
//!     }));

const std = @import("std");
const abi = @import("../runtime/abi.zig");
const wit = @import("../bindings/pumpkin.zig");

const TextComponent = wit.text.TextComponent;

pub const Color = wit.common.NamedColor;
pub const Rgb = wit.common.RgbColor;

pub const Click = union(enum) {
    open_url: []const u8,
    run_command: []const u8,
    suggest_command: []const u8,
    copy: []const u8,
    change_page: u32,
};

pub const Span = struct {
    text: []const u8 = "",
    /// A translation key, used instead of `text`.
    translate: ?[]const u8 = null,
    color: ?Color = null,
    /// Wins over `color`.
    rgb: ?Rgb = null,
    bold: ?bool = null,
    italic: ?bool = null,
    underlined: ?bool = null,
    strikethrough: ?bool = null,
    obfuscated: ?bool = null,
    click: ?Click = null,
    /// Plain text shown on hover.
    hover: ?[]const u8 = null,
    /// Inserted into the chat box on shift click.
    insertion: ?[]const u8 = null,
    font: ?[]const u8 = null,
};

pub fn span(s: Span) TextComponent {
    const out: TextComponent = if (s.translate) |key| .translate(key, &.{}) else .text(s.text);

    if (s.rgb) |rgb| out.colorRgb(rgb) else if (s.color) |color| out.colorNamed(color);
    if (s.bold) |v| out.bold(v);
    if (s.italic) |v| out.italic(v);
    if (s.underlined) |v| out.underlined(v);
    if (s.strikethrough) |v| out.strikethrough(v);
    if (s.obfuscated) |v| out.obfuscated(v);
    if (s.insertion) |v| out.insertion(v);
    if (s.font) |v| out.font(v);
    if (s.hover) |v| out.hoverShowText(.text(v));
    if (s.click) |click| switch (click) {
        .open_url => |v| out.clickOpenUrl(v),
        .run_command => |v| out.clickRunCommand(v),
        .suggest_command => |v| out.clickSuggestCommand(v),
        .copy => |v| out.clickCopyToClipboard(v),
        .change_page => |v| out.clickChangePage(v),
    };
    return out;
}

/// One component made of `spans`, in order.
pub fn build(spans: []const Span) TextComponent {
    if (spans.len == 1) return span(spans[0]);
    const root: TextComponent = .text("");
    for (spans) |s| root.addChild(span(s));
    return root;
}

pub fn plain(text: []const u8) TextComponent {
    return .text(text);
}

/// A formatted single color message, `color` may be null.
pub fn fmt(color: ?Color, comptime format: []const u8, args: anytype) TextComponent {
    const text = std.fmt.allocPrint(abi.arena(), format, args) catch @panic("OOM");
    return span(.{ .text = text, .color = color });
}
