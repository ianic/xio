const IoUring = @This();

const builtin = @import("builtin");
const is_linux = builtin.os.tag == .linux;

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const posix = std.posix;
const linux = std.os.linux;
const testing = std.testing;
const page_size_min = std.heap.page_size_min;
pub const Sqe = @import("io_uring_sqe.zig").Sqe;
const linuxx = @import("linuxx.zig");

fd: linux.fd_t = -1,
sq: SubmissionQueue,
cq: CompletionQueue,
flags: u32,
features: u32,
enter_flags: u8 = 0,

/// A friendly way to setup an io_uring, with default linux.io_uring_params.
/// `entries` must be a power of two between 1 and 32768, although the kernel will make the final
/// call on how many entries the submission and completion queues will ultimately have,
/// see https://github.com/torvalds/linux/blob/v5.8/fs/io_uring.c#L8027-L8050.
/// Matches the interface of io_uring_queue_init() in liburing.
pub fn init(entries: u16, flags: u32) !IoUring {
    var params = std.mem.zeroInit(linux.io_uring_params, .{
        .flags = flags | linux.IORING_SETUP_NO_SQARRAY, // default to no sq array
        .sq_thread_idle = 1000,
    });
    return IoUring.init_params(entries, &params) catch |err| {
        if (flags & linux.IORING_SETUP_NO_SQARRAY == 0 and err == error.ArgumentsInvalid) {
            // fallback with sq array
            params.flags = flags;
            return try IoUring.init_params(entries, &params);
        }
        return err;
    };
}

/// A powerful way to setup an io_uring, if you want to tweak linux.io_uring_params such as submission
/// queue thread cpu affinity or thread idle timeout (the kernel and our default is 1 second).
/// `params` is passed by reference because the kernel needs to modify the parameters.
/// Matches the interface of io_uring_queue_init_params() in liburing.
pub fn init_params(entries: u16, p: *linux.io_uring_params) !IoUring {
    if (entries == 0) return error.EntriesZero;
    if (!std.math.isPowerOfTwo(entries)) return error.EntriesNotPowerOfTwo;

    const unsupported_flags = linux.IORING_SETUP_CQE32 |
        linux.IORING_SETUP_SQE128 |
        linux.IORING_SETUP_NO_MMAP |
        linux.IORING_SETUP_REGISTERED_FD_ONLY;
    if (p.flags & unsupported_flags > 0) return error.UnsupportedFlags;

    assert(p.sq_entries == 0);
    assert(p.cq_entries == 0 or p.flags & linux.IORING_SETUP_CQSIZE != 0);
    assert(p.features == 0);
    assert(p.wq_fd == 0 or p.flags & linux.IORING_SETUP_ATTACH_WQ != 0);
    assert(p.resv[0] == 0);
    assert(p.resv[1] == 0);
    assert(p.resv[2] == 0);

    const res = linux.io_uring_setup(entries, p);
    switch (linux.errno(res)) {
        .SUCCESS => {},
        .FAULT => return error.ParamsOutsideAccessibleAddressSpace,
        // The resv array contains non-zero data, p.flags contains an unsupported flag,
        // entries out of bounds, IORING_SETUP_SQ_AFF was specified without IORING_SETUP_SQPOLL,
        // or IORING_SETUP_CQSIZE was specified but linux.io_uring_params.cq_entries was invalid:
        .INVAL => return error.ArgumentsInvalid,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        // IORING_SETUP_SQPOLL was specified but effective user ID lacks sufficient privileges,
        // or a container seccomp policy prohibits io_uring syscalls:
        .PERM => return error.PermissionDenied,
        .NOSYS => return error.SystemOutdated,
        else => |errno| return posix.unexpectedErrno(errno),
    }
    const fd = @as(linux.fd_t, @intCast(res));
    assert(fd >= 0);
    errdefer _ = linux.close(fd);

    // Kernel versions 5.4 and up use only one mmap() for the submission and completion queues.
    // This is not an optional feature for us... if the kernel does it, we have to do it.
    // The thinking on this by the kernel developers was that both the submission and the
    // completion queue rings have sizes just over a power of two, but the submission queue ring
    // is significantly smaller with u32 slots. By bundling both in a single mmap, the kernel
    // gets the submission queue ring for free.
    // See https://patchwork.kernel.org/patch/11115257 for the kernel patch.
    // We do not support the double mmap() done before 5.4, because we want to keep the
    // init/deinit mmap paths simple and because io_uring has had many bug fixes even since 5.4.
    if ((p.features & linux.IORING_FEAT_SINGLE_MMAP) == 0) {
        return error.SystemOutdated;
    }

    // Check that the kernel has actually set params and that "impossible is nothing".
    assert(p.sq_entries != 0);
    assert(p.cq_entries != 0);
    assert(p.cq_entries >= p.sq_entries);

    // From here on, we only need to read from params, so pass `p` by value as immutable.
    // The completion queue shares the mmap with the submission queue, so pass `sq` there too.
    var sq = try SubmissionQueue.init(fd, p.*);
    errdefer sq.deinit();
    var cq = try CompletionQueue.init(fd, p.*, sq);
    errdefer cq.deinit();

    // Check that our starting state is as we expect.
    assert(sq.head.* == 0);
    assert(sq.tail.* == 0);
    assert(sq.mask == p.sq_entries - 1);
    // Allow flags.* to be non-zero, since the kernel may set IORING_SQ_NEED_WAKEUP at any time.
    assert(sq.dropped.* == 0);
    assert(sq.array.len == p.sq_entries or sq.array.len == 0);
    assert(sq.sqes.len == p.sq_entries);
    assert(sq.sqe_head == 0);
    assert(sq.sqe_tail == 0);

    assert(cq.head.* == 0);
    assert(cq.tail.* == 0);
    assert(cq.mask == p.cq_entries - 1);
    assert(cq.overflow.* == 0);
    assert(cq.cqes.len == p.cq_entries);

    return IoUring{
        .fd = fd,
        .sq = sq,
        .cq = cq,
        .flags = p.flags,
        .features = p.features,
    };
}

pub fn deinit(self: *IoUring) void {
    assert(self.fd >= 0);
    // The mmaps depend on the fd, so the order of these calls is important:
    self.cq.deinit();
    self.sq.deinit();
    _ = linux.close(self.fd);
    self.fd = -1;
}

/// Returns a pointer to a vacant SQE, or an error if the submission queue is full.
/// We follow the implementation (and atomics) of liburing's `io_uring_get_sqe()` exactly.
/// However, instead of a null we return an error to force safe handling.
/// Any situation where the submission queue is full tends more towards a control flow error,
/// and the null return in liburing is more a C idiom than anything else, for lack of a better
/// alternative. In Zig, we have first-class error handling... so let's use it.
/// Matches the implementation of io_uring_get_sqe() in liburing.
pub fn get_sqe(self: *IoUring) !*Sqe {
    const head = @atomicLoad(u32, self.sq.head, .acquire);
    // Remember that these head and tail offsets wrap around every four billion operations.
    // We must therefore use wrapping addition and subtraction to avoid a runtime crash.
    const next = self.sq.sqe_tail +% 1;
    if (next -% head > self.sq.sqes.len) return error.SubmissionQueueFull;
    const sqe = &self.sq.sqes[self.sq.sqe_tail & self.sq.mask];
    self.sq.sqe_tail = next;
    return sqe;
}

/// Submits the SQEs acquired via get_sqe() to the kernel. You can call this once after you have
/// called get_sqe() multiple times to setup multiple I/O requests.
/// Returns the number of SQEs submitted, if not used alongside IORING_SETUP_SQPOLL.
/// If the io_uring instance is uses IORING_SETUP_SQPOLL, the value returned on success is not
/// guaranteed to match the amount of actually submitted sqes during this call. A value higher
/// or lower, including 0, may be returned.
/// Matches the implementation of io_uring_submit() in liburing.
pub fn submit(self: *IoUring) !u32 {
    return self.submit_and_wait_min_timeout(0, null, 0);
}

