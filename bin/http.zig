const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.main);
const mem = std.mem;
const http = std.http;
const xio = @import("xio");
const testing = std.testing;
const assert = std.debug.assert;

pub fn main(init: std.process.Init) !void {
    // var threaded = Io.Threaded.init(init.gpa, .{
    //     //.async_limit = .limited(2),
    //     //.concurrent_limit = .limited(2),
    // });
    // defer threaded.deinit();
    // const io = threaded.io();

    var evented: xio.Evented = undefined;
    try evented.init(init.gpa, .{});
    defer evented.deinit();
    const io = evented.io();

    const addr: Io.net.IpAddress = .{ .ip4 = .unspecified(8080) };
    // var server = try addr.listen(io, .{ .reuse_address = true });

    const root_dir = try Io.Dir.openDirAbsolute(io, "/home/ianic/Code/httpd/site/ziglang.org/", .{ .iterate = false });
    defer root_dir.close(io);

    var grp: Io.Group = .init;
    grp.async(io, listener, .{ io, init.gpa, &grp, addr, root_dir });
    try grp.await(io);
}

fn listener(io: Io, gpa: mem.Allocator, grp: *Io.Group, addr: Io.net.IpAddress, root_dir: Io.Dir) void {
    listenerFallible(io, gpa, grp, addr, root_dir) catch |err| {
        log.err("listener {}", .{err});
    };
}

fn listenerFallible(io: Io, gpa: mem.Allocator, grp: *Io.Group, addr: Io.net.IpAddress, root_dir: Io.Dir) !void {
    var server = try addr.listen(io, .{ .reuse_address = true });
    while (true) {
        const conn = try server.accept(io);
        errdefer conn.close(io);

        // const linux = std.os.linux;
        // try setSocketOptionPosix(conn.socket.handle, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1);

        try grp.concurrent(io, handler, .{ io, gpa, conn, root_dir });
    }
}

fn handler(io: Io, gpa: mem.Allocator, conn: Io.net.Stream, root_dir: Io.Dir) void {
    defer conn.close(io);
    handlerFallible(io, gpa, conn, root_dir) catch |err| {
        log.err("{}: {}", .{ conn.socket.handle, err });
    };
}

fn handlerFallible(io: Io, gpa: mem.Allocator, conn: Io.net.Stream, root_dir: Io.Dir) !void {
    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var read_buffer: [1024]u8 = undefined;
    var write_buffer: [4098]u8 = undefined;
    var reader = conn.reader(io, &read_buffer);
    var writer = conn.writer(io, &write_buffer);
    var rdr = &reader.interface;
    var wrt = &writer.interface;

    while (true) {
        var req: Request = .{};

        while (true) {
            log.debug("{} read loop {}", .{ conn.socket.handle, rdr.bufferedLen() });
            const n = try req.parse(arena, rdr.buffered()) orelse {
                rdr.fillMore() catch |err| switch (err) {
                    error.EndOfStream => return,
                    else => |e| return e,
                };
                continue;
            };
            rdr.toss(n);
            break;
        }

        var rsp: Response = .{
            .file = if (root_dir.statFile(io, req.path, .{})) |fs|
                Response.File{
                    .dir = root_dir,
                    .path = req.path,
                    .stat = fs,
                    .encoding = .plain,
                }
            else |err| switch (err) {
                error.FileNotFound => null,
                else => |e| return e,
            },
        };
        try rsp.init(arena, req);

        try wrt.writeAll(rsp.header);
        const has_body = !req.onlyHeader() and rsp.hasBody();
        if (has_body) {
            const file = try root_dir.openFile(io, req.path, .{});
            defer file.close(io);
            var frdr = file.reader(io, &.{});
            //const m = try wrt.sendFileReadingAll(&frdr, .limited(rsp.file.?.stat.size));
            const m = try wrt.sendFile(&frdr, .limited(rsp.file.?.stat.size));
            assert(m == rsp.file.?.stat.size);
            // ovo ne radi jer nema dovoljan buffer
            // const m = try wrt.sendFileHeader(rsp.header, &frdr, .limited(rsp.file.?.stat.size));
        }
        try wrt.flush();

        log.debug("{} req path: {s}, method: {}, keep_alive: {}\nrsp: header len: {}, has body: {}, body len: {}", .{
            conn.socket.handle,
            req.path,
            req.method,
            req.keep_alive,
            rsp.header.len,
            has_body,
            if (rsp.file) |f| f.stat.size else 0,
        });

        if (!req.keep_alive) break;
        _ = arena_instance.reset(.retain_capacity);
    }
}

