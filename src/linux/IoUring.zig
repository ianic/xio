const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const linux = std.os.linux;
const linuxx = @import("linuxx.zig");

pub const Sqe = @import("io_uring_sqe.zig").Sqe;
pub const Cqe = CompletionQueue.Entry;

const IoUring = @This();

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
    return IoUring.initParams(entries, &params) catch |err| {
        if (flags & linux.IORING_SETUP_NO_SQARRAY == 0 and err == error.ArgumentsInvalid) {
            // fallback with sq array
            params.flags = flags;
            return try IoUring.initParams(entries, &params);
        }
        return err;
    };
}

/// A powerful way to setup an io_uring, if you want to tweak linux.io_uring_params such as submission
/// queue thread cpu affinity or thread idle timeout (the kernel and our default is 1 second).
/// `params` is passed by reference because the kernel needs to modify the parameters.
/// Matches the interface of io_uring_queue_init_params() in liburing.
pub fn initParams(entries: u16, p: *linux.io_uring_params) !IoUring {
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
pub fn getSqe(self: *IoUring) !*Sqe {
    const head = @atomicLoad(u32, self.sq.head, .acquire);
    // Remember that these head and tail offsets wrap around every four billion operations.
    // We must therefore use wrapping addition and subtraction to avoid a runtime crash.
    const next = self.sq.sqe_tail +% 1;
    if (next -% head > self.sq.sqes.len) return error.SubmissionQueueFull;
    const sqe = &self.sq.sqes[self.sq.sqe_tail & self.sq.mask];
    self.sq.sqe_tail = next;
    return sqe;
}

pub const SubmitWait = struct {
    /// Number of completions to wait for.
    nr: u32 = 0,
    /// Timeout to wait:
    ///   - when min_wait_usec == 0 for `wait_nr` completions
    ///   - when min_wait_usec > 0  for any number of completions
    /// Requires IORING_FEAT_EXT_ARG set in features.
    /// Available since kernel 5.11.
    timeout: ?*const linux.kernel_timespec = null,
    /// Number of microseconds to wait for the full completions batch.
    /// Requires IORING_FEAT_MIN_TIMEOUT set in features.
    /// Available since kernel 6.12.
    min_wait_usec: u32 = 0,
};

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
pub fn submit(self: *IoUring, wait: SubmitWait) !u32 {
    const pending_sqes = self.flush_sq();
    var flags: u32 = self.enter_flags;
    const cq_needs_enter = self.cq_ring_needs_enter() or wait.nr > 0;
    if (cq_needs_enter or self.sq_ring_needs_enter(&flags)) {
        if (cq_needs_enter) {
            flags |= linux.IORING_ENTER_GETEVENTS;
        }

        if (wait.nr == 0 or (wait.timeout == null and wait.min_wait_usec == 0)) {
            return try self.enter(pending_sqes, wait.nr, flags, null);
        }

        if (self.features & linux.IORING_FEAT_EXT_ARG == 0)
            return error.SystemOutdated;
        if (wait.min_wait_usec > 0 and (self.features & linuxx.IORING_FEAT_MIN_TIMEOUT == 0))
            return error.SystemOutdated;

        const arg = std.mem.zeroInit(linuxx.io_uring_getevents_arg, .{
            .sigmask_sz = linux.NSIG / 8,
            .ts = @intFromPtr(wait.timeout),
            .min_wait_usec = wait.min_wait_usec,
        });
        return try self.enter(pending_sqes, wait.nr, flags, &arg);
    }
    return pending_sqes;
}

fn cq_ring_needs_enter(self: *IoUring) bool {
    // IOPOLL always needs to enter, except if SQPOLL is set as well.
    return (self.flags & (linux.IORING_SETUP_IOPOLL | linux.IORING_SETUP_SQPOLL) == linux.IORING_SETUP_IOPOLL) or
        self.cq_ring_needs_flush();
}

/// Tell the kernel we have submitted SQEs and/or want to wait for CQEs.
/// Returns the number of SQEs submitted.
fn enter(
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
fn flush_sq(self: *IoUring) u32 {
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
fn sq_ring_needs_enter(self: *IoUring, flags: *u32) bool {
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
fn sq_ready(self: *IoUring) u32 {
    // Always use the shared ring state (i.e. head and not sqe_head) to avoid going out of sync,
    // see https://github.com/axboe/liburing/issues/92.
    return self.sq.sqe_tail -% @atomicLoad(u32, self.sq.head, .acquire);
}

/// Returns the number of CQEs in the completion queue, i.e. its length.
/// These are CQEs that the application is yet to consume.
/// Matches the implementation of io_uring_cq_ready in liburing.
fn cq_ready(self: *IoUring) u32 {
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
fn copy_cqes(self: *IoUring, cqes: []Cqe, wait_nr: u32) !u32 {
    const count = self.copyReadyCqes(cqes);
    if (count > 0) return count;
    if (self.cq_ring_needs_flush() or wait_nr > 0) {
        _ = try self.enter(0, wait_nr, self.enter_flags | linux.IORING_ENTER_GETEVENTS, null);
        return self.copyReadyCqes(cqes);
    }
    return 0;
}

pub fn copyReadyCqes(self: *IoUring, cqes: []Cqe) u32 {
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
fn copy_cqe(ring: *IoUring) !Cqe {
    var cqes: [1]Cqe = undefined;
    while (true) {
        const count = try ring.copy_cqes(&cqes, 1);
        if (count > 0) return cqes[0];
    }
}

/// Matches the implementation of cq_ring_needs_flush() in liburing.
fn cq_ring_needs_flush(self: *IoUring) bool {
    return (@atomicLoad(u32, self.sq.flags, .unordered) &
        (linux.IORING_SQ_CQ_OVERFLOW | linux.IORING_SQ_TASKRUN)) != 0;
}

/// For advanced use cases only that implement custom completion queue methods.
/// Matches the implementation of cq_advance() in liburing.
fn cq_advance(self: *IoUring, count: u32) void {
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
pub fn setIowait(self: *IoUring, enable: bool) !void {
    if (self.features & linux.IORING_FEAT_NO_IOWAIT == 0) {
        return error.SystemOutdated;
    }
    if (enable) {
        self.enter_flags &= ~@as(u8, linux.IORING_ENTER_NO_IOWAIT);
    } else {
        self.enter_flags |= linux.IORING_ENTER_NO_IOWAIT;
    }
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
    try resizeParams(self, &p);
}

/// Matches the interface of io_uring_resize_rings() in liburing.
fn resizeParams(self: *IoUring, p: *linux.io_uring_params) !void {
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
    const page_align = std.heap.page_size_min;

    head: *u32,
    tail: *u32,
    mask: u32,
    flags: *u32,
    dropped: *u32,
    array: []u32,
    sqes: []Sqe,
    mmap: []align(page_align) u8,
    mmap_sqes: []align(page_align) u8,

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
            p.cq_off.cqes + p.cq_entries * @sizeOf(Cqe),
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
    cqes: []Cqe,

    pub const Entry = extern struct {
        /// io_uring_sqe.data submission passed back
        user_data: u64,

        /// result code for this event
        res: i32,
        flags: u32,

        pub fn err(self: Entry) linux.E {
            if (self.res > -4096 and self.res < 0) {
                return @as(linux.E, @fromBackingInt(@intCast(-self.res)));
            }
            return .SUCCESS;
        }
    };

    pub fn init(fd: linux.fd_t, p: linux.io_uring_params, sq: SubmissionQueue) !CompletionQueue {
        assert(fd >= 0);
        assert((p.features & linux.IORING_FEAT_SINGLE_MMAP) != 0);
        const mmap = sq.mmap;
        const cqes: [*]Cqe = @ptrCast(@alignCast(&mmap[p.cq_off.cqes]));
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
