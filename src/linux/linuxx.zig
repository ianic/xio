const std = @import("std");
const linux = std.os.linux;

pub const IO_URING_SOCKET_OP = enum(u32) {
    SIOCIN = 0,
    SIOCOUTQ = 1,
    GETSOCKOPT = 2,
    SETSOCKOPT = 3,
    TX_TIMESTAMP = 4,
    GETSOCKNAME = 5,
};

pub fn io_uring_enter(fd: linux.fd_t, to_submit: u32, min_complete: u32, flags: u32, arg: ?*const anyopaque, sz: u32) usize {
    return linux.syscall6(.io_uring_enter, @as(u32, @bitCast(fd)), to_submit, min_complete, flags, @intFromPtr(arg), sz);
}

pub const IORING_FEAT_MIN_TIMEOUT = 1 << 15;

pub const io_uring_getevents_arg = extern struct {
    sigmask: u64,
    sigmask_sz: u32,
    min_wait_usec: u32,
    ts: u64,
};
