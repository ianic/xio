const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const log = std.log.scoped(.main);
const mem = std.mem;
const xio = @import("xio");

pub fn main(init: std.process.Init) !void {
    const args = try Args.parse(init);

    var threaded: Io.Threaded = undefined;
    var evented: xio.Evented = undefined;
    const io = brk: switch (args.io_mode) {
        .threaded => {
            threaded = Io.Threaded.init(init.gpa, .{
                .async_limit = if (args.threaded_thread_limit) |l| Io.Limit.limited(l) else null,
                .concurrent_limit = if (args.threaded_thread_limit) |l| Io.Limit.limited(l) else .unlimited,
            });
            break :brk threaded.io();
        },
        .uring => {
            try evented.init(init.gpa, .{});
            break :brk evented.io();
        },
    };
    defer switch (args.io_mode) {
        .threaded => threaded.deinit(),
        .uring => evented.deinit(),
    };

    const data = try init.gpa.alloc(u8, args.bytes);
    defer init.gpa.free(data);
    io.random(data);

    var group: Io.Group = .init;
    const addr = try Io.net.IpAddress.parse("0.0.0.0", 4242);
    for (0..args.connections) |_| {
        // to limit number of conncurent connections
        // if (no % 128 == 0) {
        //     try group.await(io);
        //     group = .init;
        // }
        group.async(io, run, .{ io, addr, data, args.requests });
    }
    try group.await(io);
}

fn run(io: Io, addr: Io.net.IpAddress, data: []const u8, requests: usize) void {
    runFallible(io, addr, data, requests) catch |err| {
        log.err("run {}", .{err});
        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
    };
}

fn runFallible(io: Io, addr: Io.net.IpAddress, data: []const u8, requests: usize) !void {
    var stream = try addr.connect(io, .{
        .mode = .stream,
        .protocol = .tcp,
        //.timeout = .{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .real } },
    });
    defer stream.close(io);

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [0]u8 = undefined;
    var rdr = stream.reader(io, &read_buffer);
    var wrt = stream.writer(io, &write_buffer);

    return sendReceive(&rdr.interface, &wrt.interface, data, requests) catch |err|
        switch (err) {
            error.EndOfStream => |e| e,
            error.ReadFailed => |e| if (rdr.err) |re| re else e,
            error.WriteFailed => |e| if (wrt.err) |we| we else e,
        };
}

fn sendReceive(r: *Io.Reader, w: *Io.Writer, data: []const u8, requests: usize) !void {
    for (0..requests) |_| {
        try w.writeAll(data);
        try w.flush();
        var n: usize = 0;
        while (n < data.len) {
            try r.fillMore();
            assert(std.mem.eql(u8, data[n..][0..r.bufferedLen()], r.buffered()));
            n += r.bufferedLen();
            r.tossBuffered();
        }
    }
}

const Args = struct {
    connections: usize = 1024,
    requests: usize = 16,
    bytes: usize = 4096,
    io_mode: enum {
        threaded,
        uring,
    } = .threaded,
    threaded_thread_limit: ?usize = null,
    uring_thread_limit: ?usize = null,

    pub fn parse(init: std.process.Init) !Args {
        var iter = init.minimal.args.iterate();
        _ = iter.next();
        var args: Args = .{};

        while (iter.next()) |arg| {
            if (mem.eql(u8, "-c", arg)) {
                args.connections = try std.fmt.parseInt(usize, iter.next().?, 10);
            } else if (mem.eql(u8, "-r", arg)) {
                args.requests = try std.fmt.parseInt(usize, iter.next().?, 10);
            } else if (mem.eql(u8, "-b", arg)) {
                args.bytes = try std.fmt.parseInt(usize, iter.next().?, 10);
            } else if (mem.eql(u8, "-t", arg)) {
                args.io_mode = .threaded;
            } else if (mem.eql(u8, "-u", arg)) {
                args.io_mode = .uring;
            } else if (mem.eql(u8, "-l", arg)) {
                args.threaded_thread_limit = try std.fmt.parseInt(usize, iter.next().?, 10);
            } else if (mem.eql(u8, "-k", arg)) {
                args.uring_thread_limit = try std.fmt.parseInt(usize, iter.next().?, 10);
            } else {
                std.debug.print("unknown argument '{s}'\n", .{arg});
                std.process.exit(1);
            }
        }
        return args;
    }
};