//////////////////////////////////////////
const Request = struct {
    path: [:0]const u8 = &.{},
    etag: struct {
        size: u64 = 0,
        mtime: i96 = 0,
    } = .{},
    keep_alive: bool = false,
    accept_encoding_buf: [4]ContentEncoding = @splat(.plain),
    accept_encoding: []ContentEncoding = &.{},
    size: usize = 0,
    method: http.Method = .GET,

    /// Returns null if recv_buf doesn't hold full http request
    fn parse(req: *Request, arena: mem.Allocator, buf: []const u8) !?usize {
        if (buf.len == 0) return null;

        var hp: http.HeadParser = .{};
        const n = hp.feed(buf);
        if (hp.state != .finished) {
            return null;
        }

        const head = try Head.parse(buf[0..n]);
        if (head.method != .GET and head.method != .HEAD) {
            return error.BadRequest;
        }
        if (head.content_length) |content_length| if (content_length != 0) {
            return error.BadRequest;
        };

        req.* = .{
            .keep_alive = head.keep_alive,
            .method = head.method,
        };
        if (head.etag) |et| { // parse etag
            var it = mem.splitScalar(u8, et, '-');
            req.etag.mtime = std.fmt.parseInt(i96, it.first(), 16) catch 0;
            req.etag.size = std.fmt.parseInt(u64, it.rest(), 16) catch 0;
        }
        req.path = if (head.target.len <= 1)
            try arena.dupeSentinel(u8, "index.html", 0)
        else if (head.target[head.target.len - 1] == '/')
            try mem.joinZ(arena, "", &.{ head.target[1..], "index.html" })
        else
            try arena.dupeSentinel(u8, head.target[1..], 0);

        req.accept_encoding_buf[0] = .plain;
        req.accept_encoding = req.accept_encoding_buf[0..1];
        if (compressible(req.path)) {
            if (head.accept_encoding) |accept_encoding_str| {
                req.accept_encoding = try ContentEncoding.parse(&req.accept_encoding_buf, accept_encoding_str);
            }
        }

        return n;
    }

    fn onlyHeader(req: Request) bool {
        return req.method == .HEAD;
    }
};

