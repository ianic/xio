const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const log = std.log.scoped(.main);
const assert = std.debug.assert;
const testing = std.testing;
const Uring = @import("Uring.zig");

test "tcp echo" {
    const gpa = testing.allocator;

    var uring: Uring = undefined;
    try uring.init(gpa, .{});
    defer uring.deinit();

    var threaded = Io.Threaded.init(gpa, .{
        .async_limit = .limited(2),
        .concurrent_limit = .limited(2),
    });
    defer threaded.deinit();

    for ([_]Io{ threaded.io(), uring.io() }) |io| {
        var addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
        var server = try addr.listen(io, .{ .reuse_address = true });
        addr = server.socket.address;

        var f_server = io.async(echoServer, .{ io, &server });
        var f_client = io.async(sendRecvClient, .{ io, addr, 4096, 2 });
        try testing.expectEqual(try f_server.await(io), try f_client.await(io));
    }
}

// Handles single connection. Echoes any received bytes until connection is
// closed. Returns number of bytes echoed.
fn echoServer(io: std.Io, server: *Io.net.Server) !usize {
    const conn = try server.accept(io);
    defer conn.close(io);

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [0]u8 = undefined;
    var rdr = conn.reader(io, &read_buffer);
    var wrt = conn.writer(io, &write_buffer);
    const r = &rdr.interface;
    const w = &wrt.interface;

    var bytes_count: usize = 0;
    while (true) {
        r.fillMore() catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        try w.writeAll(r.buffered());
        bytes_count += r.bufferedLen();
        try w.flush();
        r.tossBuffered();
    }
    return bytes_count;
}

// Sends `bytes_count` bytes `send_count` times to the address and expectes to
// receive same bytes back.
fn sendRecvClient(io: Io, addr: Io.net.IpAddress, bytes_count: usize, send_count: usize) !usize {
    const data = try testing.allocator.alloc(u8, bytes_count);
    defer testing.allocator.free(data);
    io.random(data);

    var conn = try addr.connect(io, .{
        .mode = .stream,
        .protocol = .tcp,
        //.timeout = .{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .real } },
    });
    defer conn.close(io);

    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [0]u8 = undefined;
    var rdr = conn.reader(io, &read_buffer);
    var wrt = conn.writer(io, &write_buffer);
    const r = &rdr.interface;
    const w = &wrt.interface;

    for (0..send_count) |_| {
        try w.writeAll(data);
        var n: usize = 0;
        while (n < data.len) {
            try r.fillMore();
            try testing.expectEqualSlices(u8, data[n..][0..r.bufferedLen()], r.buffered());
            n += r.bufferedLen();
            r.tossBuffered();
        }
    }
    return send_count * data.len;
}

test "tcp sendfile" {
    const S = struct {
        // Collect received data
        fn server(gpa: mem.Allocator, io: std.Io, srv: *Io.net.Server) ![]u8 {
            const conn = try srv.accept(io);
            defer conn.close(io);

            var read_buffer: [4096]u8 = undefined;
            var rdr = conn.reader(io, &read_buffer);
            const r = &rdr.interface;

            var a: Io.Writer.Allocating = .init(gpa);
            defer a.deinit();
            const w = &a.writer;

            while (true) {
                r.fillMore() catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => |e| return e,
                };
                try w.writeAll(r.buffered());
                r.tossBuffered();
            }
            return try a.toOwnedSlice();
        }

        // Use sendfile to send header and file from offset and max limit bytes
        fn client(io: Io, addr: Io.net.IpAddress, file: Io.File, header: []const u8, offset: usize, limit: Io.Limit) !usize {
            var fr = file.reader(io, &.{});
            try fr.seekTo(offset);

            var conn = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
            defer conn.close(io);

            var writer_buf: [4096]u8 = undefined;
            assert(header.len < writer_buf.len);
            var wrt = conn.writer(io, &writer_buf);
            const w = &wrt.interface;
            try w.writeAll(header);

            const n = try w.sendFile(&fr, limit);
            return n + header.len;
        }
    };

    // Open a file
    // const dir = try Io.Dir.openDirAbsolute(testing.io, "/home/ianic/Code/tmp", .{});
    // defer dir.close(testing.io);
    // const file = try dir.openFile(testing.io, "pg2600.txt", .{});
    const file = try Io.Dir.cwd().openFile(testing.io, "build.zig.zon", .{});

    defer file.close(testing.io);
    const header = "iso medu u ducan nije reko dobar dan";
    const offset = 32;
    const limit: Io.Limit = .limited(1024); //.unlimited;

    // Init Io.Uring
    const gpa = testing.allocator;
    var uring: Uring = undefined;
    try uring.init(gpa, .{});
    defer uring.deinit();
    const io = uring.io();

    _ = try file.length(io);

    // Start server on os assigned port
    var addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    addr = server.socket.address;

    // Run client adn server
    var f_server = io.async(S.server, .{ gpa, io, &server });
    var f_client = io.async(S.client, .{ io, addr, file, header, offset, limit });
    const recv = try f_server.await(io);
    const sent = try f_client.await(io);
    defer gpa.free(recv);

    // Server should get header and part of the file defined by offset and limit.
    try testing.expectEqual(recv.len, sent);
    try testing.expectEqualSlices(u8, recv[0..header.len], header);
    var fr = file.reader(testing.io, &.{});
    try fr.seekTo(offset);
    const r = &fr.interface;
    const file_content = try r.readAlloc(gpa, recv.len - header.len);
    defer gpa.free(file_content);
    try testing.expectEqualSlices(u8, recv[header.len..], file_content);
}

