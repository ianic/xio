const addressFromPosix = Io.Threaded.addressFromPosix;
const addressToPosix = Io.Threaded.addressToPosix;
const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;
const Argv0 = Io.Threaded.Argv0;
const assert = std.debug.assert;
const builtin = @import("builtin");
const ChdirError = Io.Threaded.ChdirError;
const clockToPosix = Io.Threaded.clockToPosix;
const Csprng = Io.Threaded.Csprng;
const default_PATH = Io.Threaded.default_PATH;
const Dir = Io.Dir;
const Environ = Io.Threaded.Environ;
const errnoBug = Io.Threaded.errnoBug;
const Evented = @This();
const fallbackSeed = Io.Threaded.fallbackSeed;
const fd_t = linux.fd_t;
const File = Io.File;
const Io = std.Io;
const IoUring = @import("linux/IoUring.zig");
const iovec = std.posix.iovec;
const iovec_const = std.posix.iovec_const;
const linux = std.os.linux;
const linux_statx_request = Io.Threaded.linux_statx_request;
const LOCK = std.posix.LOCK;
const log = std.log.scoped(.@"io-uring");
const max_iovecs_len = Io.Threaded.max_iovecs_len;
const nanosecondsFromPosix = Io.Threaded.nanosecondsFromPosix;
const net = Io.net;
const PATH_MAX = linux.PATH_MAX;
const pathToPosix = Io.Threaded.pathToPosix;
const pid_t = linux.pid_t;
const PosixAddress = Io.Threaded.PosixAddress;
const posixAddressFamily = Io.Threaded.posixAddressFamily;
const posixSocketModeProtocol = Io.Threaded.posixSocketModeProtocol;
const process = std.process;
const recoverableOsBugDetected = Io.Threaded.recoverableOsBugDetected;
const setTimestampToPosix = Io.Threaded.setTimestampToPosix;
const splat_buffer_size = Io.Threaded.splat_buffer_size;
const statFromLinux = Io.Threaded.statFromLinux;
const statxKind = Io.Threaded.statxKind;
const std = @import("std");
const timestampFromPosix = Io.Threaded.timestampFromPosix;
const unexpectedErrno = std.posix.unexpectedErrno;
const winsize = std.posix.winsize;

/// Empirically saw >128KB being used by the self-hosted backend to panic.
/// Empirically saw glibc complain about 256KB.
const idle_stack_size = 512 * 1024;

backing_allocator: Allocator,
allocated_slice: []align(@alignOf(usize)) u8,
main_fiber_buffer: [
    std.mem.alignForward(usize, @sizeOf(Fiber), @alignOf(Completion)) + @sizeOf(Completion)
]u8 align(@max(@alignOf(Fiber), @alignOf(Completion))),

stderr_writer_initialized: bool = false,
stderr_mutex: Io.Mutex,
stderr_writer: File.Writer = .{
    .io = undefined,
    .interface = Io.File.Writer.initInterface(&.{}),
    .file = .stderr(),
    .mode = .streaming,
},
stderr_mode: Io.Terminal.Mode = .no_color,

environ_mutex: Io.Mutex,
environ_initialized: bool,
environ: Environ,

null_fd: CachedFd,
random_fd: CachedFd,
csprng: Csprng,

idle_context: Io.fiber.Context,
current_context: *Io.fiber.Context,
ready_queue: ?*Fiber,
free_queue: ?*Fiber,
io_uring: IoUring,

op_getsockname_supported: bool = true,

const Fiber = struct {
    required_align: void align(4),
    context: Io.fiber.Context,
    link: union {
        awaiter: ?*Fiber,
        group: struct { prev: ?*Fiber, next: ?*Fiber },
    },
    status: union(enum) {
        queue_next: ?*Fiber,
        awaiting_group: Group,
        free_next: ?*Fiber,
    },
    cancel_status: CancelStatus,
    cancel_protection: CancelProtection,

    const CancelStatus = struct {
        requested: bool,
        awaiting: Awaiting,

        const unrequested: CancelStatus = .{ .requested = false, .awaiting = .nothing };

        const Awaiting = enum {
            nothing,
            group,
            operation,
        };

        fn changeAwaiting(
            cancel_status: *CancelStatus,
            old_awaiting: Awaiting,
            new_awaiting: Awaiting,
        ) bool {
            assert(cancel_status.awaiting == old_awaiting);
            cancel_status.awaiting = new_awaiting;
            return cancel_status.requested;
        }
    };

    const CancelProtection = packed struct {
        user: Io.CancelProtection,
        acknowledged: bool,

        const unblocked: CancelProtection = .{ .user = .unblocked, .acknowledged = false };

        fn check(cancel_protection: CancelProtection) Io.CancelProtection {
            return @fromBackingInt(@intCast(@intFromBool(cancel_protection != unblocked)));
        }

        fn acknowledge(cancel_protection: *CancelProtection) void {
            assert(!cancel_protection.acknowledged);
            cancel_protection.acknowledged = true;
        }

        fn recancel(cancel_protection: *CancelProtection) void {
            assert(cancel_protection.acknowledged);
            cancel_protection.acknowledged = false;
        }

        test check {
            try std.testing.expectEqual(Io.CancelProtection.unblocked, check(.unblocked));
            try std.testing.expectEqual(Io.CancelProtection.blocked, check(.{
                .user = .unblocked,
                .acknowledged = true,
            }));
            try std.testing.expectEqual(Io.CancelProtection.blocked, check(.{
                .user = .blocked,
                .acknowledged = false,
            }));
            try std.testing.expectEqual(Io.CancelProtection.blocked, check(.{
                .user = .blocked,
                .acknowledged = true,
            }));
        }
    };

    const finished: ?*Fiber = @ptrFromInt(@alignOf(Fiber));

    const max_result_align: Alignment = .@"16";
    const max_result_size = max_result_align.forward(512);
    /// This includes any stack realignments that need to happen, and also the
    /// initial frame return address slot and argument frame, depending on target.
    const min_stack_size = 60 * 1024 * 1024;
    const max_context_align: Alignment = .@"16";
    const max_context_size = max_context_align.forward(1024);
    const max_closure_size: usize = @sizeOf(AsyncClosure);
    const max_closure_align: Alignment = .of(AsyncClosure);
    const allocation_size = std.mem.alignForward(
        usize,
        max_closure_align.max(max_context_align).forward(
            max_result_align.forward(@sizeOf(Fiber)) + max_result_size + min_stack_size,
        ) + max_closure_size + max_context_size,
        std.heap.page_size_max,
    );
    comptime {
        assert(max_result_align.compare(.gte, .of(Completion)));
        assert(max_result_size >= @sizeOf(Completion));
    }

    fn create(ev: *Evented) error{OutOfMemory}!*Fiber {
        if (ev.free_queue) |free_fiber| {
            assert(free_fiber != finished);
            ev.free_queue = free_fiber.status.free_next;
            return free_fiber;
        }
        return @ptrCast(try ev.backing_allocator.alignedAlloc(u8, .of(Fiber), allocation_size));
    }

    fn destroy(fiber: *Fiber, ev: *Evented) void {
        assert(fiber.status.queue_next == null);
        fiber.status = .{ .free_next = ev.free_queue };
        ev.free_queue = fiber;
    }

    fn allocatedSlice(f: *Fiber) []align(@alignOf(Fiber)) u8 {
        return @as([*]align(@alignOf(Fiber)) u8, @ptrCast(f))[0..allocation_size];
    }

    fn allocatedEnd(f: *Fiber) [*]u8 {
        const allocated_slice = f.allocatedSlice();
        return allocated_slice[allocated_slice.len..].ptr;
    }

    fn resultPointer(f: *Fiber, comptime Result: type) *Result {
        return @ptrCast(@alignCast(f.resultBytes(.of(Result))));
    }

    fn resultBytes(f: *Fiber, alignment: Alignment) [*]u8 {
        return @ptrFromInt(alignment.forward(@intFromPtr(f) + @sizeOf(Fiber)));
    }

    fn complete(f: *Fiber, c: Completion) void {
        f.resultPointer(Completion).* = c;
        _ = f.cancel_status.changeAwaiting(.operation, .nothing);
    }
    fn completion(f: *Fiber) Completion {
        return f.resultPointer(Completion).*;
    }
    fn errno(f: *Fiber) linux.E {
        return f.completion().errno();
    }

    const Queue = struct { head: *Fiber, tail: *Fiber };

    /// Like a `*Fiber`, but 2 bits smaller than a pointer (because the LSBs are always 0 due to
    /// alignment) so that those two bits can be used in a `packed struct`.
    const PackedPtr = enum(@Int(.unsigned, @bitSizeOf(usize) - 2)) {
        null = 0,
        all_ones = std.math.maxInt(@Int(.unsigned, @bitSizeOf(usize) - 2)),
        _,

        const Split = packed struct(usize) { low: u2, high: PackedPtr };
        fn pack(ptr: ?*Fiber) PackedPtr {
            const split: Split = @bitCast(@intFromPtr(ptr));
            assert(split.low == 0);
            return split.high;
        }
        fn unpack(ptr: PackedPtr) ?*Fiber {
            const split: Split = .{ .low = 0, .high = ptr };
            return @ptrFromInt(@as(usize, @bitCast(split)));
        }
    };

    fn requestCancel(fiber: *Fiber, ev: *Evented) void {
        assert(!fiber.cancel_status.requested);
        fiber.cancel_status.requested = true;
        switch (fiber.cancel_status.awaiting) {
            .nothing => {},
            .group => {
                // The awaiter received a cancelation request while awaiting a group,
                // so propagate the cancelation to the group.
                if (fiber.status.awaiting_group.cancel(ev, null)) {
                    fiber.status = .{ .queue_next = null };
                    ev.schedule(.{ .head = fiber, .tail = fiber });
                }
            },
            .operation => {
                ev.getSqe().asyncCancel(
                    @backingInt(Completion.Userdata.wakeup),
                    @intFromPtr(&fiber),
                );
            },
        }
    }
};

const CachedFd = struct {
    fd: fd_t = -1,

    fn close(self: *CachedFd) void {
        if (self.fd != -1) {
            _ = linux.close(self.fd);
        }
    }

    fn open(
        self: *CachedFd,
        ev: *Evented,
        path: [*:0]const u8,
        flags: linux.O,
    ) File.OpenError!fd_t {
        if (self.fd == -1) {
            self.fd = ev.openat(linux.AT.FDCWD, path, flags, 0) catch |err| switch (err) {
                error.OperationUnsupported => return error.Unexpected, // TMPFILE unset.
                else => |e| return e,
            };
        }
        return self.fd;
    }
};

pub fn io(ev: *Evented) Io {
    return .{
        .userdata = ev,
        .vtable = &.{
            .crashHandler = crashHandler,

            .async = async,
            .concurrent = concurrent,
            .await = await,
            .cancel = cancel,

            .groupAsync = groupAsync,
            .groupConcurrent = groupConcurrent,
            .groupAwait = groupAwait,
            .groupCancel = groupCancel,

            .recancel = recancel,
            .swapCancelProtection = swapCancelProtection,
            .checkCancel = checkCancel,

            .futexWait = futexWait,
            .futexWaitUncancelable = futexWaitUncancelable,
            .futexWake = futexWake,

            .operate = operate,
            .batchAwaitAsync = batchAwaitAsync,
            .batchAwaitConcurrent = batchAwaitConcurrent,
            .batchCancel = batchCancel,

            .dirCreateDir = dirCreateDir,
            .dirCreateDirPath = dirCreateDirPath,
            .dirCreateDirPathOpen = dirCreateDirPathOpen,
            .dirOpenDir = dirOpenDir,
            .dirStat = dirStat,
            .dirStatFile = dirStatFile,
            .dirAccess = dirAccess, // sync
            .dirCreateFile = dirCreateFile,
            .dirCreateFileAtomic = dirCreateFileAtomic,
            .dirOpenFile = dirOpenFile,
            .dirClose = dirClose,
            .dirRead = dirRead,
            .dirRealPath = dirRealPath, // sync
            .dirRealPathFile = dirRealPathFile, // sync
            .dirDeleteFile = dirDeleteFile,
            .dirDeleteDir = dirDeleteDir,
            .dirRename = dirRename,
            .dirRenamePreserve = dirRenamePreserve,
            .dirSymLink = dirSymLink,
            .dirReadLink = dirReadLink, // sync
            .dirSetOwner = dirSetOwner, // sync
            .dirSetFileOwner = dirSetFileOwner, // sync
            .dirSetPermissions = dirSetPermissions, // sync
            .dirSetFilePermissions = dirSetFilePermissions, // sync
            .dirSetTimestamps = dirSetTimestamps, // sync
            .dirHardLink = dirHardLink,

            .fileStat = fileStat,
            .fileLength = fileLength,
            .fileClose = fileClose,
            .fileWritePositional = fileWritePositional,
            .fileWriteFileStreaming = fileWriteFileStreaming,
            .fileWriteFilePositional = fileWriteFilePositional,
            .fileReadPositional = fileReadPositional,
            .fileSeekBy = fileSeekBy,
            .fileSeekTo = fileSeekTo,
            .fileSync = fileSync,
            .fileIsTty = fileIsTty,
            .fileEnableAnsiEscapeCodes = fileEnableAnsiEscapeCodes,
            .fileSupportsAnsiEscapeCodes = fileIsTty,
            .fileSetLength = fileSetLength,
            .fileSetOwner = fileSetOwner,
            .fileSetPermissions = fileSetPermissions,
            .fileSetTimestamps = fileSetTimestamps,
            .fileLock = fileLock,
            .fileTryLock = fileTryLock,
            .fileUnlock = fileUnlock,
            .fileDowngradeLock = fileDowngradeLock,
            .fileRealPath = fileRealPath,
            .fileHardLink = fileHardLink,

            .fileMemoryMapCreate = fileMemoryMapCreate,
            .fileMemoryMapDestroy = fileMemoryMapDestroy,
            .fileMemoryMapSetLength = fileMemoryMapSetLength,
            .fileMemoryMapRead = fileMemoryMapRead,
            .fileMemoryMapWrite = fileMemoryMapWrite,

            .processExecutableOpen = processExecutableOpen,
            .processExecutablePath = processExecutablePath,
            .lockStderr = lockStderr,
            .tryLockStderr = tryLockStderr,
            .unlockStderr = unlockStderr,
            .processCurrentPath = processCurrentPath,
            .processSetCurrentDir = processSetCurrentDir,
            .processSetCurrentPath = processSetCurrentPath,
            .processReplace = processReplace,
            .processReplacePath = processReplacePath,
            .processSpawn = processSpawn,
            .processSpawnPath = processSpawnPath,
            .childWait = childWait,
            .childKill = childKill,

            .progressParentFile = progressParentFile,

            .now = now,
            .clockResolution = clockResolution,
            .sleep = sleep,

            .random = random,
            .randomSecure = randomSecure,

            .netListenIp = netListenIp,
            .netAccept = netAccept,
            .netBindIp = netBindIp,
            .netConnectIp = netConnectIp,
            .netListenUnix = netListenUnixUnavailable,
            .netConnectUnix = netConnectUnixUnavailable,
            .netSocketCreatePair = netSocketCreatePairUnavailable,
            .netSend = netSend,
            .netWrite = netWrite,
            .netWriteFile = netWriteFile,
            .netClose = netClose,
            .netShutdown = netShutdown,
            .netInterfaceNameResolve = netInterfaceNameResolveUnavailable,
            .netInterfaceName = netInterfaceNameUnavailable,
            .netLookup = netLookupUnavailable,
        },
    };
}

pub const InitOptions = struct {
    /// Maximum thread pool size (excluding the main thread).
    /// Defaults to one less than the number of logical CPU cores.
    thread_limit: ?usize = 0,

    log2_ring_entries: u4 = 10,

    /// Affects the following operations:
    /// * `processExecutablePath` on OpenBSD and Haiku.
    argv0: Argv0 = .empty,
    /// Affects the following operations:
    /// * `fileIsTty`
    /// * `processSpawn`, `processSpawnPath`, `processReplace`, `processReplacePath`
    environ: process.Environ = .empty,
};

pub fn init(ev: *Evented, backing_allocator: Allocator, options: InitOptions) !void {
    const idle_stack_end_offset = std.mem.alignForward(usize, idle_stack_size, std.heap.pageSize());
    const allocated_slice = try backing_allocator.alignedAlloc(u8, .of(usize), idle_stack_end_offset);
    errdefer backing_allocator.free(allocated_slice);
    ev.* = .{
        .backing_allocator = backing_allocator,
        .main_fiber_buffer = undefined,

        .stderr_writer_initialized = false,
        .stderr_mutex = .init,
        .stderr_writer = .{
            .io = ev.io(),
            .interface = Io.File.Writer.initInterface(&.{}),
            .file = .stderr(),
            .mode = .streaming,
        },
        .stderr_mode = .no_color,

        .environ_mutex = .init,
        .environ_initialized = options.environ.block.isEmpty(),
        .environ = .{ .process_environ = options.environ },

        .null_fd = .{},
        .random_fd = .{},

        .csprng = .uninitialized,
        .allocated_slice = allocated_slice,

        .idle_context = switch (builtin.cpu.arch) {
            .aarch64 => .{
                .sp = @intFromPtr(allocated_slice[idle_stack_end_offset..].ptr),
                .fp = @intFromPtr(ev),
                .pc = @intFromPtr(&mainIdleEntry),
            },
            .riscv64 => .{
                .sp = @intFromPtr(allocated_slice[idle_stack_end_offset..].ptr),
                .fp = @intFromPtr(ev),
                .pc = @intFromPtr(&mainIdleEntry),
            },
            .x86_64 => .{
                .rsp = @intFromPtr(allocated_slice[idle_stack_end_offset..].ptr),
                .rbp = @intFromPtr(ev),
                .rip = @intFromPtr(&mainIdleEntry),
            },
            else => @compileError("unimplemented architecture"),
        },
        .current_context = undefined,
        .ready_queue = null,
        .free_queue = null,
        .io_uring = try .init(@as(u16, 1) << options.log2_ring_entries, .{
            .flags = .{
                .coop_taskrun = true,
                .single_issuer = true,
                .taskrun_flag = true,
                .defer_taskrun = true, // needed for resize
            },
        }),
    };
    const main_fiber: *Fiber = @ptrCast(&ev.main_fiber_buffer);
    main_fiber.* = .{
        .required_align = {},
        .context = undefined,
        .link = .{ .awaiter = null },
        .status = .{ .queue_next = null },
        .cancel_status = .unrequested,
        .cancel_protection = .unblocked,
    };
    ev.current_context = &main_fiber.context;
}

pub fn deinit(ev: *Evented) void {
    const main_fiber: *Fiber = @ptrCast(&ev.main_fiber_buffer);
    assert(ev.currentFiber() == main_fiber);
    assert(ev.ready_queue == null or ev.ready_queue == Fiber.finished); // pending async
    var next_fiber = ev.free_queue;
    while (next_fiber) |free_fiber| {
        next_fiber = free_fiber.status.free_next;
        ev.backing_allocator.free(free_fiber.allocatedSlice());
    }
    ev.io_uring.deinit();
    ev.backing_allocator.free(ev.allocated_slice);
    ev.* = undefined;
}

fn currentFiber(ev: *Evented) *Fiber {
    assert(ev.current_context != &ev.idle_context);
    return @fieldParentPtr("context", ev.current_context);
}

fn getSqe(ev: *Evented) *IoUring.Sqe {
    while (true) return ev.io_uring.getSqe() catch {
        const sq_len: u32 = @intCast(ev.io_uring.sq.sqes.len);
        ev.io_uring.resize(sq_len * 2, 0) catch ev.submit();
        continue;
    };
}

fn enqueue(ev: *Evented) error{Canceled}!struct { *IoUring.Sqe, *Fiber } {
    const fiber = ev.currentFiber();
    if (fiber.cancel_status.requested) {
        fiber.cancel_protection.acknowledge();
        return error.Canceled;
    }
    _ = fiber.cancel_status.changeAwaiting(.nothing, .operation);
    return .{ ev.getSqe(), fiber };
}

// Enqueue with blocked cancel protection.
fn enqueueBlocked(ev: *Evented) struct { *IoUring.Sqe, *Fiber } {
    const fiber = ev.currentFiber();
    _ = fiber.cancel_status.changeAwaiting(.nothing, .operation);
    return .{ ev.getSqe(), fiber };
}

// Marking start of the sync io operation.
fn enqueueSync(ev: *Evented) error{Canceled}!void {
    const fiber = ev.currentFiber();
    if (fiber.cancel_status.requested) {
        fiber.cancel_protection.acknowledge();
        return error.Canceled;
    }
    _ = fiber.cancel_status.changeAwaiting(.nothing, .nothing);
}

fn submit(ev: *Evented) void {
    _ = ev.io_uring.submit(.{}) catch |err| switch (err) {
        error.SignalInterrupt => {},
        else => |e| @panic(@errorName(e)),
    };
}

fn findReadyFiber(ev: *Evented) ?*Fiber {
    if (ev.ready_queue) |ready_fiber| {
        assert(ready_fiber != Fiber.finished);
        ev.ready_queue = ready_fiber.status.queue_next;
        ready_fiber.status.queue_next = null;
        return ready_fiber;
    }
    return null;
}

fn yield(ev: *Evented, maybe_ready_fiber: ?*Fiber, pending_task: SwitchMessage.PendingTask) void {
    const ready_context = if (maybe_ready_fiber orelse ev.findReadyFiber()) |ready_fiber|
        &ready_fiber.context
    else
        &ev.idle_context;

    const message: SwitchMessage = .{
        .contexts = .{
            .old = ev.current_context,
            .new = ready_context,
        },
        .pending_task = pending_task,
    };
    contextSwitch(&message).handle(ev);
}

