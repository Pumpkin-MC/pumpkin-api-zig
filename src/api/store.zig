//! Data a plugin keeps for each player, or for anything else with a name,
//! such as coins, homes or statistics. Every entry is a file, JSON unless the
//! store says otherwise, in a folder of the plugin's data folder. Entries are read the first time they are
//! used, written again when they change, and dropped from memory once they
//! go unused. Needs the "fs.read.data" and "fs.write.data" permissions.
//!
//!     var profiles: pumpkin.store.Store(Profile) = .{ .dir = "players" };
//!
//!     const profile = try profiles.player(player);
//!     profile.coins += 10;

const std = @import("std");
const abi = @import("../runtime/abi.zig");
const runtime_io = @import("../runtime/io.zig");
const tasks = @import("tasks.zig");
const toml_parser = @import("toml.zig");
const wit = @import("../bindings/pumpkin.zig");

const Player = wit.player.Player;
const Server = wit.server.Server;

pub const Error = error{
    /// The store's `valid_key` rejected the key.
    InvalidKey,
    /// The entry's file couldn't be read, see the log.
    ReadFailed,
    /// The entry's file couldn't be decoded into the entry type, see the log.
    /// The file is left as it is.
    InvalidData,
    OutOfMemory,
};

/// How entries of type `T` are turned into file contents and back.
pub fn Codec(comptime T: type) type {
    return struct {
        /// Appended to the key to name the file, such as ".json".
        extension: []const u8,
        encode: *const fn (std.mem.Allocator, T) error{OutOfMemory}![]const u8,
        /// Allocates the value's strings and slices with the given allocator,
        /// which lives as long as the entry.
        decode: *const fn (std.mem.Allocator, []const u8) anyerror!T,
    };
}

