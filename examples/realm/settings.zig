//! The config file, `plugins/data/example-realm/config.toml`.

const pumpkin = @import("pumpkin");

pub const Ore = struct {
    /// The block's id with its namespace, such as "minecraft:diamond_ore".
    block: []const u8,
    coins: u32,
};

pub const Offer = struct {
    /// The name `/buy` takes.
    key: []const u8,
    id: []const u8,
    count: u8 = 1,
    price: u32,
};

pub const Daily = struct {
    coins: u32 = 50,
    /// Added for every day in a row after the first.
    streak_bonus: u32 = 10,
    max_streak: u32 = 7,
};

pub const Config = struct {
    currency: []const u8 = "coins",
    /// Given once, when a player joins for the first time.
    starting_coins: u32 = 100,
    daily: Daily = .{},
    payday: struct {
        /// How often everyone online gets paid. 0 turns it off.
        minutes: u32 = 15,
        coins: u32 = 10,
    } = .{},
    rush: struct {
        seconds: u32 = 120,
        /// Ore rewards are multiplied by this during a coin rush.
        multiplier: u32 = 2,
    } = .{},
    /// The port of the ledger on 127.0.0.1. 0 turns it off.
    ledger_port: u16 = 25581,
    /// A Discord webhook URL that hears about coin rushes. Empty turns it off.
    webhook: []const u8 = "",
    ores: []const Ore = &.{
        .{ .block = "minecraft:coal_ore", .coins = 1 },
        .{ .block = "minecraft:iron_ore", .coins = 3 },
        .{ .block = "minecraft:gold_ore", .coins = 5 },
        .{ .block = "minecraft:redstone_ore", .coins = 4 },
        .{ .block = "minecraft:lapis_ore", .coins = 6 },
        .{ .block = "minecraft:diamond_ore", .coins = 25 },
        .{ .block = "minecraft:emerald_ore", .coins = 40 },
        .{ .block = "minecraft:deepslate_diamond_ore", .coins = 30 },
        .{ .block = "minecraft:ancient_debris", .coins = 80 },
    },
    shop: []const Offer = &.{
        .{ .key = "bread", .id = "minecraft:bread", .count = 8, .price = 10 },
        .{ .key = "torches", .id = "minecraft:torch", .count = 16, .price = 12 },
        .{ .key = "arrows", .id = "minecraft:arrow", .count = 16, .price = 20 },
        .{ .key = "golden_apple", .id = "minecraft:golden_apple", .price = 60 },
        .{ .key = "ender_pearls", .id = "minecraft:ender_pearl", .count = 4, .price = 80 },
        .{ .key = "experience", .id = "minecraft:experience_bottle", .count = 8, .price = 90 },
        .{ .key = "diamond", .id = "minecraft:diamond", .price = 150 },
        .{ .key = "elytra", .id = "minecraft:elytra", .price = 2500 },
    },
};

/// How many offers fit in the shop menu. The ones after them aren't sold.
pub const shop_slots = 27;

pub var file: pumpkin.config.File(Config) = .{ .path = "config.toml" };

pub fn get() *const Config {
    return &file.value;
}

/// The offers that fit in the shop.
pub fn offers() []const Offer {
    const shop = file.value.shop;
    return shop[0..@min(shop.len, shop_slots)];
}
