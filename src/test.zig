const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const log = std.log.scoped(.main);
const assert = std.debug.assert;
const testing = std.testing;
const Evented = @import("Evented.zig");

test "tcp" {
    const gpa = testing.allocator;

    var evented: Evented = undefined;
    try evented.init(gpa, .{});
    defer evented.deinit();

    var threaded = Io.Threaded.init(gpa, .{
        .async_limit = .limited(2),
        .concurrent_limit = .limited(2),
    });
    defer threaded.deinit();

    for (0..2) |_| {
        for ([_]Io{ threaded.io(), evented.io() }) |io| {
            var addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
            var server = try addr.listen(io, .{ .reuse_address = true });
            addr = server.socket.address;

            var f_server = io.async(echoServer, .{ io, &server });
            var f_client = io.async(sendRecvClient, .{ io, addr, 4096, 2 });
            try testing.expectEqual(try f_server.await(io), try f_client.await(io));
        }
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

test "sendfile" {
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
    var evented: Evented = undefined;
    try evented.init(gpa, .{});
    defer evented.deinit();
    const io = evented.io();

    _ = try file.length(io);

    // Start server on os assigned port
    var addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    addr = server.socket.address;

    // Run client and server
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
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    var evented: Evented = undefined;
    try evented.init(gpa, .{});
    defer evented.deinit();
    const io = evented.io();

    {
        try dir.createDir(io, "folder1", .default_dir);
        try dir.createDirPath(io, "folder2/folder21");
        const dir2 = try dir.createDirPathOpen(io, "folder3/folder31", .{});
        defer dir2.close(io);
        var stat = try dir2.stat(io);
        try testing.expectEqual(.directory, stat.kind);
        try dir.rename("folder1", dir2, "folder32", io);

        const file = try dir.createFile(io, "file2", .{});
        defer file.close(io);
        try dir.hardLink("file2", dir2, "link", io, .{});
        try file.hardLink(io, dir2, "link2", .{});

        try dir.symLink(io, "../../file2", "folder3/folder31/symlink", .{});
        stat = try dir.statFile(io, "folder3/folder31/symlink", .{ .follow_symlinks = false });
        try testing.expectEqual(.sym_link, stat.kind);
        stat = try dir.statFile(io, "folder3/folder31/symlink", .{ .follow_symlinks = true });
        try testing.expectEqual(.file, stat.kind);

        const file3 = try dir.createFile(io, "file3", .{});
        file3.close(io);
        try dir.rename("file3", dir2, "file3_mv", io);
        stat = try dir.statFile(io, "folder3/folder31/file3_mv", .{});
        try testing.expectEqual(.file, stat.kind);
    }
    { // sync operations
        try testing.expectError(error.FileNotFound, dir.access(io, "folder1", .{}));
        try dir.createDir(io, "folder1", .default_dir);
        try dir.access(io, "folder1", .{ .read = true, .write = true });
    }
    {
        const file = try dir.createFile(io, "file1", .{ .read = true });
        var n = try file.writeStreaming(io, "header\n", &.{ "line1\n", "line2\n", "footer\n" }, 2);
        try testing.expectEqual(33, n);

        var buf1: [5]u8 = undefined;
        n = try file.readPositional(io, &.{&buf1}, 7);
        try testing.expectEqualSlices(u8, "line1", buf1[0..n]);

        var buf2: [7]u8 = undefined;
        var buf3: [7]u8 = undefined;

        n = try file.readPositional(io, &.{ &buf2, &buf3 }, 19);
        try testing.expectEqual(14, n);
        try testing.expectEqualSlices(u8, "footer\n", &buf2);
        try testing.expectEqualSlices(u8, &buf3, &buf2);

        n = try file.writePositional(io, &.{ "line3\n", "line4\n" }, 7);
        try testing.expectEqual(12, n);

        try file.setLength(io, 33 - 3);
        // var buf4: [1024]u8 = undefined;
        // n = try file.readPositional(io, &.{&buf4}, 0);
        // std.debug.print("{s}", .{buf4[0..n]});
    }
    {
        const file = try dir.openFile(testing.io, "file1", .{});
        defer file.close(io);
        const len = try file.length(io);
        const stat = try file.stat(io);
        try testing.expectEqual(30, len);
        try testing.expectEqual(len, stat.size);
    }
    {
        try dir.deleteFile(io, "file1");
        try dir.deleteFile(io, "file2");
        try dir.deleteDir(io, "folder1");
    }
}

test "some dir operations" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    const gpa = testing.allocator;
    var evented: Evented = undefined;
    try evented.init(gpa, .{});
    defer evented.deinit();
    const io = evented.io();

    var file = try dir.createFile(io, "pero", .{});
    defer file.close(io);
    try testing.expectError(error.NotDir, dir.createDirPath(io, "pero"));

    try file.setPermissions(io, .default_file);
}

test "batch" {
    if (true) return error.SkipZigTest;
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
    // var threaded = Io.Threaded.init(gpa, .{
    //     .async_limit = .limited(2),
    //     .concurrent_limit = .limited(2),
    // });
    // defer threaded.deinit();
    // const io = threaded.io();

    var evented: Evented = undefined;
    try evented.init(gpa, .{});
    defer evented.deinit();
    const io = evented.io();

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

test "random" {
    const gpa = testing.allocator;
    var evented: Evented = undefined;
    try evented.init(gpa, .{});
    defer evented.deinit();
    const io = evented.io();

    var buffer: [1024]u8 = @splat(0xff);
    io.random(&buffer);
    var n: usize = 0;
    for (buffer, 1..) |c, i| {
        _ = i;
        // std.debug.print("{x:0<2} ", .{c});
        // if (i % 8 == 0) std.debug.print(" ", .{});
        // if (i % 32 == 0) std.debug.print("\n", .{});
        if (c == 0xff) n += 1;
    }
    //std.debug.print("0xff count: {}\n", .{n});
    try testing.expect(n < buffer.len);
}

test "panic" {
    if (true) return error.SkipZigTest;
    const gpa = testing.allocator;
    var evented: Evented = undefined;
    try evented.init(gpa, .{});
    defer evented.deinit();
    const io = evented.io();

    var addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    addr = server.socket.address;
    var f = io.async(Io.net.Server.accept, .{ &server, io });
    try io.sleep(.fromMilliseconds(1), .real);
    _ = std.os.linux.close(evented.io_uring.fd);

    const conn = try f.await(io);
    //const conn = try server.accept(io);
    defer conn.close(io);
}

test "resize" {
    const gpa = testing.allocator;
    var evented: Evented = undefined;
    try evented.init(gpa, .{ .log2_ring_entries = 1 });
    defer evented.deinit();
    const io = evented.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try testing.expectEqual(2, evented.io_uring.sq.sqes.len);

    var f1 = io.async(Io.Dir.createFile, .{ dir, io, "file1", Io.Dir.CreateFileOptions{} });
    var f2 = io.async(Io.Dir.createFile, .{ dir, io, "file2", Io.Dir.CreateFileOptions{} });
    var f3 = io.async(Io.Dir.createFile, .{ dir, io, "file3", Io.Dir.CreateFileOptions{} });
    _ = try f1.await(io);
    try testing.expectEqual(4, evented.io_uring.sq.sqes.len);
    _ = try f2.await(io);
    _ = try f3.await(io);
}

test "group" {
    const Task = struct {
        err: ?anyerror = null,
        fn createFile(self: *@This(), io: Io, dir: Io.Dir, name: []const u8) Io.Cancelable!void {
            const file = dir.createFile(io, name, .{}) catch |err| {
                self.err = err;
                switch (err) {
                    error.Canceled => |e| return e,
                    else => return,
                }
            };
            file.close(io);
        }
    };

    const gpa = testing.allocator;
    var evented: Evented = undefined;
    try evented.init(gpa, .{});
    defer evented.deinit();
    const io = evented.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    {
        var task1: Task = .{};
        var task2: Task = .{};
        var task3: Task = .{};

        var grp = Io.Group.init;
        grp.async(io, Task.createFile, .{ &task1, io, dir, ".." });
        grp.async(io, Task.createFile, .{ &task2, io, dir, "file2" });
        grp.async(io, Task.createFile, .{ &task3, io, dir, "file3" });
        try grp.await(io);

        try testing.expect(task1.err != null);
        try testing.expectEqual(error.IsDir, task1.err.?);
        try testing.expect(task2.err == null);
        try testing.expect(task3.err == null);
    }

    {
        var task1: Task = .{};
        var task2: Task = .{};
        var task3: Task = .{};

        var grp = Io.Group.init;
        try testing.expect(evented.ready_queue == null);
        grp.async(io, Task.createFile, .{ &task1, io, dir, ".." });
        try testing.expect(evented.ready_queue != null);
        const fiber1 = evented.ready_queue.?;
        try testing.expect(fiber1.link.group.next == null);

        grp.async(io, Task.createFile, .{ &task2, io, dir, "file2" });
        const fiber2 = evented.ready_queue.?;
        try testing.expect(fiber2.link.group.next != null);
        try testing.expect(fiber2.link.group.next.? == fiber1);

        grp.async(io, Task.createFile, .{ &task3, io, dir, "file3" });
        const fiber3 = evented.ready_queue.?;
        try testing.expect(fiber3.link.group.next != null);
        try testing.expect(fiber3.link.group.next.? == fiber2);

        try testing.expect(!fiber1.cancel_status.requested);
        try testing.expectEqual(.nothing, fiber1.cancel_status.awaiting);
        try testing.expect(!fiber2.cancel_status.requested);
        try testing.expectEqual(.nothing, fiber2.cancel_status.awaiting);
        try testing.expect(!fiber3.cancel_status.requested);
        try testing.expectEqual(.nothing, fiber3.cancel_status.awaiting);

        // if (true) return error.Exit; // this panics in uring.deinit();
        grp.cancel(io);

        try testing.expectEqual(error.Canceled, task1.err.?);
        try testing.expectEqual(error.Canceled, task2.err.?);
        try testing.expectEqual(error.Canceled, task3.err.?);
    }
}

// test "dns" {
//     const gpa = testing.allocator;
//     var ev: Evented = undefined;
//     try ev.init(gpa, .{});
//     defer ev.deinit();
//     const io = ev.io();

//     const host = "google.com";
//     const host_name = try Io.net.HostName.init(host);
//     _ = host_name.connect(io, 80, .{ .mode = .stream }) catch |err| switch (err) {
//         error.NetworkDown => .{},
//         else => |e| return e,
//     };
// }

test "dns io" {
    const gpa = testing.allocator;

    var threaded = Io.Threaded.init(gpa, .{
        .async_limit = .limited(2),
        .concurrent_limit = .limited(2),
    });
    defer threaded.deinit();

    var ev: Evented = undefined;
    try ev.init(gpa, .{});
    defer ev.deinit();

    const host = "www.google.com";
    //const host = "trinitymedia.ai";
    const host_name = try Io.net.HostName.init(host);

    for ([_]Io{ threaded.io(), ev.io() }) |io| {
        var canonical_name_buffer: [Io.net.HostName.max_len]u8 = undefined;
        const port: u16 = 80;
        var lookup_buffer: [32]Io.net.HostName.LookupResult = undefined;
        var lookup_queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&lookup_buffer);
        try host_name.lookup(io, &lookup_queue, .{
            .port = port,
            .canonical_name_buffer = &canonical_name_buffer,
            //.family = .ip6,
        });

        while (true) {
            const res = lookup_queue.getOne(io) catch |err| switch (err) {
                error.Closed => break,
                else => |e| return e,
            };
            switch (res) {
                .address => |a| {
                    std.debug.print("address: {}\n", .{a});
                },
                .canonical_name => |c| {
                    std.debug.print("cname: {s}\n", .{c.bytes});
                },
            }
        }
    }
}

test "dns lookup /etc/hosts" {
    const gpa = testing.allocator;

    var threaded = Io.Threaded.init(gpa, .{
        .async_limit = .limited(2),
        .concurrent_limit = .limited(2),
    });
    defer threaded.deinit();

    var ev: Evented = undefined;
    try ev.init(gpa, .{});
    defer ev.deinit();

    const host = "nas";
    const expected = try Io.net.IpAddress.parseIp4("192.168.190.250", 81);

    for ([_]Io{ threaded.io(), ev.io() }) |io| {
        const host_name = try Io.net.HostName.init(host);
        var canonical_name_buffer: [Io.net.HostName.max_len]u8 = undefined;
        const port: u16 = 81;
        var lookup_buffer: [2]Io.net.HostName.LookupResult = undefined;
        var lookup_queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&lookup_buffer);
        try host_name.lookup(io, &lookup_queue, .{
            .port = port,
            .canonical_name_buffer = &canonical_name_buffer,
            .family = .ip4,
        });

        const res = try lookup_queue.getOne(io);
        try testing.expect(res.address.eql(&expected));
    }
}

