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

test "dns" {
    const gpa = testing.allocator;
    var ev: Evented = undefined;
    try ev.init(gpa, .{});
    defer ev.deinit();
    const io = ev.io();

    const host = "google.com";
    const host_name = try std.Io.net.HostName.init(host);
    _ = host_name.connect(io, 80, .{ .mode = .stream }) catch |err| switch (err) {
        error.NetworkDown => .{},
        else => |e| return e,
    };
}

test "dns io" {
    const gpa = testing.allocator;
    var ev: Evented = undefined;
    try ev.init(gpa, .{});
    defer ev.deinit();
    const io = ev.io();

    const host = "google.com";
    const host_name = try std.Io.net.HostName.init(host);
    _ = host_name.connect(io, 80, .{ .mode = .stream }) catch |err| switch (err) {
        error.NetworkDown => .{},
        else => |e| return e,
    };
}

const Header = packed struct {
    transaction_id: u16 = 0,
    flags: Flags = .{},
    query_count: u16,
    answer_count: u16 = 0,
    record_count: u16 = 0,
    additional_count: u16 = 0,
};

const Flags = packed struct {
    qr: u1 = 0, // query = 1, response = 2
    opcode: u4 = 0,
    aa: u1 = 0,
    tc: u1 = 0,
    rd: u1 = 0,
    ra: u1 = 0,
    z: u1 = 0,
    ad: u1 = 0,
    cd: u1 = 0,
    rcode: u4 = 0,
};

const udp_payload_size = 1472;

fn query(buf: []u8, transaction_id: u16, name: []const u8) ![]u8 {
    assert(buf.len >= 256);

    var w = Io.Writer.fixed(buf);
    try w.writeInt(u16, transaction_id, .big);
    try w.writeStruct(Flags{ .ra = 1 }, .big);
    try w.writeInt(u16, 1, .big);
    try w.writeInt(u16, 0, .big);
    try w.writeInt(u16, 0, .big);
    try w.writeInt(u16, 1, .big);

    var pos: usize = 0;
    while (true) {
        const idx = mem.findScalarPos(u8, name, pos, '.') orelse {
            if (pos < name.len) {
                try w.writeByte(@intCast(name.len - pos));
                try w.writeAll(name[pos..]);
            }
            try w.writeByte(0);
            break;
        };
        if (idx - pos > 0) {
            try w.writeByte(@intCast(idx - pos));
            try w.writeAll(name[pos..idx]);
        }
        pos = idx + 1;
    }
    try w.writeInt(u16, 1, .big); // query type 1 - A, 28 - AAAA
    try w.writeInt(u16, 1, .big); // query class 1 - internet

    {
        try w.writeByte(0);
        try w.writeInt(u16, 41, .big); // option type
        try w.writeInt(u16, udp_payload_size, .big);
        try w.writeAll(&[6]u8{ 0, 0, 0, 0, 0, 0 });
    }

    return w.buffered();
}

test "dns query" {
    var buf: [256]u8 = undefined;
    const q = try query(&buf, 0x6af8, "www.google.com");
    try testing.expectEqualSlices(u8, testdata.query, q);
}

fn readName(rec: *Io.Reader, buf: []u8) ![]u8 {
    var w = Io.Writer.fixed(buf);

    var cr: Io.Reader = undefined; // compression reader
    var r = rec;
    while (true) {
        const n: u8 = try r.takeByte();
        if (n == 0) {
            return buf[0..if (w.end > 0) w.end - 1 else 0];
        }
        if (n & 0b1100_000 > 0) {
            const off: u16 = (@as(u16, (n & 0b0011_1111)) << 8) + try r.takeByte();
            cr = Io.Reader.fixed(r.buffer[off..]);
            r = &cr;
            continue;
        }
        try w.writeAll(try r.take(n));
        try w.writeByte('.');
    }
}

const Response = struct {
    const Query = struct {
        name: []u8,
        addr_type: u16,
        class: u16,
    };
    const Answer = struct {
        name: []u8,
        addr_type: u16,
        class: u16,
        ttl: u32,
        addr: []u8,
    };

    r: Io.Reader,
    remaining_answers: u16 = 0,
    name_buf: [256]u8 = undefined,

    fn init(rec: []const u8) Response {
        return .{
            .r = Io.Reader.fixed(rec),
        };
    }

    fn header(self: *Response) !Header {
        const transaction_id = try self.r.takeInt(u16, .big);
        const flags = try self.r.takeStruct(Flags, .big);
        const query_count = try self.r.takeInt(u16, .big);
        const answer_count = try self.r.takeInt(u16, .big);
        const record_count = try self.r.takeInt(u16, .big);
        const additional_count = try self.r.takeInt(u16, .big);
        self.remaining_answers = answer_count;
        return .{
            .transaction_id = transaction_id,
            .flags = flags,
            .query_count = query_count,
            .answer_count = answer_count,
            .record_count = record_count,
            .additional_count = additional_count,
        };
    }

    fn query(self: *Response) !Query {
        const name = try readName(&self.r, &self.name_buf);
        const addr_type = try self.r.takeInt(u16, .big);
        const class = try self.r.takeInt(u16, .big);
        return .{
            .name = name,
            .addr_type = addr_type,
            .class = class,
        };
    }

    fn answer(self: *Response) !?Answer {
        if (self.remaining_answers == 0) return null;
        const name = try readName(&self.r, &self.name_buf);
        const addr_type = try self.r.takeInt(u16, .big);
        const class = try self.r.takeInt(u16, .big);
        const ttl = try self.r.takeInt(u32, .big);
        const len = try self.r.takeInt(u16, .big);
        const addr = try self.r.peek(len);
        self.r.toss(len);
        self.remaining_answers -= 1;
        return .{
            .name = name,
            .addr_type = addr_type,
            .class = class,
            .ttl = ttl,
            .addr = addr,
        };
    }
};