fn schedule(ev: *Evented, ready_queue: Fiber.Queue) void {
    ready_queue.tail.status.queue_next = ev.ready_queue;
    ev.ready_queue = ready_queue.head;
}

const Completion = struct {
    result: i32,
    flags: u32,

    const Userdata = enum(usize) {
        unused,
        wakeup,
        futex_wake,
        close,
        cleanup,
        /// If bit 0 is 1, a pointer to the `context` field of `Io.Batch.Storage.Pending`.
        /// If bits 0 and 1 are 0, a `*Fiber`.
        _,
    };

    fn errno(completion: Completion) linux.E {
        return linux.errno(@bitCast(@as(isize, completion.result)));
    }
};

fn mainIdleEntry() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ mov x0, fp
            \\ mov fp, #0
            \\ b %[mainIdle]
            :
            : [mainIdle] "X" (&mainIdle),
        ),
        .riscv64 => asm volatile (
            \\ mv a0, fp
            \\ mv fp, zero
            \\ tail %[mainIdle]@plt
            :
            : [mainIdle] "X" (&mainIdle),
        ),
        .x86_64 => asm volatile (
            \\ movq %%rbp, %%rdi
            \\ xor %%ebp, %%ebp
            \\ jmp %[mainIdle:P]
            :
            : [mainIdle] "X" (&mainIdle),
        ),
        else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
    }
}

fn mainIdle(
    ev: *Evented,
    contexts: *const Io.fiber.Switch,
) callconv(.withStackAlign(.c, @max(@alignOf(usize), @alignOf(Io.fiber.Context)))) noreturn {
    const message: *const SwitchMessage = @fieldParentPtr("contexts", contexts);
    message.handle(ev);
    ev.idle();
    ev.yield(@ptrCast(&ev.main_fiber_buffer), .nothing);
    unreachable; // switched to dead fiber
}

fn idle(ev: *Evented) void {
    var maybe_ready_fiber: ?*Fiber = null;
    while (true) {
        while (maybe_ready_fiber orelse ev.findReadyFiber()) |ready_fiber| {
            ev.yield(ready_fiber, .nothing);
            maybe_ready_fiber = null;
        }
        assert(ev.ready_queue == null);
        _ = ev.io_uring.submit(.{ .nr = 1 }) catch |err| switch (err) {
            error.SignalInterrupt => {},
            error.TimeoutExpired => {},
            error.SystemResources => {},
            error.CompletionQueueOvercommitted => {},

            error.FileDescriptorInvalid,
            error.FileDescriptorInBadState,
            error.SubmissionQueueEntryInvalid,
            error.BufferInvalid,
            error.RingShuttingDown,
            error.OpcodeNotSupported,
            error.InvalidThread,
            error.SystemOutdated,
            error.Unexpected,
            => |e| @panic(@errorName(e)),
        };
        var maybe_ready_queue: ?Fiber.Queue = null;
        while (true) {
            var cqes_buffer: [1 << 8]IoUring.Cqe = undefined;
            const cqes = cqes_buffer[0..ev.io_uring.copyReadyCqes(&cqes_buffer)];
            if (cqes.len == 0) break;
            for (cqes) |cqe| if (cqe.flags & linux.IORING_CQE_F_SKIP == 0) switch (@as(
                Completion.Userdata,
                @fromBackingInt(@intCast(cqe.user_data)),
            )) {
                .unused => unreachable, // bad submission queued?
                .wakeup => {},
                .futex_wake => switch (Completion.errno(.{ .result = cqe.res, .flags = cqe.flags })) {
                    .SUCCESS => recoverableOsBugDetected(), // success is skipped
                    .INVAL => {}, // invalid futex_wait() on ptr done elsewhere
                    .INTR, .CANCELED => recoverableOsBugDetected(), // `Completion.Userdata.futex_wake` is not cancelable
                    .FAULT => {}, // pointer became invalid while doing the wake
                    else => recoverableOsBugDetected(), // deadlock due to operating system bug
                },
                .close => switch (Completion.errno(.{ .result = cqe.res, .flags = cqe.flags })) {
                    .BADF => recoverableOsBugDetected(), // Always a race condition.
                    .INTR => {}, // This is still a success. See https://github.com/ziglang/zig/issues/2425
                    else => {},
                },
                .cleanup => @panic("failed to notify other threads that we are exiting"),
                _ => if (@as(?*Fiber, ready_fiber: switch (@as(u2, @truncate(cqe.user_data))) {
                    0b00 => {
                        const ready_fiber: *Fiber = @ptrFromInt(cqe.user_data & ~@as(usize, 0b11));
                        ready_fiber.complete(.{
                            .result = cqe.res,
                            .flags = cqe.flags,
                        });
                        break :ready_fiber ready_fiber;
                    },
                    0b01 => {
                        ev.getSqe().asyncCancel(
                            @backingInt(Completion.Userdata.wakeup),
                            cqe.user_data & ~@as(usize, 0b11),
                        );
                        break :ready_fiber null;
                    },
                    0b10 => {
                        const batch_userdata: *Io.Operation.Storage.Pending.Userdata =
                            @ptrFromInt(cqe.user_data & ~@as(usize, 0b11));
                        const batch: *Io.Batch = @ptrFromInt(batch_userdata[0]);

                        const next: usize = @as(*usize, @ptrCast(&batch.userdata)).*;
                        batch_userdata[0..3].* = .{ next, @as(u32, @bitCast(cqe.res)), cqe.flags };
                        @as(*usize, @ptrCast(&batch.userdata)).* = cqe.user_data;

                        break :ready_fiber switch (@as(u2, @truncate(next))) {
                            0b00, 0b01 => @ptrFromInt(next & ~@as(usize, 0b11)),
                            0b10, 0b11 => null,
                        };
                    },
                    0b11 => switch (Completion.errno(.{ .result = cqe.res, .flags = cqe.flags })) {
                        .SUCCESS => unreachable, // no event count specified
                        .TIME => {
                            const context: *usize = @ptrFromInt(cqe.user_data & ~@as(usize, 0b11));
                            const fiber = @atomicRmw(usize, context, .Add, 0b01, .acquire);
                            break :ready_fiber switch (@as(u2, @truncate(fiber))) {
                                else => unreachable, // timeout completed multiple times
                                0b00 => @ptrFromInt(fiber & ~@as(usize, 0b11)),
                                0b10 => null,
                            };
                        },
                        .CANCELED => null, // user data may have been invalidated
                        else => |err| unexpectedErrno(err) catch null,
                    },
                })) |ready_fiber| {
                    assert(ready_fiber.status.queue_next == null);
                    if (maybe_ready_fiber == null) {
                        maybe_ready_fiber = ready_fiber;
                    } else if (maybe_ready_queue) |*ready_queue| {
                        ready_queue.tail.status.queue_next = ready_fiber;
                        ready_queue.tail = ready_fiber;
                    } else maybe_ready_queue = .{ .head = ready_fiber, .tail = ready_fiber };
                },
            };
        }
        if (maybe_ready_queue) |ready_queue| ev.schedule(ready_queue);
    }
}

const SwitchMessage = struct {
    contexts: Io.fiber.Switch,
    pending_task: PendingTask,

    const PendingTask = union(enum) {
        nothing,
        reschedule,
        await: *Fiber,
        group_await: Group,
        group_cancel: Group,
        batch_await: *Io.Batch,
        destroy,
    };

    fn handle(message: *const SwitchMessage, ev: *Evented) void {
        ev.current_context = message.contexts.new;
        switch (message.pending_task) {
            .nothing => {},
            .reschedule => if (message.contexts.old != &ev.idle_context) {
                const fiber: *Fiber = @alignCast(@fieldParentPtr("context", message.contexts.old));
                assert(fiber.status.queue_next == null);
                ev.schedule(.{ .head = fiber, .tail = fiber });
            },
            .await => |awaiting| {
                const awaiter: *Fiber = @alignCast(@fieldParentPtr("context", message.contexts.old));
                assert(awaiter.status.queue_next == null);
                if (@atomicRmw(?*Fiber, &awaiting.link.awaiter, .Xchg, awaiter, .acq_rel) ==
                    Fiber.finished) ev.schedule(.{ .head = awaiter, .tail = awaiter });
            },
            .group_await => |group| {
                const fiber: *Fiber = @alignCast(@fieldParentPtr("context", message.contexts.old));
                if (group.await(ev, fiber))
                    ev.schedule(.{ .head = fiber, .tail = fiber });
            },
            .group_cancel => |group| {
                const fiber: *Fiber = @alignCast(@fieldParentPtr("context", message.contexts.old));
                if (group.cancel(ev, fiber))
                    ev.schedule(.{ .head = fiber, .tail = fiber });
            },
            .batch_await => |batch| {
                const fiber: *Fiber = @alignCast(@fieldParentPtr("context", message.contexts.old));
                if (@cmpxchgStrong(
                    ?*anyopaque,
                    &batch.userdata,
                    null,
                    fiber,
                    .release,
                    .monotonic,
                )) |head| {
                    assert(@as(u2, @truncate(@intFromPtr(head))) != 0b00);
                    ev.schedule(.{ .head = fiber, .tail = fiber });
                }
            },
            .destroy => {
                const fiber: *Fiber = @alignCast(@fieldParentPtr("context", message.contexts.old));
                fiber.destroy(ev);
            },
        }
    }
};

inline fn contextSwitch(message: *const SwitchMessage) *const SwitchMessage {
    return @fieldParentPtr("contexts", Io.fiber.contextSwitch(&message.contexts));
}

fn crashHandler(userdata: ?*anyopaque) void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    if (ev.current_context == &ev.idle_context) std.process.abort();
    const fiber = ev.currentFiber();
    fiber.cancel_status = .{ .requested = true, .awaiting = .nothing };
    fiber.cancel_protection = .{ .user = .blocked, .acknowledged = true };
}

const AsyncClosure = struct {
    evented: *Evented,
    fiber: *Fiber,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    result_align: Alignment,

    fn fromFiber(fiber: *Fiber) *AsyncClosure {
        return @ptrFromInt(Fiber.max_context_align.max(.of(AsyncClosure)).backward(
            @intFromPtr(fiber.allocatedEnd()) - Fiber.max_context_size,
        ) - @sizeOf(AsyncClosure));
    }

    fn contextPointer(closure: *AsyncClosure) [*]align(Fiber.max_context_align.toByteUnits()) u8 {
        return @alignCast(@as([*]u8, @ptrCast(closure)) + @sizeOf(AsyncClosure));
    }

    fn entry() callconv(.naked) void {
        switch (builtin.cpu.arch) {
            .aarch64 => asm volatile (
                \\ mov x0, sp
                \\ b %[call]
                :
                : [call] "X" (&call),
            ),
            .riscv64 => asm volatile (
                \\ mv a0, sp
                \\ tail %[call]@plt
                :
                : [call] "X" (&call),
            ),
            .x86_64 => asm volatile (
                \\ leaq 8(%%rsp), %%rdi
                \\ jmp %[call:P]
                :
                : [call] "X" (&call),
            ),
            else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
        }
    }

    fn call(
        closure: *AsyncClosure,
        contexts: *const Io.fiber.Switch,
    ) callconv(.withStackAlign(.c, @alignOf(AsyncClosure))) noreturn {
        const message: *const SwitchMessage = @fieldParentPtr("contexts", contexts);
        const ev = closure.evented;
        const fiber = closure.fiber;
        message.handle(ev);
        closure.start(closure.contextPointer(), fiber.resultBytes(closure.result_align));
        ev.yield(@atomicRmw(?*Fiber, &fiber.link.awaiter, .Xchg, Fiber.finished, .acq_rel), .nothing);
        unreachable; // switched to dead fiber
    }
};

fn async(
    userdata: ?*anyopaque,
    result: []u8,
    result_alignment: Alignment,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) ?*std.Io.AnyFuture {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    return concurrent(ev, result.len, result_alignment, context, context_alignment, start) catch {
        start(context.ptr, result.ptr);
        return null;
    };
}

fn concurrent(
    userdata: ?*anyopaque,
    result_len: usize,
    result_alignment: Alignment,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) Io.ConcurrentError!*std.Io.AnyFuture {
    assert(result_alignment.compare(.lte, Fiber.max_result_align)); // TODO
    assert(context_alignment.compare(.lte, Fiber.max_context_align)); // TODO
    assert(result_len <= Fiber.max_result_size); // TODO
    assert(context.len <= Fiber.max_context_size); // TODO

    const ev: *Evented = @ptrCast(@alignCast(userdata));
    const fiber = Fiber.create(ev) catch |err| switch (err) {
        error.OutOfMemory => return error.ConcurrencyUnavailable,
    };

    const closure: *AsyncClosure = .fromFiber(fiber);
    fiber.* = .{
        .required_align = {},
        .context = switch (builtin.cpu.arch) {
            .aarch64 => .{
                .sp = @intFromPtr(closure),
                .fp = 0,
                .pc = @intFromPtr(&AsyncClosure.entry),
            },
            .riscv64 => .{
                .sp = @intFromPtr(closure),
                .fp = 0,
                .pc = @intFromPtr(&AsyncClosure.entry),
            },
            .x86_64 => .{
                .rsp = @intFromPtr(closure) - 8,
                .rbp = 0,
                .rip = @intFromPtr(&AsyncClosure.entry),
            },
            else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
        },
        .link = .{ .awaiter = null },
        .status = .{ .queue_next = null },
        .cancel_status = .unrequested,
        .cancel_protection = .unblocked,
    };
    closure.* = .{
        .evented = ev,
        .fiber = fiber,
        .start = start,
        .result_align = result_alignment,
    };
    @memcpy(closure.contextPointer(), context);

    ev.schedule(.{ .head = fiber, .tail = fiber });
    return @ptrCast(fiber);
}

fn await(
    userdata: ?*anyopaque,
    future: *std.Io.AnyFuture,
    result: []u8,
    result_alignment: Alignment,
) void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    const awaiting: *Fiber = @ptrCast(@alignCast(future));
    if (awaiting.link.awaiter != Fiber.finished)
        ev.yield(null, .{ .await = awaiting });
    @memcpy(result, awaiting.resultBytes(result_alignment));
    awaiting.destroy(ev);
}

fn cancel(
    userdata: ?*anyopaque,
    future: *std.Io.AnyFuture,
    result: []u8,
    result_alignment: Alignment,
) void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    const future_fiber: *Fiber = @ptrCast(@alignCast(future));
    future_fiber.requestCancel(ev);
    await(ev, future, result, result_alignment);
}

const Group = struct {
    ptr: *Io.Group,

    const List = packed struct(usize) {
        cancel_requested: bool,
        awaiter_delayed: bool,
        fibers: Fiber.PackedPtr,
    };
    fn listPtr(group: Group) *List {
        return @ptrCast(&group.ptr.token);
    }

    const Awaiter = packed struct(usize) {
        locked: bool,
        contended: bool,
        awaiter: Fiber.PackedPtr,
    };
    fn awaiterPtr(group: Group) *Awaiter {
        return @ptrCast(&group.ptr.state);
    }

    fn addFiber(group: Group, fiber: *Fiber) void {
        const ptr = group.listPtr();
        const list = ptr.*;
        if (list.cancel_requested) fiber.cancel_status = .{ .requested = true, .awaiting = .nothing };
        const old_head = list.fibers.unpack();
        if (old_head) |head| head.link.group.prev = fiber;
        fiber.link.group.next = old_head;
        ptr.* = .{
            .cancel_requested = list.cancel_requested,
            .awaiter_delayed = list.awaiter_delayed,
            .fibers = .pack(fiber),
        };
    }

    fn removeFiber(group: Group, fiber: *Fiber) ?*Fiber {
        const ptr = group.listPtr();
        const list = ptr.*;
        if (fiber.link.group.next) |next| next.link.group.prev = fiber.link.group.prev;
        if (fiber.link.group.prev) |prev| {
            prev.link.group.next = fiber.link.group.next;
        } else if (fiber.link.group.next) |new_head| {
            ptr.* = .{
                .cancel_requested = list.cancel_requested,
                .awaiter_delayed = list.awaiter_delayed,
                .fibers = .pack(new_head),
            };
        } else if (group.awaiterPtr().*.awaiter.unpack()) |awaiter| {
            if (!awaiter.cancel_status.changeAwaiting(.group, .nothing) or list.cancel_requested) {
                ptr.* = .{
                    .cancel_requested = false,
                    .awaiter_delayed = false,
                    .fibers = .null,
                };
                assert(awaiter.status.awaiting_group.ptr == group.ptr);
                awaiter.status = .{ .queue_next = null };
                return awaiter;
            }
            ptr.* = .{
                .cancel_requested = false,
                .awaiter_delayed = true,
                .fibers = .null,
            };
        } else {
            ptr.* = .{
                .cancel_requested = false,
                .awaiter_delayed = false,
                .fibers = .null,
            };
        }
        return null;
    }

    fn await(group: Group, ev: *Evented, awaiter: *Fiber) bool {
        const ptr = group.listPtr();
        const list = ptr.*;
        if (list.fibers.unpack()) |_| {
            if (group.registerAwaiter(awaiter) and awaiter.cancel_protection.check() == .unblocked) {
                // The awaiter already had an unacknowledged cancelation request before
                // attempting to await a group, so propagate the cancelation to the group.
                assert(!group.cancel(ev, null));
            }
            return false;
        }
        return true;
    }

    fn cancel(group: Group, ev: *Evented, maybe_awaiter: ?*Fiber) bool {
        const ptr = group.listPtr();
        const list = ptr.*;
        assert(!list.cancel_requested);
        ptr.* = .{
            .cancel_requested = true,
            .awaiter_delayed = false,
            .fibers = list.fibers,
        };
        if (list.fibers.unpack()) |head| {
            var maybe_fiber: ?*Fiber = head;
            while (maybe_fiber) |fiber| {
                fiber.requestCancel(ev);
                maybe_fiber = fiber.link.group.next;
            }
            if (maybe_awaiter) |awaiter| _ = group.registerAwaiter(awaiter);
            return false;
        }
        ptr.* = .{
            .cancel_requested = false,
            .awaiter_delayed = false,
            .fibers = .null,
        };
        return if (maybe_awaiter) |_| true else list.awaiter_delayed;
    }

    fn registerAwaiter(group: Group, awaiter: *Fiber) bool {
        assert(awaiter.status.queue_next == null);
        awaiter.status = .{ .awaiting_group = group };
        const ptr = group.awaiterPtr();
        assert(ptr.awaiter == .null);
        ptr.* = .{
            .locked = ptr.locked,
            .contended = ptr.contended,
            .awaiter = .pack(awaiter),
        };
        return awaiter.cancel_status.changeAwaiting(.nothing, .group);
    }

    const AsyncClosure = struct {
        evented: *Evented,
        group: Group,
        fiber: *Fiber,
        start: *const fn (context: *const anyopaque) void,

        fn fromFiber(fiber: *Fiber) *Group.AsyncClosure {
            return @ptrFromInt(Fiber.max_context_align.max(.of(Group.AsyncClosure)).backward(
                @intFromPtr(fiber.allocatedEnd()) - Fiber.max_context_size,
            ) - @sizeOf(Group.AsyncClosure));
        }

        fn contextPointer(
            closure: *Group.AsyncClosure,
        ) [*]align(Fiber.max_context_align.toByteUnits()) u8 {
            return @alignCast(@as([*]u8, @ptrCast(closure)) + @sizeOf(Group.AsyncClosure));
        }

        fn entry() callconv(.naked) void {
            switch (builtin.cpu.arch) {
                .aarch64 => asm volatile (
                    \\ mov x0, sp
                    \\ b %[call]
                    :
                    : [call] "X" (&call),
                ),
                .riscv64 => asm volatile (
                    \\ mv a0, sp
                    \\ tail %[call]@plt
                    :
                    : [call] "X" (&call),
                ),
                .x86_64 => asm volatile (
                    \\ leaq 8(%%rsp), %%rdi
                    \\ jmp %[call:P]
                    :
                    : [call] "X" (&call),
                ),
                else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
            }
        }

        fn call(
            closure: *Group.AsyncClosure,
            contexts: *const Io.fiber.Switch,
        ) callconv(.withStackAlign(.c, @alignOf(Group.AsyncClosure))) noreturn {
            const message: *const SwitchMessage = @fieldParentPtr("contexts", contexts);
            const ev = closure.evented;
            const fiber = closure.fiber;
            message.handle(ev);
            assert(fiber.status.queue_next == null);
            closure.start(closure.contextPointer());
            ev.yield(closure.group.removeFiber(fiber), .destroy);
            unreachable; // switched to dead fiber
        }
    };
};

fn groupAsync(
    userdata: ?*anyopaque,
    type_erased: *Io.Group,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (context: *const anyopaque) void,
) void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    return groupConcurrent(ev, type_erased, context, context_alignment, start) catch {
        start(context.ptr);
    };
}