test "dns lookup ip" {
    const gpa = testing.allocator;

    var threaded = Io.Threaded.init(gpa, .{
        .async_limit = .limited(2),
        .concurrent_limit = .limited(2),
    });
    defer threaded.deinit();

    var ev: Evented = undefined;
    try ev.init(gpa, .{});
    defer ev.deinit();

    const host = "192.168.190.250";
    const expected = try Io.net.IpAddress.parseIp4("192.168.190.250", 82);

    for ([_]Io{ threaded.io(), ev.io() }) |io| {
        const host_name = try Io.net.HostName.init(host);
        var canonical_name_buffer: [Io.net.HostName.max_len]u8 = undefined;
        const port: u16 = 82;
        var lookup_buffer: [2]Io.net.HostName.LookupResult = undefined;
        var lookup_queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&lookup_buffer);
        try host_name.lookup(io, &lookup_queue, .{
            .port = port,
            .canonical_name_buffer = &canonical_name_buffer,
            .family = .ip4,
        });

        const res = try lookup_queue.getOne(io);
        try testing.expect(res.address.eql(&expected));
    }
}

test "netReceive" {
    const gpa = testing.allocator;

    // var threaded = Io.Threaded.init(gpa, .{
    //     .async_limit = .limited(2),
    //     .concurrent_limit = .limited(2),
    // });
    // defer threaded.deinit();
    // const io = threaded.io();

    var ev: Evented = undefined;
    try ev.init(gpa, .{});
    defer ev.deinit();
    const io = ev.io();

    const bind_addr = try std.Io.net.IpAddress.parse("0.0.0.0", 0);
    const socket = try bind_addr.bind(io, .{ .mode = .dgram, .protocol = .udp });
    const addr = &socket.address;

    var data: [128 * 4]u8 = undefined;
    io.random(&data);

    var outgoing_messages: [4]Io.net.OutgoingMessage = undefined;
    for (&outgoing_messages, 0..) |*msg, i| {
        msg.* = .{
            .address = addr,
            .data_ptr = data[128 * i ..].ptr,
            .data_len = 128,
        };
    }

    var incoming_messages: [4]Io.net.IncomingMessage = undefined;
    var buf: [128 * 5]u8 = undefined;

    const timeout: Io.Timeout = .{ .duration = .{ .clock = .real, .raw = .fromMicroseconds(100) } };

    var out_msgs: usize = 4;
    var in_msgs: usize = 4;
    {
        try socket.sendMany(io, outgoing_messages[0..out_msgs], .{});
        const recv_err, const recv_n = socket.receiveManyTimeout(io, incoming_messages[0..in_msgs], &buf, .{}, timeout);
        if (recv_err) |err| return err;
        const msgs = @min(in_msgs, out_msgs);
        try testing.expectEqual(msgs, recv_n);
        try testing.expectEqualSlices(u8, data[0 .. 128 * msgs], buf[0 .. 128 * msgs]);
    }

    out_msgs = 2;
    in_msgs = 4;
    {
        try socket.sendMany(io, outgoing_messages[0..out_msgs], .{});
        const recv_err, const recv_n = socket.receiveManyTimeout(io, incoming_messages[0..in_msgs], &buf, .{}, timeout);
        if (recv_err) |err| return err;
        const msgs = @min(in_msgs, out_msgs);
        try testing.expectEqual(msgs, recv_n);
        try testing.expectEqualSlices(u8, data[0 .. 128 * msgs], buf[0 .. 128 * msgs]);
    }

    out_msgs = 4;
    in_msgs = 2;
    {
        try socket.sendMany(io, outgoing_messages[0..out_msgs], .{});

        const recv_err, const recv_n = socket.receiveManyTimeout(io, incoming_messages[0..in_msgs], &buf, .{}, timeout);
        if (recv_err) |err| return err;
        const msgs = @min(in_msgs, out_msgs);
        try testing.expectEqual(msgs, recv_n);
        try testing.expectEqualSlices(u8, data[0 .. 128 * msgs], buf[0 .. 128 * msgs]);
    }
    {
        const recv_err, const recv_n = socket.receiveManyTimeout(io, incoming_messages[0..in_msgs], &buf, .{}, timeout);
        if (recv_err) |err| return err;
        const msgs = @min(in_msgs, out_msgs);
        try testing.expectEqual(msgs, recv_n);
        try testing.expectEqualSlices(u8, data[128 * 2 ..][0 .. 128 * msgs], buf[0 .. 128 * msgs]);
    }

    const recv_err, _ = socket.receiveManyTimeout(io, incoming_messages[0..in_msgs], &buf, .{}, timeout);
    try testing.expect(recv_err != null);
    try testing.expectEqual(error.Timeout, recv_err.?);
}

