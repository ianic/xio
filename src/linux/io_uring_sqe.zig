const std = @import("std");
const linux = std.os.linux;

pub const Sqe = extern struct {
    opcode: Op = .nop,
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
    fd: i32 = 0, // file descriptor to do IO on
    a: packed union(u64) {
        offset: u64, // offset into file
        addr2: u64,
        opt: packed struct {
            cmd: SocketOp,
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

    pub fn splice(
        sqe: *Sqe,
        user_data: u64,
        fd_in: linux.fd_t,
        off_in: u64,
        fd_out: linux.fd_t,
        off_out: u64,
        len: u32,
        flags: u32,
    ) void {
        sqe.* = .{
            .opcode = .splice,
            .fd = fd_out,
            .a = .{ .offset = off_out },
            .b = .{ .splice_off_in = off_in },
            .c = .{ .splice_fd_in = fd_in },
            .len = len,
            .user_data = user_data,
            .op_flags = flags,
        };
    }

    pub fn pipe(
        sqe: *Sqe,
        user_data: u64,
        fds: *[2]linux.fd_t,
        flags: u32,
    ) void {
        sqe.* = .{
            .opcode = .pipe,
            .b = .{ .addr = @intFromPtr(fds) },
            .user_data = user_data,
            .op_flags = flags,
        };
    }

    pub fn listen(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        backlog: u32,
        flags: u32,
    ) void {
        sqe.* = .{
            .opcode = .listen,
            .fd = fd,
            .len = backlog,
            .user_data = user_data,
            .op_flags = flags,
        };
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
        sqe.* = .{
            .opcode = .statx,
            .fd = fd,
            .b = .{ .addr = @intFromPtr(path) },
            .len = @as(u32, @bitCast(mask)),
            .a = .{ .offset = @intFromPtr(buf) },
            .user_data = user_data,
            .op_flags = flags,
        };
    }

    pub fn sendmsg(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        msg: *const linux.msghdr_const,
        flags: u32,
    ) void {
        sqe.* = .{
            .opcode = .sendmsg,
            .fd = fd,
            .b = .{ .addr = @intFromPtr(msg) },
            .len = 1,
            .user_data = user_data,
            .op_flags = flags,
        };
    }

    pub fn send(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        buffer: []const u8,
        flags: u32,
    ) void {
        sqe.* = .{
            .opcode = .send,
            .fd = fd,
            .b = .{ .addr = @intFromPtr(buffer.ptr) },
            .len = @intCast(buffer.len),
            .user_data = user_data,
            .op_flags = flags,
        };
    }

    pub fn socket(
        sqe: *Sqe,
        user_data: u64,
        domain: u32,
        socket_type: u32,
        protocol: u32,
        flags: u32,
    ) void {
        sqe.* = .{
            .opcode = .socket,
            .fd = @intCast(domain),
            .len = protocol,
            .a = .{ .offset = socket_type },
            .user_data = user_data,
            .op_flags = flags,
        };
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
        sqe.* = .{
            .opcode = .uring_cmd,
            .fd = fd,
            .a = .{ .opt = .{ .cmd = .setsockopt } },
            .b = .{ .opt = .{ .level = level, .name = opt_name } },
            .c = .{ .optlen = optlen },
            .d = .{ .optval = optval },
            .user_data = user_data,
        };
    }

    pub fn getsockname(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        addr: *linux.sockaddr,
        addr_len: *linux.socklen_t,
    ) void {
        sqe.* = .{
            .opcode = .uring_cmd,
            .fd = fd,
            .a = .{ .opt = .{ .cmd = .getsockname } },
            .b = .{ .addr = @intFromPtr(addr) },
            .c = .{ .optlen = 0 }, // optlen: 0 - local, 1 - peer
            .d = .{ .addr3 = @intFromPtr(addr_len) },
            .user_data = user_data,
        };
    }

    pub fn asyncCancel(
        sqe: *Sqe,
        user_data: u64,
        cancel_user_data: u64,
    ) void {
        sqe.* = .{
            .opcode = .async_cancel,
            .fd = -1,
            .b = .{ .addr = cancel_user_data },
            .user_data = user_data,
            .flags = .{ .cqe_skip_success = true },
        };
    }

    pub fn nop(sqe: *Sqe, user_data: u64) void {
        sqe.* = .{
            .opcode = .nop,
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
        sqe.* = .{
            .opcode = .read,
            .fd = fd,
            .b = .{ .addr = @intFromPtr(buffer.ptr) },
            .len = @min(buffer.len, 0xfffff000),
            .a = .{ .offset = offset orelse no_offset },
            .user_data = user_data,
        };
    }

    pub fn readv(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        iovecs: []const std.posix.iovec,
        offset: ?u64,
    ) void {
        sqe.* = .{
            .opcode = .readv,
            .fd = fd,
            .b = .{ .addr = @intFromPtr(iovecs.ptr) },
            .len = @intCast(iovecs.len),
            .a = .{ .offset = offset orelse no_offset },
            .user_data = user_data,
        };
    }

    pub fn write(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        buffer: []const u8,
        offset: ?u64,
    ) void {
        sqe.* = .{
            .opcode = .write,
            .fd = fd,
            .b = .{ .addr = @intFromPtr(buffer.ptr) },
            .len = @intCast(buffer.len),
            .a = .{ .offset = offset orelse no_offset },
            .user_data = user_data,
        };
    }

    pub fn writev(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        iovecs: []const std.posix.iovec_const,
        offset: ?u64,
    ) void {
        sqe.* = .{
            .opcode = .writev,
            .fd = fd,
            .b = .{ .addr = @intFromPtr(iovecs.ptr) },
            .len = @intCast(iovecs.len),
            .a = .{ .offset = offset orelse no_offset },
            .user_data = user_data,
        };
    }

    pub fn connect(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        addr: *const linux.sockaddr,
        addr_len: linux.socklen_t,
    ) void {
        sqe.* = .{
            .opcode = .connect,
            .fd = fd,
            .b = .{ .addr = @intFromPtr(addr) },
            .a = .{ .offset = addr_len },
            .user_data = user_data,
        };
    }

    pub fn bind(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        addr: *const linux.sockaddr,
        addrlen: linux.socklen_t,
    ) void {
        sqe.* = .{
            .opcode = .bind,
            .fd = fd,
            .b = .{ .addr = @intFromPtr(addr) },
            .a = .{ .offset = addrlen },
            .user_data = user_data,
        };
    }

    pub fn linkTimeout(
        sqe: *Sqe,
        user_data: u64,
        ts: *const linux.kernel_timespec,
        flags: u32,
    ) void {
        sqe.* = .{
            .opcode = .link_timeout,
            .fd = -1,
            .b = .{ .addr = @intFromPtr(ts) },
            .len = 1,
            .op_flags = flags,
            .user_data = user_data,
        };
    }

    pub fn shutdown(
        sqe: *Sqe,
        user_data: u64,
        sockfd: linux.socket_t,
        how: u32,
    ) void {
        sqe.* = .{
            .opcode = .shutdown,
            .fd = sockfd,
            .len = how,
            .user_data = user_data,
        };
    }

    pub fn recvmsg(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        msg: *linux.msghdr,
        flags: u32,
    ) void {
        sqe.* = .{
            .opcode = .recvmsg,
            .fd = fd,
            .b = .{ .addr = @intFromPtr(msg) },
            .len = 1,
            .user_data = user_data,
            .op_flags = flags,
        };
    }

    pub fn accept(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
        addr: ?*linux.sockaddr,
        addrlen: ?*linux.socklen_t,
        flags: u32,
    ) void {
        sqe.* = .{
            .opcode = .accept,
            .fd = fd,
            .a = .{ .addr2 = @intFromPtr(addrlen) },
            .b = .{ .addr = @intFromPtr(addr) },
            .user_data = user_data,
            .op_flags = flags,
        };
    }

    pub fn timeout(
        sqe: *Sqe,
        user_data: u64,
        ts: *const linux.kernel_timespec,
        count: u32,
        flags: u32,
    ) void {
        sqe.* = .{
            .opcode = .timeout,
            .fd = -1,
            .a = .{ .offset = count },
            .b = .{ .addr = @intFromPtr(ts) },
            .len = 1,
            .user_data = user_data,
            .op_flags = flags,
        };
    }

    pub fn timeoutRemove(sqe: *Sqe, user_data: u64, timeout_user_data: u64) void {
        sqe.* = .{
            .opcode = .timeout_remove,
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
            .opcode = .waitid,
            .fd = id,
            .a = .{ .addr2 = @intFromPtr(&infop) },
            .c = .{ .optlen = options },
            .len = @backingInt(id_type),
            .user_data = user_data,
        };
    }

    pub fn close(
        sqe: *Sqe,
        user_data: u64,
        fd: linux.fd_t,
    ) void {
        sqe.* = .{
            .opcode = .close,
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
        sqe.* = .{
            .opcode = .linkat,
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
            .opcode = .symlinkat,
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
            .opcode = .openat,
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
            .opcode = .unlinkat,
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
            .opcode = .fsync,
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
            .opcode = .ftruncate,
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
            .opcode = .renameat,
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
            .opcode = .futex_wait,
            .fd = @bitCast(linux.FUTEX2_FLAGS{ .size = .U32, .private = true }),
            .a = .{ .offset = expected },
            .b = .{ .addr = @intFromPtr(ptr) },
            .d = .{ .addr3 = std.math.maxInt(u32) },
            .user_data = user_data,
        };
    }

    pub fn futexWake(
        sqe: *Sqe,
        user_data: u64,
        ptr: *const u32,
        max_waiters: u32,
    ) void {
        sqe.* = .{
            .opcode = .futex_wake,
            .flags = .{ .cqe_skip_success = true },
            .fd = @bitCast(linux.FUTEX2_FLAGS{ .size = .U32, .private = true }),
            .a = .{ .offset = max_waiters },
            .b = .{ .addr = @intFromPtr(ptr) },
            .d = .{ .addr3 = std.math.maxInt(u32) },
            .user_data = user_data,
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
            .opcode = .mkdirat,
            .fd = dir_fd,
            .b = .{ .addr = @intFromPtr(path) },
            .len = mode,
            .user_data = user_data,
        };
    }
};

const SocketOp = enum(u32) {
    siocin = 0,
    siocoutq = 1,
    getsockopt = 2,
    setsockopt = 3,
    tx_timestamp = 4,
    getsockname = 5,
};

const Op = enum(u8) {
    nop,
    readv,
    writev,
    fsync,
    read_fixed,
    write_fixed,
    poll_add,
    poll_remove,
    sync_file_range,
    sendmsg,
    recvmsg,
    timeout,
    timeout_remove,
    accept,
    async_cancel,
    link_timeout,
    connect,
    fallocate,
    openat,
    close,
    files_update,
    statx,
    read,
    write,
    fadvise,
    madvise,
    send,
    recv,
    openat2,
    epoll_ctl,
    splice,
    provide_buffers,
    remove_buffers,
    tee,
    shutdown,
    renameat,
    unlinkat,
    mkdirat,
    symlinkat,
    linkat,
    msg_ring,
    fsetxattr,
    setxattr,
    fgetxattr,
    getxattr,
    socket,
    uring_cmd,
    send_zc,
    sendmsg_zc,
    read_multishot,
    waitid,
    futex_wait,
    futex_wake,
    futex_waitv,
    fixed_fd_install,
    ftruncate,
    bind,
    listen,
    recv_zc,
    epoll_wait,
    readv_fixed,
    writev_fixed,
    pipe,
    nop128,
    uring_cmd128,
    _,
};

const no_offset = std.math.maxInt(u64);