fn groupConcurrent(
    userdata: ?*anyopaque,
    type_erased: *Io.Group,
    context: []const u8,
    context_alignment: Alignment,
    start: *const fn (context: *const anyopaque) void,
) Io.ConcurrentError!void {
    assert(context_alignment.compare(.lte, Fiber.max_context_align)); // TODO
    assert(context.len <= Fiber.max_context_size); // TODO

    const ev: *Evented = @ptrCast(@alignCast(userdata));
    const group: Group = .{ .ptr = type_erased };
    const fiber = Fiber.create(ev) catch |err| switch (err) {
        error.OutOfMemory => return error.ConcurrencyUnavailable,
    };

    const closure: *Group.AsyncClosure = .fromFiber(fiber);
    fiber.* = .{
        .required_align = {},
        .context = switch (builtin.cpu.arch) {
            .aarch64 => .{
                .sp = @intFromPtr(closure),
                .fp = 0,
                .pc = @intFromPtr(&Group.AsyncClosure.entry),
            },
            .riscv64 => .{
                .sp = @intFromPtr(closure),
                .fp = 0,
                .pc = @intFromPtr(&Group.AsyncClosure.entry),
            },
            .x86_64 => .{
                .rsp = @intFromPtr(closure) - 8,
                .rbp = 0,
                .rip = @intFromPtr(&Group.AsyncClosure.entry),
            },
            else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
        },
        .link = .{ .group = .{ .prev = null, .next = null } },
        .status = .{ .queue_next = null },
        .cancel_status = .unrequested,
        .cancel_protection = .unblocked,
    };
    closure.* = .{
        .evented = ev,
        .group = group,
        .fiber = fiber,
        .start = start,
    };
    @memcpy(closure.contextPointer(), context);
    group.addFiber(fiber);
    ev.schedule(.{ .head = fiber, .tail = fiber });
}

fn groupAwait(
    userdata: ?*anyopaque,
    type_erased: *Io.Group,
    initial_token: *anyopaque,
) Io.Cancelable!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    _ = initial_token;
    ev.yield(null, .{ .group_await = .{ .ptr = type_erased } });
}

fn groupCancel(userdata: ?*anyopaque, type_erased: *Io.Group, initial_token: *anyopaque) void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    _ = initial_token;
    ev.yield(null, .{ .group_cancel = .{ .ptr = type_erased } });
}

fn recancel(userdata: ?*anyopaque) void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    ev.currentFiber().cancel_protection.recancel();
}

fn swapCancelProtection(userdata: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    const cancel_protection = &ev.currentFiber().cancel_protection;
    defer cancel_protection.user = new;
    return cancel_protection.user;
}

fn checkCancel(userdata: ?*anyopaque) Io.Cancelable!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    const fiber = ev.currentFiber();
    switch (fiber.cancel_protection.check()) {
        .unblocked => {
            assert(fiber.cancel_status.awaiting == .nothing);
            if (fiber.cancel_status.requested) {
                @branchHint(.unlikely);
                fiber.cancel_protection.acknowledge();
                return error.Canceled;
            }
        },
        .blocked => {},
    }
}

fn futexWait(
    userdata: ?*anyopaque,
    ptr: *const u32,
    expected: u32,
    timeout: Io.Timeout,
) Io.Cancelable!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    const timespec: ?linux.kernel_timespec, const clock: Io.Clock, const timeout_flags: u32 = timespec: switch (timeout) {
        .none => .{
            null,
            .awake,
            linux.IORING_TIMEOUT_ABS,
        },
        .duration => |duration| {
            const ns = duration.raw.toNanoseconds();
            break :timespec .{
                .{
                    .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
                    .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
                },
                duration.clock,
                0,
            };
        },
        .deadline => |deadline| {
            const ns = deadline.raw.toNanoseconds();
            break :timespec .{
                .{
                    .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
                    .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
                },
                deadline.clock,
                linux.IORING_TIMEOUT_ABS,
            };
        },
    };
    const sqe, const fiber = try ev.enqueue();
    sqe.futexWait(@intFromPtr(fiber), ptr, expected);
    if (timespec) |*timespec_ptr| {
        sqe.flags.io_link = true;
        sqe.linkTimeout(@backingInt(Completion.Userdata.wakeup), timespec_ptr, timeout_flags | @as(u32, switch (clock) {
            .real => linux.IORING_TIMEOUT_REALTIME,
            else => 0,
            .boot => linux.IORING_TIMEOUT_BOOTTIME,
        }));
        sqe.flags.cqe_skip_success = true;
    }
    ev.yield(null, .nothing);
    switch (fiber.errno()) {
        .SUCCESS => {}, // notified by `wake()`
        .INTR, .CANCELED => {}, // caller's responsibility to retry
        .AGAIN => {}, // ptr.* != expect
        .INVAL => {}, // possibly timeout overflow
        .TIMEDOUT => unreachable,
        .FAULT => recoverableOsBugDetected(), // ptr was invalid
        else => recoverableOsBugDetected(),
    }
}

fn futexWaitUncancelable(userdata: ?*anyopaque, ptr: *const u32, expected: u32) void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    const sqe, const fiber = ev.enqueueBlocked();
    sqe.futexWait(@intFromPtr(fiber), ptr, expected);
    ev.yield(null, .nothing);
    switch (fiber.errno()) {
        .SUCCESS => {}, // notified by `wake()`
        .INTR, .CANCELED => {}, // caller's responsibility to retry
        .AGAIN => {}, // ptr.* != expect
        .INVAL => {}, // possibly timeout overflow
        .FAULT => recoverableOsBugDetected(), // ptr was invalid
        else => recoverableOsBugDetected(),
    }
}

fn futexWake(userdata: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    const sqe = ev.getSqe();
    sqe.futexWake(@backingInt(Completion.Userdata.futex_wake), ptr, max_waiters);
    sqe.flags.cqe_skip_success = true;
    ev.submit();
}

fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    return switch (operation) {
        .file_read_streaming => |o| .{
            .file_read_streaming = ev.fileReadStreaming(
                o.file,
                o.data,
            ) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => |e| e,
            },
        },
        .file_write_streaming => |o| .{
            .file_write_streaming = ev.fileWriteStreaming(
                o.file,
                o.header,
                o.data,
                o.splat,
            ) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => |e| e,
            },
        },
        .device_io_control => |o| .{
            .device_io_control = try ev.deviceIoControl(o),
        },
        .net_receive => |o| .{
            .net_receive = r: {
                const opt_err, const n = ev.netReceive(o.socket_handle, o.message_buffer, o.data_buffer, o.flags);
                break :r .{
                    if (opt_err) |err| switch (err) {
                        error.Canceled => |e| return e,
                        else => |e| e,
                    } else null,
                    n,
                };
            },
        },
        .net_read => |o| .{
            .net_read = ev.netRead(o.socket_handle, o.data) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => |e| e,
            },
        },
    };
}

fn fileReadStreaming(
    ev: *Evented,
    file: File,
    data: []const []u8,
) File.ReadStreamingError!usize {
    const n = if (data.len == 1)
        try ev.read(file.handle, data[0], null, File.Reader.Error)
    else
        try ev.preadv(file.handle, data, null, File.Reader.Error);
    return if (n == 0) error.EndOfStream else n;
}

fn fileWriteStreaming(
    ev: *Evented,
    file: File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) File.Writer.Error!usize {
    return ev.pwritev(file.handle, header, data, splat, null);
}

fn deviceIoControl(ev: *Evented, o: Io.Operation.DeviceIoControl) Io.Cancelable!i32 {
    while (true) {
        try ev.enqueueSync();
        const rc = linux.ioctl(o.file.handle, @bitCast(o.code), @intFromPtr(o.arg));
        switch (linux.errno(rc)) {
            .SUCCESS => return @bitCast(@as(u32, @truncate(rc))),
            .INTR => {},
            else => |err| return -@as(i32, @backingInt(err)),
        }
    }
}

fn batchAwaitAsync(userdata: ?*anyopaque, batch: *Io.Batch) Io.Cancelable!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    ev.batchDrainSubmitted(batch, false) catch |err| switch (err) {
        error.ConcurrencyUnavailable => unreachable, // passed concurrency=false
        error.Canceled => |e| return e,
    };
    while (true) {
        batchDrainReady(batch) catch |err| switch (err) {
            error.Timeout => unreachable, // no timeout
        };
        if (batch.completed.head != .none or batch.pending.head == .none) return;
        ev.yield(null, .{ .batch_await = batch });
    }
}

fn batchAwaitConcurrent(
    userdata: ?*anyopaque,
    batch: *Io.Batch,
    timeout: Io.Timeout,
) Io.Batch.AwaitConcurrentError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    try ev.batchDrainSubmitted(batch, true);

    const timespec: linux.kernel_timespec, const clock: Io.Clock, const timeout_flags: u32 = while (true) {
        batchDrainReady(batch) catch |err| switch (err) {
            error.Timeout => unreachable, // no timeout
        };
        if (batch.completed.head != .none or batch.pending.head == .none) return;
        switch (timeout) {
            .none => ev.yield(null, .{ .batch_await = batch }),
            .duration => |duration| {
                const ns = duration.raw.toNanoseconds();
                break .{
                    .{
                        .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
                        .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
                    },
                    duration.clock,
                    0,
                };
            },
            .deadline => |deadline| {
                const ns = deadline.raw.toNanoseconds();
                break .{
                    .{
                        .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
                        .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
                    },
                    deadline.clock,
                    linux.IORING_TIMEOUT_ABS,
                };
            },
        }
    };
    {
        // TODO: rethink cancelation
        ev.getSqe().timeout(
            @intFromPtr(&batch.userdata) | 0b11,
            &timespec,
            0,
            timeout_flags | @as(u32, switch (clock) {
                .real => linux.IORING_TIMEOUT_REALTIME,
                else => 0,
                .boot => linux.IORING_TIMEOUT_BOOTTIME,
            }),
        );
    }
    while (batch.completed.head == .none and batch.pending.head != .none) {
        ev.yield(null, .{ .batch_await = batch });
        batchDrainReady(batch) catch |err| switch (err) {
            error.Timeout => |e| return if (batch.completed.head == .none and
                batch.pending.head != .none) e,
        };
    }
    const sqe, const fiber = try ev.enqueue();
    sqe.timeoutRemove(@intFromPtr(fiber), @intFromPtr(&batch.userdata) | 0b11);
    ev.yield(null, .nothing);
    switch (fiber.errno()) {
        .SUCCESS => return,
        .BUSY, .NOENT => {},
        else => |err| unexpectedErrno(err) catch {},
    }
    while (true) {
        batchDrainReady(batch) catch |err| switch (err) {
            error.Timeout => return,
        };
        ev.yield(null, .{ .batch_await = batch });
    }
}

/// If `concurrency` is false, `error.ConcurrencyUnavailable` is unreachable.
fn batchDrainSubmitted(
    ev: *Evented,
    batch: *Io.Batch,
    concurrency: bool,
) (Io.ConcurrentError || Io.Cancelable)!void {
    var index = batch.submitted.head;
    if (index == .none) return;
    // TODO:
    //try maybe_sync.cancelRegion().awaitIoUring(ev);
    errdefer batch.submitted.head = index;
    while (index != .none) {
        const storage = &batch.storage[index.toIndex()];
        const next_index = storage.submission.node.next;
        if (@as(?Io.Operation.Result, result: switch (storage.submission.operation) {
            .file_read_streaming => |o| {
                const buffer = for (o.data) |buffer| {
                    if (buffer.len > 0) break buffer;
                } else break :result .{ .file_read_streaming = 0 };
                const fd = o.file.handle;
                storage.* = .{ .pending = .{
                    .node = .{ .prev = batch.pending.tail, .next = .none },
                    .tag = .file_read_streaming,
                    .userdata = undefined,
                } };
                ev.getSqe().read(
                    @intFromPtr(&storage.pending.userdata) | 0b10,
                    fd,
                    buffer,
                    null,
                );
                break :result null;
            },
            .file_write_streaming => |o| {
                const buffer = buffer: {
                    if (o.header.len != 0) break :buffer o.header;
                    for (o.data[0 .. o.data.len - 1]) |buffer| {
                        if (buffer.len > 0) break :buffer buffer;
                    }
                    if (o.splat > 0) break :buffer o.data[o.data.len - 1];
                    break :result .{ .file_write_streaming = 0 };
                };
                const fd = o.file.handle;
                storage.* = .{ .pending = .{
                    .node = .{ .prev = batch.pending.tail, .next = .none },
                    .tag = .file_write_streaming,
                    .userdata = undefined,
                } };
                ev.getSqe().write(@intFromPtr(&storage.pending.userdata) | 0b10, fd, buffer, null);
                break :result null;
            },
            .device_io_control => |o| if (concurrency)
                return error.ConcurrencyUnavailable
            else
                .{ .device_io_control = try ev.deviceIoControl(o) },
            .net_receive => |o| {
                _ = o;
                @panic("TODO implement batchDrainSubmitted for net_receive");
            },
            .net_read => |o| {
                _ = o;
                @panic("TODO implement batchDrainSubmitted for net_read");
            },
        })) |result| {
            switch (batch.completed.tail) {
                .none => batch.completed.head = index,
                else => |tail_index| batch.storage[tail_index.toIndex()].completion.node.next = index,
            }
            batch.completed.tail = index;
            storage.* = .{ .completion = .{ .node = .{ .next = .none }, .result = result } };
        } else {
            switch (batch.pending.tail) {
                .none => batch.pending.head = index,
                else => |tail_index| batch.storage[tail_index.toIndex()].pending.node.next = index,
            }
            batch.pending.tail = index;
            storage.pending.userdata[0] = @intFromPtr(batch);
        }
        index = next_index;
    }
    batch.submitted = .{ .head = .none, .tail = .none };
}

fn batchDrainReady(batch: *Io.Batch) Io.Timeout.Error!void {
    while (@atomicRmw(?*anyopaque, &batch.userdata, .Xchg, null, .acquire)) |head| {
        var next: usize = @intFromPtr(head);
        var timeout = false;
        while (cond: switch (@as(u2, @truncate(next))) {
            0b00 => if (timeout) return error.Timeout else false,
            0b01 => {
                assert(!timeout);
                return error.Timeout;
            },
            0b10 => true,
            0b11 => {
                assert(!timeout);
                timeout = true;
                break :cond true;
            },
        }) {
            const operation_userdata: *Io.Operation.Storage.Pending.Userdata =
                @ptrFromInt(next & ~@as(usize, 0b11));
            next = operation_userdata[0];
            const completion: Completion = .{
                .result = @bitCast(@as(u32, @intCast(operation_userdata[1]))),
                .flags = @intCast(operation_userdata[2]),
            };
            const pending: *Io.Operation.Storage.Pending =
                @fieldParentPtr("userdata", operation_userdata);
            const storage: *Io.Operation.Storage = @fieldParentPtr("pending", pending);
            const index: Io.Operation.OptionalIndex = .fromIndex(storage - batch.storage.ptr);
            assert(completion.flags & linux.IORING_CQE_F_SKIP == 0);
            switch (pending.node.prev) {
                .none => batch.pending.head = pending.node.next,
                else => |prev_index| batch.storage[prev_index.toIndex()].pending.node.next =
                    pending.node.next,
            }
            switch (pending.node.next) {
                .none => batch.pending.tail = pending.node.prev,
                else => |prev_index| batch.storage[prev_index.toIndex()].pending.node.prev =
                    pending.node.prev,
            }
            if (@as(?Io.Operation.Result, result: switch (pending.tag) {
                .file_read_streaming => .{
                    .file_read_streaming = switch (completion.errno()) {
                        .SUCCESS => @as(u32, @bitCast(completion.result)),
                        .INTR => 0,
                        .CANCELED => break :result null,
                        .INVAL => |err| errnoBug(err),
                        .FAULT => |err| errnoBug(err),
                        .AGAIN => error.WouldBlock,
                        .BADF => |err| errnoBug(err), // File descriptor used after closed
                        .IO => error.InputOutput,
                        .ISDIR => error.IsDir,
                        .NOBUFS => error.SystemResources,
                        .NOMEM => error.SystemResources,
                        .NOTCONN => error.SocketUnconnected,
                        .CONNRESET => error.ConnectionResetByPeer,
                        else => |err| unexpectedErrno(err),
                    },
                },
                .file_write_streaming => .{
                    .file_write_streaming = switch (completion.errno()) {
                        .SUCCESS => @as(u32, @bitCast(completion.result)),
                        .INTR => 0,
                        .CANCELED => break :result null,
                        .INVAL => |err| errnoBug(err),
                        .FAULT => |err| errnoBug(err),
                        .AGAIN => error.WouldBlock,
                        .BADF => error.NotOpenForWriting, // Can be a race condition.
                        .DESTADDRREQ => |err| errnoBug(err), // `connect` was never called.
                        .DQUOT => error.DiskQuota,
                        .FBIG => error.FileTooBig,
                        .IO => error.InputOutput,
                        .NOSPC => error.NoSpaceLeft,
                        .PERM => error.PermissionDenied,
                        .PIPE => error.BrokenPipe,
                        .CONNRESET => |err| errnoBug(err), // Not a socket handle.
                        .BUSY => error.DeviceBusy,
                        else => |err| unexpectedErrno(err),
                    },
                },
                .device_io_control => unreachable,
                .net_receive => @panic("TODO"),
                .net_read => @panic("TODO"),
            })) |result| {
                switch (batch.completed.tail) {
                    .none => batch.completed.head = index,
                    else => |tail_index| batch.storage[tail_index.toIndex()].completion.node.next =
                        index,
                }
                storage.* = .{ .completion = .{ .node = .{ .next = .none }, .result = result } };
                batch.completed.tail = index;
            } else {
                switch (batch.unused.tail) {
                    .none => batch.unused.head = index,
                    else => |tail_index| batch.storage[tail_index.toIndex()].unused.next = index,
                }
                storage.* = .{ .unused = .{ .prev = batch.unused.tail, .next = .none } };
                batch.unused.tail = index;
            }
        }
    }
}

fn batchCancel(userdata: ?*anyopaque, batch: *Io.Batch) void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    batchDrainReady(batch) catch |err| switch (err) {
        error.Timeout => unreachable, // no timeout
    };
    var index = batch.pending.head;
    if (index == .none) return;

    while (index != .none) {
        const pending = &batch.storage[index.toIndex()].pending;
        ev.getSqe().asyncCancel(
            @backingInt(Completion.Userdata.wakeup),
            @intFromPtr(&pending.userdata) | 0b10,
        );
        index = pending.node.next;
    }
    while (batch.pending.head != .none) batchDrainReady(batch) catch |err| switch (err) {
        error.Timeout => unreachable, // no timeout
    };
}

