const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.main);
const mem = std.mem;
const xio = @import("xio");

pub fn main(init: std.process.Init) !void {
    var evented: xio.Evented = undefined;
    try evented.init(init.gpa, .{});
    defer evented.deinit();
    const io = evented.io();

    var bind_addr = try std.Io.net.IpAddress.parse("0.0.0.0", 0);
    const socket = try bind_addr.bind(io, .{ .mode = .dgram, .protocol = .udp });

    const dns_addr = try std.Io.net.IpAddress.parse("192.168.190.1", 53);
    var buf: [xio.dns.udp_payload_size]u8 = undefined;

    const transaction_id: u16 = 1;
    const domain = "gmail.google.com";

    const query = try xio.dns.query(&buf, transaction_id, domain);
    try socket.send(io, &dns_addr, query);

    const msg = try socket.receive(io, &buf);
    var rsp = xio.dns.Response.init(msg.data);

    const h = try rsp.header();
    std.debug.print("header: {}\n", .{h});
    if (h.err()) |err| return err;
    if (h.answer_count == 0) return error.NoData;
    if (h.query_count != 1) return error.MissingQuery;

    const q = try rsp.query();
    if (!mem.eql(u8, q.domain, domain)) return error.InvalidQueryDomain;
    //std.debug.print("query: {}\n", .{q});

    while (try rsp.answer()) |a| {
        switch (a.query_type) {
            .a => {
                //if (!mem.eql(u8, q.domain, domain)) return error.InvalidAnswerDomain;
                std.debug.print("A: {s} {any}\n", .{ a.domain, a.addr });
            },
            .cname => {
                std.debug.print("CNAME: {s} {s}\n", .{ a.domain, a.addr });
            },
            else => {
                std.debug.print("answer: {}\n", .{a});
            },
        }
    }
}