/// Like submit(), but allows waiting for events as well.
/// Returns the number of SQEs submitted, if not used alongside IORING_SETUP_SQPOLL.
/// Matches the implementation of io_uring_submit_and_wait() in liburing.
pub fn submit_and_wait(self: *IoUring, wait_nr: u32) !u32 {
    return self.submit_and_wait_min_timeout(wait_nr, null, 0);
}

/// Like submit_and_wait(), but waits for `wait_nr` completion events OR until
/// the `wait_timeout` expires.
/// Returns error.TimeoutExpired if no completions are posted until `wait_timeout`.
/// Returns the number of SQEs submitted, if not used alongside IORING_SETUP_SQPOLL.
pub fn submit_and_wait_timeout(self: *IoUring, wait_nr: u32, wait_timeout: ?*const linux.kernel_timespec) !u32 {
    return self.submit_and_wait_min_timeout(wait_nr, wait_timeout, 0);
}

/// Same as io_uring_submit_and_wait_timeout() if `min_wait_usec` is zero.
///
/// If `wait_nr` number of completions have been received within `min_wait_usec`
/// number of microseconds, then the function returns successfully. If that
/// isn't the case, once min_wait_usec time has passed, control is returned if
/// any completions have been posted. If no completions have been posted, the
/// kernel switches to a normal wait of up to `wait_timeout`, subtracting the
/// time already waited. If any completions are posted after this happens,
/// control is returned immediately to the application.
///
/// Returns error.TimeoutExpired if no completions are posted until `wait_timeout`.
/// Returns the number of SQEs submitted, if not used alongside IORING_SETUP_SQPOLL.
pub fn submit_and_wait_min_timeout(
    self: *IoUring,
    /// Number of completions to wait for.
    wait_nr: u32,
    /// Timeout to wait:
    ///   - when min_wait_usec == 0 for `wait_nr` completions
    ///   - when min_wait_usec > 0  for any number of completions
    /// Requires IORING_FEAT_EXT_ARG set in features.
    /// Available since kernel 5.11.
    wait_timeout: ?*const linux.kernel_timespec,
    /// Number of microseconds to wait for the full completions batch.
    /// Requires IORING_FEAT_MIN_TIMEOUT set in features.
    /// Available since kernel 6.12.
    min_wait_usec: u32,
) !u32 {
    const pending_sqes = self.flush_sq();
    var flags: u32 = self.enter_flags;
    if (self.sq_ring_needs_enter(&flags) or wait_nr > 0) {
        if (wait_nr > 0 or (self.flags & linux.IORING_SETUP_IOPOLL) != 0) {
            flags |= linux.IORING_ENTER_GETEVENTS;
        }

        if (wait_nr == 0 or (wait_timeout == null and min_wait_usec == 0)) {
            return try self.enter(pending_sqes, wait_nr, flags, null);
        }

        if (self.features & linux.IORING_FEAT_EXT_ARG == 0)
            return error.SystemOutdated;
        if (min_wait_usec > 0 and (self.features & linuxx.IORING_FEAT_MIN_TIMEOUT == 0))
            return error.SystemOutdated;

        const arg = std.mem.zeroInit(linuxx.io_uring_getevents_arg, .{
            .sigmask_sz = linux.NSIG / 8,
            .ts = @intFromPtr(wait_timeout),
            .min_wait_usec = min_wait_usec,
        });
        return try self.enter(pending_sqes, wait_nr, flags, &arg);
    }
    return pending_sqes;
}

/// Tell the kernel we have submitted SQEs and/or want to wait for CQEs.
/// Returns the number of SQEs submitted.
pub fn enter(
    self: *IoUring,
    to_submit: u32,
    min_complete: u32,
    flags: u32,
    arg: ?*const linuxx.io_uring_getevents_arg,
) !u32 {
    assert(self.fd >= 0);
    const res = linuxx.io_uring_enter(
        self.fd,
        to_submit,
        min_complete,
        if (arg != null) flags | linux.IORING_ENTER_EXT_ARG else flags,
        arg,
        if (arg != null) @sizeOf(linuxx.io_uring_getevents_arg) else linux.NSIG / 8,
    );
    switch (linux.errno(res)) {
        .SUCCESS => {},
        // The kernel was unable to allocate memory or ran out of resources for the request.
        // The application should wait for some completions and try again:
        .AGAIN => return error.SystemResources,
        // The SQE `fd` is invalid, or IOSQE_FIXED_FILE was set but no files were registered:
        .BADF => return error.FileDescriptorInvalid,
        // The file descriptor is valid, but the ring is not in the right state.
        // See io_uring_register(2) for how to enable the ring.
        .BADFD => return error.FileDescriptorInBadState,
        // The application attempted to overcommit the number of requests it can have pending.
        // The application should wait for some completions and try again:
        .BUSY => return error.CompletionQueueOvercommitted,
        // The SQE is invalid, or valid but the ring was setup with IORING_SETUP_IOPOLL:
        .INVAL => return error.SubmissionQueueEntryInvalid,
        // The buffer is outside the process' accessible address space, or IORING_OP_READ_FIXED
        // or IORING_OP_WRITE_FIXED was specified but no buffers were registered, or the range
        // described by `addr` and `len` is not within the buffer registered at `buf_index`:
        .FAULT => return error.BufferInvalid,
        .NXIO => return error.RingShuttingDown,
        // The kernel believes our `self.fd` does not refer to an io_uring instance,
        // or the opcode is valid but not supported by this kernel (more likely):
        .OPNOTSUPP => return error.OpcodeNotSupported,
        // The thread submitting the work is invalid. This may occur if IORING_ENTER_GETEVENTS
        // and IORING_SETUP_DEFER_TASKRUN is set, but the submitting thread is not the thread
        // that initially created or enabled the io_uring associated with fd.
        .EXIST => return error.InvalidThread,
        // The operation was interrupted by a delivery of a signal before it could complete.
        // This can happen while waiting for events with IORING_ENTER_GETEVENTS:
        .INTR => return error.SignalInterrupt,
        // Timeout specified in `arg.ts` has expired.
        .TIME => return error.TimeoutExpired,
        else => |errno| return posix.unexpectedErrno(errno),
    }
    return @as(u32, @intCast(res));
}

/// Sync internal state with kernel ring state on the SQ side.
/// Returns the number of all pending events in the SQ ring, for the shared ring.
/// This return value includes previously flushed SQEs, as per liburing.
/// The rationale is to suggest that an io_uring_enter() call is needed rather than not.
/// Matches the implementation of __io_uring_flush_sq() in liburing.
pub fn flush_sq(self: *IoUring) u32 {
    if (self.sq.sqe_head != self.sq.sqe_tail) {
        const tail = self.sq.sqe_tail;
        self.sq.sqe_head = tail;
        // Ensure that the kernel can actually see the SQE updates when it sees the tail update.
        @atomicStore(u32, self.sq.tail, tail, .release);
    }
    return self.sq_ready();
}

/// Returns true if we are not using an SQ thread (thus nobody submits but us),
/// or if IORING_SQ_NEED_WAKEUP is set and the SQ thread must be explicitly awakened.
/// For the latter case, we set the SQ thread wakeup flag.
/// Matches the implementation of sq_ring_needs_enter() in liburing.
pub fn sq_ring_needs_enter(self: *IoUring, flags: *u32) bool {
    if ((self.flags & linux.IORING_SETUP_SQPOLL) == 0) return true;
    if ((@atomicLoad(u32, self.sq.flags, .unordered) & linux.IORING_SQ_NEED_WAKEUP) != 0) {
        flags.* |= linux.IORING_ENTER_SQ_WAKEUP;
        return true;
    }
    return false;
}

/// Returns the number of flushed and unflushed SQEs pending in the submission queue.
/// In other words, this is the number of SQEs in the submission queue, i.e. its length.
/// These are SQEs that the kernel is yet to consume.
/// Matches the implementation of io_uring_sq_ready in liburing.
pub fn sq_ready(self: *IoUring) u32 {
    // Always use the shared ring state (i.e. head and not sqe_head) to avoid going out of sync,
    // see https://github.com/axboe/liburing/issues/92.
    return self.sq.sqe_tail -% @atomicLoad(u32, self.sq.head, .acquire);
}

