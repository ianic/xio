const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.main);
const mem = std.mem;
const xio = @import("xio");

pub fn main(init: std.process.Init) !void {
    // var threaded = Io.Threaded.init(init.gpa, .{
    //     .async_limit = .limited(1),
    //     .concurrent_limit = .limited(2),
    // });
    // defer threaded.deinit();
    // const io = threaded.io();

    // var uring: Io.Uring = undefined;
    // try uring.init(init.gpa, .{
    //     .backing_allocator_needs_mutex = false,
    //     .thread_limit = 0,
    //     .log2_ring_entries = 10,
    // });
    // defer uring.deinit();
    // const io = uring.io();

    var evented: xio.Evented = undefined;
    try evented.init(init.gpa, .{});
    defer evented.deinit();
    const io = evented.io();

    {
        var cond: std.Io.Condition = .init;
        var mutex: std.Io.Mutex = .init;
        try mutex.lock(io);
        var fwait = io.async(Io.Condition.wait, .{ &cond, io, &mutex });

        var fstat = io.async(Io.Dir.stat, .{ Io.Dir.cwd(), io });
        _ = try fstat.await(io);

        var fsignal = io.async(Io.Condition.signal, .{ &cond, io });
        fsignal.await(io);
        try fwait.await(io);
    }
    std.debug.print("====================================\n", .{});
    // Ako ide bez ovog gore, onda futext radi samo ako je private = false.
    // Ako je private = true futexwake odradi i dobije cqe u kome je res = 0 (nikoga nije probudio).
    // ako nije private onda dobije res = 1

    {
        var i: usize = 0;
        const Result = union(enum) {
            a: Io.Dir.StatFileError!Io.Dir.Stat,
            b: Io.Dir.StatFileError!Io.Dir.Stat,
        };
        var results: [2]Result = undefined;
        var select = Io.Select(Result).init(io, &results);
        defer _ = select.cancel();

        const wd = Io.Dir.cwd();
        select.async(.a, Io.Dir.statFile, .{ wd, io, "build.zig", .{} });
        select.async(.b, Io.Dir.statFile, .{ wd, io, "build.zig", .{} });
        while (i < 2) {
            std.debug.print("wait {}\n", .{i});
            switch (try select.await()) {
                .a => {
                    std.debug.print("done a\n", .{});
                },
                .b => {
                    std.debug.print("done b\n", .{});
                },
            }
            i += 1;
        }
    }
}
