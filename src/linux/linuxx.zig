const std = @import("std");
const linux = std.os.linux;

pub fn io_uring_enter(fd: linux.fd_t, to_submit: u32, min_complete: u32, flags: u32, arg: ?*const anyopaque, sz: u32) usize {
    return linux.syscall6(.io_uring_enter, @as(u32, @bitCast(fd)), to_submit, min_complete, flags, @intFromPtr(arg), sz);
}

pub const io_uring_getevents_arg = extern struct {
    sigmask: u64,
    sigmask_sz: u32,
    min_wait_usec: u32,
    ts: u64,
};

// io_uring_enter flags
pub const IORING_ENTER_GETEVENTS = 1 << 0;
pub const IORING_ENTER_SQ_WAKEUP = 1 << 1;
pub const IORING_ENTER_SQ_WAIT = 1 << 2;
pub const IORING_ENTER_EXT_ARG = 1 << 3;
pub const IORING_ENTER_REGISTERED_RING = 1 << 4;
pub const IORING_ENTER_ABS_TIMER = 1 << 5;
pub const IORING_ENTER_EXT_ARG_REG = 1 << 6;
pub const IORING_ENTER_NO_IOWAIT = 1 << 7;