fn dirCreateDir(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    permissions: Dir.Permissions,
) Dir.CreateDirError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    var path_buffer: [PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);
    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.mkdirat(@intFromPtr(fiber), dir.handle, sub_path_posix, permissions.toMode());
        ev.yield(null, .nothing);
        switch (fiber.errno()) {
            .SUCCESS => return,
            .INTR, .CANCELED => {},
            .ACCES => return error.AccessDenied,
            .BADF => |err| return errnoBug(err), // File descriptor used after closed.
            .PERM => return error.PermissionDenied,
            .DQUOT => return error.DiskQuota,
            .EXIST => return error.PathAlreadyExists,
            .FAULT => |err| return errnoBug(err),
            .LOOP => return error.SymLinkLoop,
            .MLINK => return error.LinkQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .NOTDIR => return error.NotDir,
            .ROFS => return error.ReadOnlyFileSystem,
            .ILSEQ => return error.BadPathName,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn dirCreateDirPath(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    permissions: Dir.Permissions,
) Dir.CreateDirPathError!Dir.CreatePathStatus {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    var it = Dir.path.componentIterator(sub_path);
    var status: Dir.CreatePathStatus = .existed;
    var component = it.last() orelse return error.BadPathName;
    while (true) {
        if (dirCreateDir(ev, dir, component.path, permissions)) |_| {
            status = .created;
        } else |err| switch (err) {
            error.PathAlreadyExists => {
                // stat the file and return an error if it's not a directory
                // this is important because otherwise a dangling symlink
                // could cause an infinite loop
                const kind = try ev.filePathKind(dir, component.path);
                if (kind != .directory) return error.NotDir;
            },
            error.FileNotFound => |e| {
                component = it.previous() orelse return e;
                continue;
            },
            else => |e| return e,
        }
        component = it.next() orelse return status;
    }
}

const FilePathStatError = Io.Cancelable || Dir.PathNameError || error{ SystemResources, Unexpected };

fn filePathKind(ev: *Evented, dir: Dir, sub_path: []const u8) FilePathStatError!File.Kind {
    var path_buffer: [PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);
    const linux_statx, const errno = try ev.statxRaw(
        dir.handle,
        sub_path_posix.ptr,
        linux.STATX{ .TYPE = true },
        linux.AT.NO_AUTOMOUNT | linux.AT.SYMLINK_NOFOLLOW,
    );
    if (linux_statx) |ls| {
        if (!ls.mask.SIZE) return error.Unexpected;
        return statxKind(ls.mode);
    }
    return errnoToError(FilePathStatError, errno);
}

fn dirCreateDirPathOpen(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    permissions: Dir.Permissions,
    options: Dir.OpenOptions,
) Dir.CreateDirPathOpenError!Dir {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    return dirOpenDir(ev, dir, sub_path, options) catch |err| switch (err) {
        error.FileNotFound => {
            _ = try dirCreateDirPath(ev, dir, sub_path, permissions);
            return dirOpenDir(ev, dir, sub_path, options);
        },
        else => |e| return e,
    };
}

fn dirOpenDir(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.OpenOptions,
) Dir.OpenError!Dir {
    const ev: *Evented = @ptrCast(@alignCast(userdata));

    var path_buffer: [PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    return .{
        .handle = ev.openat(dir.handle, sub_path_posix, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .NOFOLLOW = !options.follow_symlinks,
            .CLOEXEC = true,
            .PATH = !options.iterate,
        }, 0) catch |err| switch (err) {
            error.IsDir => return errnoBug(.ISDIR),
            error.WouldBlock => return errnoBug(.AGAIN),
            error.FileTooBig => return errnoBug(.FBIG),
            error.NoSpaceLeft => return errnoBug(.NOSPC),
            error.DeviceBusy => return errnoBug(.BUSY), // EXCL unset.
            error.FileBusy => return errnoBug(.TXTBSY),
            error.PathAlreadyExists => return errnoBug(.EXIST), // Not creating.
            error.OperationUnsupported => return errnoBug(.OPNOTSUPP), // No TMPFILE, no locks.
            error.ReadOnlyFileSystem => return errnoBug(.ROFS), // Not creating.
            else => |e| return e,
        },
    };
}

fn dirStat(userdata: ?*anyopaque, dir: Dir) Dir.StatError!Dir.Stat {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    return ev.stat(dir.handle);
}

fn dirStatFile(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.StatFileOptions,
) Dir.StatFileError!File.Stat {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    var path_buffer: [PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);
    return ev.statx(dir.handle, sub_path_posix, linux.AT.NO_AUTOMOUNT |
        @as(u32, if (options.follow_symlinks) 0 else linux.AT.SYMLINK_NOFOLLOW));
}

fn dirAccess(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.AccessOptions,
) Dir.AccessError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));

    var path_buffer: [PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    const mode: u32 =
        @as(u32, if (options.read) linux.R_OK else 0) |
        @as(u32, if (options.write) linux.W_OK else 0) |
        @as(u32, if (options.execute) linux.X_OK else 0);
    const flags: u32 = if (options.follow_symlinks) 0 else linux.AT.SYMLINK_NOFOLLOW;

    while (true) {
        try ev.enqueueSync();
        switch (linux.errno(linux.faccessat(dir.handle, sub_path_posix, mode, flags))) {
            .SUCCESS => return,
            .INTR => {},
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ROFS => return error.ReadOnlyFileSystem,
            .LOOP => return error.SymLinkLoop,
            .TXTBSY => return error.FileBusy,
            .NOTDIR => return error.FileNotFound,
            .NOENT => return error.FileNotFound,
            .NAMETOOLONG => return error.NameTooLong,
            .INVAL => |err| return errnoBug(err),
            .FAULT => |err| return errnoBug(err),
            .IO => return error.InputOutput,
            .NOMEM => return error.SystemResources,
            .ILSEQ => return error.BadPathName,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn dirCreateFile(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    flags: Dir.CreateFileOptions,
) File.OpenError!File {
    const ev: *Evented = @ptrCast(@alignCast(userdata));

    var path_buffer: [PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    const fd = ev.openat(dir.handle, sub_path_posix, .{
        .ACCMODE = if (flags.read) .RDWR else .WRONLY,
        .CREAT = true,
        .TRUNC = flags.truncate,
        .EXCL = flags.exclusive,
        .CLOEXEC = true,
    }, flags.permissions.toMode()) catch |err| switch (err) {
        error.OperationUnsupported => return error.Unexpected, // TMPFILE unset.
        else => |e| return e,
    };
    errdefer ev.closeAsync(fd);

    switch (flags.lock) {
        .none => {},
        .shared, .exclusive => try ev.flock(
            fd,
            flags.lock,
            if (flags.lock_nonblocking) .nonblocking else .blocking,
        ),
    }

    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

fn dirCreateFileAtomic(
    userdata: ?*anyopaque,
    dir: Dir,
    dest_path: []const u8,
    options: Dir.CreateFileAtomicOptions,
) Dir.CreateFileAtomicError!File.Atomic {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    // Linux has O_TMPFILE, but linkat() does not support AT_REPLACE, so it's
    // useless when we have to make up a bogus path name to do the rename()
    // anyway.
    if (!options.replace) tmpfile: {
        const flags: linux.O = if (@hasField(linux.O, "TMPFILE")) .{
            .ACCMODE = .RDWR,
            .TMPFILE = true,
            .DIRECTORY = true,
            .CLOEXEC = true,
        } else if (@hasField(linux.O, "TMPFILE0") and !@hasField(linux.O, "TMPFILE2")) .{
            .ACCMODE = .RDWR,
            .TMPFILE0 = true,
            .TMPFILE1 = true,
            .DIRECTORY = true,
            .CLOEXEC = true,
        } else break :tmpfile;

        const dest_dirname = Dir.path.dirname(dest_path);
        if (dest_dirname) |dirname| {
            // This has a nice side effect of preemptively triggering EISDIR or
            // ENOENT, avoiding the ambiguity below.
            _ = dirCreateDirPath(ev, dir, dirname, .default_dir) catch |err| switch (err) {
                // None of these make sense in this context.
                error.IsDir,
                error.Streaming,
                error.DiskQuota,
                error.PathAlreadyExists,
                error.LinkQuotaExceeded,
                error.PipeBusy,
                error.FileTooBig,
                error.DeviceBusy,
                error.FileLocksUnsupported,
                error.FileBusy,
                => return error.Unexpected,

                else => |e| return e,
            };
        }

        var path_buffer: [PATH_MAX]u8 = undefined;
        const sub_path_posix = try pathToPosix(dest_dirname orelse ".", &path_buffer);

        return .{
            .file = .{
                .handle = ev.openat(
                    dir.handle,
                    sub_path_posix,
                    flags,
                    options.permissions.toMode(),
                ) catch |err| switch (err) {
                    error.IsDir, error.FileNotFound, error.OperationUnsupported => {
                        // Ambiguous error code. It might mean the file system
                        // does not support O_TMPFILE. Therefore, we must fall
                        // back to not using O_TMPFILE.
                        break :tmpfile;
                    },
                    error.FileTooBig => return errnoBug(.FBIG),
                    error.DeviceBusy => return errnoBug(.BUSY), // O_EXCL not passed
                    error.PathAlreadyExists => return errnoBug(.EXIST), // Not creating.
                    else => |e| return e,
                },
                .flags = .{ .nonblocking = false },
            },
            .file_basename_hex = 0,
            .dest_sub_path = dest_path,
            .file_open = true,
            .file_exists = false,
            .close_dir_on_deinit = false,
            .dir = dir,
        };
    }

    if (Dir.path.dirname(dest_path)) |dirname| {
        const new_dir = if (options.make_path)
            dirCreateDirPathOpen(ev, dir, dirname, .default_dir, .{}) catch |err| switch (err) {
                // None of these make sense in this context.
                error.IsDir,
                error.Streaming,
                error.DiskQuota,
                error.PathAlreadyExists,
                error.LinkQuotaExceeded,
                error.PipeBusy,
                error.FileTooBig,
                error.FileLocksUnsupported,
                error.DeviceBusy,
                => return error.Unexpected,

                else => |e| return e,
            }
        else
            try dirOpenDir(ev, dir, dirname, .{});

        return ev.atomicFileInit(Dir.path.basename(dest_path), options.permissions, new_dir, true);
    }

    return ev.atomicFileInit(dest_path, options.permissions, dir, false);
}

fn atomicFileInit(
    ev: *Evented,
    dest_basename: []const u8,
    permissions: File.Permissions,
    dir: Dir,
    close_dir_on_deinit: bool,
) Dir.CreateFileAtomicError!File.Atomic {
    while (true) {
        var random_integer: u64 = undefined;
        random(ev, @ptrCast(&random_integer));
        const tmp_sub_path = std.fmt.hex(random_integer);
        const file = dirCreateFile(ev, dir, &tmp_sub_path, .{
            .permissions = permissions,
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            error.DeviceBusy => continue,
            error.FileBusy => continue,

            error.IsDir => return error.Unexpected, // No path components.
            error.FileTooBig => return error.Unexpected, // Creating, not opening.
            error.FileLocksUnsupported => return error.Unexpected, // Not asking for locks.
            error.PipeBusy => return error.Unexpected, // Not opening a pipe.

            else => |e| return e,
        };
        return .{
            .file = file,
            .file_basename_hex = random_integer,
            .dest_sub_path = dest_basename,
            .file_open = true,
            .file_exists = true,
            .close_dir_on_deinit = close_dir_on_deinit,
            .dir = dir,
        };
    }
}

fn dirOpenFile(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    flags: Dir.OpenFileOptions,
) File.OpenError!File {
    const ev: *Evented = @ptrCast(@alignCast(userdata));

    var path_buffer: [PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    const fd = ev.openat(dir.handle, sub_path_posix, .{
        .ACCMODE = switch (flags.mode) {
            .read_only => .RDONLY,
            .write_only => .WRONLY,
            .read_write => .RDWR,
        },
        .NOCTTY = !flags.allow_ctty,
        .NOFOLLOW = !flags.follow_symlinks,
        .CLOEXEC = true,
        .PATH = flags.path_only,
    }, 0) catch |err| switch (err) {
        error.OperationUnsupported => return error.Unexpected, // TMPFILE unset.
        else => |e| return e,
    };
    errdefer ev.closeAsync(fd);

    if (!flags.allow_directory) {
        const is_dir = is_dir: {
            const s = ev.stat(fd) catch |err| switch (err) {
                // The directory-ness is either unknown or unknowable
                error.Streaming => break :is_dir false,
                else => |e| return e,
            };
            break :is_dir s.kind == .directory;
        };
        if (is_dir) return error.IsDir;
    }

    switch (flags.lock) {
        .none => {},
        .shared, .exclusive => try ev.flock(
            fd,
            flags.lock,
            if (flags.lock_nonblocking) .nonblocking else .blocking,
        ),
    }

    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

fn dirClose(userdata: ?*anyopaque, dirs: []const Dir) void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    for (dirs) |dir| ev.close(dir.handle);
}

fn dirRead(userdata: ?*anyopaque, dr: *Dir.Reader, buffer: []Dir.Entry) Dir.Reader.Error!usize {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    var buffer_index: usize = 0;
    while (buffer.len - buffer_index != 0) {
        if (dr.end - dr.index == 0) {
            // Refill the buffer, unless we've already created references to
            // buffered data.
            if (buffer_index != 0) break;

            if (dr.state == .reset) {
                ev.lseek(dr.dir.handle, 0, linux.SEEK.SET) catch |err| switch (err) {
                    error.Unseekable => return error.Unexpected,
                    else => |e| return e,
                };
                dr.state = .reading;
            }
            const n = while (true) {
                try ev.enqueueSync();
                const rc = linux.getdents64(dr.dir.handle, dr.buffer.ptr, @min(dr.buffer.len, std.math.maxInt(c_uint)));
                switch (linux.errno(rc)) {
                    .SUCCESS => break rc,
                    .INTR => {},
                    .BADF => |err| return errnoBug(err), // Dir is invalid or was opened without iteration ability.
                    .FAULT => |err| return errnoBug(err),
                    .NOTDIR => |err| return errnoBug(err),
                    // To be consistent across platforms, iteration
                    // ends if the directory being iterated is deleted
                    // during iteration. This matches the behavior of
                    // non-Linux, non-WASI UNIX platforms.
                    .NOENT => {
                        dr.state = .finished;
                        return 0;
                    },
                    // This can occur when reading /proc/$PID/net, or
                    // if the provided buffer is too small. Neither
                    // scenario is intended to be handled by this API.
                    .INVAL => return error.Unexpected,
                    .ACCES => return error.AccessDenied, // Lacking permission to iterate this directory.
                    else => |err| return unexpectedErrno(err),
                }
            };
            if (n == 0) {
                dr.state = .finished;
                return 0;
            }
            dr.index = 0;
            dr.end = n;
        }
        // Linux aligns the header by padding after the null byte of the name
        // to align the next entry. This means we can find the end of the name
        // by looking at only the 8 bytes before the next record. However since
        // file names are usually short it's better to keep the machine code
        // simpler.
        //
        // Furthermore, I observed qemu user mode to not align this struct, so
        // this code makes the conservative choice to not assume alignment.
        const linux_entry: *align(1) linux.dirent64 = @ptrCast(&dr.buffer[dr.index]);
        const next_index = dr.index + linux_entry.reclen;
        dr.index = next_index;
        const name_ptr: [*]u8 = &linux_entry.name;
        const padded_name = name_ptr[0 .. linux_entry.reclen - @offsetOf(linux.dirent64, "name")];
        const name_len = std.mem.findScalar(u8, padded_name, 0).?;
        const name = name_ptr[0..name_len :0];

        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const entry_kind: File.Kind = switch (linux_entry.type) {
            linux.DT.BLK => .block_device,
            linux.DT.CHR => .character_device,
            linux.DT.DIR => .directory,
            linux.DT.FIFO => .named_pipe,
            linux.DT.LNK => .sym_link,
            linux.DT.REG => .file,
            linux.DT.SOCK => .unix_domain_socket,
            else => .unknown,
        };
        buffer[buffer_index] = .{
            .name = name,
            .kind = entry_kind,
            .inode = linux_entry.ino,
        };
        buffer_index += 1;
    }
    return buffer_index;
}

fn dirRealPath(userdata: ?*anyopaque, dir: Dir, out_buffer: []u8) Dir.RealPathError!usize {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    return ev.realPath(dir.handle, out_buffer);
}

fn dirRealPathFile(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    out_buffer: []u8,
) Dir.RealPathFileError!usize {
    const ev: *Evented = @ptrCast(@alignCast(userdata));

    var path_buffer: [PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    const fd = ev.openat(dir.handle, sub_path_posix, .{
        .CLOEXEC = true,
        .PATH = true,
    }, 0) catch |err| switch (err) {
        error.WouldBlock => return errnoBug(.AGAIN),
        error.OperationUnsupported => return errnoBug(.OPNOTSUPP), // Not asking for locks.
        error.ReadOnlyFileSystem => return errnoBug(.ROFS), // Not creating.
        else => |e| return e,
    };
    defer ev.closeAsync(fd);
    return ev.realPath(fd, out_buffer);
}

fn dirDeleteFile(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8) Dir.DeleteFileError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));

    var path_buffer: [PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.unlinkat(@intFromPtr(fiber), dir.handle, sub_path_posix, 0);
        ev.yield(null, .nothing);
        switch (fiber.errno()) {
            .SUCCESS => return,
            .INTR, .CANCELED => {},
            .PERM => return error.PermissionDenied,
            .ACCES => return error.AccessDenied,
            .BUSY => return error.FileBusy,
            .FAULT => |err| return errnoBug(err),
            .IO => return error.FileSystem,
            .ISDIR => return error.IsDir,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NOMEM => return error.SystemResources,
            .ROFS => return error.ReadOnlyFileSystem,
            .EXIST => |err| return errnoBug(err),
            .NOTEMPTY => |err| return errnoBug(err), // Not passing AT.REMOVEDIR
            .ILSEQ => return error.BadPathName,
            .INVAL => |err| return errnoBug(err), // invalid flags, or pathname has . as last component
            .BADF => |err| return errnoBug(err), // File descriptor used after closed.
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn dirDeleteDir(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8) Dir.DeleteDirError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));

    var path_buffer: [PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);

    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.unlinkat(@intFromPtr(fiber), dir.handle, sub_path_posix, linux.AT.REMOVEDIR);
        ev.yield(null, .nothing);
        switch (fiber.errno()) {
            .SUCCESS => return,
            .INTR, .CANCELED => {},
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .BUSY => return error.FileBusy,
            .FAULT => |err| return errnoBug(err),
            .IO => return error.FileSystem,
            .ISDIR => |err| return errnoBug(err),
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NOMEM => return error.SystemResources,
            .ROFS => return error.ReadOnlyFileSystem,
            .EXIST => |err| return errnoBug(err),
            .NOTEMPTY => return error.DirNotEmpty,
            .ILSEQ => return error.BadPathName,
            .INVAL => |err| return errnoBug(err), // invalid flags, or pathname has . as last component
            .BADF => |err| return errnoBug(err), // File descriptor used after closed.
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn dirRename(
    userdata: ?*anyopaque,
    old_dir: Dir,
    old_sub_path: []const u8,
    new_dir: Dir,
    new_sub_path: []const u8,
) Dir.RenameError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));

    var old_path_buffer: [PATH_MAX]u8 = undefined;
    var new_path_buffer: [PATH_MAX]u8 = undefined;

    const old_sub_path_posix = try pathToPosix(old_sub_path, &old_path_buffer);
    const new_sub_path_posix = try pathToPosix(new_sub_path, &new_path_buffer);

    return ev.renameat(
        old_dir.handle,
        old_sub_path_posix,
        new_dir.handle,
        new_sub_path_posix,
        .{},
    );
}

fn dirRenamePreserve(
    userdata: ?*anyopaque,
    old_dir: Dir,
    old_sub_path: []const u8,
    new_dir: Dir,
    new_sub_path: []const u8,
) Dir.RenamePreserveError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));

    var old_path_buffer: [PATH_MAX]u8 = undefined;
    var new_path_buffer: [PATH_MAX]u8 = undefined;

    const old_sub_path_posix = try pathToPosix(old_sub_path, &old_path_buffer);
    const new_sub_path_posix = try pathToPosix(new_sub_path, &new_path_buffer);

    return ev.renameat(
        old_dir.handle,
        old_sub_path_posix,
        new_dir.handle,
        new_sub_path_posix,
        .{ .NOREPLACE = true },
    );
}

fn dirSymLink(
    userdata: ?*anyopaque,
    dir: Dir,
    target_path: []const u8,
    sym_link_path: []const u8,
    flags: Dir.SymLinkFlags,
) Dir.SymLinkError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    _ = flags;

    var target_path_buffer: [PATH_MAX]u8 = undefined;
    var sym_link_path_buffer: [PATH_MAX]u8 = undefined;

    const target_path_posix = try pathToPosix(target_path, &target_path_buffer);
    const sym_link_path_posix = try pathToPosix(sym_link_path, &sym_link_path_buffer);

    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.symlinkat(@intFromPtr(fiber), target_path_posix.ptr, dir.handle, sym_link_path_posix.ptr);
        ev.yield(null, .nothing);
        switch (fiber.errno()) {
            .SUCCESS => return,
            .INTR, .CANCELED => {},
            .FAULT => |err| return errnoBug(err),
            .INVAL => |err| return errnoBug(err),
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .DQUOT => return error.DiskQuota,
            .EXIST => return error.PathAlreadyExists,
            .IO => return error.FileSystem,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .ROFS => return error.ReadOnlyFileSystem,
            .ILSEQ => return error.BadPathName,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn dirReadLink(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    buffer: []u8,
) Dir.ReadLinkError!usize {
    const ev: *Evented = @ptrCast(@alignCast(userdata));

    var sub_path_buffer: [PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &sub_path_buffer);

    while (true) {
        try ev.enqueueSync();
        const rc = linux.readlinkat(dir.handle, sub_path_posix, buffer.ptr, buffer.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return @bitCast(rc),
            .INTR => {},
            .ACCES => return error.AccessDenied,
            .FAULT => |err| return errnoBug(err),
            .INVAL => return error.NotLink,
            .IO => return error.FileSystem,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOTDIR => return error.NotDir,
            .ILSEQ => return error.BadPathName,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn dirSetOwner(
    userdata: ?*anyopaque,
    dir: Dir,
    owner: ?File.Uid,
    group: ?File.Gid,
) Dir.SetOwnerError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    try ev.fchownat(
        dir.handle,
        "",
        owner orelse std.math.maxInt(linux.uid_t),
        group orelse std.math.maxInt(linux.gid_t),
        linux.AT.EMPTY_PATH,
    );
}

fn dirSetFileOwner(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    owner: ?File.Uid,
    group: ?File.Gid,
    options: Dir.SetFileOwnerOptions,
) Dir.SetFileOwnerError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    var path_buffer: [PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);
    try ev.fchownat(
        dir.handle,
        sub_path_posix,
        owner orelse std.math.maxInt(linux.uid_t),
        group orelse std.math.maxInt(linux.gid_t),
        if (options.follow_symlinks) 0 else linux.AT.SYMLINK_NOFOLLOW,
    );
}

fn dirSetPermissions(
    userdata: ?*anyopaque,
    dir: Dir,
    permissions: Dir.Permissions,
) Dir.SetPermissionsError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    ev.fchmodat(
        dir.handle,
        "",
        permissions.toMode(),
        linux.AT.EMPTY_PATH,
    ) catch |err| switch (err) {
        error.NameTooLong => return errnoBug(.NAMETOOLONG),
        error.BadPathName => return errnoBug(.ILSEQ),
        error.ProcessFdQuotaExceeded => return errnoBug(.MFILE),
        error.SystemFdQuotaExceeded => return errnoBug(.NFILE),
        error.OperationUnsupported => return errnoBug(.OPNOTSUPP),
        else => |e| return e,
    };
}

fn dirSetFilePermissions(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    permissions: Dir.Permissions,
    options: Dir.SetFilePermissionsOptions,
) Dir.SetFilePermissionsError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    var path_buffer: [PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);
    try ev.fchmodat(
        dir.handle,
        sub_path_posix,
        permissions.toMode(),
        if (options.follow_symlinks) 0 else linux.AT.SYMLINK_NOFOLLOW,
    );
}

fn dirSetTimestamps(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.SetTimestampsOptions,
) Dir.SetTimestampsError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    var path_buffer: [PATH_MAX]u8 = undefined;
    const sub_path_posix = try pathToPosix(sub_path, &path_buffer);
    try ev.utimensat(
        dir.handle,
        sub_path_posix,
        if (options.modify_timestamp != .now or options.access_timestamp != .now) &.{
            setTimestampToPosix(options.access_timestamp),
            setTimestampToPosix(options.modify_timestamp),
        } else null,
        if (options.follow_symlinks) 0 else linux.AT.SYMLINK_NOFOLLOW,
    );
}

fn dirHardLink(
    userdata: ?*anyopaque,
    old_dir: Dir,
    old_sub_path: []const u8,
    new_dir: Dir,
    new_sub_path: []const u8,
    options: Dir.HardLinkOptions,
) Dir.HardLinkError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));

    var old_path_buffer: [PATH_MAX]u8 = undefined;
    var new_path_buffer: [PATH_MAX]u8 = undefined;

    const old_sub_path_posix = try pathToPosix(old_sub_path, &old_path_buffer);
    const new_sub_path_posix = try pathToPosix(new_sub_path, &new_path_buffer);

    return ev.linkat(
        old_dir.handle,
        old_sub_path_posix,
        new_dir.handle,
        new_sub_path_posix,
        if (options.follow_symlinks) linux.AT.SYMLINK_FOLLOW else 0,
    );
}