test "explain batch" {
    const gpa = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    var ev: Evented = undefined;
    try ev.init(gpa, .{});
    defer ev.deinit();
    const io = ev.io();

    const f = try dir.createFile(io, "file1", .{});
    defer f.close(io);

    var storage: [4]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&storage);
    batch.addAt(0, .{ .file_write_streaming = .{
        .file = f,
        .data = &[_][]const u8{"iso medo u ducan"},
    } });
    batch.addAt(1, .{ .file_write_streaming = .{
        .file = f,
        .data = &[_][]const u8{"nije reko dobar dan"},
    } });
    batch.addAt(2, .{ .file_write_streaming = .{
        .file = f,
        .data = &[_][]const u8{"nije reko dobar dan"},
    } });
    batch.addAt(3, .{ .file_write_streaming = .{
        .file = f,
        .data = &[_][]const u8{"nije reko dobar dan"},
    } });

    while (!(batch.pending.head == .none and batch.submitted.head == .none)) {
        try batch.awaitConcurrent(
            io,
            .{ .duration = .{ .clock = .real, .raw = .fromMicroseconds(100) } },
        );
        while (batch.next()) |completion| {
            std.debug.print("completion.index: {}\n", .{completion.index});
            switch (completion.index) {
                0 => try testing.expectEqual(16, (try completion.result.file_write_streaming)),
                1, 2, 3 => try testing.expectEqual(19, (try completion.result.file_write_streaming)),
                else => unreachable,
            }
        }
    }
}

test {
    //_ = @import("dns.zig");
}