/// Returns the number of CQEs in the completion queue, i.e. its length.
/// These are CQEs that the application is yet to consume.
/// Matches the implementation of io_uring_cq_ready in liburing.
pub fn cq_ready(self: *IoUring) u32 {
    return @atomicLoad(u32, self.cq.tail, .acquire) -% self.cq.head.*;
}

/// Copies as many CQEs as are ready, and that can fit into the destination `cqes` slice.
/// If none are available, enters into the kernel to wait for at most `wait_nr` CQEs.
/// Returns the number of CQEs copied, advancing the CQ ring.
/// Provides all the wait/peek methods found in liburing, but with batching and a single method.
/// The rationale for copying CQEs rather than copying pointers is that pointers are 8 bytes
/// whereas CQEs are not much more at only 16 bytes, and this provides a safer faster interface.
/// Safer, because you no longer need to call cqe_seen(), avoiding idempotency bugs.
/// Faster, because we can now amortize the atomic store release to `cq.head` across the batch.
/// See https://github.com/axboe/liburing/issues/103#issuecomment-686665007.
/// Matches the implementation of io_uring_peek_batch_cqe() in liburing, but supports waiting.
pub fn copy_cqes(self: *IoUring, cqes: []linux.io_uring_cqe, wait_nr: u32) !u32 {
    const count = self.copy_cqes_ready(cqes);
    if (count > 0) return count;
    if (self.cq_ring_needs_flush() or wait_nr > 0) {
        _ = try self.enter(0, wait_nr, self.enter_flags | linux.IORING_ENTER_GETEVENTS, null);
        return self.copy_cqes_ready(cqes);
    }
    return 0;
}

fn copy_cqes_ready(self: *IoUring, cqes: []linux.io_uring_cqe) u32 {
    const ready = self.cq_ready();
    const count = @min(cqes.len, ready);
    const head = self.cq.head.* & self.cq.mask;

    // before wrapping
    const n = @min(self.cq.cqes.len - head, count);
    @memcpy(cqes[0..n], self.cq.cqes[head..][0..n]);

    if (count > n) {
        // wrap self.cq.cqes
        const w = count - n;
        @memcpy(cqes[n..][0..w], self.cq.cqes[0..w]);
    }

    self.cq_advance(count);
    return count;
}

/// Returns a copy of an I/O completion, waiting for it if necessary, and advancing the CQ ring.
/// A convenience method for `copy_cqes()` for when you don't need to batch or peek.
pub fn copy_cqe(ring: *IoUring) !linux.io_uring_cqe {
    var cqes: [1]linux.io_uring_cqe = undefined;
    while (true) {
        const count = try ring.copy_cqes(&cqes, 1);
        if (count > 0) return cqes[0];
    }
}

/// Matches the implementation of cq_ring_needs_flush() in liburing.
pub fn cq_ring_needs_flush(self: *IoUring) bool {
    return (@atomicLoad(u32, self.sq.flags, .unordered) & linux.IORING_SQ_CQ_OVERFLOW) != 0;
}

/// For advanced use cases only that implement custom completion queue methods.
/// If you use copy_cqes() or copy_cqe() you must not call cqe_seen() or cq_advance().
/// Must be called exactly once after a zero-copy CQE has been processed by your application.
/// Not idempotent, calling more than once will result in other CQEs being lost.
/// Matches the implementation of cqe_seen() in liburing.
pub fn cqe_seen(self: *IoUring, cqe: *linux.io_uring_cqe) void {
    _ = cqe;
    self.cq_advance(1);
}

/// For advanced use cases only that implement custom completion queue methods.
/// Matches the implementation of cq_advance() in liburing.
pub fn cq_advance(self: *IoUring, count: u32) void {
    if (count > 0) {
        // Ensure the kernel only sees the new head value after the CQEs have been read.
        @atomicStore(u32, self.cq.head, self.cq.head.* +% count, .release);
    }
}

/// Toggle of iowait usage when waiting on CQEs. Enabled by default when a ring
/// is created marking a waiting task as being in iowait if it's sleeping
/// waiting on events and there are pending requests. This isn't necessarily
/// always useful, and may be confusing on non-storage setups where iowait isn't
/// expected. It can also cause extra power usage by preventing the CPU from
/// entering lower sleep states.
/// Available since 6.15
pub fn set_iowait(self: *IoUring, enable: bool) !void {
    if (self.features & linux.IORING_FEAT_NO_IOWAIT == 0) {
        return error.SystemOutdated;
    }
    if (enable) {
        self.enter_flags &= ~@as(u8, linux.IORING_ENTER_NO_IOWAIT);
    } else {
        self.enter_flags |= linux.IORING_ENTER_NO_IOWAIT;
    }
}

/// Queues (but does not submit) an SQE to perform an `fsync(2)`.
/// Returns a pointer to the SQE so that you can further modify the SQE for advanced use cases.
/// For example, for `fdatasync()` you can set `IORING_FSYNC_DATASYNC` in the SQE's `rw_flags`.
/// N.B. While SQEs are initiated in the order in which they appear in the submission queue,
/// operations execute in parallel and completions are unordered. Therefore, an application that
/// submits a write followed by an fsync in the submission queue cannot expect the fsync to
/// apply to the write, since the fsync may complete before the write is issued to the disk.
/// You should preferably use `link_with_next_sqe()` on a write's SQE to link it with an fsync,
/// or else insert a full write barrier using `drain_previous_sqes()` when queueing an fsync.
pub fn fsync(self: *IoUring, user_data: u64, fd: linux.fd_t, flags: u32) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_fsync(fd, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a no-op.
/// Returns a pointer to the SQE so that you can further modify the SQE for advanced use cases.
/// A no-op is more useful than may appear at first glance.
/// For example, you could call `drain_previous_sqes()` on the returned SQE, to use the no-op to
/// know when the ring is idle before acting on a kill signal.
pub fn nop(self: *IoUring, user_data: u64) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_nop();
    sqe.user_data = user_data;
    return sqe;
}

/// Used to select how the read should be handled.
pub const ReadBuffer = union(enum) {
    /// io_uring will read directly into this buffer
    buffer: []u8,

    /// io_uring will read directly into these buffers using readv.
    iovecs: []const posix.iovec,

    /// io_uring will select a buffer that has previously been provided with `provide_buffers`.
    /// The buffer group reference by `group_id` must contain at least one buffer for the read to work.
    /// `len` controls the number of bytes to read into the selected buffer.
    buffer_selection: struct {
        group_id: u16,
        len: usize,
    },
};

