const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var uring: Io.Uring = undefined;
    try uring.init(gpa, .{});
    defer uring.deinit();
    const io = uring.io();

    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", 4242);
    const socket = try addr.bind(io, .{ .mode = .dgram, .protocol = .udp });

    var prevAddr: ?Io.net.IpAddress = null;
    var total: usize = 0;
    while (true) {
        var buf: [8 * 1024]u8 = undefined;
        const msg = try socket.receive(io, &buf);
        if (prevAddr == null or !msg.from.eql(&prevAddr.?)) {
            total = 0;
        }
        total += msg.data.len;
        log.debug("recived data len {} {}", .{ msg.data.len, total });
        try socket.send(io, &msg.from, msg.data);
        prevAddr = msg.from;
    }
}
//
// in 1024 chunks
// cat ~/Code/zig/lib/std/Io/Threaded.zig | nc -uv 127.0.0.1 4242
//
// in 8192 chunks, some packes are dropped
// cat ~/Code/zig/lib/std/Io/Threaded.zig | ncat -uv 127.0.0.1 4242 -q 1