test "some file operations" {
    const gpa = testing.allocator;
    var uring: Uring = undefined;
    try uring.init(gpa, .{});
    defer uring.deinit();
    const io = uring.io();

    const dir = Io.Dir.cwd();
    const file = try dir.openFile(testing.io, "build.zig.zon", .{});
    defer file.close(io);
    const len = try file.length(io);
    const stat = try file.stat(io);
    try testing.expectEqual(len, stat.size);
}

test "some dir operations" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    const gpa = testing.allocator;
    var uring: Uring = undefined;
    try uring.init(gpa, .{});
    defer uring.deinit();
    const io = uring.io();

    var file = try dir.createFile(io, "pero", .{});
    defer file.close(io);
    try testing.expectError(error.NotDir, dir.createDirPath(io, "pero"));

    try file.setPermissions(io, .default_file);
}

test "batch" {
    const S = struct {
        fn server(gpa: mem.Allocator, io: std.Io, socket: *Io.net.Socket) !usize {
            _ = gpa;
            var data_buffer: [1024]u8 = undefined;
            var msg: [2]Io.net.IncomingMessage = undefined;
            const timeout: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(1000), .clock = .real } };

            const maybe_err, const msg_count = socket.receiveManyTimeout(io, &msg, &data_buffer, .{}, timeout);
            if (maybe_err) |err| switch (err) {
                error.Timeout => return 0,
                else => |e| return e,
            };
            var size: usize = 0;
            for (0..msg_count) |i| {
                size += msg[i].data.len;
            }
            return size;
        }
        fn client(io: Io, addr: Io.net.IpAddress) !usize {
            var baddr = try Io.net.IpAddress.parse("127.0.0.1", 0);
            const sock = try baddr.bind(io, .{ .mode = .dgram, .protocol = .udp });
            defer sock.close(io);

            const data = "iso medu u ducan nije reko dobar dan";
            var msgs: [2]Io.net.OutgoingMessage = .{
                .{
                    .address = &addr,
                    .data_ptr = data[0..].ptr,
                    .data_len = 10,
                },
                .{
                    .address = &addr,
                    .data_ptr = data[10..].ptr,
                    .data_len = data[10..].len,
                },
            };

            try sock.sendMany(io, &msgs, .{});
            return data.len;
        }
    };

    const gpa = testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{
        .async_limit = .limited(2),
        .concurrent_limit = .limited(2),
    });
    defer threaded.deinit();
    const io = threaded.io();

    // var uring: Io.Uring = undefined;
    // try uring.init(gpa, .{});
    // defer uring.deinit();
    // const io = uring.io();

    // Start server on os assigned port
    var addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var socket = try addr.bind(io, .{ .mode = .dgram, .protocol = .udp });
    addr = socket.address;

    // Run client adn server
    var f_server = io.async(S.server, .{ gpa, io, &socket });
    var f_client = io.async(S.client, .{ io, addr });
    const recv = try f_server.await(io);
    const sent = try f_client.await(io);

    try testing.expectEqual(36, sent);
    try testing.expect(recv > 0);
    try testing.expect(recv == 36 or recv == 10);
}
