const std = @import("std");
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

    const addr = try Io.net.IpAddress.parse("0.0.0.0", 4242);
    var server = try addr.listen(io, .{ .reuse_address = true, .kernel_backlog = 4 * 1024 });

    var group: Io.Group = .init;
    while (true) {
        const stream = try server.accept(io);
        log.debug(
            "{} accepted, port: {}",
            .{ stream.socket.handle, stream.socket.address.getPort() },
        );
        group.async(io, handle, .{ io, init.gpa, stream, args.read_buffer_size });
    }
    try group.await(io);
}

fn handle(io: Io, gpa: mem.Allocator, stream: Io.net.Stream, read_buffer_size: usize) void {
    handleFallible(io, gpa, stream, read_buffer_size) catch |err| {
        log.err("{} {}", .{ stream.socket.handle, err });
    };
    log.debug("{} closed", .{stream.socket.handle});
}

fn handleFallible(io: Io, gpa: mem.Allocator, stream: Io.net.Stream, read_buffer_size: usize) !void {
    defer stream.close(io);

    const read_buffer = try gpa.alloc(u8, read_buffer_size);
    var write_buffer: [0]u8 = undefined;
    var rdr = stream.reader(io, read_buffer);
    var wrt = stream.writer(io, &write_buffer);

    return echo(stream.socket.handle, &rdr.interface, &wrt.interface) catch |err|
        switch (err) {
            error.EndOfStream => {},
            error.ReadFailed => |e| if (rdr.err) |re| re else e,
            error.WriteFailed => |e| if (wrt.err) |we| we else e,
        };
}

fn echo(fd: Io.net.Socket.Handle, r: *Io.Reader, w: *Io.Writer) !void {
    while (true) {
        try r.fillMore();
        log.debug("{} read {} bytes", .{ fd, r.bufferedLen() });
        try w.writeAll(r.buffered());
        try w.flush();
        r.tossBuffered();
    }
}

const Args = struct {
    read_buffer_size: usize = 4096,
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
            if (mem.eql(u8, "-b", arg)) {
                args.read_buffer_size = try std.fmt.parseInt(usize, iter.next().?, 10);
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