/// Entries as JSON, indented as `whitespace` says.
pub fn json(comptime T: type, comptime whitespace: @FieldType(std.json.Stringify.Options, "whitespace")) Codec(T) {
    const impl = struct {
        fn encode(gpa: std.mem.Allocator, value: T) error{OutOfMemory}![]const u8 {
            return std.json.Stringify.valueAlloc(gpa, value, .{ .whitespace = whitespace });
        }

        fn decode(gpa: std.mem.Allocator, text: []const u8) anyerror!T {
            return std.json.parseFromSliceLeaky(T, gpa, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        }
    };
    return .{ .extension = ".json", .encode = impl.encode, .decode = impl.decode };
}

/// Entries as TOML, with the parser behind `pumpkin.config`.
pub fn toml(comptime T: type) Codec(T) {
    const impl = struct {
        fn encode(gpa: std.mem.Allocator, value: T) error{OutOfMemory}![]const u8 {
            return toml_parser.stringify(gpa, value);
        }

        fn decode(gpa: std.mem.Allocator, text: []const u8) anyerror!T {
            var diagnostics: toml_parser.Diagnostics = .{};
            const tree = try toml_parser.parse(abi.arena(), text, &diagnostics);
            return std.json.parseFromValueLeaky(T, gpa, tree, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        }
    };
    return .{ .extension = ".toml", .encode = impl.encode, .decode = impl.decode };
}

/// The default `valid_key`: letters, digits, '-', '_' and '.', not empty and
/// not starting with '.', which keeps keys inside the store's folder.
pub fn isValidKey(key: []const u8) bool {
    if (key.len == 0 or key[0] == '.') return false;
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    }
    return true;
}

/// A folder of entries of type `T`, which needs a default for every field.
/// Fields a file lacks get their defaults, so new fields can be added later.
pub fn Store(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The folder, relative to the plugin's data folder.
        dir: []const u8,
        /// How often changed entries are written.
        autosave: tasks.Duration = .minutes(1),
        /// How many autosave periods an entry may go unused before it is
        /// written and dropped from memory. Null keeps entries until the plugin unloads.
        idle: ?u32 = 1,
        codec: Codec(T) = json(T, .indent_2),
        /// Decides which keys are allowed. A key becomes part of a file path,
        /// so the check has to keep it inside the folder.
        valid_key: *const fn ([]const u8) bool = isValidKey,
        /// Files larger than this fail with `error.ReadFailed`.
        max_size: usize = 16 * 1024 * 1024,
        entries: std.StringArrayHashMapUnmanaged(*Entry) = .empty,
        started: bool = false,

        const Entry = struct {
            value: T,
            memory: std.heap.ArenaAllocator,
            /// The hash of the value as it was last read or written, which
            /// tells whether it changed since.
            saved: u64,
            /// Autosave periods since the entry was last used.
            unused: u32,
        };

        /// Returns the entry for `key`, reading it from its file or starting
        /// from the defaults. The pointer stays valid until the entry is
        /// dropped, so look it up again in every callback instead of keeping it.
        pub fn get(self: *Self, key: []const u8) Error!*T {
            if (self.entries.get(key)) |entry| {
                entry.unused = 0;
                return &entry.value;
            }
            if (!self.valid_key(key)) return error.InvalidKey;
            self.start();

            const entry = try abi.heap.create(Entry);
            errdefer abi.heap.destroy(entry);
            entry.* = .{ .value = .{}, .memory = .init(abi.heap), .saved = 0, .unused = 0 };
            errdefer entry.memory.deinit();

            const path = try self.pathOf(abi.arena(), key, "");
            const io = runtime_io.current();
            if (std.Io.Dir.cwd().readFileAlloc(io, path, abi.arena(), .limited(self.max_size))) |text| {
                entry.value = self.codec.decode(entry.memory.allocator(), text) catch |err| {
                    std.log.err("{s} can't be read as an entry ({t}), it is left as it is", .{ path, err });
                    return error.InvalidData;
                };
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => {
                    std.log.err("can't read {s} ({t}), the plugin needs the fs.read.data permission", .{ path, err });
                    return error.ReadFailed;
                },
            }
            entry.saved = hash(try self.codec.encode(abi.arena(), entry.value));

            const owned_key = try entry.memory.allocator().dupe(u8, key);
            try self.entries.put(abi.heap, owned_key, entry);
            return &entry.value;
        }

        /// Returns the entry of `p`, keyed by the player's UUID.
        pub fn player(self: *Self, p: Player) Error!*T {
            return self.get(wit.uuid.toString(p.getId()));
        }

        /// Memory that lives as long as the entry behind `value`, for strings
        /// and slices put into it.
        pub fn allocator(_: *Self, value: *T) std.mem.Allocator {
            const entry: *Entry = @alignCast(@fieldParentPtr("value", value));
            return entry.memory.allocator();
        }

        /// Reports whether `key` has an entry, in memory or on disk.
        pub fn exists(self: *Self, key: []const u8) bool {
            if (self.entries.contains(key)) return true;
            if (!self.valid_key(key)) return false;
            const path = self.pathOf(abi.arena(), key, "") catch return false;
            std.Io.Dir.cwd().access(runtime_io.current(), path, .{}) catch return false;
            return true;
        }

        /// Writes the entry for `key` now if it changed.
        pub fn save(self: *Self, key: []const u8) !void {
            const entry = self.entries.get(key) orelse return;
            try self.write(key, entry);
        }

        /// Writes every entry that changed. The plugin does this by itself
        /// when it unloads.
        pub fn flush(self: *Self) void {
            var it = self.entries.iterator();
            while (it.next()) |e| self.write(e.key_ptr.*, e.value_ptr.*) catch {};
        }

        /// Deletes the entry for `key`, from memory and from disk.
        pub fn remove(self: *Self, key: []const u8) !void {
            if (!self.valid_key(key)) return error.InvalidKey;
            if (self.entries.fetchSwapRemove(key)) |kv| destroy(kv.value);
            const path = try self.pathOf(abi.arena(), key, "");
            std.Io.Dir.cwd().deleteFile(runtime_io.current(), path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }

        fn start(self: *Self) void {
            if (self.started) return;
            self.started = true;
            _ = tasks.every(self.autosave, autosaveTick, self);
            open_stores.append(abi.heap, .{ .store = self, .flush = flushErased }) catch @panic("OOM");
        }

        fn autosaveTick(_: Server, self: *Self) void {
            var i = self.entries.count();
            while (i > 0) {
                i -= 1;
                const key = self.entries.keys()[i];
                const entry = self.entries.values()[i];
                self.write(key, entry) catch continue;
                const idle = self.idle orelse continue;
                if (entry.unused < idle) {
                    entry.unused += 1;
                } else {
                    self.entries.swapRemoveAt(i);
                    destroy(entry);
                }
            }
        }

        fn flushErased(store: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(store));
            self.flush();
        }

        /// Writes to a temporary file first and renames it over the old one,
        /// so a crash halfway through doesn't leave a broken file.
        fn write(self: *Self, key: []const u8, entry: *Entry) !void {
            const text = try self.codec.encode(abi.arena(), entry.value);
            const h = hash(text);
            if (h == entry.saved) return;

            const io = runtime_io.current();
            const cwd = std.Io.Dir.cwd();
            const path = try self.pathOf(abi.arena(), key, "");
            const temporary = try self.pathOf(abi.arena(), key, ".tmp");
            errdefer |err| std.log.err("can't write {s} ({t}), the plugin needs the fs.write.data permission", .{ path, err });
            try cwd.createDirPath(io, self.dir);
            try cwd.writeFile(io, .{ .sub_path = temporary, .data = text });
            try std.Io.Dir.rename(cwd, temporary, cwd, path, io);
            entry.saved = h;
        }

        fn pathOf(self: *const Self, gpa: std.mem.Allocator, key: []const u8, suffix: []const u8) ![]const u8 {
            return std.fmt.allocPrint(gpa, "{s}/{s}{s}{s}", .{ self.dir, key, self.codec.extension, suffix });
        }

        fn destroy(entry: *Entry) void {
            entry.memory.deinit();
            abi.heap.destroy(entry);
        }
    };
}

fn hash(text: []const u8) u64 {
    return std.hash.Wyhash.hash(0, text);
}

var open_stores: std.ArrayList(struct { store: *anyopaque, flush: *const fn (*anyopaque) void }) = .empty;

/// Writes the changed entries of every store. `register` calls this when the
/// plugin unloads.
pub fn flushAll() void {
    for (open_stores.items) |s| s.flush(s.store);
}

test isValidKey {
    try std.testing.expect(isValidKey("069a79f4-44e9-4726-a5be-fca90e38aaf5"));
    try std.testing.expect(isValidKey("spawn.town"));
    try std.testing.expect(!isValidKey(""));
    try std.testing.expect(!isValidKey("../config"));
    try std.testing.expect(!isValidKey("a/b"));
    try std.testing.expect(!isValidKey(".hidden"));
}

test "codecs read back what they write" {
    const Home = struct { name: []const u8, x: f64 };
    const Profile = struct { visits: u32 = 0, homes: []const Home = &.{} };
    const value: Profile = .{ .visits = 3, .homes = &.{.{ .name = "base", .x = 1.5 }} };

    var memory: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer memory.deinit();
    inline for (.{ json(Profile, .indent_2), toml(Profile) }) |codec| {
        const text = try codec.encode(memory.allocator(), value);
        const back = try codec.decode(memory.allocator(), text);
        try std.testing.expectEqual(value.visits, back.visits);
        try std.testing.expectEqualStrings("base", back.homes[0].name);
        try std.testing.expectEqual(1.5, back.homes[0].x);
    }
}
