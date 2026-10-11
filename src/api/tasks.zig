//! Delayed and repeating tasks that carry a value, such as the UUID of the
//! player they are about. Tasks still pending when the plugin unloads are
//! cancelled.
//!
//!     _ = pumpkin.tasks.after(.seconds(5), teleport, player.getId());

const std = @import("std");
const abi = @import("../runtime/abi.zig");
const scheduler = @import("../bindings/pumpkin.zig").scheduler;
const Server = @import("../bindings/pumpkin.zig").server.Server;

/// A span of game time. The server runs 20 ticks per second.
pub const Duration = struct {
    ticks: u64,

    pub fn fromTicks(n: u64) Duration {
        return .{ .ticks = n };
    }

    /// Rounds up to whole ticks.
    pub fn milliseconds(n: u64) Duration {
        return .{ .ticks = (n + 49) / 50 };
    }

    pub fn seconds(n: u64) Duration {
        return .{ .ticks = n * 20 };
    }

    pub fn minutes(n: u64) Duration {
        return .{ .ticks = n * 20 * 60 };
    }
};

/// A scheduled task. Cancelling one that already ran or was cancelled does nothing.
pub const Task = struct {
    slot: u32,
    generation: u32,

    pub fn cancel(task: Task) void {
        const s = slotOf(task) orelse return;
        if (s.running) {
            s.cancelled = true;
            return;
        }
        scheduler.cancelTask(s.task_id);
        free(task.slot);
    }

    /// Whether the task is still scheduled.
    pub fn pending(task: Task) bool {
        const s = slotOf(task) orelse return false;
        return !s.cancelled;
    }
};

/// Runs `handler` once, `delay` from now. `handler` is a
/// `fn (Server, T) void`, where `T` is the type of `data`, or
/// `fn (Server, *T, Task) void` to change the stored value or cancel the task
/// from inside. With `{}` as `data` it can also be a `fn (Server) void`.
/// `data` is copied, so any slices it holds have to outlive the task.
pub fn after(delay: Duration, comptime handler: anytype, data: anytype) Task {
    return schedule(delay, null, handler, data);
}

/// Runs `handler` every `period`, starting one period from now, until the
/// task is cancelled. `handler` and `data` work as in `after`.
pub fn every(period: Duration, comptime handler: anytype, data: anytype) Task {
    return schedule(period, period, handler, data);
}

/// Like `every`, but the first run is `delay` from now instead of one period.
pub fn repeat(delay: Duration, period: Duration, comptime handler: anytype, data: anytype) Task {
    return schedule(delay, period, handler, data);
}

/// Task handler ids with this bit set belong to this module. The other ids
/// are function pointers, which are small table indices on wasm32.
pub const id_bit: u32 = 1 << 31;

const Slot = struct {
    generation: u32 = 0,
    used: bool = false,
    task_id: u32 = 0,
    repeating: bool = false,
    running: bool = false,
    cancelled: bool = false,
    data: *anyopaque = undefined,
    run: *const fn (Server, *anyopaque, Task) void = undefined,
    destroy: *const fn (*anyopaque) void = undefined,
};

var slots: std.ArrayList(Slot) = .empty;

fn schedule(delay: Duration, period: ?Duration, comptime handler: anytype, data: anytype) Task {
    const T = @TypeOf(data);
    const glue = Glue(T, handler);

    const stored = abi.heap.create(T) catch @panic("OOM");
    stored.* = data;

    const index = for (slots.items, 0..) |s, i| {
        if (!s.used) break i;
    } else blk: {
        slots.append(abi.heap, .{}) catch @panic("OOM");
        break :blk slots.items.len - 1;
    };
    const s = &slots.items[index];
    s.* = .{
        .generation = s.generation +% 1,
        .used = true,
        .repeating = period != null,
        .data = stored,
        .run = glue.run,
        .destroy = glue.destroy,
    };
    const task: Task = .{ .slot = @intCast(index), .generation = s.generation };

    const handler_id = id_bit | @as(u32, @intCast(index));
    const task_id = if (period) |p|
        scheduler.scheduleRepeatingTask(handler_id, delay.ticks, @max(p.ticks, 1))
    else
        scheduler.scheduleDelayedTask(handler_id, delay.ticks);
    slots.items[index].task_id = task_id;
    return task;
}

fn Glue(comptime T: type, comptime handler: anytype) type {
    const params = @typeInfo(@TypeOf(handler)).@"fn".params.len;
    if (params < 1 or params > 3) @compileError("a task handler takes (Server), (Server, T) or (Server, *T, Task)");

    return struct {
        fn run(srv: Server, data: *anyopaque, task: Task) void {
            const value: *T = @ptrCast(@alignCast(data));
            switch (params) {
                1 => handler(srv),
                2 => handler(srv, value.*),
                else => handler(srv, value, task),
            }
        }

        fn destroy(data: *anyopaque) void {
            abi.heap.destroy(@as(*T, @ptrCast(@alignCast(data))));
        }
    };
}

fn slotOf(task: Task) ?*Slot {
    if (task.slot >= slots.items.len) return null;
    const s = &slots.items[task.slot];
    return if (s.used and s.generation == task.generation) s else null;
}

fn free(index: u32) void {
    const s = &slots.items[index];
    s.destroy(s.data);
    s.used = false;
}

/// Runs the task behind `handler_id`. `register` calls this for every task
/// handler id with `id_bit` set.
pub fn dispatch(handler_id: u32, srv: Server) void {
    const index = handler_id & ~id_bit;
    if (index >= slots.items.len or !slots.items[index].used) return;
    const s = &slots.items[index];
    if (s.cancelled) return;

    const task: Task = .{ .slot = index, .generation = s.generation };
    s.running = true;
    s.run(srv, s.data, task);
    // The handler may have scheduled more tasks, which can move the slots.
    const after_run = &slots.items[index];
    after_run.running = false;
    if (after_run.cancelled) scheduler.cancelTask(after_run.task_id);
    if (after_run.cancelled or !after_run.repeating) free(index);
}

/// Cancels every pending task. `register` calls this when the plugin unloads.
pub fn cancelAll() void {
    for (slots.items, 0..) |s, i| {
        if (!s.used) continue;
        scheduler.cancelTask(s.task_id);
        free(@intCast(i));
    }
}
