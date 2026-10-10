//! Not part of the package. Zig only analyzes what gets used, so a plugin build
//! never looks at most of src/bindings. This takes the address of every generated
//! function to get all of them compiled, see `zig build check`.

const std = @import("std");
const wit = @import("bindings/pumpkin.zig");
const wasi = @import("bindings/wasi.zig");

fn collect(comptime T: type) []const *const anyopaque {
    var out: []const *const anyopaque = &.{};
    for (std.meta.declarations(T)) |decl| {
        const Decl = @TypeOf(@field(T, decl.name));
        if (Decl == type) {
            const Inner = @field(T, decl.name);
            switch (@typeInfo(Inner)) {
                .@"struct", .@"enum", .@"union" => out = out ++ collect(Inner),
                else => {},
            }
        } else if (@typeInfo(Decl) == .@"fn" and !@typeInfo(Decl).@"fn".is_generic) {
            out = out ++ [1]*const anyopaque{@ptrCast(&@field(T, decl.name))};
        }
    }
    return out;
}

const all = blk: {
    @setEvalBranchQuota(10_000_000);
    const list = collect(wit) ++ collect(wasi);
    break :blk list[0..list.len].*;
};

export const table: [all.len]*const anyopaque = all;
