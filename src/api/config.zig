//! A config file in the plugin's data folder, read into a struct whose field
//! defaults make up the default config. Files ending in `.json` are JSON,
//! everything else is TOML. Needs the "fs.read.data" and "fs.write.data"
//! permissions.
//!
//!     var config: pumpkin.config.File(Config) = .{ .path = "config.toml" };

const std = @import("std");
const abi = @import("../runtime/abi.zig");
const runtime_io = @import("../runtime/io.zig");
const toml = @import("toml.zig");

pub fn File(comptime T: type) type {
    if (@typeInfo(T) != .@"struct") @compileError("a config has to be a struct");

    return struct {
        const Self = @This();

        /// The file name, relative to the plugin's data folder.
        path: []const u8,
        /// The config as last loaded. Its strings stay valid until the next
        /// successful `load` or `deinit`.
        value: T = .{},
        memory: std.heap.ArenaAllocator = .init(abi.heap),

        /// Reads the file into `value`. A missing file is created with the
        /// defaults, and settings the file lacks are added with their defaults,
        /// which is how new settings reach existing configs. Unknown settings
        /// are reported in the log and left in place. When the file can't be
        /// parsed, the error is logged with its line and `value` stays as it was.
        pub fn load(self: *Self) !void {
            const io = runtime_io.current();
            const text = std.Io.Dir.cwd().readFileAlloc(io, self.path, abi.arena(), .limited(16 * 1024 * 1024)) catch |err| switch (err) {
                error.FileNotFound => {
                    std.log.info("creating {s} with the default settings", .{self.path});
                    return self.save();
                },
                else => |e| {
                    std.log.err("can't read {s} ({t}), the plugin needs the fs.read.data permission", .{ self.path, e });
                    return e;
                },
            };

            const tree = try self.parse(text);
            var memory: std.heap.ArenaAllocator = .init(abi.heap);
            errdefer memory.deinit();
            const value = std.json.parseFromValueLeaky(T, memory.allocator(), tree, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch |err| {
                std.log.err("{s}: a setting has the wrong type ({t})", .{ self.path, err });
                return error.InvalidConfig;
            };

            self.memory.deinit();
            self.memory = memory;
            self.value = value;

            const missing = self.checkKeys(T, tree, "");
            if (missing) {
                std.log.info("adding new settings to {s}", .{self.path});
                try self.save();
            }
        }

        /// Writes `value` to the file, replacing what is there.
        pub fn save(self: *Self) !void {
            const io = runtime_io.current();
            const text = if (self.isJson())
                try std.json.Stringify.valueAlloc(abi.arena(), self.value, .{ .whitespace = .indent_2 })
            else
                try toml.stringify(abi.arena(), self.value);
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = self.path, .data = text }) catch |err| {
                std.log.err("can't write {s} ({t}), the plugin needs the fs.write.data permission", .{ self.path, err });
                return err;
            };
        }

        /// Frees the memory behind `value` and puts the defaults back.
        pub fn deinit(self: *Self) void {
            self.memory.deinit();
            self.memory = .init(abi.heap);
            self.value = .{};
        }

        fn isJson(self: *const Self) bool {
            return std.mem.endsWith(u8, self.path, ".json");
        }

        /// Parses `text` into a tree that lives until the current callback returns.
        fn parse(self: *const Self, text: []const u8) !std.json.Value {
            const tree = if (self.isJson()) json: {
                var scanner: std.json.Scanner = .initCompleteInput(abi.arena(), text);
                var diagnostics: std.json.Diagnostics = .{};
                scanner.enableDiagnostics(&diagnostics);
                break :json std.json.parseFromTokenSourceLeaky(std.json.Value, abi.arena(), &scanner, .{}) catch |err| {
                    std.log.err("{s}:{d}:{d}: {t}", .{ self.path, diagnostics.getLine(), diagnostics.getColumn(), err });
                    return error.InvalidConfig;
                };
            } else toml: {
                var diagnostics: toml.Diagnostics = .{};
                break :toml toml.parse(abi.arena(), text, &diagnostics) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    std.log.err("{s}:{d}:{d}: {s}", .{ self.path, diagnostics.line, diagnostics.column, diagnostics.message });
                    return error.InvalidConfig;
                };
            };
            if (tree != .object) {
                std.log.err("{s}: the config has to be an object", .{self.path});
                return error.InvalidConfig;
            }
            return tree;
        }

        /// Logs the settings in `tree` that `S` doesn't have, inside tables as
        /// well, and returns whether `tree` is missing any setting of `S`.
        fn checkKeys(self: *const Self, comptime S: type, tree: std.json.Value, prefix: []const u8) bool {
            if (tree != .object) return false;
            const fields = @typeInfo(S).@"struct".fields;
            var missing = false;
            inline for (fields) |field| {
                const name = if (prefix.len == 0) field.name else std.fmt.allocPrint(abi.arena(), "{s}.{s}", .{ prefix, field.name }) catch field.name;
                if (tree.object.get(field.name)) |child| {
                    const Child = switch (@typeInfo(field.type)) {
                        .optional => |o| o.child,
                        else => field.type,
                    };
                    if (@typeInfo(Child) == .@"struct") {
                        if (self.checkKeys(Child, child, name)) missing = true;
                    }
                } else if (@typeInfo(field.type) != .optional) {
                    missing = true;
                }
            }
            for (tree.object.keys()) |key| {
                const known = inline for (fields) |field| {
                    if (std.mem.eql(u8, field.name, key)) break true;
                } else false;
                if (!known) {
                    if (prefix.len == 0) {
                        std.log.warn("{s}: unknown setting '{s}'", .{ self.path, key });
                    } else {
                        std.log.warn("{s}: unknown setting '{s}.{s}'", .{ self.path, prefix, key });
                    }
                }
            }
            return missing;
        }
    };
}

test {
    _ = toml;
}