fn fileStat(userdata: ?*anyopaque, file: File) File.StatError!File.Stat {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    return ev.stat(file.handle);
}

fn fileLength(userdata: ?*anyopaque, file: File) File.StatError!u64 {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    const linux_statx, const errno = try ev.statxRaw(
        file.handle,
        "",
        linux.STATX{ .SIZE = true },
        linux.AT.EMPTY_PATH,
    );
    if (linux_statx) |ls| {
        if (!ls.mask.SIZE) return error.Unexpected;
        return ls.size;
    }
    return errnoToError(File.StatError, errno);
}

fn fileClose(userdata: ?*anyopaque, files: []const File) void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    for (files) |file| ev.close(file.handle);
}

fn fileWritePositional(
    userdata: ?*anyopaque,
    file: File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    offset: u64,
) File.WritePositionalError!usize {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    return ev.pwritev(file.handle, header, data, splat, offset);
}

fn fileWriteFileStreaming(
    userdata: ?*anyopaque,
    file: File,
    header: []const u8,
    file_reader: *File.Reader,
    limit: Io.Limit,
) File.Writer.WriteFileError!usize {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    _ = ev;
    _ = file;
    _ = header;
    _ = file_reader;
    _ = limit;
    return error.Unimplemented;
}

fn fileWriteFilePositional(
    userdata: ?*anyopaque,
    file: File,
    header: []const u8,
    file_reader: *File.Reader,
    limit: Io.Limit,
    offset: u64,
) File.WriteFilePositionalError!usize {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    _ = ev;
    _ = file;
    _ = header;
    _ = file_reader;
    _ = limit;
    _ = offset;
    return error.Unimplemented;
}

fn fileReadPositional(
    userdata: ?*anyopaque,
    file: File,
    data: []const []u8,
    offset: u64,
) File.ReadPositionalError!usize {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    if (data.len == 1) {
        return try ev.read(file.handle, data[0], offset, File.ReadPositionalError);
    }
    return ev.preadv(file.handle, data, offset, File.ReadPositionalError);
}

fn fileSeekBy(userdata: ?*anyopaque, file: File, offset: i64) File.SeekError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    try ev.lseek(file.handle, @bitCast(offset), linux.SEEK.CUR);
}

fn fileSeekTo(userdata: ?*anyopaque, file: File, offset: u64) File.SeekError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    try ev.lseek(file.handle, offset, linux.SEEK.SET);
}

fn fileSync(userdata: ?*anyopaque, file: File) File.SyncError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.fsync(@intFromPtr(fiber), file.handle, 0);
        ev.yield(null, .nothing);
        switch (fiber.errno()) {
            .SUCCESS => return,
            .INTR, .CANCELED => {},
            .BADF => |err| return errnoBug(err),
            .INVAL => |err| return errnoBug(err),
            .ROFS => |err| return errnoBug(err),
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .DQUOT => return error.DiskQuota,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn fileIsTty(userdata: ?*anyopaque, file: File) Io.Cancelable!bool {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    while (true) {
        try ev.enqueueSync();
        var wsz: winsize = undefined;
        const rc = linux.ioctl(file.handle, linux.T.IOCGWINSZ, @intFromPtr(&wsz));
        switch (linux.errno(rc)) {
            .SUCCESS => return true,
            .INTR => {},
            else => return false,
        }
    }
}

fn fileEnableAnsiEscapeCodes(userdata: ?*anyopaque, file: File) File.EnableAnsiEscapeCodesError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    if (!try fileIsTty(ev, file)) return error.NotTerminalDevice;
}

fn fileSetLength(userdata: ?*anyopaque, file: File, length: u64) File.SetLengthError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.ftrucate(@intFromPtr(fiber), file.handle, length, 0);
        ev.yield(null, .nothing);
        switch (fiber.errno()) {
            .SUCCESS => return,
            .INTR, .CANCELED => {},
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .PERM => return error.PermissionDenied,
            .TXTBSY => return error.FileBusy,
            .BADF => |err| return errnoBug(err), // Handle not open for writing.
            .INVAL => return error.NonResizable, // This is returned for /dev/null for example.
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn fileSetOwner(
    userdata: ?*anyopaque,
    file: File,
    owner: ?File.Uid,
    group: ?File.Gid,
) File.SetOwnerError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    try ev.fchownat(
        file.handle,
        "",
        owner orelse std.math.maxInt(linux.uid_t),
        group orelse std.math.maxInt(linux.gid_t),
        linux.AT.EMPTY_PATH,
    );
}

fn fileSetPermissions(
    userdata: ?*anyopaque,
    file: File,
    permissions: File.Permissions,
) File.SetPermissionsError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    ev.fchmodat(
        file.handle,
        "",
        permissions.toMode(),
        linux.AT.EMPTY_PATH,
    ) catch |err| switch (err) {
        error.NameTooLong => return errnoBug(.NAMETOOLONG),
        error.BadPathName => return errnoBug(.ILSEQ),
        error.ProcessFdQuotaExceeded => return errnoBug(.MFILE),
        error.SystemFdQuotaExceeded => return errnoBug(.NFILE),
        error.OperationUnsupported => return errnoBug(.OPNOTSUPP),
        else => |e| return e,
    };
}

fn fileSetTimestamps(
    userdata: ?*anyopaque,
    file: File,
    options: File.SetTimestampsOptions,
) File.SetTimestampsError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    try ev.utimensat(
        file.handle,
        "",
        if (options.modify_timestamp != .now or options.access_timestamp != .now) &.{
            setTimestampToPosix(options.access_timestamp),
            setTimestampToPosix(options.modify_timestamp),
        } else null,
        linux.AT.EMPTY_PATH,
    );
}

fn fileLock(userdata: ?*anyopaque, file: File, lock: File.Lock) File.LockError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    ev.flock(file.handle, lock, .blocking) catch |err| switch (err) {
        error.WouldBlock => unreachable, // blocking
        else => |e| return e,
    };
}

fn fileTryLock(userdata: ?*anyopaque, file: File, lock: File.Lock) File.LockError!bool {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    ev.flock(file.handle, lock, switch (lock) {
        .none => .blocking,
        .shared, .exclusive => .nonblocking,
    }) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => |e| return e,
    };
    return true;
}

fn fileUnlock(userdata: ?*anyopaque, file: File) void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    ev.flock(file.handle, .none, .blocking) catch |err| switch (err) {
        error.Canceled => unreachable, // blocked
        error.WouldBlock => unreachable, // blocking
        error.SystemResources => return recoverableOsBugDetected(), // Resource deallocation.
        error.FileLocksUnsupported => return recoverableOsBugDetected(), // We already got the lock.
        error.Unexpected => return recoverableOsBugDetected(), // Resource deallocation must succeed.
    };
}

fn fileDowngradeLock(userdata: ?*anyopaque, file: File) File.DowngradeLockError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    ev.flock(file.handle, .shared, .nonblocking) catch |err| switch (err) {
        error.WouldBlock => return errnoBug(.AGAIN), // File was not locked in exclusive mode.
        error.SystemResources => return errnoBug(.NOLCK), // Lock already obtained.
        error.FileLocksUnsupported => return errnoBug(.OPNOTSUPP), // Lock already obtained.
        else => |e| return e,
    };
}

fn fileRealPath(userdata: ?*anyopaque, file: File, out_buffer: []u8) File.RealPathError!usize {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    return ev.realPath(file.handle, out_buffer);
}

fn fileHardLink(
    userdata: ?*anyopaque,
    file: File,
    new_dir: Dir,
    new_sub_path: []const u8,
    options: File.HardLinkOptions,
) File.HardLinkError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));

    var new_path_buffer: [PATH_MAX]u8 = undefined;
    const new_sub_path_posix = try pathToPosix(new_sub_path, &new_path_buffer);

    return ev.linkat(
        file.handle,
        "",
        new_dir.handle,
        new_sub_path_posix,
        linux.AT.EMPTY_PATH | @as(u32, if (options.follow_symlinks) linux.AT.SYMLINK_FOLLOW else 0),
    );
}

fn fileMemoryMapCreate(
    userdata: ?*anyopaque,
    file: File,
    options: File.MemoryMap.CreateOptions,
) File.MemoryMap.CreateError!File.MemoryMap {
    const ev: *Evented = @ptrCast(@alignCast(userdata));

    const prot: linux.PROT = .{
        .READ = options.protection.read,
        .WRITE = options.protection.write,
        .EXEC = options.protection.execute,
    };
    const flags: linux.MAP = .{
        .TYPE = .SHARED_VALIDATE,
        .POPULATE = options.populate,
    };

    const page_align = std.heap.page_size_min;
    const contents = while (true) {
        try ev.enqueueSync();
        const casted_offset = std.math.cast(i64, options.offset) orelse return error.Unseekable;
        const rc = linux.mmap(null, options.len, prot, flags, file.handle, casted_offset);
        switch (linux.errno(rc)) {
            .SUCCESS => break @as([*]align(page_align) u8, @ptrFromInt(rc))[0..options.len],
            .INTR => {},
            .ACCES => return error.AccessDenied,
            .AGAIN => return error.LockedMemoryLimitExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.OutOfMemory,
            .PERM => return error.PermissionDenied,
            .OVERFLOW => return error.Unseekable,
            .BADF => |err| return errnoBug(err), // Always a race condition.
            .INVAL => |err| return errnoBug(err), // Invalid parameters to mmap()
            .OPNOTSUPP => |err| return errnoBug(err), // Bad flags with MAP.SHARED_VALIDATE on Linux.
            else => |err| return unexpectedErrno(err),
        }
    };
    return .{
        .file = file,
        .offset = options.offset,
        .memory = contents,
        .section = {},
    };
}

fn fileMemoryMapDestroy(userdata: ?*anyopaque, mm: *File.MemoryMap) void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    _ = ev;
    const memory = mm.memory;
    if (memory.len == 0) return;
    switch (linux.errno(linux.munmap(memory.ptr, memory.len))) {
        .SUCCESS => {},
        else => |err| if (builtin.mode == .debug)
            std.log.err("failed to unmap {d} bytes at {*}: {t}", .{ memory.len, memory.ptr, err }),
    }
    mm.* = undefined;
}

fn fileMemoryMapSetLength(
    userdata: ?*anyopaque,
    mm: *File.MemoryMap,
    new_len: usize,
) File.MemoryMap.SetLengthError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));

    const page_size = std.heap.pageSize();
    const alignment: Alignment = .fromByteUnits(page_size);
    const page_align = std.heap.page_size_min;
    const old_memory = mm.memory;

    if (alignment.forward(new_len) == alignment.forward(old_memory.len)) {
        mm.memory.len = new_len;
        return;
    }
    const flags: linux.MREMAP = .{ .MAYMOVE = true };
    const addr_hint: ?[*]const u8 = null;
    const new_memory = while (true) {
        try ev.enqueueSync();
        const rc = linux.mremap(old_memory.ptr, old_memory.len, new_len, flags, addr_hint);
        switch (linux.errno(rc)) {
            .SUCCESS => break @as([*]align(page_align) u8, @ptrFromInt(rc))[0..new_len],
            .INTR => {},
            .AGAIN => return error.LockedMemoryLimitExceeded,
            .NOMEM => return error.OutOfMemory,
            .INVAL => |err| return errnoBug(err),
            .FAULT => |err| return errnoBug(err),
            else => |err| return unexpectedErrno(err),
        }
    };
    mm.memory = new_memory;
}

fn fileMemoryMapRead(userdata: ?*anyopaque, mm: *File.MemoryMap) File.ReadPositionalError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    _ = ev;
    _ = mm;
}

fn fileMemoryMapWrite(userdata: ?*anyopaque, mm: *File.MemoryMap) File.WritePositionalError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    _ = ev;
    _ = mm;
}

fn processExecutableOpen(
    userdata: ?*anyopaque,
    flags: Dir.OpenFileOptions,
) process.OpenExecutableError!File {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    return dirOpenFile(ev, .{ .handle = linux.AT.FDCWD }, "/proc/self/exe", flags);
}

fn processExecutablePath(userdata: ?*anyopaque, out_buffer: []u8) process.ExecutablePathError!usize {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    return dirReadLink(ev, .cwd(), "/proc/self/exe", out_buffer) catch |err| switch (err) {
        error.UnsupportedReparsePointType => unreachable, // Windows-only
        error.NetworkNotFound => unreachable, // Windows-only
        error.FileBusy => unreachable, // Windows-only
        else => |e| return e,
    };
}

fn lockStderr(userdata: ?*anyopaque, terminal_mode: ?Io.Terminal.Mode) Io.Cancelable!Io.LockedStderr {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    const ev_io = ev.io();
    ev.stderr_mutex.lockUncancelable(ev_io);
    errdefer ev.stderr_mutex.unlock(ev_io);
    return ev.initLockedStderr(terminal_mode);
}

fn tryLockStderr(
    userdata: ?*anyopaque,
    terminal_mode: ?Io.Terminal.Mode,
) Io.Cancelable!?Io.LockedStderr {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    const ev_io = ev.io();
    if (!ev.stderr_mutex.tryLock()) return null;
    errdefer ev.stderr_mutex.unlock(ev_io);
    return try ev.initLockedStderr(terminal_mode);
}

fn initLockedStderr(ev: *Evented, terminal_mode: ?Io.Terminal.Mode) Io.Cancelable!Io.LockedStderr {
    if (!ev.stderr_writer_initialized) {
        const ev_io = ev.io();
        const cancel_protection = swapCancelProtection(ev, .blocked);
        defer assert(swapCancelProtection(ev, cancel_protection) == .blocked);
        ev.scanEnviron() catch |err| switch (err) {
            error.Canceled => unreachable, // blocked
        };
        const NO_COLOR = ev.environ.exist.NO_COLOR;
        const CLICOLOR_FORCE = ev.environ.exist.CLICOLOR_FORCE;
        ev.stderr_mode = Io.Terminal.Mode.detect(
            ev_io,
            ev.stderr_writer.file,
            NO_COLOR,
            CLICOLOR_FORCE,
        ) catch |err| switch (err) {
            error.Canceled => unreachable, // blocked
        };
        ev.stderr_writer_initialized = true;
    }
    return .{
        .file_writer = &ev.stderr_writer,
        .terminal_mode = terminal_mode orelse ev.stderr_mode,
    };
}

fn unlockStderr(userdata: ?*anyopaque) void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    if (ev.stderr_writer.err == null) ev.stderr_writer.interface.flush() catch {};
    if (ev.stderr_writer.err) |err| {
        switch (err) {
            error.Canceled => ev.currentFiber().cancel_protection.recancel(),
            else => {},
        }
        ev.stderr_writer.err = null;
    }
    ev.stderr_writer.interface.end = 0;
    ev.stderr_writer.interface.buffer = &.{};
    ev.stderr_mutex.unlock(ev.io());
}