const Response = struct {
    const File = struct {
        dir: std.Io.Dir,
        path: [:0]const u8 = &.{},
        stat: Io.File.Stat,
        encoding: ContentEncoding,
    };

    file: ?File = null,
    status: http.Status = @fromBackingInt(@intCast(0)),
    header: []const u8 = &.{},

    fn init(rsp: *Response, arena: mem.Allocator, req: Request) !void {
        if (rsp.file == null) {
            rsp.status = .not_found;
            rsp.header = try notFound(arena, req.keep_alive);
            return;
        }
        const stat = rsp.file.?.stat;
        switch (stat.kind) {
            .file, .sym_link => {
                if (etagMatch(stat, req)) {
                    rsp.status = .not_modified;
                    rsp.header = try notModified(arena, stat, req.keep_alive);
                } else {
                    rsp.status = .ok;
                    rsp.header = try ok(arena, stat, req.path, rsp.file.?.encoding, req.keep_alive);
                }
            },
            .directory => {
                // Target path was without trailing '/' and points to directory; redirect
                rsp.status = .moved_permanently;
                rsp.header = try dirRedirect(arena, req.path, req.keep_alive);
            },
            else => {
                rsp.status = .not_found;
                rsp.header = try notFound(arena, req.keep_alive);
            },
        }
    }

    fn etagMatch(stat: Io.File.Stat, req: Request) bool {
        return stat.size == req.etag.size and stat.mtime.toSeconds() == req.etag.mtime;
    }

    fn hasBody(rsp: Response) bool {
        return rsp.status == .ok and rsp.bodySize() > 0;
    }

    fn bodySize(rsp: Response) usize {
        if (rsp.file) |f| return f.stat.size;
        return 0;
    }

    fn contentEncoding(rsp: Response) ContentEncoding {
        if (rsp.file) |f| return f.encoding;
        return .plain;
    }

    const connection_keep_alive = "Connection: keep-alive";
    const connection_close = "Connection: close";

    fn ok(
        arena: mem.Allocator,
        stat: Io.File.Stat,
        file: [:0]const u8,
        encoding: ContentEncoding,
        keep_alive: bool,
    ) ![]const u8 {
        const last_modified: LastModified = .{ .sec = stat.mtime.toSeconds() };
        const fmt = "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: {s}\r\n{s}" ++
            "Content-Length: {d}\r\n" ++
            "ETag: \"{x}-{x}\"\r\n" ++
            "Last-Modified: {f}\r\n" ++
            "{s}\r\n\r\n";
        return try std.fmt.allocPrint(arena, fmt, .{
            contentType(file),
            encoding.header(),
            stat.size,
            stat.mtime.toSeconds(),
            stat.size,
            last_modified,
            if (keep_alive) connection_keep_alive else connection_close,
        });
    }

    fn notModified(arena: mem.Allocator, stat: Io.File.Stat, keep_alive: bool) ![]const u8 {
        const last_modified: LastModified = .{ .sec = stat.mtime.toSeconds() };
        const fmt = "HTTP/1.1 304 Not Modified\r\n" ++
            "ETag: \"{x}-{x}\"\r\n" ++
            "Last-Modified: {f}\r\n" ++
            "{s}\r\n\r\n";
        return try std.fmt.allocPrint(arena, fmt, .{
            stat.mtime.toSeconds(),
            stat.size,
            last_modified,
            if (keep_alive) connection_keep_alive else connection_close,
        });
    }

    fn notFound(arena: mem.Allocator, keep_alive: bool) ![]const u8 {
        const fmt = "HTTP/1.1 404 Not Found\r\n" ++
            "Content-Length: 0\r\n" ++
            "{s}\r\n\r\n";
        return try std.fmt.allocPrint(arena, fmt, .{
            if (keep_alive) connection_keep_alive else connection_close,
        });
    }

    fn dirRedirect(arena: mem.Allocator, path: []const u8, keep_alive: bool) ![]const u8 {
        const fmt = "HTTP/1.1 301 Moved Permanently\r\n" ++
            "Content-Length: 0\r\n" ++
            "Location: \\{s}\\ \r\n" ++
            "{s}\r\n\r\n";
        return try std.fmt.allocPrint(arena, fmt, .{
            path,
            if (keep_alive) connection_keep_alive else connection_close,
        });
    }

    fn contentType(file_name: []const u8) []const u8 {
        const mime_types = [_][2][]const u8{
            .{ ".html", "text/html" },
            .{ ".htm", "text/html" },
            .{ ".css", "text/css" },
            .{ ".js", "application/javascript" },
            .{ ".json", "application/json" },
            .{ ".png", "image/png" },
            .{ ".jpg", "image/jpeg" },
            .{ ".jpeg", "image/jpeg" },
            .{ ".gif", "image/gif" },
            .{ ".svg", "image/svg+xml" },
            .{ ".txt", "text/plain" },
            .{ ".xml", "text/xml" },
            .{ ".csv", "text/csv" },
            .{ ".gz", "application/gzip" },
            .{ ".ico", "image/vnd.microsoft.icon" },
            .{ ".otf", "font/otf" },
            .{ ".pdf", "application/pdf" },
            .{ ".tar", "application/x-tar" },
            .{ ".ttf", "font/ttf" },
            .{ ".wasm", "application/wasm" },
            .{ ".webp", "image/webp" },
            .{ ".woff", "font/woff" },
            .{ ".woff2", "font/woff2" },
            .{ ".md", "text/markdown" },
            .{ ".rss", "application/rss+xml" },
            .{ ".atom", "application/rss+xml" },
        };
        for (mime_types) |pair| {
            if (mem.endsWith(u8, file_name, pair[0])) return pair[1];
        }
        return "application/octet-stream"; // Default MIME type
    }

    test "header_buf size is big enough" {
        var arena_instance = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();

        var req: Request = .{
            .path = "index.html",
            .keep_alive = true,
        };
        var rsp: Response = .{};
        { // not found
            try rsp.init(arena, req);
            try testing.expectEqual(.not_found, rsp.status);
            try testing.expectEqual(69, rsp.header.len);
            // std.debug.print("{s}\n", .{rsp.header});
        }
        const stx = mem.zeroInit(Io.File.Stat, .{
            .kind = .file,
            .size = 1024 * 1024 * 1024,
            .mtime = .{ .nanoseconds = 1777896219 * std.time.ns_per_s },
        });

        { // ok
            rsp.file = .{
                .dir = undefined,
                .encoding = .plain,
                .stat = stx,
            };
            try rsp.init(arena, req);
            try testing.expectEqual(.ok, rsp.status);
            // std.debug.print("{s}\n", .{rsp.header});
            try testing.expectEqual(169, rsp.header.len);
        }
        { // not modified
            req.etag.mtime = stx.mtime.toSeconds();
            req.etag.size = stx.size;
            try rsp.init(arena, req);
            try testing.expectEqual(.not_modified, rsp.status);
            try testing.expectEqual(126, rsp.header.len);
            // std.debug.print("{s}\n", .{rsp.header});
        }
    }
};

