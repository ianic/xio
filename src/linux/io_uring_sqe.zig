//! Contains only the definition of `io_uring_sqe`.
//! Split into its own file to compartmentalize the initialization methods.

const std = @import("std");
const linux = std.os.linux;
const linuxx = @import("linuxx.zig");

pub const Sqe = extern struct {
    opcode: linux.IORING_OP = .NOP,
    flags: packed struct(u8) { // IOSQE_* flags
        fixed_file: bool = false,
        io_drain: bool = false,
        io_link: bool = false,
        io_hardlink: bool = false,
        async: bool = false,
        buffer_select: bool = false,
        cqe_skip_success: bool = false,
        _: u1 = 0,
    } = .{},
    ioprio: u16 = 0,
    fd: i32 = -1, // file descriptor to do IO on
    a: packed union(u64) {
        offset: u64, // offset into file
        addr2: u64,
        opt: packed struct {
            cmd: linux.IO_URING_SOCKET_OP,
            _: u32 = 0,
        },
    } = .{ .offset = 0 },
    b: packed union(u64) {
        addr: u64, // pointer to buffer or iovecs
        splice_off_in: u64,
        opt: packed struct {
            level: u32,
            name: u32,
        },
    } = .{ .addr = 0 },
    len: u32 = 0, // buffer size or number of iovecs
    op_flags: u32 = 0, // operation flags
    user_data: u64 = 0, // data to be passed back at completion time
    buf_group: u16 = 0,
    personality: u16 = 0,
    c: packed union(u32) {
        splice_fd_in: i32,
        file_index: u32,
        zcrx_ifq_idx: u32,
        optlen: u32,
        addr: packed struct {
            len: u16,
            _: u16 = 0,
        },
    } = .{ .splice_fd_in = 0 },
    d: packed union(u64) {
        addr3: u64,
        optval: u64,
    } = .{ .addr3 = 0 },
    _: u64 = 0,

    pub fn prep_rw(
        sqe: *Sqe,
        op: linux.IORING_OP,
        fd: linux.fd_t,
        addr: u64,
        len: usize,
        offset: u64,
    ) void {
        sqe.* = .{
            .opcode = op,
            .fd = fd,
            .a = .{ .offset = offset },
            .b = .{ .addr = addr },
            .len = @intCast(len),
        };
    }

    pub fn splice(
        sqe: *Sqe,
        user_data: u64,
        fd_in: linux.fd_t,
        off_in: u64,
        fd_out: linux.fd_t,
        off_out: u64,
        len: usize,
        flags: u32,
    ) void {
        sqe.prep_rw(.SPLICE, fd_out, off_in, len, off_out);
        sqe.c = .{ .splice_fd_in = fd_in };
        sqe.user_data = user_data;
        sqe.op_flags = flags;
    }

    pub fn pipe(
        sqe: *Sqe,
        user_data: u64,
        fds: *[2]linux.fd_t,
        flags: u32,
    ) void {
        const OP_PIPE = 62;
        sqe.prep_rw(@fromBackingInt(@intCast(OP_PIPE)), 0, @intFromPtr(fds), 0, 0);
        sqe.user_data = user_data;
        sqe.op_flags = flags;
    }

    pub fn listen(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        backlog: usize,
        flags: u32,
    ) void {
        sqe.prep_rw(.LISTEN, fd, 0, backlog, 0);
        sqe.user_data = user_data;
        sqe.op_flags = flags;
    }

    pub fn statx(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        path: [*:0]const u8,
        mask: linux.STATX,
        buf: *linux.Statx,
        flags: u32,
    ) void {
        sqe.prep_rw(.STATX, fd, @intFromPtr(path), @as(u32, @bitCast(mask)), @intFromPtr(buf));
        sqe.user_data = user_data;
        sqe.op_flags = flags;
    }

    pub fn sendmsg(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        msg: *const linux.msghdr_const,
        flags: u32,
    ) void {
        sqe.prep_rw(.SENDMSG, fd, @intFromPtr(msg), 1, 0);
        sqe.user_data = user_data;
        sqe.op_flags = flags;
    }

    pub fn send(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        buffer: []const u8,
        flags: u32,
    ) void {
        sqe.prep_rw(.SEND, fd, @intFromPtr(buffer.ptr), buffer.len, 0);
        sqe.user_data = user_data;
        sqe.op_flags = flags;
    }

    pub fn socket(
        sqe: *Sqe,
        user_data: u64,
        domain: u32,
        socket_type: u32,
        protocol: u32,
        flags: u32,
    ) void {
        sqe.prep_rw(.SOCKET, @intCast(domain), 0, protocol, socket_type);
        sqe.user_data = user_data;
        sqe.op_flags = flags;
    }

    pub fn setsockopt(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        level: u32,
        opt_name: u32,
        optval: u64,
        optlen: u32,
    ) void {
        sqe.prep_rw(.URING_CMD, fd, 0, 0, 0);
        sqe.user_data = user_data;
        sqe.a = .{ .opt = .{ .cmd = .SETSOCKOPT } };
        sqe.b = .{ .opt = .{ .level = level, .name = opt_name } };
        sqe.c = .{ .optlen = optlen };
        sqe.d = .{ .optval = optval };
    }

    pub fn getsockname(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        addr: *linux.sockaddr,
        addr_len: *linux.socklen_t,
    ) void {
        sqe.prep_rw(.URING_CMD, fd, 0, 0, 0);
        sqe.user_data = user_data;
        sqe.a = .{ .opt = .{ .cmd = .GETSOCKNAME } };
        sqe.b = .{ .addr = @intFromPtr(addr) };
        sqe.c = .{ .optlen = 0 }; // optlen: 0 - local, 1 - peer
        sqe.d = .{ .addr3 = @intFromPtr(addr_len) };
    }

    pub fn asyncCancel(
        sqe: *Sqe,
        user_data: u64,
        cancel_user_data: u64,
    ) void {
        sqe.prep_rw(.ASYNC_CANCEL, -1, cancel_user_data, 0, 0);
        sqe.user_data = user_data;
        sqe.flags.cqe_skip_success = true;
    }

    pub fn nop(sqe: *Sqe, user_data: u64) void {
        sqe.* = .{
            .opcode = .NOP,
            .user_data = user_data,
        };
    }

    pub fn read(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        buffer: []u8,
        offset: ?u64,
    ) void {
        const off = offset orelse std.math.maxInt(u64);
        sqe.prep_rw(.READ, fd, @intFromPtr(buffer.ptr), @min(buffer.len, 0xfffff000), off);
        sqe.user_data = user_data;
    }

    pub fn readv(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        iovecs: []const std.posix.iovec,
        offset: ?u64,
    ) void {
        const off = offset orelse std.math.maxInt(u64);
        sqe.prep_rw(.READV, fd, @intFromPtr(iovecs.ptr), iovecs.len, off);
        sqe.user_data = user_data;
    }

    pub fn write(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        buffer: []const u8,
        offset: ?u64,
    ) void {
        const off = offset orelse std.math.maxInt(u64);
        sqe.prep_rw(.WRITE, fd, @intFromPtr(buffer.ptr), buffer.len, off);
        sqe.user_data = user_data;
    }

    pub fn writev(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        iovecs: []const std.posix.iovec_const,
        offset: ?u64,
    ) void {
        const off = offset orelse std.math.maxInt(u64);
        sqe.prep_rw(.WRITEV, fd, @intFromPtr(iovecs.ptr), iovecs.len, off);
        sqe.user_data = user_data;
    }

    pub fn connect(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        addr: *const linux.sockaddr,
        addr_len: linux.socklen_t,
    ) void {
        sqe.prep_rw(.CONNECT, fd, @intFromPtr(addr), 0, addr_len);
        sqe.user_data = user_data;
    }

    pub fn bind(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        addr: *const linux.sockaddr,
        addrlen: linux.socklen_t,
    ) void {
        sqe.prep_rw(.BIND, fd, @intFromPtr(addr), 0, addrlen);
        sqe.user_data = user_data;
    }

    pub fn linkTimeout(
        sqe: *Sqe,
        user_data: u64,
        ts: *const linux.kernel_timespec,
        flags: u32,
    ) void {
        sqe.prep_rw(.LINK_TIMEOUT, -1, @intFromPtr(ts), 1, 0);
        sqe.op_flags = flags;
        sqe.user_data = user_data;
    }

    pub fn shutdown(
        sqe: *Sqe,
        user_data: u64,
        sockfd: linux.socket_t,
        how: u32,
    ) void {
        sqe.prep_rw(.SHUTDOWN, sockfd, 0, how, 0);
        sqe.user_data = user_data;
    }

    pub fn recvmsg(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        msg: *linux.msghdr,
        flags: u32,
    ) void {
        sqe.prep_rw(.RECVMSG, fd, @intFromPtr(msg), 1, 0);
        sqe.user_data = user_data;
        sqe.op_flags = flags;
    }

    pub fn accept(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        addr: ?*linux.sockaddr,
        addrlen: ?*linux.socklen_t,
        flags: u32,
    ) void {
        sqe.prep_rw(.ACCEPT, fd, @intFromPtr(addr), 0, @intFromPtr(addrlen));
        sqe.user_data = user_data;
        sqe.op_flags = flags;
    }

    pub fn timeout(
        sqe: *Sqe,
        user_data: u64,
        ts: *const linux.kernel_timespec,
        count: u32,
        flags: u32,
    ) void {
        sqe.prep_rw(.TIMEOUT, -1, @intFromPtr(ts), 1, count);
        sqe.user_data = user_data;
        sqe.op_flags = flags;
    }

    pub fn timeoutRemove(sqe: *Sqe, user_data: u64, timeout_user_data: u64) void {
        sqe.* = .{
            .opcode = .TIMEOUT_REMOVE,
            .b = .{ .addr = timeout_user_data },
            .user_data = user_data,
        };
    }

    pub fn waitid(
        sqe: *Sqe,
        user_data: u64,
        id_type: linux.P,
        id: i32,
        infop: *linux.siginfo_t,
        options: u32,
    ) void {
        sqe.* = .{
            .opcode = .WAITID,
            .fd = id,
            .a = .{ .addr2 = @intFromPtr(&infop) },
            .len = @backingInt(id_type),
            .user_data = user_data,
            .c = .{ .optlen = options },
        };
    }

    pub fn close(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
    ) void {
        sqe.* = .{
            .opcode = .CLOSE,
            .fd = fd,
            .user_data = user_data,
        };
    }

    pub fn linkat(
        sqe: *Sqe,
        user_data: u64,
        old_dir_fd: linux.fd_t,
        old_path: [*:0]const u8,
        new_dir_fd: linux.fd_t,
        new_path: [*:0]const u8,
        flags: u32,
    ) void {
        sqe.prep_rw(
            .LINKAT,
            old_dir_fd,
            @intFromPtr(old_path),
            0,
            @intFromPtr(new_path),
        );
        sqe.len = @bitCast(new_dir_fd);
        sqe.op_flags = flags;

        sqe.* = .{
            .opcode = .LINKAT,
            .fd = old_dir_fd,
            .a = .{ .addr2 = @intFromPtr(new_path) },
            .b = .{ .addr = @intFromPtr(old_path) },
            .len = @bitCast(new_dir_fd),
            .op_flags = flags,
            .user_data = user_data,
        };
    }

    pub fn symlinkat(
        sqe: *Sqe,
        user_data: u64,
        target: [*:0]const u8,
        new_dir_fd: linux.fd_t,
        link_path: [*:0]const u8,
    ) void {
        sqe.* = .{
            .opcode = .SYMLINKAT,
            .fd = new_dir_fd,
            .a = .{ .addr2 = @intFromPtr(link_path) },
            .b = .{ .addr = @intFromPtr(target) },
            .user_data = user_data,
        };
    }

    pub fn openat(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        path: [*:0]const u8,
        flags: linux.O,
        mode: linux.mode_t,
    ) void {
        sqe.* = .{
            .opcode = .OPENAT,
            .fd = fd,
            .b = .{ .addr = @intFromPtr(path) },
            .len = mode,
            .op_flags = @bitCast(flags),
            .user_data = user_data,
        };
    }

    pub fn unlinkat(
        sqe: *Sqe,
        user_data: u64,
        dir_fd: linux.fd_t,
        path: [*:0]const u8,
        flags: u32,
    ) void {
        sqe.* = .{
            .opcode = .UNLINKAT,
            .fd = dir_fd,
            .b = .{ .addr = @intFromPtr(path) },
            .op_flags = flags,
            .user_data = user_data,
        };
    }

    pub fn fsync(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        flags: u32,
    ) void {
        sqe.* = .{
            .opcode = .FSYNC,
            .fd = fd,
            .op_flags = flags,
            .user_data = user_data,
        };
    }

    pub fn ftrucate(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        length: u64,
        flags: u32,
    ) void {
        sqe.* = .{
            .opcode = .FTRUNCATE,
            .fd = fd,
            .a = .{ .offset = length },
            .op_flags = flags,
            .user_data = user_data,
        };
    }

    pub fn renameat(
        sqe: *Sqe,
        user_data: u64,
        old_dir_fd: linux.fd_t,
        old_path: [*:0]const u8,
        new_dir_fd: linux.fd_t,
        new_path: [*:0]const u8,
        flags: linux.RENAME,
    ) void {
        sqe.* = .{
            .opcode = .RENAMEAT,
            .fd = old_dir_fd,
            .a = .{ .addr2 = @intFromPtr(new_path) },
            .b = .{ .addr = @intFromPtr(old_path) },
            .len = @bitCast(new_dir_fd),
            .op_flags = @bitCast(flags),
            .user_data = user_data,
        };
    }

    pub fn futexWait(
        sqe: *Sqe,
        user_data: u64,
        ptr: *const u32,
        expected: u32,
    ) void {
        sqe.* = .{
            .opcode = .FUTEX_WAIT,
            .fd = @bitCast(linux.FUTEX2_FLAGS{ .size = .U32, .private = true }),
            .a = .{ .offset = expected },
            .b = .{ .addr = @intFromPtr(ptr) },
            .user_data = user_data,
            .d = .{ .addr3 = std.math.maxInt(u32) },
        };
    }

    pub fn futexWake(
        sqe: *Sqe,
        user_data: u64,
        ptr: *const u32,
        max_waiters: u32,
    ) void {
        sqe.* = .{
            .opcode = .FUTEX_WAKE,
            .flags = .{ .cqe_skip_success = true },
            .fd = @bitCast(linux.FUTEX2_FLAGS{ .size = .U32, .private = true }),
            .a = .{ .offset = max_waiters },
            .b = .{ .addr = @intFromPtr(ptr) },
            .user_data = user_data,
            .d = .{ .addr3 = std.math.maxInt(u32) },
        };
    }

    pub fn mkdirat(
        sqe: *Sqe,
        user_data: u64,
        dir_fd: linux.fd_t,
        path: [*:0]const u8,
        mode: linux.mode_t,
    ) void {
        sqe.* = .{
            .opcode = .MKDIRAT,
            .fd = dir_fd,
            .b = .{ .addr = @intFromPtr(path) },
            .len = mode,
            .user_data = user_data,
        };
    }
};