fn processCurrentPath(userdata: ?*anyopaque, buffer: []u8) process.CurrentPathError!usize {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    while (true) {
        try ev.enqueueSync();
        switch (linux.errno(linux.getcwd(buffer.ptr, buffer.len))) {
            .SUCCESS => return std.mem.findScalar(u8, buffer, 0).?,
            .INTR => {},
            .NOENT => return error.CurrentDirUnlinked,
            .RANGE => return error.NameTooLong,
            .FAULT => |err| return errnoBug(err),
            .INVAL => |err| return errnoBug(err),
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn processSetCurrentDir(userdata: ?*anyopaque, dir: Dir) process.SetCurrentDirError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    if (dir.handle == linux.AT.FDCWD) return;
    try ev.enqueueSync();
    return fchdir(dir.handle);
}

fn processSetCurrentPath(userdata: ?*anyopaque, dir_path: []const u8) process.SetCurrentPathError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    var path_buffer: [PATH_MAX]u8 = undefined;
    const dir_path_posix = try pathToPosix(dir_path, &path_buffer);
    try ev.enqueueSync();
    return chdir(dir_path_posix);
}

fn processReplace(userdata: ?*anyopaque, options: process.ReplaceOptions) process.ReplaceError {
    const ev: *Evented = @ptrCast(@alignCast(userdata));

    try ev.scanEnviron(); // for PATH
    const PATH = ev.environ.string.PATH orelse default_PATH;

    var arena_allocator = std.heap.ArenaAllocator.init(ev.backing_allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const argv_buf = try arena.allocSentinel(?[*:0]const u8, options.argv.len, null);
    for (options.argv, 0..) |arg, i| argv_buf[i] = (try arena.dupeSentinel(u8, arg, 0)).ptr;

    const env_block = env_block: {
        const prog_fd: i32 = -1;
        if (options.environ_map) |environ_map| break :env_block try environ_map.createPosixBlock(arena, .{
            .zig_progress_fd = prog_fd,
        });
        break :env_block try ev.environ.process_environ.createPosixBlock(arena, .{
            .zig_progress_fd = prog_fd,
        });
    };

    try ev.enqueueSync();
    return execv(options.expand_arg0, argv_buf.ptr[0].?, argv_buf.ptr, env_block, PATH);
}

fn processReplacePath(
    userdata: ?*anyopaque,
    dir: Dir,
    options: process.ReplaceOptions,
) process.ReplaceError {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    _ = ev;
    _ = dir;
    _ = options;
    @panic("TODO processReplacePath");
}

fn processSpawn(userdata: ?*anyopaque, options: process.SpawnOptions) process.SpawnError!process.Child {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    const spawned = try ev.spawn(options);
    defer ev.closeAsync(spawned.err_fd);

    // Wait for the child to report any errors in or before `execvpe`.
    var child_err: ForkBailError = undefined;
    ev.readAll(spawned.err_fd, @ptrCast(&child_err)) catch |read_err| {
        switch (read_err) {
            error.Canceled => unreachable, // blocked
            error.EndOfStream => {
                // Write end closed by CLOEXEC at the time of the `execvpe` call,
                // indicating success.
            },
            else => {
                // Problem reading the error from the error reporting pipe. We
                // don't know if the child is alive or dead. Better to assume it is
                // alive so the resource does not risk being leaked.
            },
        }
        return .{
            .id = spawned.pid,
            .thread_handle = {},
            .stdin = spawned.stdin,
            .stdout = spawned.stdout,
            .stderr = spawned.stderr,
            .request_resource_usage_statistics = options.request_resource_usage_statistics,
        };
    };
    return child_err;
}

fn processSpawnPath(
    userdata: ?*anyopaque,
    dir: Dir,
    options: process.SpawnOptions,
) process.SpawnError!process.Child {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    _ = ev;
    _ = dir;
    _ = options;
    @panic("TODO processSpawnPath");
}

const prog_fileno = @max(linux.STDIN_FILENO, linux.STDOUT_FILENO, linux.STDERR_FILENO);

const Spawned = struct {
    pid: pid_t,
    err_fd: fd_t,
    stdin: ?File,
    stdout: ?File,
    stderr: ?File,
};
fn spawn(ev: *Evented, options: process.SpawnOptions) process.SpawnError!Spawned {
    try ev.enqueueSync();
    // The child process does need to access (one end of) these pipes. However,
    // we must initially set CLOEXEC to avoid a race condition. If another thread
    // is racing to spawn a different child process, we don't want it to inherit
    // these FDs in any scenario; that would mean that, for instance, calls to
    // `poll` from the parent would not report the child's stdout as closing when
    // expected, since the other child may retain a reference to the write end of
    // the pipe. So, we create the pipes with CLOEXEC initially. After fork, we
    // need to do something in the new child to make sure we preserve the reference
    // we want. We could use `fcntl` to remove CLOEXEC from the FD, but as it
    // turns out, we `dup2` everything anyway, so there's no need!
    const pipe_flags: linux.O = .{ .CLOEXEC = true };

    const stdin_pipe = if (options.stdin == .pipe) try pipe2Sync(pipe_flags) else undefined;
    errdefer if (options.stdin == .pipe) {
        ev.destroyPipe(stdin_pipe);
    };

    const stdout_pipe = if (options.stdout == .pipe) try pipe2Sync(pipe_flags) else undefined;
    errdefer if (options.stdout == .pipe) {
        ev.destroyPipe(stdout_pipe);
    };

    const stderr_pipe = if (options.stderr == .pipe) try pipe2Sync(pipe_flags) else undefined;
    errdefer if (options.stderr == .pipe) {
        ev.destroyPipe(stderr_pipe);
    };

    const any_ignore =
        options.stdin == .ignore or options.stdout == .ignore or options.stderr == .ignore;
    const dev_null_fd = if (any_ignore) try ev.null_fd.open(ev, "/dev/null", .{
        .ACCMODE = .RDWR,
    }) else undefined;

    const prog_pipe: [2]fd_t = if (options.progress_node.index != .none) pipe: {
        // We use CLOEXEC for the same reason as in `pipe_flags`.
        const pipe = try pipe2Sync(.{ .NONBLOCK = true, .CLOEXEC = true });
        _ = linux.fcntl(pipe[0], linux.F.SETPIPE_SZ, @as(u32, std.Progress.max_packet_len * 2));
        break :pipe pipe;
    } else .{ -1, -1 };
    errdefer ev.destroyPipe(prog_pipe);

    var arena_allocator = std.heap.ArenaAllocator.init(ev.backing_allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    // The POSIX standard does not allow malloc() between fork() and execve(),
    // and this allocator may be a libc allocator.
    // I have personally observed the child process deadlocking when it tries
    // to call malloc() due to a heap allocation between fork() and execve(),
    // in musl v1.1.24.
    // Additionally, we want to reduce the number of possible ways things
    // can fail between fork() and execve().
    // Therefore, we do all the allocation for the execve() before the fork().
    // This means we must do the null-termination of argv and env vars here.
    const argv_buf = try arena.allocSentinel(?[*:0]const u8, options.argv.len, null);
    for (options.argv, 0..) |arg, i| argv_buf[i] = (try arena.dupeSentinel(u8, arg, 0)).ptr;

    const env_block = env_block: {
        const prog_fd: i32 = if (prog_pipe[1] == -1) -1 else prog_fileno;
        if (options.environ_map) |environ_map| break :env_block try environ_map.createPosixBlock(arena, .{
            .zig_progress_fd = prog_fd,
        });
        break :env_block try ev.environ.process_environ.createPosixBlock(arena, .{
            .zig_progress_fd = prog_fd,
        });
    };

    // This pipe communicates to the parent errors in the child between `fork` and `execvpe`.
    // It is closed by the child (via CLOEXEC) without writing if `execvpe` succeeds.
    const err_pipe: [2]fd_t = try pipe2Sync(.{ .CLOEXEC = true });
    errdefer ev.destroyPipe(err_pipe);

    try ev.scanEnviron(); // for PATH
    const PATH = ev.environ.string.PATH orelse default_PATH;

    const pid_result: pid_t = fork: {
        const rc = linux.fork();
        switch (linux.errno(rc)) {
            .SUCCESS => break :fork @intCast(rc),
            .AGAIN => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOSYS => return error.OperationUnsupported,
            else => |err| return unexpectedErrno(err),
        }
    };

    if (pid_result == 0) {
        defer comptime unreachable; // We are the child.
        // Note that the parent uring is no longer accessible, so we must no longer reference `ev`.
        const err = setUpChild(.{
            .stdin_pipe = stdin_pipe[0],
            .stdout_pipe = stdout_pipe[1],
            .stderr_pipe = stderr_pipe[1],
            .dev_null_fd = dev_null_fd,
            .prog_pipe = prog_pipe[1],
            .argv_buf = argv_buf,
            .env_block = env_block,
            .PATH = PATH,
            .spawn = options,
        });
        writeAllSync(err_pipe[1], @ptrCast(&err)) catch {};
        const exit = if (builtin.single_threaded) linux.exit else linux.exit_group;
        exit(1);
    }

    const pid: pid_t = @intCast(pid_result); // We are the parent.
    errdefer comptime unreachable; // The child is forked; we must not error from now on

    ev.closeAsync(err_pipe[1]); // make sure only the child holds the write end open

    if (options.stdin == .pipe) ev.closeAsync(stdin_pipe[0]);
    if (options.stdout == .pipe) ev.closeAsync(stdout_pipe[1]);
    if (options.stderr == .pipe) ev.closeAsync(stderr_pipe[1]);

    if (prog_pipe[1] != -1) ev.closeAsync(prog_pipe[1]);

    options.progress_node.setIpcFile(ev, .{ .handle = prog_pipe[0], .flags = .{ .nonblocking = true } });

    return .{
        .pid = pid,
        .err_fd = err_pipe[0],
        .stdin = switch (options.stdin) {
            .pipe => .{ .handle = stdin_pipe[1], .flags = .{ .nonblocking = false } },
            else => null,
        },
        .stdout = switch (options.stdout) {
            .pipe => .{ .handle = stdout_pipe[0], .flags = .{ .nonblocking = false } },
            else => null,
        },
        .stderr = switch (options.stderr) {
            .pipe => .{ .handle = stderr_pipe[0], .flags = .{ .nonblocking = false } },
            else => null,
        },
    };
}

pub const PipeError = error{
    SystemFdQuotaExceeded,
    ProcessFdQuotaExceeded,
} || Io.UnexpectedError;
pub fn pipe2Sync(flags: linux.O) PipeError![2]fd_t {
    var fds: [2]fd_t = undefined;
    switch (linux.errno(linux.pipe2(&fds, flags))) {
        .SUCCESS => return fds,
        .INVAL => |err| return errnoBug(err), // Invalid flags
        .NFILE => return error.SystemFdQuotaExceeded,
        .MFILE => return error.ProcessFdQuotaExceeded,
        else => |err| return unexpectedErrno(err),
    }
}
fn destroyPipe(ev: *Evented, pipe: [2]fd_t) void {
    if (pipe[0] != -1) ev.closeAsync(pipe[0]);
    if (pipe[0] != pipe[1]) ev.closeAsync(pipe[1]);
}

/// Errors that can occur between fork() and execv()
const ForkBailError = process.SetCurrentDirError || ChdirError ||
    process.SpawnError || process.ReplaceError;
fn setUpChild(options: struct {
    stdin_pipe: fd_t,
    stdout_pipe: fd_t,
    stderr_pipe: fd_t,
    dev_null_fd: fd_t,
    prog_pipe: fd_t,
    argv_buf: [:null]?[*:0]const u8,
    env_block: process.Environ.Block,
    PATH: []const u8,
    spawn: process.SpawnOptions,
}) ForkBailError {
    try setUpChildIo(
        options.spawn.stdin,
        options.stdin_pipe,
        linux.STDIN_FILENO,
        options.dev_null_fd,
    );
    try setUpChildIo(
        options.spawn.stdout,
        options.stdout_pipe,
        linux.STDOUT_FILENO,
        options.dev_null_fd,
    );
    try setUpChildIo(
        options.spawn.stderr,
        options.stderr_pipe,
        linux.STDERR_FILENO,
        options.dev_null_fd,
    );

    switch (options.spawn.cwd) {
        .inherit => {},
        .dir => |cwd_dir| try fchdir(cwd_dir.handle),
        .path => |cwd_path| {
            var cwd_path_buffer: [PATH_MAX]u8 = undefined;
            const cwd_path_posix = try pathToPosix(cwd_path, &cwd_path_buffer);
            try chdir(cwd_path_posix);
        },
    }

    // Must happen after fchdir above, the cwd file descriptor might be
    // equal to prog_fileno and be clobbered by this dup2 call.
    if (options.prog_pipe != -1) try dup2(options.prog_pipe, prog_fileno);

    if (options.spawn.gid) |gid| {
        switch (linux.errno(linux.setregid(gid, gid))) {
            .SUCCESS => {},
            .AGAIN => return error.ResourceLimitReached,
            .INVAL => return error.InvalidUserId,
            .PERM => return error.PermissionDenied,
            else => return error.Unexpected,
        }
    }

    if (options.spawn.uid) |uid| {
        switch (linux.errno(linux.setreuid(uid, uid))) {
            .SUCCESS => {},
            .AGAIN => return error.ResourceLimitReached,
            .INVAL => return error.InvalidUserId,
            .PERM => return error.PermissionDenied,
            else => return error.Unexpected,
        }
    }

    if (options.spawn.pgid) |pid| {
        switch (linux.errno(linux.setpgid(0, pid))) {
            .SUCCESS => {},
            .ACCES => return error.ProcessAlreadyExec,
            .INVAL => return error.InvalidProcessGroupId,
            .PERM => return error.PermissionDenied,
            else => return error.Unexpected,
        }
    }

    if (options.spawn.start_suspended) {
        switch (linux.errno(linux.kill(0, .STOP))) {
            .SUCCESS => {},
            .PERM => return error.PermissionDenied,
            else => return error.Unexpected,
        }
    }

    return execv(
        options.spawn.expand_arg0,
        options.argv_buf.ptr[0].?,
        options.argv_buf.ptr,
        options.env_block,
        options.PATH,
    );
}

fn setUpChildIo(
    stdio: process.SpawnOptions.StdIo,
    pipe_fd: fd_t,
    std_fileno: i32,
    dev_null_fd: fd_t,
) !void {
    switch (stdio) {
        .pipe => try dup2(pipe_fd, std_fileno),
        .close => _ = linux.close(std_fileno),
        .inherit => {},
        .ignore => try dup2(dev_null_fd, std_fileno),
        .file => |file| try dup2(file.handle, std_fileno),
    }
}

pub const DupError = error{
    ProcessFdQuotaExceeded,
    SystemResources,
} || Io.UnexpectedError || Io.Cancelable;
pub fn dup2(old_fd: fd_t, new_fd: fd_t) DupError!void {
    while (true) {
        switch (linux.errno(linux.dup2(old_fd, new_fd))) {
            .SUCCESS => return,
            .BUSY, .INTR => {},
            .INVAL => |err| return errnoBug(err), // invalid parameters
            .BADF => |err| return errnoBug(err), // use after free
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn fchdir(dir: fd_t) process.SetCurrentDirError!void {
    if (dir == linux.AT.FDCWD) return;
    while (true) {
        switch (linux.errno(linux.fchdir(dir))) {
            .SUCCESS => return,
            .INTR => {},
            .ACCES => return error.AccessDenied,
            .NOTDIR => return error.NotDir,
            .IO => return error.FileSystem,
            .BADF => |err| return errnoBug(err),
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn execv(
    arg0_expand: process.ArgExpansion,
    file: [*:0]const u8,
    child_argv: [*:null]?[*:0]const u8,
    env_block: process.Environ.PosixBlock,
    PATH: []const u8,
) process.ReplaceError {
    const file_slice = std.mem.sliceTo(file, 0);
    if (std.mem.findScalar(u8, file_slice, '/') != null)
        return execvPath(file, child_argv, env_block);

    // Use of PATH_MAX here is valid as the path_buf will be passed
    // directly to the operating system in posixExecvPath.
    var path_buf: [PATH_MAX]u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, PATH, ':');
    var seen_eacces = false;
    var err: process.ReplaceError = error.FileNotFound;

    // In case of expanding arg0 we must put it back if we return with an error.
    const prev_arg0 = child_argv[0];
    defer switch (arg0_expand) {
        .expand => child_argv[0] = prev_arg0,
        .no_expand => {},
    };

    while (it.next()) |search_path| {
        const path_len = search_path.len + file_slice.len + 1;
        if (path_buf.len < path_len + 1) return error.NameTooLong;
        @memcpy(path_buf[0..search_path.len], search_path);
        path_buf[search_path.len] = '/';
        @memcpy(path_buf[search_path.len + 1 ..][0..file_slice.len], file_slice);
        path_buf[path_len] = 0;
        const full_path = path_buf[0..path_len :0].ptr;
        switch (arg0_expand) {
            .expand => child_argv[0] = full_path,
            .no_expand => {},
        }
        err = execvPath(full_path, child_argv, env_block);
        switch (err) {
            error.AccessDenied => seen_eacces = true,
            error.FileNotFound, error.NotDir => {},
            else => |e| return e,
        }
    }
    if (seen_eacces) return error.AccessDenied;
    return err;
}
/// This function ignores PATH environment variable.
pub fn execvPath(
    path: [*:0]const u8,
    child_argv: [*:null]const ?[*:0]const u8,
    env_block: process.Environ.PosixBlock,
) process.ReplaceError {
    switch (linux.errno(linux.execve(path, child_argv, env_block.slice.ptr))) {
        .FAULT => |err| return errnoBug(err), // Bad pointer parameter.
        .@"2BIG" => return error.SystemResources,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NAMETOOLONG => return error.NameTooLong,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .INVAL => return error.InvalidExe,
        .NOEXEC => return error.InvalidExe,
        .IO => return error.FileSystem,
        .LOOP => return error.FileSystem,
        .ISDIR => return error.IsDir,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .TXTBSY => return error.FileBusy,
        .LIBBAD => return error.InvalidExe,
        else => |err| return unexpectedErrno(err),
    }
}

fn childWait(userdata: ?*anyopaque, child: *process.Child) process.Child.WaitError!process.Child.Term {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    defer ev.childCleanup(child);

    const pid = child.id.?;
    var info: linux.siginfo_t = undefined;
    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.waitid(
            @intFromPtr(fiber),
            .PID,
            pid,
            &info,
            linux.W.EXITED | @as(u32, if (child.request_resource_usage_statistics) linux.W.NOWAIT else 0),
        );
        ev.yield(null, .nothing);
        switch (fiber.errno()) {
            .SUCCESS => {
                if (child.request_resource_usage_statistics) {
                    while (true) {
                        try ev.enqueueSync();
                        var rusage: linux.rusage = undefined;
                        switch (linux.errno(linux.waitid(
                            .PID,
                            pid,
                            &info,
                            linux.W.EXITED | linux.W.NOHANG,
                            &rusage,
                        ))) {
                            .SUCCESS => {
                                child.resource_usage_statistics.rusage = rusage;
                                break;
                            },
                            .INTR, .CANCELED => {},
                            .CHILD => |err| return errnoBug(err), // Double-free.
                            else => |err| return unexpectedErrno(err),
                        }
                    }
                }
                const status: u32 = @bitCast(info.fields.common.second.sigchld.status);
                const code: linux.CLD = @fromBackingInt(@intCast(info.code));
                return switch (code) {
                    .EXITED => .{ .exited = @truncate(status) },
                    .KILLED, .DUMPED => .{ .signal = @fromBackingInt(@intCast(status)) },
                    .TRAPPED, .STOPPED => .{ .stopped = @fromBackingInt(@intCast(status)) },
                    _, .CONTINUED => .{ .unknown = status },
                };
            },
            .INTR, .CANCELED => {},
            .CHILD => |err| return errnoBug(err), // Double-free.
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn childKill(userdata: ?*anyopaque, child: *process.Child) void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    defer ev.childCleanup(child);

    const pid = child.id.?;
    while (true) switch (linux.errno(linux.kill(pid, .TERM))) {
        .SUCCESS => break,
        .INTR => {},
        .PERM => return,
        .INVAL => |err| return errnoBug(err) catch {},
        .SRCH => |err| return errnoBug(err) catch {},
        else => |err| return unexpectedErrno(err) catch {},
    };

    var info: linux.siginfo_t = undefined;
    while (true) {
        const sqe, const fiber = ev.enqueueBlocked();
        sqe.waitid(
            @intFromPtr(fiber),
            .PID,
            pid,
            &info,
            linux.W.EXITED,
        );
        ev.yield(null, .nothing);
        switch (fiber.errno()) {
            .SUCCESS => return,
            .INTR, .CANCELED => {},
            .CHILD => |err| return errnoBug(err) catch {}, // Double-free.
            else => |err| return unexpectedErrno(err) catch {},
        }
    }
}

fn childCleanup(ev: *Evented, child: *process.Child) void {
    if (child.stdin) |*stdin| {
        ev.closeAsync(stdin.handle);
        child.stdin = null;
    }
    if (child.stdout) |*stdout| {
        ev.closeAsync(stdout.handle);
        child.stdout = null;
    }
    if (child.stderr) |*stderr| {
        ev.closeAsync(stderr.handle);
        child.stderr = null;
    }
    child.id = null;
}

fn progressParentFile(userdata: ?*anyopaque) std.Progress.ParentFileError!File {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    const cancel_protection = swapCancelProtection(ev, .blocked);
    defer assert(swapCancelProtection(ev, cancel_protection) == .blocked);
    ev.scanEnviron() catch |err| switch (err) {
        error.Canceled => unreachable, // blocked
    };
    return ev.environ.zig_progress_file;
}

fn scanEnviron(ev: *Evented) Io.Cancelable!void {
    const ev_io = ev.io();
    try ev.environ_mutex.lock(ev_io);
    defer ev.environ_mutex.unlock(ev_io);
    if (ev.environ_initialized) return;
    ev.environ.scan(ev.backing_allocator);
    ev.environ_initialized = true;
}

fn clockResolution(userdata: ?*anyopaque, clock: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    _ = ev;
    const clock_id = clockToPosix(clock);
    var timespec: linux.timespec = undefined;
    return switch (linux.errno(linux.clock_getres(clock_id, &timespec))) {
        .SUCCESS => .fromNanoseconds(nanosecondsFromPosix(&timespec)),
        .INVAL => return error.ClockUnavailable,
        else => |err| return unexpectedErrno(err),
    };
}

fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    _ = ev;
    var tp: linux.timespec = undefined;
    switch (linux.errno(linux.clock_gettime(clockToPosix(clock), &tp))) {
        .SUCCESS => return timestampFromPosix(&tp),
        else => return .zero,
    }
}

fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));

    const timespec: linux.kernel_timespec, const clock: Io.Clock, const timeout_flags: u32 = timespec: switch (timeout) {
        .none => .{
            .{
                .sec = std.math.maxInt(i64),
                .nsec = std.time.ns_per_s - 1,
            },
            .awake,
            linux.IORING_TIMEOUT_ABS,
        },
        .duration => |duration| {
            const ns = duration.raw.toNanoseconds();
            break :timespec .{
                .{
                    .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
                    .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
                },
                duration.clock,
                0,
            };
        },
        .deadline => |deadline| {
            const ns = deadline.raw.toNanoseconds();
            break :timespec .{
                .{
                    .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
                    .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
                },
                deadline.clock,
                linux.IORING_TIMEOUT_ABS,
            };
        },
    };

    const sqe, const fiber = try ev.enqueue();
    sqe.timeout(@intFromPtr(fiber), &timespec, 0, timeout_flags | @as(u32, switch (clock) {
        .real => linux.IORING_TIMEOUT_REALTIME,
        else => 0,
        .boot => linux.IORING_TIMEOUT_BOOTTIME,
    }));
    ev.yield(null, .nothing);
    // Handles SUCCESS as well as clock not available and unexpected
    // errors. The user had a chance to check clock resolution before
    // getting here, which would have reported 0, making this a legal
    // amount of time to sleep.
}

fn random(userdata: ?*anyopaque, buffer: []u8) void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    if (!ev.csprng.isInitialized()) {
        @branchHint(.unlikely);
        var seed: [Csprng.seed_len]u8 = undefined;
        ev.urandomReadAll(&seed) catch |err| switch (err) {
            error.Canceled => unreachable, // blocked
            else => fallbackSeed(ev, &seed),
        };
        ev.csprng.rng = .init(seed);
    }
    ev.csprng.rng.fill(buffer);
}

fn randomSecure(userdata: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    if (buffer.len == 0) return;
    ev.urandomReadAll(buffer) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return error.EntropyUnavailable,
    };
}

fn netListenIp(
    userdata: ?*anyopaque,
    address: *const net.IpAddress,
    options: net.IpAddress.ListenOptions,
) net.IpAddress.ListenError!net.Socket {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    const family = posixAddressFamily(address);
    const socket_fd = try ev.socket(family, .{ .mode = options.mode, .protocol = options.protocol });
    errdefer ev.close(socket_fd);
    if (options.reuse_address) {
        try ev.setsockopt(socket_fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);
        try ev.setsockopt(socket_fd, linux.SOL.SOCKET, linux.SO.REUSEPORT, 1);
    }
    var storage: PosixAddress = undefined;
    var addr_len = addressToPosix(address, &storage);
    try ev.bind(socket_fd, &storage.any, addr_len);
    try ev.listen(socket_fd, options.kernel_backlog);
    try ev.getsockname(socket_fd, &storage.any, &addr_len);
    return .{ .handle = socket_fd, .address = addressFromPosix(&storage) };
}

fn netAccept(
    userdata: ?*anyopaque,
    listen_handle: net.Socket.Handle,
    options: net.Server.AcceptOptions,
) net.Server.AcceptError!net.Socket {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    options;

    while (true) {
        var storage: PosixAddress = undefined;
        var addr_len: linux.socklen_t = @sizeOf(PosixAddress);
        const sqe, const fiber = try ev.enqueue();
        sqe.accept(@intFromPtr(fiber), listen_handle, @ptrCast(&storage), &addr_len, 0);
        ev.yield(null, .nothing);
        const completion = fiber.completion();
        switch (completion.errno()) {
            .SUCCESS => return .{
                .handle = completion.result,
                .address = addressFromPosix(&storage),
            },
            .INTR, .CANCELED => {},
            .AGAIN => |err| return errnoBug(err),
            .BADF => |err| return errnoBug(err), // File descriptor used after closed.
            .CONNABORTED => return error.ConnectionAborted,
            .FAULT => |err| return errnoBug(err),
            .INVAL => return error.SocketNotListening,
            .NOTSOCK => |err| return errnoBug(err),
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .OPNOTSUPP => |err| return errnoBug(err),
            .PROTO => return error.ProtocolFailure,
            .PERM => return error.BlockedByFirewall,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn netBindIp(
    userdata: ?*anyopaque,
    address: *const net.IpAddress,
    options: net.IpAddress.BindOptions,
) net.IpAddress.BindError!net.Socket {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    const family = posixAddressFamily(address);
    const socket_fd = try ev.socket(family, options);
    errdefer ev.closeAsync(socket_fd);

    var storage: PosixAddress = undefined;
    var addr_len = addressToPosix(address, &storage);
    try ev.bind(socket_fd, &storage.any, addr_len);
    if (options.allow_broadcast) try ev.setsockopt(socket_fd, linux.SOL.SOCKET, linux.SO.BROADCAST, 1);
    try ev.getsockname(socket_fd, &storage.any, &addr_len);
    return .{ .handle = socket_fd, .address = addressFromPosix(&storage) };
}

fn netConnectIp(
    userdata: ?*anyopaque,
    address: *const net.IpAddress,
    options: net.IpAddress.ConnectOptions,
) net.IpAddress.ConnectError!net.Socket {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    const family = posixAddressFamily(address);
    const socket_fd = try ev.socket(family, .{ .mode = options.mode, .protocol = options.protocol });
    errdefer ev.closeAsync(socket_fd);
    var storage: PosixAddress = undefined;
    var addr_len = addressToPosix(address, &storage);
    const timeout, const timeout_flags = timeoutToLinux(options.timeout);
    try ev.connect(socket_fd, &storage.any, addr_len, timeout, timeout_flags);
    try ev.getsockname(socket_fd, &storage.any, &addr_len);
    return .{ .handle = socket_fd, .address = addressFromPosix(&storage) };
}

fn netListenUnixUnavailable(
    userdata: ?*anyopaque,
    address: *const net.UnixAddress,
    options: net.UnixAddress.ListenOptions,
) net.UnixAddress.ListenError!net.Socket.Handle {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    _ = ev;
    _ = address;
    _ = options;
    return error.AddressFamilyUnsupported;
}

fn netConnectUnixUnavailable(
    userdata: ?*anyopaque,
    address: *const net.UnixAddress,
) net.UnixAddress.ConnectError!net.Socket.Handle {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    _ = ev;
    _ = address;
    return error.AddressFamilyUnsupported;
}

fn netSocketCreatePairUnavailable(
    userdata: ?*anyopaque,
    options: net.Socket.CreatePairOptions,
) net.Socket.CreatePairError![2]net.Socket {
    _ = userdata;
    _ = options;
    return error.OperationUnsupported;
}

fn netSend(
    userdata: ?*anyopaque,
    handle: net.Socket.Handle,
    messages: []net.OutgoingMessage,
    flags: net.SendFlags,
) struct { ?net.Socket.SendError, usize } {
    const ev: *Evented = @ptrCast(@alignCast(userdata));

    const linux_flags: u32 =
        @as(u32, if (flags.confirm) linux.MSG.CONFIRM else 0) |
        @as(u32, if (flags.dont_route) linux.MSG.DONTROUTE else 0) |
        @as(u32, if (flags.eor) linux.MSG.EOR else 0) |
        @as(u32, if (flags.oob) linux.MSG.OOB else 0) |
        @as(u32, if (flags.fastopen) linux.MSG.FASTOPEN else 0) |
        linux.MSG.NOSIGNAL;

    var i: usize = 0;
    while (messages.len - i != 0) {
        var message = &messages[i];
        var addr: PosixAddress = undefined;
        var iov: iovec_const = .{ .base = @constCast(message.data_ptr), .len = message.data_len };
        const msg: linux.msghdr_const = .{
            .name = &addr.any,
            .namelen = addressToPosix(message.address, &addr),
            .iov = (&iov)[0..1],
            .iovlen = 1,
            .control = if (message.control.len == 0) null else @constCast(message.control.ptr),
            .controllen = @intCast(message.control.len),
            .flags = 0,
        };

        message.data_len = ev.sendmsg(handle, &msg, linux_flags, net.Socket.SendError) catch |err| return .{ err, i };
        i += 1;
    }
    return .{ null, i };
}

fn netReceive(
    ev: *Evented,
    handle: net.Socket.Handle,
    message_buffer: []net.IncomingMessage,
    data_buffer: []u8,
    flags: net.ReceiveFlags,
) struct { ?net.Socket.ReceiveError, usize } {
    var message_i: usize = 0;
    var data_i: usize = 0;
    while (true) {
        if (message_buffer.len - message_i == 0) return .{ null, message_i };
        const message = &message_buffer[message_i];
        const remaining_data_buffer = data_buffer[data_i..];
        var storage: PosixAddress = undefined;
        var iov: iovec = .{ .base = remaining_data_buffer.ptr, .len = remaining_data_buffer.len };
        var msg: linux.msghdr = .{
            .name = &storage.any,
            .namelen = @sizeOf(PosixAddress),
            .iov = (&iov)[0..1],
            .iovlen = 1,
            .control = message.control.ptr,
            .controllen = @intCast(message.control.len),
            .flags = undefined,
        };

        const sqe, const fiber = ev.enqueue() catch |err| return .{ err, message_i };
        sqe.recvmsg(@intFromPtr(fiber), handle, &msg, linux.MSG.NOSIGNAL |
            @as(u32, if (flags.oob) linux.MSG.OOB else 0) |
            @as(u32, if (flags.peek) linux.MSG.PEEK else 0) |
            @as(u32, if (flags.trunc) linux.MSG.TRUNC else 0));
        ev.yield(null, .nothing);
        const completion = fiber.completion();
        switch (completion.errno()) {
            .SUCCESS => {
                const data = remaining_data_buffer[0..@intCast(completion.result)];
                data_i += data.len;
                message.* = .{
                    .from = addressFromPosix(&storage),
                    .data = data,
                    .control = if (msg.control) |ptr| @as([*]u8, @ptrCast(ptr))[0..msg.controllen] else message.control,
                    .flags = .{
                        .eor = msg.flags & linux.MSG.EOR != 0,
                        .trunc = msg.flags & linux.MSG.TRUNC != 0,
                        .ctrunc = msg.flags & linux.MSG.CTRUNC != 0,
                        .oob = msg.flags & linux.MSG.OOB != 0,
                        .errqueue = msg.flags & linux.MSG.ERRQUEUE != 0,
                    },
                };
                message_i += 1;
                continue;
            },
            .AGAIN => unreachable,
            .INTR, .CANCELED => {},
            .BADF => |err| return .{ errnoBug(err), message_i },
            .NFILE => return .{ error.SystemFdQuotaExceeded, message_i },
            .MFILE => return .{ error.ProcessFdQuotaExceeded, message_i },
            .FAULT => |err| return .{ errnoBug(err), message_i },
            .INVAL => |err| return .{ errnoBug(err), message_i },
            .NOBUFS => return .{ error.SystemResources, message_i },
            .NOMEM => return .{ error.SystemResources, message_i },
            .NOTCONN => return .{ error.SocketUnconnected, message_i },
            .NOTSOCK => |err| return .{ errnoBug(err), message_i },
            .MSGSIZE => return .{ error.MessageOversize, message_i },
            .PIPE => return .{ error.SocketUnconnected, message_i },
            .OPNOTSUPP => |err| return .{ errnoBug(err), message_i },
            .CONNRESET => return .{ error.ConnectionResetByPeer, message_i },
            .NETDOWN => return .{ error.NetworkDown, message_i },
            else => |err| return .{ unexpectedErrno(err), message_i },
        }
    }
}

fn netRead(
    ev: *Evented,
    fd: net.Socket.Handle,
    data: [][]u8,
) net.Stream.Reader.Error!usize {
    if (data.len == 1) {
        return try ev.read(fd, data[0], null, net.Stream.Reader.Error);
    }
    return ev.preadv(fd, data, null, net.Stream.Reader.Error);
}

fn netWrite(
    userdata: ?*anyopaque,
    handle: net.Socket.Handle,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) net.Stream.Writer.Error!usize {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    var iovecs: [max_iovecs_len]iovec_const = undefined;
    const iov = fillIovecs(&iovecs, header, data, splat);
    var msg: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = iov.ptr,
        .iovlen = iov.len,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    return ev.sendmsg(handle, &msg, linux.MSG.NOSIGNAL, net.Stream.Writer.Error);
}

fn netWriteFile(
    userdata: ?*anyopaque,
    socket_handle: net.Socket.Handle,
    header: []const u8,
    file_reader: *File.Reader,
    limit: Io.Limit,
) net.Stream.Writer.WriteFileError!usize {
    const ev: *Evented = @ptrCast(@alignCast(userdata));

    var n: usize = 0;
    if (header.len > 0) {
        n += try ev.send(socket_handle, header, 0);
        if (n < header.len) return n;
    }

    const file_size = file_reader.size orelse
        (ev.stat(file_reader.file.handle) catch return error.Unexpected).size;
    ev.sendfile(
        file_reader.file.handle,
        file_reader.pos,
        socket_handle,
        limit.minInt(file_size - file_reader.pos),
        &n,
    ) catch |err| {
        if (n > 0) return n;
        return err;
    };
    return n;
}

fn netClose(userdata: ?*anyopaque, handles: []const net.Socket.Handle) void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    for (handles) |handle| ev.close(handle);
}

fn netShutdown(
    userdata: ?*anyopaque,
    handle: net.Socket.Handle,
    how: net.ShutdownHow,
) net.ShutdownError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.shutdown(@intFromPtr(fiber), handle, switch (how) {
            .recv => linux.SHUT.RD,
            .send => linux.SHUT.WR,
            .both => linux.SHUT.RDWR,
        });
        ev.yield(null, .nothing);
        switch (fiber.errno()) {
            .SUCCESS => return,
            .INTR, .CANCELED => {},
            .BADF, .NOTSOCK, .INVAL => |err| return errnoBug(err),
            .NOTCONN => return error.SocketUnconnected,
            .NOBUFS => return error.SystemResources,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn netInterfaceNameResolveUnavailable(
    userdata: ?*anyopaque,
    name: *const net.Interface.Name,
) net.Interface.Name.ResolveError!net.Interface {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    _ = ev;
    _ = name;
    return error.InterfaceNotFound;
}

fn netInterfaceNameUnavailable(
    userdata: ?*anyopaque,
    interface: net.Interface,
) net.Interface.NameError!net.Interface.Name {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    _ = ev;
    _ = interface;
    return error.Unexpected;
}

fn netLookupUnavailable(
    userdata: ?*anyopaque,
    host_name: net.HostName,
    resolved: *Io.Queue(net.HostName.LookupResult),
    options: net.HostName.LookupOptions,
) net.HostName.LookupError!void {
    const ev: *Evented = @ptrCast(@alignCast(userdata));
    _ = host_name;
    _ = options;
    resolved.close(ev.io());
    return error.NetworkDown;
}

fn bind(
    ev: *Evented,
    socket_fd: fd_t,
    addr: *const linux.sockaddr,
    addr_len: linux.socklen_t,
) !void {
    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.bind(@intFromPtr(fiber), socket_fd, addr, addr_len);
        ev.yield(null, .nothing);
        switch (fiber.errno()) {
            .SUCCESS => return,
            .INTR, .CANCELED => {},
            .ADDRINUSE => return error.AddressInUse,
            .BADF => |err| return errnoBug(err), // File descriptor used after closed.
            .INVAL => |err| return errnoBug(err), // invalid parameters
            .NOTSOCK => |err| return errnoBug(err), // invalid `sockfd`
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .ADDRNOTAVAIL => return error.AddressUnavailable,
            .FAULT => |err| return errnoBug(err), // invalid `addr` pointer
            .NOMEM => return error.SystemResources,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn connect(
    ev: *Evented,
    fd: fd_t,
    addr: *const linux.sockaddr,
    addr_len: linux.socklen_t,
    timeout: ?linux.kernel_timespec,
    timeout_flags: u32,
) !void {
    while (true) {
        var sqe, const fiber = try ev.enqueue();
        sqe.connect(@intFromPtr(fiber), fd, addr, addr_len);
        if (timeout) |*timespec_ptr| {
            sqe.flags.io_link = true;
            sqe = ev.getSqe();
            sqe.linkTimeout(@backingInt(Completion.Userdata.wakeup), timespec_ptr, timeout_flags);
            sqe.flags.cqe_skip_success = true;
        }
        ev.yield(null, .nothing);
        switch (fiber.errno()) {
            .SUCCESS => return,
            .INTR => {},
            .CANCELED => return error.Timeout,
            .ADDRNOTAVAIL => return error.AddressUnavailable,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .AGAIN, .INPROGRESS => return error.WouldBlock,
            .ALREADY => return error.ConnectionPending,
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .HOSTUNREACH => return error.HostUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .TIMEDOUT => return error.Timeout,
            .ACCES => return error.AccessDenied,
            .NETDOWN => return error.NetworkDown,
            .BADF => |err| return errnoBug(err), // File descriptor used after closed.
            .CONNABORTED => |err| return errnoBug(err),
            .FAULT => |err| return errnoBug(err),
            .ISCONN => |err| return errnoBug(err),
            .NOENT => |err| return errnoBug(err),
            .NOTSOCK => |err| return errnoBug(err),
            .PERM => |err| return errnoBug(err),
            .PROTOTYPE => |err| return errnoBug(err),
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn chdir(path: [*:0]const u8) ChdirError!void {
    while (true) {
        switch (linux.errno(linux.chdir(path))) {
            .SUCCESS => return,
            .INTR => {},
            .ACCES => return error.AccessDenied,
            .IO => return error.FileSystem,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOTDIR => return error.NotDir,
            .ILSEQ => return error.BadPathName,
            .FAULT => |err| return errnoBug(err),
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn close(ev: *Evented, fd: fd_t) void {
    const sqe, const fiber = ev.enqueueBlocked();
    sqe.close(@intFromPtr(fiber), fd);
    ev.yield(null, .nothing);
    switch (fiber.errno()) {
        .BADF => recoverableOsBugDetected(), // Always a race condition.
        .INTR => {}, // This is still a success. See https://github.com/ziglang/zig/issues/2425
        else => {},
    }
}

fn closeAsync(ev: *Evented, fd: fd_t) void {
    const sqe = ev.getSqe();
    sqe.close(@backingInt(Completion.Userdata.close), fd);
    sqe.flags.cqe_skip_success = true;
}

fn fchmodat(
    ev: *Evented,
    dir: fd_t,
    path: [*:0]const u8,
    mode: linux.mode_t,
    flags: u32,
) Dir.SetFilePermissionsError!void {
    while (true) {
        try ev.enqueueSync();
        switch (linux.errno(linux.fchmodat2(dir, path, mode, flags))) {
            .SUCCESS => return,
            .INTR => {},
            .BADF => |err| return errnoBug(err),
            .FAULT => |err| return errnoBug(err),
            .INVAL => |err| return errnoBug(err),
            .ACCES => return error.AccessDenied,
            .IO => return error.InputOutput,
            .LOOP => return error.SymLinkLoop,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOTDIR => return error.FileNotFound,
            .OPNOTSUPP => return error.OperationUnsupported,
            .PERM => return error.PermissionDenied,
            .ROFS => return error.ReadOnlyFileSystem,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn fchownat(
    ev: *Evented,
    dir: fd_t,
    path: [*:0]const u8,
    owner: linux.uid_t,
    group: linux.gid_t,
    flags: u32,
) File.SetOwnerError!void {
    while (true) {
        try ev.enqueueSync();
        switch (linux.errno(linux.fchownat(dir, path, owner, group, flags))) {
            .SUCCESS => return,
            .INTR => {},
            .BADF => |err| return errnoBug(err), // likely fd refers to directory opened without `Dir.OpenOptions.iterate`
            .FAULT => |err| return errnoBug(err),
            .INVAL => |err| return errnoBug(err),
            .ACCES => return error.AccessDenied,
            .IO => return error.InputOutput,
            .LOOP => return error.SymLinkLoop,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOTDIR => return error.FileNotFound,
            .PERM => return error.PermissionDenied,
            .ROFS => return error.ReadOnlyFileSystem,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn flock(
    ev: *Evented,
    fd: fd_t,
    op: File.Lock,
    blocking: enum { blocking, nonblocking },
) (File.LockError || error{WouldBlock})!void {
    while (true) {
        try ev.enqueueSync();
        switch (linux.errno(linux.flock(fd, LOCK.NB | @as(i32, switch (op) {
            .none => LOCK.UN,
            .shared => LOCK.SH,
            .exclusive => LOCK.EX,
        })))) {
            .SUCCESS => return,
            .INTR => {},
            .BADF => |err| return errnoBug(err),
            .INVAL => |err| return errnoBug(err), // invalid parameters
            .NOLCK => return error.SystemResources,
            .AGAIN => {
                const sqe, const fiber = try ev.enqueue();
                sqe.nop(@intFromPtr(fiber));
                ev.yield(null, .nothing);
                switch (fiber.errno()) {
                    .SUCCESS, .INTR, .CANCELED => {},
                    else => unreachable,
                }
                switch (blocking) {
                    .blocking => continue,
                    .nonblocking => return error.WouldBlock,
                }
            },
            .OPNOTSUPP => return error.FileLocksUnsupported,
            else => |err| return unexpectedErrno(err),
        }
    }
}

// io_uring supports getsockname since kernel 6.19, on older kernels this
// fallbacks to sync syscall after first async try.
fn getsockname(
    ev: *Evented,
    socket_fd: fd_t,
    addr: *linux.sockaddr,
    addr_len: *linux.socklen_t,
) !void {
    if (ev.op_getsockname_supported) {
        if (ev.getsocknameAsync(socket_fd, addr, addr_len)) |_|
            // Async success
            return
        else |err| switch (err) {
            // We are on kernel older than 6.19 fallback to sync
            error.OperationUnsupported => ev.op_getsockname_supported = false,
            else => |e| return e,
        }
    }
    while (true) {
        try ev.enqueueSync();
        switch (linux.errno(linux.getsockname(socket_fd, addr, addr_len))) {
            .SUCCESS => return,
            .INTR => {},
            .BADF => |err| return errnoBug(err), // File descriptor used after closed.
            .FAULT => |err| return errnoBug(err),
            .INVAL => |err| return errnoBug(err), // invalid parameters
            .NOTSOCK => |err| return errnoBug(err), // always a race condition
            .NOBUFS => return error.SystemResources,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn getsocknameAsync(
    ev: *Evented,
    socket_fd: fd_t,
    addr: *linux.sockaddr,
    addr_len: *linux.socklen_t,
) !void {
    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.getsockname(@intFromPtr(fiber), socket_fd, addr, addr_len);
        ev.yield(null, .nothing);
        switch (fiber.errno()) {
            .SUCCESS => return,
            .INTR, .CANCELED => {},
            .OPNOTSUPP => return error.OperationUnsupported,
            .BADF => |err| return errnoBug(err), // File descriptor used after closed.
            .FAULT => |err| return errnoBug(err),
            .INVAL => |err| return errnoBug(err), // invalid parameters
            .NOTSOCK => |err| return errnoBug(err), // always a race condition
            .NOBUFS => return error.SystemResources,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn linkat(
    ev: *Evented,
    old_dir: fd_t,
    old_path: [*:0]const u8,
    new_dir: fd_t,
    new_path: [*:0]const u8,
    flags: u32,
) File.HardLinkError!void {
    // allowed flags: https://man7.org/linux/man-pages/man2/linkat.2.html
    assert(flags & ~(@as(u32, linux.AT.SYMLINK_FOLLOW | linux.AT.EMPTY_PATH)) == 0);
    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.linkat(@intFromPtr(fiber), old_dir, old_path, new_dir, new_path, flags);
        ev.yield(null, .nothing);
        switch (fiber.errno()) {
            .SUCCESS => return,
            .INTR, .CANCELED => {},
            .ACCES => return error.AccessDenied,
            .DQUOT => return error.DiskQuota,
            .EXIST => return error.PathAlreadyExists,
            .IO => return error.HardwareFailure,
            .LOOP => return error.SymLinkLoop,
            .MLINK => return error.LinkQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .NOTDIR => return error.NotDir,
            .PERM => return error.PermissionDenied,
            .ROFS => return error.ReadOnlyFileSystem,
            .XDEV => return error.CrossDevice,
            .ILSEQ => return error.BadPathName,
            .FAULT => |err| return errnoBug(err),
            .INVAL => |err| return errnoBug(err),
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn lseek(
    ev: *Evented,
    fd: fd_t,
    offset: u64,
    whence: u32,
) File.SeekError!void {
    while (true) {
        try ev.enqueueSync();
        var result: u64 = undefined;
        switch (linux.errno(switch (@sizeOf(usize)) {
            else => comptime unreachable,
            4 => linux.llseek(fd, offset, &result, whence),
            8 => linux.lseek(fd, @bitCast(offset), whence),
        })) {
            .SUCCESS => return,
            .INTR => {},
            .BADF => |err| return errnoBug(err), // File descriptor used after closed.
            .INVAL => return error.Unseekable,
            .OVERFLOW => return error.Unseekable,
            .SPIPE => return error.Unseekable,
            .NXIO => return error.Unseekable,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn openat(
    ev: *Evented,
    dir: fd_t,
    path: [*:0]const u8,
    flags: linux.O,
    mode: linux.mode_t,
) !fd_t {
    var mut_flags = flags;
    if (@hasField(linux.O, "LARGEFILE")) mut_flags.LARGEFILE = true;
    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.openat(
            @intFromPtr(fiber),
            dir,
            path,
            mut_flags,
            mode,
        );
        ev.yield(null, .nothing);
        const completion = fiber.completion();
        switch (completion.errno()) {
            .SUCCESS => return completion.result,
            .INTR, .CANCELED => {},
            .FAULT => |err| return errnoBug(err),
            .INVAL => return error.BadPathName,
            .BADF => |err| return errnoBug(err), // File descriptor used after closed.
            .ACCES => return error.AccessDenied,
            .FBIG => return error.FileTooBig,
            .OVERFLOW => return error.FileTooBig,
            .ISDIR => return error.IsDir,
            .LOOP => return error.SymLinkLoop,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NODEV => return error.NoDevice,
            .NOENT => return error.FileNotFound,
            .SRCH => return error.FileNotFound, // Linux when opening procfs files.
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .NOTDIR => return error.NotDir,
            .PERM => return error.PermissionDenied,
            .EXIST => return error.PathAlreadyExists,
            .BUSY => return error.DeviceBusy,
            // This can be triggered by file locking and TMPFILE, but those
            // flags are mutually exclusive.
            .OPNOTSUPP => return error.OperationUnsupported,
            .AGAIN => return error.WouldBlock,
            .TXTBSY => return error.FileBusy,
            .NXIO => return error.NoDevice,
            .ROFS => return error.ReadOnlyFileSystem,
            .ILSEQ => return error.BadPathName,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn read(
    ev: *Evented,
    fd: fd_t,
    buffer: []u8,
    offset: ?u64,
    comptime ErrorSet: type,
) ErrorSet!usize {
    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.read(@intFromPtr(fiber), fd, buffer, offset);
        ev.yield(null, .nothing);
        const completion = fiber.completion();
        switch (completion.errno()) {
            .SUCCESS => return @as(u32, @bitCast(completion.result)),
            .INTR, .CANCELED => {},
            else => |errno| return errnoToError(ErrorSet, errno),
        }
    }
}

fn preadv(
    ev: *Evented,
    fd: fd_t,
    data: []const []u8,
    offset: ?u64,
    comptime ErrorSet: type,
) ErrorSet!usize {
    if (data.len == 0) return 0;

    var iovecs_buffer: [max_iovecs_len]iovec = undefined;
    var i: usize = 0;
    for (data) |buf| {
        if (iovecs_buffer.len - i == 0) break;
        if (buf.len > 0) {
            iovecs_buffer[i] = .{ .base = buf.ptr, .len = buf.len };
            i += 1;
        }
    }
    const iov = iovecs_buffer[0..i];
    assert(iov[0].len > 0);

    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.readv(@intFromPtr(fiber), fd, iov, offset);
        ev.yield(null, .nothing);
        const completion = fiber.completion();
        switch (completion.errno()) {
            .SUCCESS => return @as(u32, @bitCast(completion.result)),
            .INTR, .CANCELED => {},
            else => |errno| return errnoToError(ErrorSet, errno),
        }
    }
}

fn pwritev(
    ev: *Evented,
    fd: fd_t,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    offset: ?u64,
) File.Writer.Error!usize {
    var iovecs: [max_iovecs_len]iovec_const = undefined;
    const iov = fillIovecs(&iovecs, header, data, splat);

    if (iov.len == 0) return 0;
    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.writev(@intFromPtr(fiber), fd, iov, offset);
        ev.yield(null, .nothing);
        const completion = fiber.completion();
        switch (completion.errno()) {
            .SUCCESS => return @as(u32, @bitCast(completion.result)),
            .INTR, .CANCELED => {},
            else => |errno| return errnoToError(File.Writer.Error, errno),
        }
    }
}

fn readAll(ev: *Evented, fd: fd_t, buffer: []u8) (File.Reader.Error || error{EndOfStream})!void {
    var index: usize = 0;
    while (buffer.len - index != 0) {
        const len = try ev.read(fd, buffer, null, File.Reader.Error);
        if (len == 0) return error.EndOfStream;
        index += len;
    }
}

fn realPath(ev: *Evented, fd: fd_t, out_buffer: []u8) File.RealPathError!usize {
    var procfs_buf: [std.fmt.count("/proc/self/fd/{d}\x00", .{std.math.minInt(fd_t)})]u8 = undefined;
    const proc_path = std.fmt.bufPrintSentinel(&procfs_buf, "/proc/self/fd/{d}", .{fd}, 0) catch
        unreachable;
    while (true) {
        try ev.enqueueSync();
        const rc = linux.readlink(proc_path, out_buffer.ptr, out_buffer.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => {},
            .ACCES => return error.AccessDenied,
            .FAULT => |err| return errnoBug(err),
            .IO => return error.FileSystem,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOTDIR => return error.NotDir,
            .ILSEQ => |err| return errnoBug(err),
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn renameat(
    ev: *Evented,
    old_dir: fd_t,
    old_path: [*:0]const u8,
    new_dir: fd_t,
    new_path: [*:0]const u8,
    flags: linux.RENAME,
) Dir.RenameError!void {
    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.renameat(@intFromPtr(fiber), old_dir, old_path, new_dir, new_path, flags);
        ev.yield(null, .nothing);
        switch (fiber.errno()) {
            .SUCCESS => return,
            .INTR, .CANCELED => {},
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .BUSY => return error.FileBusy,
            .DQUOT => return error.DiskQuota,
            .ISDIR => return error.IsDir,
            .IO => return error.HardwareFailure,
            .LOOP => return error.SymLinkLoop,
            .MLINK => return error.LinkQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .EXIST => return error.DirNotEmpty,
            .NOTEMPTY => return error.DirNotEmpty,
            .ROFS => return error.ReadOnlyFileSystem,
            .XDEV => return error.CrossDevice,
            .ILSEQ => return error.BadPathName,
            .FAULT => |err| return errnoBug(err),
            .INVAL => |err| return errnoBug(err),
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn setsockopt(
    ev: *Evented,
    fd: fd_t,
    level: u32,
    opt_name: u32,
    option: u32,
) !void {
    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.setsockopt(
            @intFromPtr(fiber),
            fd,
            level,
            opt_name,
            @intFromPtr(&option),
            @sizeOf(u32),
        );
        ev.yield(null, .nothing);
        switch (fiber.errno()) {
            .SUCCESS => return,
            .INTR, .CANCELED => {},
            .BADF => |err| return errnoBug(err), // File descriptor used after closed.
            .NOTSOCK => |err| return errnoBug(err),
            .INVAL => |err| return errnoBug(err),
            .FAULT => |err| return errnoBug(err),
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn socket(
    ev: *Evented,
    family: linux.sa_family_t,
    options: net.IpAddress.BindOptions,
) error{
    AddressFamilyUnsupported,
    ProtocolUnsupportedBySystem,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolUnsupportedByAddressFamily,
    SocketModeUnsupported,
    OptionUnsupported,
    Unexpected,
    Canceled,
}!fd_t {
    const mode, const protocol = try posixSocketModeProtocol(family, options.mode, options.protocol);
    const socket_fd = while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.socket(@intFromPtr(fiber), family, mode | linux.SOCK.CLOEXEC, protocol, 0);
        ev.yield(null, .nothing);
        const completion = fiber.completion();
        switch (completion.errno()) {
            .SUCCESS => break completion.result,
            .INTR, .CANCELED => {},
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .INVAL => return error.ProtocolUnsupportedBySystem,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
            .PROTOTYPE => return error.SocketModeUnsupported,
            else => |err| return unexpectedErrno(err),
        }
    };
    errdefer ev.closeAsync(socket_fd);

    if (options.ip6_only) |ip6_only| {
        if (linux.IPV6 == void) return error.OptionUnsupported;
        try ev.setsockopt(socket_fd, linux.IPPROTO.IPV6, linux.IPV6.V6ONLY, @intFromBool(ip6_only));
    }

    return socket_fd;
}

fn stat(ev: *Evented, fd: fd_t) File.StatError!Dir.Stat {
    const linux_statx, const errno = try ev.statxRaw(fd, "", linux_statx_request, linux.AT.EMPTY_PATH);
    if (linux_statx) |ls| return statFromLinux(&ls);
    return errnoToError(File.StatError, errno);
}

const StatxError = Dir.StatError || Dir.PathNameError || error{ FileNotFound, NotDir, SymLinkLoop };
fn statx(
    ev: *Evented,
    dir: fd_t,
    path: [*:0]const u8,
    flags: u32,
) StatxError!Dir.Stat {
    const linux_statx, const errno = try ev.statxRaw(dir, path, linux_statx_request, flags);
    if (linux_statx) |ls| return statFromLinux(&ls);
    return errnoToError(StatxError, errno);
}

fn statxRaw(
    ev: *Evented,
    fd: fd_t,
    path: [*:0]const u8,
    mask: linux.STATX,
    flags: u32,
) Io.Cancelable!struct { ?linux.Statx, linux.E } {
    while (true) {
        var statx_buf = std.mem.zeroes(linux.Statx);
        const sqe, const fiber = try ev.enqueue();
        sqe.statx(@intFromPtr(fiber), fd, path, mask, &statx_buf, flags);
        ev.yield(null, .nothing);
        switch (fiber.errno()) {
            .SUCCESS => |errno| return .{ statx_buf, errno },
            .INTR, .CANCELED => {},
            else => |errno| return .{ null, errno },
        }
    }
}

fn urandomReadAll(
    ev: *Evented,
    buffer: []u8,
) (File.OpenError || File.Reader.Error || error{EndOfStream})!void {
    return ev.readAll(try ev.random_fd.open(ev, "/dev/urandom", .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
    }), buffer);
}

fn utimensat(
    ev: *Evented,
    dir: fd_t,
    path: [*:0]const u8,
    times: ?*const [2]linux.timespec,
    flags: u32,
) File.SetTimestampsError!void {
    while (true) {
        try ev.enqueueSync();
        switch (linux.errno(linux.utimensat(dir, path, times, flags))) {
            .SUCCESS => return,
            .INTR => {},
            .BADF => |err| return errnoBug(err), // always a race condition
            .FAULT => |err| return errnoBug(err),
            .INVAL => |err| return errnoBug(err),
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ROFS => return error.ReadOnlyFileSystem,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn listen(
    ev: *Evented,
    socket_fd: fd_t,
    backlog: u32,
) !void {
    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.listen(@intFromPtr(fiber), socket_fd, backlog, 0);
        ev.yield(null, .nothing);
        switch (fiber.errno()) {
            .SUCCESS => return,
            .INTR, .CANCELED => {},
            .ADDRINUSE => return error.AddressInUse,
            .BADF => |err| return errnoBug(err),
            .NOTSOCK => |err| return errnoBug(err),
            .OPNOTSUPP => |err| return errnoBug(err),
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn writeAllSync(fd: fd_t, buffer: []const u8) File.Writer.Error!void {
    var index: usize = 0;
    while (buffer.len - index != 0) index += try writeSync(fd, buffer[index..]);
}

fn writeSync(fd: fd_t, buffer: []const u8) File.Writer.Error!usize {
    while (true) {
        const rc = linux.write(fd, buffer.ptr, buffer.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => {},
            .INVAL => |err| return errnoBug(err),
            .FAULT => |err| return errnoBug(err),
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForWriting, // Can be a race condition.
            .DESTADDRREQ => |err| return errnoBug(err), // `connect` was never called.
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PERM => return error.PermissionDenied,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => |err| return errnoBug(err), // Not a socket handle.
            .BUSY => return error.DeviceBusy,
            .ACCES => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn send(
    ev: *Evented,
    socket_fd: net.Socket.Handle,
    buffer: []const u8,
    flags: u32,
) net.Stream.Writer.Error!usize {
    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.send(@intFromPtr(fiber), socket_fd, buffer, flags);
        ev.yield(null, .nothing);
        const completion = fiber.completion();
        switch (completion.errno()) {
            .SUCCESS => return @as(u32, @bitCast(completion.result)),
            .INTR, .CANCELED => {},
            else => |errno| return errnoToError(net.Stream.Writer.Error, errno),
        }
    }
}

fn sendmsg(
    ev: *Evented,
    socket_fd: net.Socket.Handle,
    msg: *const linux.msghdr_const,
    flags: u32,
    comptime ErrorSet: type,
) ErrorSet!usize {
    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.sendmsg(@intFromPtr(fiber), socket_fd, msg, flags);
        ev.yield(null, .nothing);
        const completion = fiber.completion();
        switch (completion.errno()) {
            .SUCCESS => return @as(u32, @bitCast(completion.result)),
            .INTR, .CANCELED => {},
            else => |errno| return errnoToError(ErrorSet, errno),
        }
    }
}

pub const PipeAsyncError = PipeError || Io.Cancelable;
fn pipe2(ev: *Evented, flags: linux.O) PipeAsyncError![2]fd_t {
    var fds: [2]fd_t = undefined;
    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.pipe(@intFromPtr(fiber), &fds, @bitCast(flags));
        ev.yield(null, .nothing);
        switch (fiber.errno()) {
            .SUCCESS => return fds,
            .INTR, .CANCELED => {},
            .INVAL, .NOPKG, .FAULT => |err| return errnoBug(err), // Invalid flags
            .NFILE => return error.SystemFdQuotaExceeded,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn sendfile(
    ev: *Evented,
    fd_in: linux.fd_t,
    off_in: u64,
    fd_out: linux.fd_t,
    count: usize,
    sent: *usize,
) error{ SystemResources, Unexpected, Canceled }!void {
    const pipe = ev.pipe2(.{ .NONBLOCK = true }) catch |err| switch (err) {
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => return error.SystemResources,
        else => |e| return e,
    };
    defer ev.destroyPipe(pipe);

    var buffered: u32 = 0;
    var offset: u64 = off_in;
    var remaining: u32 = @min(count, std.math.maxInt(u32));
    const no_offset: u64 = @bitCast(@as(i64, -1));
    while (remaining > 0) {
        if (buffered == 0) {
            // file to pipe
            const n = try ev.splice(fd_in, offset, pipe[1], no_offset, remaining);
            buffered += n;
            offset += n;
        }
        // pipe to socket
        const m = try ev.splice(pipe[0], no_offset, fd_out, no_offset, buffered);
        buffered -= m;
        sent.* += m;
        remaining -= m;
    }
}

fn splice(
    ev: *Evented,
    fd_in: fd_t,
    off_in: u64,
    fd_out: fd_t,
    off_out: u64,
    len: u32,
) error{ SystemResources, Unexpected, Canceled }!u32 {
    const splice_f_nonblock = 0x02;
    while (true) {
        const sqe, const fiber = try ev.enqueue();
        sqe.splice(@intFromPtr(fiber), fd_in, off_in, fd_out, off_out, len, splice_f_nonblock);
        ev.yield(null, .nothing);
        const completion = fiber.completion();
        switch (completion.errno()) {
            .SUCCESS => return @as(u32, @bitCast(completion.result)),
            .INTR => {},
            .NOMEM => return error.SystemResources,
            .BADF => |err| return errnoBug(err),
            .INVAL => |err| return errnoBug(err),
            .SPIPE => |err| return errnoBug(err),
            .AGAIN => |err| return errnoBug(err),
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn timeoutToLinux(timeout: Io.Timeout) struct { ?linux.kernel_timespec, u32 } {
    const ns: i96, const clock: Io.Clock, const flags: u32 = switch (timeout) {
        .none => return .{ null, 0 },
        .duration => |duration| .{ duration.raw.toNanoseconds(), duration.clock, 0 },
        .deadline => |deadline| .{ deadline.raw.toNanoseconds(), deadline.clock, linux.IORING_TIMEOUT_ABS },
    };
    return .{
        .{
            .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
            .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
        },
        flags | @as(u32, switch (clock) {
            .real => linux.IORING_TIMEOUT_REALTIME,
            .boot => linux.IORING_TIMEOUT_BOOTTIME,
            else => 0,
        }),
    };
}

fn fillIovecs(
    iovecs: []iovec_const,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) []iovec_const {
    var iovlen: usize = 0;
    addBuf(iovecs, &iovlen, header);
    for (data[0 .. data.len - 1]) |bytes| addBuf(iovecs, &iovlen, bytes);
    const pattern = data[data.len - 1];
    var backup_buffer: [splat_buffer_size]u8 = undefined;
    if (iovecs.len - iovlen != 0) switch (splat) {
        0 => {},
        1 => addBuf(iovecs, &iovlen, pattern),
        else => switch (pattern.len) {
            0 => {},
            1 => {
                const splat_buffer = &backup_buffer;
                const memset_len = @min(splat_buffer.len, splat);
                const buf = splat_buffer[0..memset_len];
                @memset(buf, pattern[0]);
                addBuf(iovecs, &iovlen, buf);
                var remaining_splat = splat - buf.len;
                while (remaining_splat > splat_buffer.len and iovecs.len - iovlen != 0) {
                    assert(buf.len == splat_buffer.len);
                    addBuf(iovecs, &iovlen, splat_buffer);
                    remaining_splat -= splat_buffer.len;
                }
                addBuf(iovecs, &iovlen, splat_buffer[0..@min(remaining_splat, splat_buffer.len)]);
            },
            else => for (0..@min(splat, iovecs.len - iovlen)) |_| {
                addBuf(iovecs, &iovlen, pattern);
            },
        },
    };
    return iovecs[0..iovlen];
}

fn addBuf(v: []iovec_const, i: *usize, bytes: []const u8) void {
    // OS checks ptr addr before length so zero length vectors must be omitted.
    if (bytes.len == 0) return;
    if (v.len - i.* == 0) return;
    v[i.*] = .{ .base = bytes.ptr, .len = bytes.len };
    i.* += 1;
}

fn errnoToError(comptime ErrorSet: type, errno: linux.E) ErrorSet {
    return switch (ErrorSet) {
        net.Stream.Writer.Error => switch (errno) {
            .AFNOSUPPORT => error.AddressFamilyUnsupported,
            .ALREADY => error.FastOpenAlreadyInProgress,
            .CONNRESET => error.ConnectionResetByPeer,
            .HOSTUNREACH => error.HostUnreachable,
            .NETDOWN => error.NetworkDown,
            .NETUNREACH => error.NetworkUnreachable,
            .NOBUFS => error.SystemResources,
            .NOMEM => error.SystemResources,
            .NOTCONN => error.SocketUnconnected,
            .PIPE => error.SocketUnconnected,
            .ACCES => |err| errnoBug(err),
            .AGAIN => |err| errnoBug(err),
            .BADF => |err| errnoBug(err), // File descriptor used after closed.
            .DESTADDRREQ => |err| errnoBug(err), // The socket is not connection-mode, and no peer address is set.
            .FAULT => |err| errnoBug(err), // An invalid user space address was specified for an argument.
            .INVAL => |err| errnoBug(err), // Invalid argument passed.
            .ISCONN => |err| errnoBug(err), // connection-mode socket was connected already but a recipient was specified
            .MSGSIZE => |err| errnoBug(err),
            .NOTSOCK => |err| errnoBug(err), // The file descriptor sockfd does not refer to a socket.
            .OPNOTSUPP => |err| errnoBug(err), // Some bit in the flags argument is inappropriate for the socket type.
            else => |err| unexpectedErrno(err),
        },
        File.Writer.Error => switch (errno) {
            .INVAL => |err| return errnoBug(err),
            .FAULT => |err| return errnoBug(err),
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForWriting, // Can be a race condition.
            .DESTADDRREQ => |err| return errnoBug(err), // `connect` was never called.
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PERM => return error.PermissionDenied,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => |err| return errnoBug(err), // Not a socket handle.
            .BUSY => return error.DeviceBusy,
            .ACCES => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        },
        net.Socket.SendError => switch (errno) {
            .ACCES => error.AccessDenied,
            .AFNOSUPPORT => error.AddressFamilyUnsupported,
            .ALREADY => error.FastOpenAlreadyInProgress,
            .CONNRESET => error.ConnectionResetByPeer,
            .HOSTUNREACH => error.HostUnreachable,
            .MSGSIZE => error.MessageOversize,
            .NETDOWN => error.NetworkDown,
            .NETUNREACH => error.NetworkUnreachable,
            .NOBUFS => error.SystemResources,
            .NOMEM => error.SystemResources,
            .NOTCONN => error.SocketUnconnected,
            .PIPE => error.SocketUnconnected,
            .BADF => |err| errnoBug(err), // File descriptor used after closed.
            .DESTADDRREQ => |err| errnoBug(err),
            .FAULT => |err| errnoBug(err),
            .INVAL => |err| errnoBug(err),
            .ISCONN => |err| errnoBug(err),
            .NOTSOCK => |err| errnoBug(err),
            .OPNOTSUPP => |err| errnoBug(err),
            else => |err| unexpectedErrno(err),
        },
        File.Reader.Error => switch (errno) {
            .INVAL => |err| errnoBug(err),
            .FAULT => |err| errnoBug(err),
            .AGAIN => error.WouldBlock,
            .BADF => |err| errnoBug(err), // File descriptor used after closed
            .IO => error.InputOutput,
            .ISDIR => error.IsDir,
            .NOBUFS => error.SystemResources,
            .NOMEM => error.SystemResources,
            .NOTCONN => error.SocketUnconnected,
            .CONNRESET => error.ConnectionResetByPeer,
            else => |err| unexpectedErrno(err),
        },
        File.ReadPositionalError => switch (errno) {
            .INVAL => |err| errnoBug(err),
            .FAULT => |err| errnoBug(err),
            .AGAIN => error.WouldBlock,
            .BADF => |err| errnoBug(err), // File descriptor used after closed
            .IO => error.InputOutput,
            .ISDIR => error.IsDir,
            .NOBUFS => error.SystemResources,
            .NOMEM => error.SystemResources,
            .NOTCONN => |err| errnoBug(err),
            .CONNRESET => |err| errnoBug(err),
            else => |err| unexpectedErrno(err),
        },
        net.Stream.Reader.Error => switch (errno) {
            .INVAL => |err| errnoBug(err),
            .FAULT => |err| errnoBug(err),
            .AGAIN => |err| errnoBug(err),
            .BADF => |err| errnoBug(err), // File descriptor used after closed.
            .NOBUFS => error.SystemResources,
            .NOMEM => error.SystemResources,
            .NOTCONN => error.SocketUnconnected,
            .CONNRESET => error.ConnectionResetByPeer,
            .PIPE => error.SocketUnconnected,
            .NETDOWN => error.NetworkDown,
            else => |err| unexpectedErrno(err),
        },
        FilePathStatError, File.StatError => switch (errno) {
            .SUCCESS => unreachable,
            .INTR, .CANCELED => unreachable,
            .ACCES => |err| return errnoBug(err),
            .BADF => |err| return errnoBug(err), // File descriptor used after closed.
            .FAULT => |err| return errnoBug(err),
            .INVAL => |err| return errnoBug(err),
            .LOOP => |err| return errnoBug(err),
            .NAMETOOLONG => |err| return errnoBug(err),
            .NOENT => |err| return errnoBug(err),
            .NOMEM => return error.SystemResources,
            .NOTDIR => |err| return errnoBug(err),
            else => |err| return unexpectedErrno(err),
        },
        StatxError => switch (errno) {
            .SUCCESS => unreachable,
            .INTR, .CANCELED => unreachable,
            .ACCES => return error.AccessDenied,
            .BADF => |err| return errnoBug(err), // File descriptor used after closed.
            .FAULT => |err| return errnoBug(err),
            .INVAL => |err| return errnoBug(err),
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => |err| return errnoBug(err),
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .NOMEM => return error.SystemResources,
            else => |err| return unexpectedErrno(err),
        },
        else => comptime unreachable,
    };
}

test {
    _ = Fiber.CancelProtection;
}