const ContentEncoding = enum {
    plain,
    gzip,
    brotli,
    zstd,

    fn extension(self: ContentEncoding) []const u8 {
        return switch (self) {
            .plain => "",
            .gzip => ".gz",
            .brotli => ".br",
            .zstd => ".zst",
        };
    }

    /// Parse Accept-Encoding http header into list of ContentEncoding values.
    /// Plain is always included at index 0.
    /// Returns null if no supported encodings are found in accept_encoding string.
    fn parse(list: []ContentEncoding, accept_encoding_str: []const u8) ![]ContentEncoding {
        list[0] = .plain;
        var i: usize = 1;
        var iter = mem.splitAny(u8, accept_encoding_str, ", ");
        while (iter.next()) |v| {
            if (v.len == 0) continue;
            const v1 = if (mem.indexOfScalar(u8, v, ';')) |j| v[0..j] else v;
            if (mem.eql(u8, v1, "gzip")) {
                list[i] = .gzip;
                i += 1;
            } else if (mem.eql(u8, v1, "br")) {
                list[i] = .brotli;
                i += 1;
            } else if (mem.eql(u8, v1, "zstd")) {
                list[i] = .zstd;
                i += 1;
            }
        }
        return list[0..i];
    }

    pub fn header(self: ContentEncoding) []const u8 {
        return switch (self) {
            .plain => "",
            .gzip => "Content-Encoding: gzip\r\n",
            .brotli => "Content-Encoding: br\r\n",
            .zstd => "Content-Encoding: zstd\r\n",
        };
    }

    test parse {
        var buf: [4]ContentEncoding = undefined;

        var ar = try parse(&buf, "gzip, deflate, zstd");
        try testing.expectEqual(3, ar.len);
        try testing.expectEqual(.plain, ar[0]);
        try testing.expectEqual(.gzip, ar[1]);
        try testing.expectEqual(.zstd, ar[2]);

        ar = try parse(&buf, "br;q=1.0, gzip;q=0.8, *;q=0.1");
        try testing.expectEqual(3, ar.len);
        try testing.expectEqual(.plain, ar[0]);
        try testing.expectEqual(.brotli, ar[1]);
        try testing.expectEqual(.gzip, ar[2]);

        ar = try parse(&buf, "one two");
        try testing.expectEqual(1, ar.len);
    }
};

pub fn compressible(file_name: []const u8) bool {
    const extensions = [_][]const u8{
        ".html",
        ".htm",
        ".css",
        ".js",
        ".json",
        ".svg",
        ".txt",
        ".xml",
        ".csv",
        ".md",
        ".rss",
        ".atom",
    };
    for (extensions) |ex| {
        if (mem.endsWith(u8, file_name, ex)) return true;
    }
    return false;
}

const LastModified = struct {
    sec: i64,

    pub fn format(self: LastModified, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(self.sec) };
        const day_secs = epoch_secs.getDaySeconds();
        const epoch_day = epoch_secs.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const weekday = (epoch_day.day + 4) % 7;

        const day_names = [_][]const u8{
            "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat",
        };
        const month_names = [_][]const u8{
            "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        };

        try writer.print(
            "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT",
            .{
                day_names[weekday],
                month_day.day_index + 1, // 0-indexed → 1-indexed
                month_names[@backingInt(month_day.month) - 1],
                year_day.year,
                day_secs.getHoursIntoDay(),
                day_secs.getMinutesIntoHour(),
                day_secs.getSecondsIntoMinute(),
            },
        );
    }

    test LastModified {
        var buf: [30]u8 = undefined;
        const sec = 1777557784;

        const lm: LastModified = .{ .sec = sec };
        const res = try std.fmt.bufPrint(&buf, "{f}", .{lm});
        try std.testing.expectEqualStrings("Thu, 30 Apr 2026 14:03:04 GMT", res);
    }
};

const Head = @import("Head.zig");

test {
    _ = Request;
    _ = Response;
    _ = LastModified;
    _ = Head;
}

const posix = std.posix;
const errnoBug = std.Io.Threaded.errnoBug;

fn setSocketOptionPosix(fd: posix.fd_t, level: i32, opt_name: u32, option: u32) !void {
    const o: []const u8 = @ptrCast(&option);
    while (true) {
        switch (posix.errno(posix.system.setsockopt(fd, level, opt_name, o.ptr, @intCast(o.len)))) {
            .SUCCESS => {
                return;
            },
            .INTR => {
                continue;
            },
            else => |e| {
                switch (e) {
                    .BADF => |err| return errnoBug(err), // File descriptor used after closed.
                    .NOTSOCK => |err| return errnoBug(err),
                    .INVAL => |err| return errnoBug(err),
                    .FAULT => |err| return errnoBug(err),
                    else => |err| return posix.unexpectedErrno(err),
                }
            },
        }
    }
}