test "dns response" {
    var r = Io.Reader.fixed(testdata.response);
    var name_buf: [256]u8 = undefined;

    const transaction_id = try r.takeInt(u16, .big);
    const flags = try r.takeStruct(Flags, .big);
    const query_count = try r.takeInt(u16, .big);
    const answer_count = try r.takeInt(u16, .big);
    const record_count = try r.takeInt(u16, .big);
    const additional_count = try r.takeInt(u16, .big);

    try testing.expectEqual(0x6af8, transaction_id);
    _ = flags;
    try testing.expectEqual(1, query_count);
    try testing.expectEqual(8, answer_count);
    try testing.expectEqual(0, record_count);
    try testing.expectEqual(1, additional_count);

    const query_name = try readName(&r, &name_buf);
    std.debug.print("query name: {s}\n", .{query_name});
    _ = try r.takeInt(u16, .big);
    _ = try r.takeInt(u16, .big);

    for (0..answer_count) |_| {
        const name = try readName(&r, &name_buf);
        std.debug.print("name: {s}\n", .{name});

        //_ = try r.takeInt(u16, .big); // TODO

        const addr_type = try r.takeInt(u16, .big);
        const addr_class = try r.takeInt(u16, .big);
        const ttl = try r.takeInt(u32, .big);
        const len = try r.takeInt(u16, .big);
        const addr = try r.peek(len);
        r.toss(len);

        try testing.expectEqual(1, addr_type);
        try testing.expectEqual(1, addr_class);
        try testing.expectEqual(4, len);
        try testing.expectEqual(60, ttl);
        std.debug.print("addr: {x}\n", .{addr});
        for (addr) |b| {
            std.debug.print("{d}.", .{b});
        }
        std.debug.print("\n", .{});
    }
}

test "dns response 2" {
    var r = Response.init(testdata.response);

    const h = try r.header();
    try testing.expectEqual(0x6af8, h.transaction_id);
    try testing.expectEqual(1, h.query_count);
    try testing.expectEqual(8, h.answer_count);
    try testing.expectEqual(0, h.record_count);
    try testing.expectEqual(1, h.additional_count);

    const q = try r.query();
    try testing.expectEqualStrings("www.google.com", q.name);
    try testing.expectEqual(1, q.class);
    try testing.expectEqual(1, q.addr_type);

    while (try r.answer()) |a| {
        try testing.expectEqualStrings("www.google.com", a.name);
        try testing.expectEqual(1, a.class);
        try testing.expectEqual(1, a.addr_type);
        try testing.expectEqual(60, a.ttl);
        try testing.expectEqual(4, a.addr.len);

        try testing.expectEqual(142, a.addr[0]);
        try testing.expectEqual(251, a.addr[1]);
        try testing.expect(a.addr[2] >= 150 and a.addr[2] <= 157);
        try testing.expectEqual(119, a.addr[3]);
    }
}

const testdata = struct {
    const query = &hexToBytes(
        \\ 6a f8 01 00 00 01 00 00 00 00 00 01 03 77 77 77
        \\ 06 67 6f 6f 67 6c 65 03 63 6f 6d 00 00 01 00 01
        \\ 00 00 29 05 c0 00 00 00 00 00 00
    );
    const response = &hexToBytes(
        \\ 6a f8 81 80 00 01 00 08 00 00 00 01 03 77 77 77
        \\ 06 67 6f 6f 67 6c 65 03 63 6f 6d 00 00 01 00 01
        \\ c0 0c 00 01 00 01 00 00 00 3c 00 04 8e fb 9a 77
        \\ c0 0c 00 01 00 01 00 00 00 3c 00 04 8e fb 99 77
        \\ c0 0c 00 01 00 01 00 00 00 3c 00 04 8e fb 97 77
        \\ c0 0c 00 01 00 01 00 00 00 3c 00 04 8e fb 9d 77
        \\ c0 0c 00 01 00 01 00 00 00 3c 00 04 8e fb 96 77
        \\ c0 0c 00 01 00 01 00 00 00 3c 00 04 8e fb 98 77
        \\ c0 0c 00 01 00 01 00 00 00 3c 00 04 8e fb 9b 77
        \\ c0 0c 00 01 00 01 00 00 00 3c 00 04 8e fb 9c 77
        \\ 00 00 29 10 00 00 00 00 00 00 00
    );
};

pub fn hexToBytes(comptime hex: []const u8) [removeNonHex(hex).len / 2]u8 {
    @setEvalBranchQuota(1000 * 100);
    const hex2 = comptime removeNonHex(hex);
    comptime var res: [hex2.len / 2]u8 = undefined;
    _ = comptime std.fmt.hexToBytes(&res, hex2) catch unreachable;
    return res;
}

fn removeNonHex(comptime hex: []const u8) []const u8 {
    @setEvalBranchQuota(1000 * 100);
    var res: [hex.len]u8 = undefined;
    var i: usize = 0;
    for (hex) |c| {
        if (std.ascii.isHex(c)) {
            res[i] = c;
            i += 1;
        }
    }
    return res[0..i];
}