/// Queues (but does not submit) an SQE to perform a `read(2)` or `preadv(2)` depending on the buffer type.
/// * Reading into a `ReadBuffer.buffer` uses `read(2)`
/// * Reading into a `ReadBuffer.iovecs` uses `preadv(2)`
///   If you want to do a `preadv2(2)` then set `rw_flags` on the returned SQE. See https://man7.org/linux/man-pages/man2/preadv2.2.html
///
/// Returns a pointer to the SQE.
pub fn read(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    buffer: ReadBuffer,
    offset: u64,
) !*Sqe {
    const sqe = try self.get_sqe();
    switch (buffer) {
        .buffer => |slice| sqe.prep_read(fd, slice, offset),
        .iovecs => |vecs| sqe.prep_readv(fd, vecs, offset),
        .buffer_selection => |selection| {
            sqe.prep_rw(.READ, fd, 0, selection.len, offset);
            sqe.flags |= linux.IOSQE_BUFFER_SELECT;
            sqe.buf_index = selection.group_id;
        },
    }
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a `write(2)`.
/// Returns a pointer to the SQE.
pub fn write(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    buffer: []const u8,
    offset: u64,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_write(fd, buffer, offset);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a `splice(2)`
/// Either `fd_in` or `fd_out` must be a pipe.
/// If `fd_in` refers to a pipe, `off_in` is ignored and must be set to std.math.maxInt(u64).
/// If `fd_in` does not refer to a pipe and `off_in` is maxInt(u64), then `len` are read
/// from `fd_in` starting from the file offset, which is incremented by the number of bytes read.
/// If `fd_in` does not refer to a pipe and `off_in` is not maxInt(u64), then the starting offset of `fd_in` will be `off_in`.
/// This splice operation can be used to implement sendfile by splicing to an intermediate pipe first,
/// then splice to the final destination. In fact, the implementation of sendfile in kernel uses splice internally.
///
/// NOTE that even if fd_in or fd_out refers to a pipe, the splice operation can still fail with EINVAL if one of the
/// fd doesn't explicitly support splice peration, e.g. reading from terminal is unsupported from kernel 5.7 to 5.11.
/// See https://github.com/axboe/liburing/issues/291
///
/// Returns a pointer to the SQE so that you can further modify the SQE for advanced use cases.
pub fn splice(self: *IoUring, user_data: u64, fd_in: linux.fd_t, off_in: u64, fd_out: linux.fd_t, off_out: u64, len: usize) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_splice(fd_in, off_in, fd_out, off_out, len);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a IORING_OP_READ_FIXED.
/// The `buffer` provided must be registered with the kernel by calling `register_buffers` first.
/// The `buffer_index` must be the same as its index in the array provided to `register_buffers`.
///
/// Returns a pointer to the SQE so that you can further modify the SQE for advanced use cases.
pub fn read_fixed(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    buffer: *posix.iovec,
    offset: u64,
    buffer_index: u16,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_read_fixed(fd, buffer, offset, buffer_index);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a `pwritev()`.
/// Returns a pointer to the SQE so that you can further modify the SQE for advanced use cases.
/// For example, if you want to do a `pwritev2()` then set `rw_flags` on the returned SQE.
/// See https://linux.die.net/man/2/pwritev.
pub fn writev(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    iovecs: []const posix.iovec_const,
    offset: u64,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_writev(fd, iovecs, offset);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a IORING_OP_WRITE_FIXED.
/// The `buffer` provided must be registered with the kernel by calling `register_buffers` first.
/// The `buffer_index` must be the same as its index in the array provided to `register_buffers`.
///
/// Returns a pointer to the SQE so that you can further modify the SQE for advanced use cases.
pub fn write_fixed(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    buffer: *posix.iovec,
    offset: u64,
    buffer_index: u16,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_write_fixed(fd, buffer, offset, buffer_index);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform an `accept4(2)` on a socket.
/// Returns a pointer to the SQE.
/// Available since 5.5
pub fn accept(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    addr: ?*posix.sockaddr,
    addrlen: ?*posix.socklen_t,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_accept(fd, addr, addrlen, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues an multishot accept on a socket.
///
/// Multishot variant allows an application to issue a single accept request,
/// which will repeatedly trigger a CQE when a connection request comes in.
/// While IORING_CQE_F_MORE flag is set in CQE flags accept will generate
/// further CQEs.
///
/// Available since 5.19
pub fn accept_multishot(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    addr: ?*posix.sockaddr,
    addrlen: ?*posix.socklen_t,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_multishot_accept(fd, addr, addrlen, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues an accept using direct (registered) file descriptors.
///
/// To use an accept direct variant, the application must first have registered
/// a file table (with register_files). An unused table index will be
/// dynamically chosen and returned in the CQE res field.
///
/// After creation, they can be used by setting IOSQE_FIXED_FILE in the SQE
/// flags member, and setting the SQE fd field to the direct descriptor value
/// rather than the regular file descriptor.
///
/// Available since 5.19
pub fn accept_direct(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    addr: ?*posix.sockaddr,
    addrlen: ?*posix.socklen_t,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_accept_direct(fd, addr, addrlen, flags, linux.IORING_FILE_INDEX_ALLOC);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues an multishot accept using direct (registered) file descriptors.
/// Available since 5.19
pub fn accept_multishot_direct(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    addr: ?*posix.sockaddr,
    addrlen: ?*posix.socklen_t,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_multishot_accept_direct(fd, addr, addrlen, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queue (but does not submit) an SQE to perform a `connect(2)` on a socket.
/// Returns a pointer to the SQE.
pub fn connect(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    addr: *const posix.sockaddr,
    addrlen: posix.socklen_t,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_connect(fd, addr, addrlen);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a `epoll_ctl(2)`.
/// Returns a pointer to the SQE.
pub fn epoll_ctl(
    self: *IoUring,
    user_data: u64,
    epfd: linux.fd_t,
    fd: linux.fd_t,
    op: u32,
    ev: ?*linux.epoll_event,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_epoll_ctl(epfd, fd, op, ev);
    sqe.user_data = user_data;
    return sqe;
}

/// Used to select how the recv call should be handled.
pub const RecvBuffer = union(enum) {
    /// io_uring will recv directly into this buffer
    buffer: []u8,

    /// io_uring will select a buffer that has previously been provided with `provide_buffers`.
    /// The buffer group referenced by `group_id` must contain at least one buffer for the recv call to work.
    /// `len` controls the number of bytes to read into the selected buffer.
    buffer_selection: struct {
        group_id: u16,
        len: usize,
    },
};

/// Queues (but does not submit) an SQE to perform a `recv(2)`.
/// Returns a pointer to the SQE.
/// Available since 5.6
pub fn recv(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    buffer: RecvBuffer,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    switch (buffer) {
        .buffer => |slice| sqe.prep_recv(fd, slice, flags),
        .buffer_selection => |selection| {
            sqe.prep_rw(.RECV, fd, 0, selection.len, 0);
            sqe.rw_flags = flags;
            sqe.flags |= linux.IOSQE_BUFFER_SELECT;
            sqe.buf_index = selection.group_id;
        },
    }
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a `send(2)`.
/// Returns a pointer to the SQE.
/// Available since 5.6
pub fn send(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    buffer: []const u8,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_send(fd, buffer, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform an async zerocopy `send(2)`.
///
/// This operation will most likely produce two CQEs. The flags field of the
/// first cqe may likely contain IORING_CQE_F_MORE, which means that there will
/// be a second cqe with the user_data field set to the same value. The user
/// must not modify the data buffer until the notification is posted. The first
/// cqe follows the usual rules and so its res field will contain the number of
/// bytes sent or a negative error code. The notification's res field will be
/// set to zero and the flags field will contain IORING_CQE_F_NOTIF. The two
/// step model is needed because the kernel may hold on to buffers for a long
/// time, e.g. waiting for a TCP ACK. Notifications responsible for controlling
/// the lifetime of the buffers. Even errored requests may generate a
/// notification.
///
/// Available since 6.0
pub fn send_zc(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    buffer: []const u8,
    send_flags: u32,
    zc_flags: u16,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_send_zc(fd, buffer, send_flags, zc_flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform an async zerocopy `send(2)`.
/// Returns a pointer to the SQE.
/// Available since 6.0
pub fn send_zc_fixed(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    buffer: []const u8,
    send_flags: u32,
    zc_flags: u16,
    buf_index: u16,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_send_zc_fixed(fd, buffer, send_flags, zc_flags, buf_index);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a `recvmsg(2)`.
/// Returns a pointer to the SQE.
/// Available since 5.3
pub fn recvmsg(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    msg: *linux.msghdr,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_recvmsg(fd, msg, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a `sendmsg(2)`.
/// Returns a pointer to the SQE.
/// Available since 5.3
pub fn sendmsg(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    msg: *const linux.msghdr_const,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_sendmsg(fd, msg, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform an async zerocopy `sendmsg(2)`.
/// Returns a pointer to the SQE.
/// Available since 6.1
pub fn sendmsg_zc(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    msg: *const linux.msghdr_const,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_sendmsg_zc(fd, msg, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform an `openat(2)`.
/// Returns a pointer to the SQE.
/// Available since 5.6.
pub fn openat(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    path: [*:0]const u8,
    flags: linux.O,
    mode: posix.mode_t,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_openat(fd, path, flags, mode);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues an openat using direct (registered) file descriptors.
///
/// To use an accept direct variant, the application must first have registered
/// a file table (with register_files). An unused table index will be
/// dynamically chosen and returned in the CQE res field.
///
/// After creation, they can be used by setting IOSQE_FIXED_FILE in the SQE
/// flags member, and setting the SQE fd field to the direct descriptor value
/// rather than the regular file descriptor.
///
/// Available since 5.15
pub fn openat_direct(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    path: [*:0]const u8,
    flags: linux.O,
    mode: posix.mode_t,
    file_index: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_openat_direct(fd, path, flags, mode, file_index);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a `close(2)`.
/// Returns a pointer to the SQE.
/// Available since 5.6.
pub fn close(self: *IoUring, user_data: u64, fd: linux.fd_t) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_close(fd);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues close of registered file descriptor.
/// Available since 5.15
pub fn close_direct(self: *IoUring, user_data: u64, file_index: u32) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_close_direct(file_index);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to register a timeout operation.
/// Returns a pointer to the SQE.
///
/// The timeout will complete when either the timeout expires, or after the specified number of
/// events complete (if `count` is greater than `0`).
///
/// `flags` may be `0` for a relative timeout, or `IORING_TIMEOUT_ABS` for an absolute timeout.
///
/// The completion event result will be `-ETIME` if the timeout completed through expiration,
/// `0` if the timeout completed after the specified number of events, or `-ECANCELED` if the
/// timeout was removed before it expired.
///
/// io_uring timeouts use the `CLOCK.MONOTONIC` clock source.
pub fn timeout(
    self: *IoUring,
    user_data: u64,
    ts: *const linux.kernel_timespec,
    count: u32,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_timeout(ts, count, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to remove an existing timeout operation.
/// Returns a pointer to the SQE.
///
/// The timeout is identified by its `user_data`.
///
/// The completion event result will be `0` if the timeout was found and canceled successfully,
/// `-EBUSY` if the timeout was found but expiration was already in progress, or
/// `-ENOENT` if the timeout was not found.
pub fn timeout_remove(
    self: *IoUring,
    user_data: u64,
    timeout_user_data: u64,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_timeout_remove(timeout_user_data, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to add a link timeout operation.
/// Returns a pointer to the SQE.
///
/// You need to set linux.IOSQE_IO_LINK to flags of the target operation
/// and then call this method right after the target operation.
/// See https://lwn.net/Articles/803932/ for detail.
///
/// If the dependent request finishes before the linked timeout, the timeout
/// is canceled. If the timeout finishes before the dependent request, the
/// dependent request will be canceled.
///
/// The completion event result of the link_timeout will be
/// `-ETIME` if the timeout finishes before the dependent request
/// (in this case, the completion event result of the dependent request will
/// be `-ECANCELED`), or
/// `-EALREADY` if the dependent request finishes before the linked timeout.
pub fn link_timeout(
    self: *IoUring,
    user_data: u64,
    ts: *const linux.kernel_timespec,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_link_timeout(ts, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a `poll(2)`.
/// Returns a pointer to the SQE.
pub fn poll_add(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    poll_mask: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_poll_add(fd, poll_mask);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to remove an existing poll operation.
/// Returns a pointer to the SQE.
pub fn poll_remove(
    self: *IoUring,
    user_data: u64,
    target_user_data: u64,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_poll_remove(target_user_data);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to update the user data of an existing poll
/// operation. Returns a pointer to the SQE.
pub fn poll_update(
    self: *IoUring,
    user_data: u64,
    old_user_data: u64,
    new_user_data: u64,
    poll_mask: u32,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_poll_update(old_user_data, new_user_data, poll_mask, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform an `fallocate(2)`.
/// Returns a pointer to the SQE.
pub fn fallocate(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    mode: i32,
    offset: u64,
    len: u64,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_fallocate(fd, mode, offset, len);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform an `statx(2)`.
/// Returns a pointer to the SQE.
pub fn statx(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    path: [:0]const u8,
    flags: u32,
    mask: linux.STATX,
    buf: *linux.Statx,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_statx(fd, path, flags, mask, buf);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to remove an existing operation.
/// Returns a pointer to the SQE.
///
/// The operation is identified by its `user_data`.
///
/// The completion event result will be `0` if the operation was found and canceled successfully,
/// `-EALREADY` if the operation was found but was already in progress, or
/// `-ENOENT` if the operation was not found.
pub fn cancel(
    self: *IoUring,
    user_data: u64,
    cancel_user_data: u64,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_cancel(cancel_user_data, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a `shutdown(2)`.
/// Returns a pointer to the SQE.
///
/// The operation is identified by its `user_data`.
pub fn shutdown(
    self: *IoUring,
    user_data: u64,
    sockfd: posix.socket_t,
    how: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_shutdown(sockfd, how);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a `renameat2(2)`.
/// Returns a pointer to the SQE.
pub fn renameat(
    self: *IoUring,
    user_data: u64,
    old_dir_fd: linux.fd_t,
    old_path: [*:0]const u8,
    new_dir_fd: linux.fd_t,
    new_path: [*:0]const u8,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_renameat(old_dir_fd, old_path, new_dir_fd, new_path, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a `unlinkat(2)`.
/// Returns a pointer to the SQE.
pub fn unlinkat(
    self: *IoUring,
    user_data: u64,
    dir_fd: linux.fd_t,
    path: [*:0]const u8,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_unlinkat(dir_fd, path, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a `mkdirat(2)`.
/// Returns a pointer to the SQE.
pub fn mkdirat(
    self: *IoUring,
    user_data: u64,
    dir_fd: linux.fd_t,
    path: [*:0]const u8,
    mode: posix.mode_t,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_mkdirat(dir_fd, path, mode);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a `symlinkat(2)`.
/// Returns a pointer to the SQE.
pub fn symlinkat(
    self: *IoUring,
    user_data: u64,
    target: [*:0]const u8,
    new_dir_fd: linux.fd_t,
    link_path: [*:0]const u8,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_symlinkat(target, new_dir_fd, link_path);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a `linkat(2)`.
/// Returns a pointer to the SQE.
pub fn linkat(
    self: *IoUring,
    user_data: u64,
    old_dir_fd: linux.fd_t,
    old_path: [*:0]const u8,
    new_dir_fd: linux.fd_t,
    new_path: [*:0]const u8,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_linkat(old_dir_fd, old_path, new_dir_fd, new_path, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to provide a group of buffers used for commands that read/receive data.
/// Returns a pointer to the SQE.
///
/// Provided buffers can be used in `read`, `recv` or `recvmsg` commands via .buffer_selection.
///
/// The kernel expects a contiguous block of memory of size (buffers_count * buffer_size).
pub fn provide_buffers(
    self: *IoUring,
    user_data: u64,
    buffers: [*]u8,
    buffer_size: usize,
    buffers_count: usize,
    group_id: usize,
    buffer_id: usize,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_provide_buffers(buffers, buffer_size, buffers_count, group_id, buffer_id);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to remove a group of provided buffers.
/// Returns a pointer to the SQE.
pub fn remove_buffers(
    self: *IoUring,
    user_data: u64,
    buffers_count: usize,
    group_id: usize,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_remove_buffers(buffers_count, group_id);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform a `waitid(2)`.
/// Returns a pointer to the SQE.
pub fn waitid(
    self: *IoUring,
    user_data: u64,
    id_type: linux.P,
    id: i32,
    infop: *linux.siginfo_t,
    options: u32,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_waitid(id_type, id, infop, options, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Prepares pipe creation request.
/// Available since 6.16
pub fn pipe(
    self: *IoUring,
    user_data: u64,
    fds: *[2]linux.fd_t,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_pipe(fds, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Prepares pipe creation request for direct (registered) file descriptors.
/// Available since 6.16
pub fn pipe_direct(
    self: *IoUring,
    user_data: u64,
    fds: *[2]linux.fd_t,
    flags: u32,
) !*Sqe {
    const sqe = try self.pipe(user_data, fds, flags);
    sqe.splice_fd_in = @bitCast(@as(u32, linux.IORING_FILE_INDEX_ALLOC));
    return sqe;
}

/// Registers an array of file descriptors.
/// Every time a file descriptor is put in an SQE and submitted to the kernel, the kernel must
/// retrieve a reference to the file, and once I/O has completed the file reference must be
/// dropped. The atomic nature of this file reference can be a slowdown for high IOPS workloads.
/// This slowdown can be avoided by pre-registering file descriptors.
/// To refer to a registered file descriptor, IOSQE_FIXED_FILE must be set in the SQE's flags,
/// and the SQE's fd must be set to the index of the file descriptor in the registered array.
/// Registering file descriptors will wait for the ring to idle.
/// Files are automatically unregistered by the kernel when the ring is torn down.
/// An application need unregister only if it wants to register a new array of file descriptors.
pub fn register_files(self: *IoUring, fds: []const linux.fd_t) !void {
    assert(self.fd >= 0);
    const res = linux.io_uring_register(
        self.fd,
        .REGISTER_FILES,
        @as(*const anyopaque, @ptrCast(fds.ptr)),
        @as(u32, @intCast(fds.len)),
    );
    try handle_registration_result(res);
}

/// Updates registered file descriptors.
///
/// Updates are applied starting at the provided offset in the original file descriptors slice.
/// There are three kind of updates:
/// * turning a sparse entry (where the fd is -1) into a real one
/// * removing an existing entry (set the fd to -1)
/// * replacing an existing entry with a new fd
/// Adding new file descriptors must be done with `register_files`.
pub fn register_files_update(self: *IoUring, offset: u32, fds: []const linux.fd_t) !void {
    assert(self.fd >= 0);

    const FilesUpdate = extern struct {
        offset: u32,
        resv: u32,
        fds: u64 align(8),
    };
    var update = FilesUpdate{
        .offset = offset,
        .resv = @as(u32, 0),
        .fds = @as(u64, @intFromPtr(fds.ptr)),
    };

    const res = linux.io_uring_register(
        self.fd,
        .REGISTER_FILES_UPDATE,
        @as(*const anyopaque, @ptrCast(&update)),
        @as(u32, @intCast(fds.len)),
    );
    try handle_registration_result(res);
}

/// Registers an empty (-1) file table of `nr_files` number of file descriptors.
pub fn register_files_sparse(self: *IoUring, nr_files: u32) !void {
    assert(self.fd >= 0);

    const reg = &linux.io_uring_rsrc_register{
        .nr = nr_files,
        .flags = linux.IORING_RSRC_REGISTER_SPARSE,
        .resv2 = 0,
        .data = 0,
        .tags = 0,
    };

    const res = linux.io_uring_register(
        self.fd,
        .REGISTER_FILES2,
        @ptrCast(reg),
        @as(u32, @sizeOf(linux.io_uring_rsrc_register)),
    );

    return handle_registration_result(res);
}

// Registers range for fixed file allocations.
// Available since 6.0
pub fn register_file_alloc_range(self: *IoUring, offset: u32, len: u32) !void {
    assert(self.fd >= 0);

    const range = &linux.io_uring_file_index_range{
        .off = offset,
        .len = len,
        .resv = 0,
    };

    const res = linux.io_uring_register(
        self.fd,
        .REGISTER_FILE_ALLOC_RANGE,
        @ptrCast(range),
        @as(u32, @sizeOf(linux.io_uring_file_index_range)),
    );

    return handle_registration_result(res);
}

/// Registers the file descriptor for an eventfd that will be notified of completion events on
///  an io_uring instance.
/// Only a single a eventfd can be registered at any given point in time.
pub fn register_eventfd(self: *IoUring, fd: linux.fd_t) !void {
    assert(self.fd >= 0);
    const res = linux.io_uring_register(
        self.fd,
        .REGISTER_EVENTFD,
        @as(*const anyopaque, @ptrCast(&fd)),
        1,
    );
    try handle_registration_result(res);
}

/// Registers the file descriptor for an eventfd that will be notified of completion events on
/// an io_uring instance. Notifications are only posted for events that complete in an async manner.
/// This means that events that complete inline while being submitted do not trigger a notification event.
/// Only a single eventfd can be registered at any given point in time.
pub fn register_eventfd_async(self: *IoUring, fd: linux.fd_t) !void {
    assert(self.fd >= 0);
    const res = linux.io_uring_register(
        self.fd,
        .REGISTER_EVENTFD_ASYNC,
        @as(*const anyopaque, @ptrCast(&fd)),
        1,
    );
    try handle_registration_result(res);
}

/// Unregister the registered eventfd file descriptor.
pub fn unregister_eventfd(self: *IoUring) !void {
    assert(self.fd >= 0);
    const res = linux.io_uring_register(
        self.fd,
        .UNREGISTER_EVENTFD,
        null,
        0,
    );
    try handle_registration_result(res);
}

pub fn register_napi(self: *IoUring, napi: *linux.io_uring_napi) !void {
    assert(self.fd >= 0);
    const res = linux.io_uring_register(self.fd, .REGISTER_NAPI, napi, 1);
    try handle_registration_result(res);
}

pub fn unregister_napi(self: *IoUring, napi: *linux.io_uring_napi) !void {
    assert(self.fd >= 0);
    const res = linux.io_uring_register(self.fd, .UNREGISTER_NAPI, napi, 1);
    try handle_registration_result(res);
}

/// Registers an array of buffers for use with `read_fixed` and `write_fixed`.
pub fn register_buffers(self: *IoUring, buffers: []const posix.iovec) !void {
    assert(self.fd >= 0);
    const res = linux.io_uring_register(
        self.fd,
        .REGISTER_BUFFERS,
        buffers.ptr,
        @as(u32, @intCast(buffers.len)),
    );
    try handle_registration_result(res);
}

/// Unregister the registered buffers.
pub fn unregister_buffers(self: *IoUring) !void {
    assert(self.fd >= 0);
    const res = linux.io_uring_register(self.fd, .UNREGISTER_BUFFERS, null, 0);
    switch (linux.errno(res)) {
        .SUCCESS => {},
        .NXIO => return error.BuffersNotRegistered,
        else => |errno| return posix.unexpectedErrno(errno),
    }
}

/// Returns a io_uring_probe which is used to probe the capabilities of the
/// io_uring subsystem of the running kernel. The io_uring_probe contains the
/// list of supported operations.
pub fn get_probe(self: *IoUring) !linux.io_uring_probe {
    var probe = std.mem.zeroInit(linux.io_uring_probe, .{});
    const res = linux.io_uring_register(self.fd, .REGISTER_PROBE, &probe, probe.ops.len);
    try handle_register_buf_ring_result(res);
    return probe;
}

fn handle_registration_result(res: usize) !void {
    switch (linux.errno(res)) {
        .SUCCESS => {},
        // One or more fds in the array are invalid, or the kernel does not support sparse sets:
        .BADF => return error.FileDescriptorInvalid,
        .BUSY => return error.FilesAlreadyRegistered,
        .INVAL => return error.FilesEmpty,
        // Adding `nr_args` file references would exceed the maximum allowed number of files the
        // user is allowed to have according to the per-user RLIMIT_NOFILE resource limit and
        // the CAP_SYS_RESOURCE capability is not set, or `nr_args` exceeds the maximum allowed
        // for a fixed file set (older kernels have a limit of 1024 files vs 64K files):
        .MFILE => return error.UserFdQuotaExceeded,
        // Insufficient kernel resources, or the caller had a non-zero RLIMIT_MEMLOCK soft
        // resource limit but tried to lock more memory than the limit permitted (not enforced
        // when the process is privileged with CAP_IPC_LOCK):
        .NOMEM => return error.SystemResources,
        // Attempt to register files on a ring already registering files or being torn down:
        .NXIO => return error.RingShuttingDownOrAlreadyRegisteringFiles,
        else => |errno| return posix.unexpectedErrno(errno),
    }
}

/// Unregisters all registered file descriptors previously associated with the ring.
pub fn unregister_files(self: *IoUring) !void {
    assert(self.fd >= 0);
    const res = linux.io_uring_register(self.fd, .UNREGISTER_FILES, null, 0);
    switch (linux.errno(res)) {
        .SUCCESS => {},
        .NXIO => return error.FilesNotRegistered,
        else => |errno| return posix.unexpectedErrno(errno),
    }
}

/// Prepares a socket creation request.
/// New socket fd will be returned in completion result.
/// Available since 5.19
pub fn socket(
    self: *IoUring,
    user_data: u64,
    domain: u32,
    socket_type: u32,
    protocol: u32,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_socket(domain, socket_type, protocol, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Prepares a socket creation request for registered file at index `file_index`.
/// Available since 5.19
pub fn socket_direct(
    self: *IoUring,
    user_data: u64,
    domain: u32,
    socket_type: u32,
    protocol: u32,
    flags: u32,
    file_index: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_socket_direct(domain, socket_type, protocol, flags, file_index);
    sqe.user_data = user_data;
    return sqe;
}

/// Prepares a socket creation request for registered file, index chosen by kernel (file index alloc).
/// File index will be returned in CQE res field.
/// Available since 5.19
pub fn socket_direct_alloc(
    self: *IoUring,
    user_data: u64,
    domain: u32,
    socket_type: u32,
    protocol: u32,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_socket_direct_alloc(domain, socket_type, protocol, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform an `bind(2)` on a socket.
/// Returns a pointer to the SQE.
/// Available since 6.11
pub fn bind(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    addr: *const posix.sockaddr,
    addrlen: posix.socklen_t,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_bind(fd, addr, addrlen, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Queues (but does not submit) an SQE to perform an `listen(2)` on a socket.
/// Returns a pointer to the SQE.
/// Available since 6.11
pub fn listen(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    backlog: usize,
    flags: u32,
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_listen(fd, backlog, flags);
    sqe.user_data = user_data;
    return sqe;
}

/// Prepares an cmd request for a socket.
/// See: https://man7.org/linux/man-pages/man3/io_uring_prep_cmd.3.html
/// Available since 6.7.
pub fn cmd_sock(
    self: *IoUring,
    user_data: u64,
    cmd_op: linux.IO_URING_SOCKET_OP,
    fd: linux.fd_t,
    level: u32, // linux.SOL
    optname: u32, // linux.SO
    optval: u64, // pointer to the option value
    optlen: u32, // size of the option value
) !*Sqe {
    const sqe = try self.get_sqe();
    sqe.prep_cmd_sock(cmd_op, fd, level, optname, optval, optlen);
    sqe.user_data = user_data;
    return sqe;
}

/// Prepares set socket option for the optname argument, at the protocol
/// level specified by the level argument.
/// Available since 6.7.n
pub fn setsockopt(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    level: u32, // linux.SOL
    optname: u32, // linux.SO
    opt: []const u8,
) !*Sqe {
    return try self.cmd_sock(
        user_data,
        .SETSOCKOPT,
        fd,
        level,
        optname,
        @intFromPtr(opt.ptr),
        @intCast(opt.len),
    );
}

/// Prepares get socket option to retrieve the value for the option specified by
/// the option_name argument for the socket specified by the fd argument.
/// Available since 6.7.
pub fn getsockopt(
    self: *IoUring,
    user_data: u64,
    fd: linux.fd_t,
    level: u32, // linux.SOL
    optname: u32, // linux.SO
    opt: []u8,
) !*Sqe {
    return try self.cmd_sock(
        user_data,
        .GETSOCKOPT,
        fd,
        level,
        optname,
        @intFromPtr(opt.ptr),
        @intCast(opt.len),
    );
}

/// Performs resizes of the SQ and CQ rings. Any pending SQ or CQ entries are
/// copied along the way. Resizing is only supported on rings initialized with
/// IORING_SETUP_DEFER_TASKRUN (which also requires IORING_SETUP_SINGLE_ISSUER).
/// If `cq_entries` is 0 CQ ring size will be set to default (like in init),
/// which is 2 times the SQ size. Max rings size is clamped to 32K for SQ, 64K
/// for CQ.
/// Available since kernel 6.13.
pub fn resize(self: *IoUring, sq_entries: u32, cq_entries: u32) !void {
    if (sq_entries == 0) return error.EntriesZero;
    if (!std.math.isPowerOfTwo(sq_entries)) return error.EntriesNotPowerOfTwo;
    var flags: u32 = linux.IORING_SETUP_CLAMP;
    if (cq_entries > 0) {
        if (!std.math.isPowerOfTwo(cq_entries)) return error.EntriesNotPowerOfTwo;
        flags |= linux.IORING_SETUP_CQSIZE;
    }
    var p = std.mem.zeroInit(linux.io_uring_params, .{
        .sq_entries = sq_entries,
        .cq_entries = cq_entries,
        .flags = flags,
    });
    try resize_params(self, &p);
}

/// Matches the interface of io_uring_resize_rings() in liburing.
fn resize_params(self: *IoUring, p: *linux.io_uring_params) !void {
    // Need to sync internal state before resize
    _ = self.flush_sq();
    // Register rings resize
    p.features |= linux.IORING_FEAT_SINGLE_MMAP; // asserted in SubmissionQueue.init
    const res = linux.io_uring_register(self.fd, .REGISTER_RESIZE_RINGS, p, 1);
    switch (linux.errno(res)) {
        .SUCCESS => {},
        // Attempting to resize a ring setup with IORING_SETUP_SINGLE_ISSUER and
        // the resizing task is different from the one that created/enabled the
        // ring.
        .EXIST => return error.InvalidThread,
        // Copying of p was unsuccessful.
        .FAULT => return error.Fault,
        // Invalid flags were specified for the operation or attempt to resize a
        // ring not setup with IORING_SETUP_DEFER_TASKRUN.
        .INVAL => return error.ArgumentsInvalid,
        // The values specified for SQ or CQ entries would cause an overflow.
        .OVERFLOW => return error.Overflow,
        .NOSYS => return error.SystemOutdated,
        else => |ern| return posix.unexpectedErrno(ern),
    }
    // Create new submission and completion queues
    var sq = try linux.IoUring.SubmissionQueue.init(self.fd, p.*);
    errdefer sq.deinit();
    var cq = try linux.IoUring.CompletionQueue.init(self.fd, p.*, sq);
    errdefer cq.deinit();
    // Copy pointers from previous submission queue
    sq.sqe_head = self.sq.sqe_head;
    sq.sqe_tail = self.sq.sqe_tail;
    // Replace queues in the ring
    self.sq.deinit();
    self.sq = sq;
    self.cq.deinit();
    self.cq = cq;
}

pub const SubmissionQueue = struct {
    head: *u32,
    tail: *u32,
    mask: u32,
    flags: *u32,
    dropped: *u32,
    array: []u32,
    sqes: []Sqe,
    mmap: []align(page_size_min) u8,
    mmap_sqes: []align(page_size_min) u8,

    // We use `sqe_head` and `sqe_tail` in the same way as liburing:
    // We increment `sqe_tail` (but not `tail`) for each call to `get_sqe()`.
    // We then set `tail` to `sqe_tail` once, only when these events are actually submitted.
    // This allows us to amortize the cost of the @atomicStore to `tail` across multiple SQEs.
    sqe_head: u32 = 0,
    sqe_tail: u32 = 0,

    pub fn init(fd: linux.fd_t, p: linux.io_uring_params) !SubmissionQueue {
        assert(fd >= 0);
        assert((p.features & linux.IORING_FEAT_SINGLE_MMAP) != 0);
        const size = @max(
            p.sq_off.array + p.sq_entries * @sizeOf(u32),
            p.cq_off.cqes + p.cq_entries * @sizeOf(linux.io_uring_cqe),
        );
        const mmap = try posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED, .POPULATE = true },
            fd,
            linux.IORING_OFF_SQ_RING,
        );
        errdefer posix.munmap(mmap);
        assert(mmap.len == size);

        // The motivation for the `sqes` and `array` indirection is to make it possible for the
        // application to preallocate static Sqe entries and then replay them when needed.
        const size_sqes = p.sq_entries * @sizeOf(Sqe);
        const mmap_sqes = try posix.mmap(
            null,
            size_sqes,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED, .POPULATE = true },
            fd,
            linux.IORING_OFF_SQES,
        );
        errdefer posix.munmap(mmap_sqes);
        assert(mmap_sqes.len == size_sqes);

        const c_array: [*]u32 = @ptrCast(@alignCast(&mmap[p.sq_off.array]));
        const array = if (p.flags & linux.IORING_SETUP_NO_SQARRAY != 0)
            c_array[0..0]
        else
            c_array[0..p.sq_entries];
        for (0..array.len) |i| {
            array[i] = @intCast(i);
        }

        const sqes: [*]Sqe = @ptrCast(@alignCast(&mmap_sqes[0]));
        // We expect the kernel copies p.sq_entries to the u32 pointed to by p.sq_off.ring_entries,
        // see https://github.com/torvalds/linux/blob/v5.8/fs/io_uring.c#L7843-L7844.
        assert(p.sq_entries == @as(*u32, @ptrCast(@alignCast(&mmap[p.sq_off.ring_entries]))).*);
        return SubmissionQueue{
            .head = @ptrCast(@alignCast(&mmap[p.sq_off.head])),
            .tail = @ptrCast(@alignCast(&mmap[p.sq_off.tail])),
            .mask = @as(*u32, @ptrCast(@alignCast(&mmap[p.sq_off.ring_mask]))).*,
            .flags = @ptrCast(@alignCast(&mmap[p.sq_off.flags])),
            .dropped = @ptrCast(@alignCast(&mmap[p.sq_off.dropped])),
            .array = array,
            .sqes = sqes[0..p.sq_entries],
            .mmap = mmap,
            .mmap_sqes = mmap_sqes,
        };
    }

    pub fn deinit(self: *SubmissionQueue) void {
        posix.munmap(self.mmap_sqes);
        posix.munmap(self.mmap);
    }
};

pub const CompletionQueue = struct {
    head: *u32,
    tail: *u32,
    mask: u32,
    overflow: *u32,
    cqes: []linux.io_uring_cqe,

    pub fn init(fd: linux.fd_t, p: linux.io_uring_params, sq: SubmissionQueue) !CompletionQueue {
        assert(fd >= 0);
        assert((p.features & linux.IORING_FEAT_SINGLE_MMAP) != 0);
        const mmap = sq.mmap;
        const cqes: [*]linux.io_uring_cqe = @ptrCast(@alignCast(&mmap[p.cq_off.cqes]));
        assert(p.cq_entries == @as(*u32, @ptrCast(@alignCast(&mmap[p.cq_off.ring_entries]))).*);
        return CompletionQueue{
            .head = @ptrCast(@alignCast(&mmap[p.cq_off.head])),
            .tail = @ptrCast(@alignCast(&mmap[p.cq_off.tail])),
            .mask = @as(*u32, @ptrCast(@alignCast(&mmap[p.cq_off.ring_mask]))).*,
            .overflow = @ptrCast(@alignCast(&mmap[p.cq_off.overflow])),
            .cqes = cqes[0..p.cq_entries],
        };
    }

    pub fn deinit(self: *CompletionQueue) void {
        _ = self;
        // A no-op since we now share the mmap with the submission queue.
        // Here for symmetry with the submission queue, and for any future feature support.
    }
};

/// Registers a shared buffer ring to be used with provided buffers.
/// `entries` number of `io_uring_buf` structures is mem mapped and shared by kernel.
/// `fd` is IO_Uring.fd for which the provided buffer ring is being registered.
/// `entries` is the number of entries requested in the buffer ring, must be power of 2.
/// `group_id` is the chosen buffer group ID, unique in IO_Uring.
pub fn setup_buf_ring(
    fd: linux.fd_t,
    entries: u16,
    group_id: u16,
    flags: linux.io_uring_buf_reg.Flags,
) !*align(page_size_min) linux.io_uring_buf_ring {
    if (entries == 0 or entries > 1 << 15) return error.EntriesNotInRange;
    if (!std.math.isPowerOfTwo(entries)) return error.EntriesNotPowerOfTwo;

    const mmap_size = @as(usize, entries) * @sizeOf(linux.io_uring_buf);
    const mmap = try posix.mmap(
        null,
        mmap_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    errdefer posix.munmap(mmap);
    assert(mmap.len == mmap_size);

    const br: *align(page_size_min) linux.io_uring_buf_ring = @ptrCast(mmap.ptr);
    try register_buf_ring(fd, @intFromPtr(br), entries, group_id, flags);
    return br;
}

fn register_buf_ring(
    fd: linux.fd_t,
    addr: u64,
    entries: u32,
    group_id: u16,
    flags: linux.io_uring_buf_reg.Flags,
) !void {
    var reg = std.mem.zeroInit(linux.io_uring_buf_reg, .{
        .ring_addr = addr,
        .ring_entries = entries,
        .bgid = group_id,
        .flags = flags,
    });
    const res = linux.io_uring_register(fd, .REGISTER_PBUF_RING, @as(*const anyopaque, @ptrCast(&reg)), 1);
    try handle_register_buf_ring_result(res);
}

fn unregister_buf_ring(fd: linux.fd_t, group_id: u16) !void {
    var reg = std.mem.zeroInit(linux.io_uring_buf_reg, .{
        .bgid = group_id,
    });
    const res = linux.io_uring_register(
        fd,
        .UNREGISTER_PBUF_RING,
        @as(*const anyopaque, @ptrCast(&reg)),
        1,
    );
    try handle_register_buf_ring_result(res);
}

fn handle_register_buf_ring_result(res: usize) !void {
    switch (linux.errno(res)) {
        .SUCCESS => {},
        .INVAL => return error.ArgumentsInvalid,
        else => |errno| return posix.unexpectedErrno(errno),
    }
}

/// Unregisters a previously registered shared buffer ring, returned from io_uring_setup_buf_ring.
pub fn free_buf_ring(fd: linux.fd_t, br: *align(page_size_min) linux.io_uring_buf_ring, entries: u32, group_id: u16) void {
    unregister_buf_ring(fd, group_id) catch {};
    var mmap: []align(page_size_min) u8 = undefined;
    mmap.ptr = @ptrCast(br);
    mmap.len = entries * @sizeOf(linux.io_uring_buf);
    posix.munmap(mmap);
}

/// Initialises `br` so that it is ready to be used.
pub fn buf_ring_init(br: *linux.io_uring_buf_ring) void {
    br.tail = 0;
}

/// Calculates the appropriate size mask for a buffer ring.
/// `entries` is the ring entries as specified in io_uring_register_buf_ring.
pub fn buf_ring_mask(entries: u16) u16 {
    return entries - 1;
}

/// Assigns `buffer` with the `br` buffer ring.
/// `buffer_id` is identifier which will be returned in the CQE.
/// `buffer_offset` is the offset to insert at from the current tail.
/// If just one buffer is provided before the ring tail is committed with advance then offset should be 0.
/// If buffers are provided in a loop before being committed, the offset must be incremented by one for each buffer added.
pub fn buf_ring_add(
    br: *linux.io_uring_buf_ring,
    buffer: []u8,
    buffer_id: u16,
    mask: u16,
    buffer_offset: u16,
) void {
    const bufs: [*]linux.io_uring_buf = @ptrCast(br);
    const buf: *linux.io_uring_buf = &bufs[(br.tail +% buffer_offset) & mask];

    buf.addr = @intFromPtr(buffer.ptr);
    buf.len = @intCast(buffer.len);
    buf.bid = buffer_id;
}

/// Make `count` new buffers visible to the kernel. Called after
/// `io_uring_buf_ring_add` has been called `count` times to fill in new buffers.
pub fn buf_ring_advance(br: *linux.io_uring_buf_ring, count: u16) void {
    const tail: u16 = br.tail +% count;
    @atomicStore(u16, &br.tail, tail, .release);
}
