const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const fiber = std.Io.fiber;

var fiber_stack: [4 * 4096]u8 align(16) = undefined;
var main_context: fiber.Context = undefined;
var worker_context: fiber.Context = undefined;

fn worker_entry() callconv(.c) void {
    const s: Io.fiber.Switch = .{ .new = &main_context, .old = &worker_context };

    for (1..10) |i| {
        std.debug.print("in worker {}\n", .{i});
        _ = fiber.contextSwitch(&s);
    }
}

pub fn main() !void {
    worker_context = initContext(&fiber_stack, &worker_entry);

    const s: Io.fiber.Switch = .{ .old = &main_context, .new = &worker_context };
    for (1..10) |i| {
        std.debug.print("in main   {}\n", .{i});
        _ = fiber.contextSwitch(&s);
    }

    std.debug.print("main exit\n", .{});
}

fn initContext(stack: []u8, entry: *const fn () callconv(.c) void) fiber.Context {
    const stack_top = @intFromPtr(stack.ptr) + stack.len;
    return switch (builtin.cpu.arch) {
        .aarch64 => .{
            .sp = stack_top,
            .fp = 0,
            .pc = @intFromPtr(entry),
        },
        .riscv64 => .{
            .sp = stack_top,
            .fp = 0,
            .pc = @intFromPtr(entry),
        },
        .x86_64 => .{
            .rsp = stack_top,
            .rbp = 0,
            .rip = @intFromPtr(entry),
        },
        else => @compileError("unimplemented architecture"),
    };
}
