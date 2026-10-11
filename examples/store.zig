//! Data kept per player with `pumpkin.store`: how often each player joined,
//! and homes they can set and teleport back to. Every player gets a file in
//! `plugins/data/example-store/players/`.

const std = @import("std");
const pumpkin = @import("pumpkin");
const cmd = pumpkin.cmd;
const msg = pumpkin.msg;

pub const std_options: std.Options = .{ .logFn = pumpkin.logFn };

const Home = struct {
    name: []const u8,
    world: []const u8,
    x: f64,
    y: f64,
    z: f64,
};

const Profile = struct {
    visits: u32 = 0,
    homes: []const Home = &.{},
};

const max_homes = 5;

const StorePlugin = struct {
    pub const metadata: pumpkin.Metadata = .{
        .name = "example-store",
        .version = "0.1.0",
        .authors = &.{"Pumpkin"},
        .description = "Counts visits and keeps homes for every player.",
        .permissions = &.{ "fs.read.data", "fs.write.data" },
    };

    pub const events = .{
        .player_join_event = onJoin,
    };

    pub const commands: []const cmd.Spec = &.{ .{
        .names = &.{"sethome"},
        .description = "Saves where you stand as a home.",
        .permission = "example-store:command.sethome",
        .then = &.{.argument("name", .{ .string = .single_word }, .{ .run = cmd.typed(setHome) })},
    }, .{
        .names = &.{"home"},
        .description = "Teleports you to one of your homes.",
        .permission = "example-store:command.home",
        .then = &.{.argument("name", .{ .string = .single_word }, .{ .run = cmd.typed(goHome) })},
    }, .{
        .names = &.{"homes"},
        .description = "Lists your homes.",
        .permission = "example-store:command.homes",
        .run = listHomes,
    } };

    var profiles: pumpkin.store.Store(Profile) = .{ .dir = "players" };

    fn onJoin(_: pumpkin.Server, ev: *pumpkin.EventData(.player_join_event)) void {
        const profile = profiles.player(ev.player) catch return;
        profile.visits += 1;
        ev.player.sendSystemMessage(msg.fmt(.gold, "Welcome! This is visit number {d}.", .{profile.visits}), false);
    }

    fn setHome(sender: cmd.Sender, _: pumpkin.Server, args: struct { name: []const u8 }) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("only players have homes");
        const profile = profiles.player(player) catch return cmd.fail("your data can't be read");
        const memory = profiles.allocator(profile);

        const x, const y, const z = player.getPosition();
        const home: Home = .{
            .name = memory.dupe(u8, args.name) catch return cmd.fail("out of memory"),
            .world = memory.dupe(u8, player.getWorld().getName()) catch return cmd.fail("out of memory"),
            .x = x,
            .y = y,
            .z = z,
        };

        if (find(profile.homes, args.name)) |i| {
            const homes = memory.dupe(Home, profile.homes) catch return cmd.fail("out of memory");
            homes[i] = home;
            profile.homes = homes;
        } else {
            if (profile.homes.len >= max_homes) return cmd.fail("you already have 5 homes");
            profile.homes = std.mem.concat(memory, Home, &.{ profile.homes, &.{home} }) catch return cmd.fail("out of memory");
        }
        sender.sendMessage(msg.fmt(.green, "Home {s} saved.", .{args.name}));
        return cmd.ok(1);
    }

    fn goHome(sender: cmd.Sender, srv: pumpkin.Server, args: struct { name: []const u8 }) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("only players have homes");
        const profile = profiles.player(player) catch return cmd.fail("your data can't be read");
        const home = profile.homes[find(profile.homes, args.name) orelse return cmd.fail("you have no home with that name")];
        const world = srv.getWorldByName(home.world) orelse return cmd.fail("that home's world is gone");
        player.teleport(.{ home.x, home.y, home.z }, null, null, world);
        return cmd.ok(1);
    }

    fn listHomes(sender: cmd.Sender, _: pumpkin.Server, _: cmd.Args) cmd.Result {
        const player = sender.asPlayer() orelse return cmd.fail("only players have homes");
        const profile = profiles.player(player) catch return cmd.fail("your data can't be read");
        if (profile.homes.len == 0) return cmd.fail("you have no homes yet, set one with /sethome");

        var names: std.ArrayList(u8) = .empty;
        for (profile.homes, 0..) |home, i| {
            if (i > 0) names.appendSlice(pumpkin.abi.arena(), ", ") catch {};
            names.appendSlice(pumpkin.abi.arena(), home.name) catch {};
        }
        sender.sendMessage(msg.fmt(.aqua, "Your homes: {s}", .{names.items}));
        return cmd.ok(@intCast(profile.homes.len));
    }

    fn find(homes: []const Home, name: []const u8) ?usize {
        for (homes, 0..) |home, i| {
            if (std.mem.eql(u8, home.name, name)) return i;
        }
        return null;
    }
};

comptime {
    pumpkin.register(StorePlugin);
}
