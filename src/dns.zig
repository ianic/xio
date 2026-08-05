const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;

pub const udp_payload_size = 1472;

pub const Header = packed struct {
    transaction_id: u16 = 0,
    flags: Flags = .{},
    query_count: u16,
    answer_count: u16 = 0,
    record_count: u16 = 0,
    additional_count: u16 = 0,

    pub const DnsError = error{ ServerFailed, NonexistentDomain, Refused, NameServerFailure };

    pub fn err(self: Header) ?DnsError {
        return switch (self.flags.rcode) {
            0 => null,
            2 => error.ServerFailed,
            3 => error.NonexistentDomain,
            4 => error.Refused,
            else => error.NameServerFailure,
        };
    }
};

pub const Flags = packed struct {
    rcode: u4 = 0,
    cd: u1 = 0,
    ad: u1 = 0,
    z: u1 = 0,
    ra: u1 = 0,

    rd: u1 = 0,
    tc: u1 = 0,
    aa: u1 = 0,
    opcode: u4 = 0,
    qr: u1 = 0, // query = 1, response = 2
};

pub fn query(buf: []u8, transaction_id: u16, domain: []const u8) ![]u8 {
    var w = Io.Writer.fixed(buf);
    { // header
        try w.writeInt(u16, transaction_id, .big);
        try w.writeStruct(Flags{ .rd = 1 }, .big);
        try w.writeInt(u16, 1, .big);
        try w.writeInt(u16, 0, .big);
        try w.writeInt(u16, 0, .big);
        try w.writeInt(u16, 1, .big);
    }
    { // query section
        var pos: usize = 0;
        while (true) {
            const idx = mem.findScalarPos(u8, domain, pos, '.') orelse {
                if (pos < domain.len) {
                    try w.writeByte(@intCast(domain.len - pos));
                    try w.writeAll(domain[pos..]);
                }
                try w.writeByte(0);
                break;
            };
            if (idx - pos > 0) {
                try w.writeByte(@intCast(idx - pos));
                try w.writeAll(domain[pos..idx]);
            }
            pos = idx + 1;
        }
        try w.writeInt(u16, 1, .big); // query type 1 - A, 28 - AAAA
        try w.writeInt(u16, 1, .big); // query class 1 - internet
    }
    { // options
        try w.writeByte(0);
        try w.writeInt(u16, 41, .big); // option type
        try w.writeInt(u16, udp_payload_size, .big);
        try w.writeAll(&[6]u8{ 0, 0, 0, 0, 0, 0 });
    }
    return w.buffered();
}

pub const QueryType = enum(u16) {
    a = 1,
    cname = 5,
    aaaa = 28,
    _,
};

pub const Response = struct {
    const Query = struct {
        domain: []u8,
        query_type: QueryType,
        class: u16,
    };
    const Answer = struct {
        domain: []u8,
        query_type: QueryType,
        class: u16,
        ttl: u32,
        addr: []u8,
    };

    r: Io.Reader,
    remaining_answers: u16 = 0,
    domain_buf: [2][256]u8 = undefined,

    pub fn init(rec: []const u8) Response {
        return .{
            .r = Io.Reader.fixed(rec),
        };
    }

    fn domainName(self: *Response, buf: []u8) ![]u8 {
        var w = Io.Writer.fixed(buf);

        var cr: Io.Reader = undefined; // compression reader
        var r = &self.r;
        while (true) {
            const n: u8 = try r.takeByte();
            if (n == 0) {
                return buf[0..if (w.end > 0) w.end - 1 else 0];
            }
            if (n & 0b1100_000 > 0) {
                const off: u16 = (@as(u16, (n & 0b0011_1111)) << 8) + try r.takeByte();
                if (off >= self.r.buffer.len) return error.InvalidCompressionLabel;
                cr = Io.Reader.fixed(self.r.buffer[off..]);
                r = &cr;
                continue;
            }
            try w.writeAll(try r.take(n));
            try w.writeByte('.');
        }
    }

    pub fn header(self: *Response) !Header {
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

    pub fn query(self: *Response) !Query {
        const domain = try self.domainName(&self.domain_buf[0]);
        const query_type: QueryType = @fromBackingInt(@intCast(try self.r.takeInt(u16, .big)));
        const class = try self.r.takeInt(u16, .big);
        return .{
            .domain = domain,
            .query_type = query_type,
            .class = class,
        };
    }

    pub fn answer(self: *Response) !?Answer {
        if (self.remaining_answers == 0) return null;
        const domain = try self.domainName(&self.domain_buf[0]);
        const query_type: QueryType = @fromBackingInt(@intCast(try self.r.takeInt(u16, .big)));
        const class = try self.r.takeInt(u16, .big);
        const ttl = try self.r.takeInt(u32, .big);
        const len = try self.r.takeInt(u16, .big);
        const addr = if (query_type == .cname)
            try self.domainName(&self.domain_buf[1])
        else
            try self.r.take(len);
        self.remaining_answers -= 1;
        return .{
            .domain = domain,
            .query_type = query_type,
            .class = class,
            .ttl = ttl,
            .addr = addr,
        };
    }
};

test "dns response " {
    var r = Response.init(testdata.answer);

    const h = try r.header();
    try testing.expectEqual(0x6af8, h.transaction_id);
    try testing.expectEqual(1, h.query_count);
    try testing.expectEqual(8, h.answer_count);
    try testing.expectEqual(0, h.record_count);
    try testing.expectEqual(1, h.additional_count);
    try testing.expectEqual(Flags{ .qr = 1, .ra = 1, .rd = 1 }, h.flags);
    try testing.expectEqual(null, h.err());

    const q = try r.query();
    try testing.expectEqualStrings("www.google.com", q.domain);
    try testing.expectEqual(1, q.class);
    try testing.expectEqual(.a, q.query_type);

    while (try r.answer()) |a| {
        try testing.expectEqualStrings("www.google.com", a.domain);
        try testing.expectEqual(1, a.class);
        try testing.expectEqual(.a, a.query_type);
        try testing.expectEqual(60, a.ttl);
        try testing.expectEqual(4, a.addr.len);

        try testing.expectEqual(142, a.addr[0]);
        try testing.expectEqual(251, a.addr[1]);
        try testing.expect(a.addr[2] >= 150 and a.addr[2] <= 157);
        try testing.expectEqual(119, a.addr[3]);
    }
}

test "cname answer" {
    var r = Response.init(testdata.answer_with_cname);

    const h = try r.header();
    try testing.expectEqual(1, h.transaction_id);
    try testing.expectEqual(1, h.query_count);
    try testing.expectEqual(2, h.answer_count);
    try testing.expectEqual(0, h.record_count);
    try testing.expectEqual(1, h.additional_count);
    try testing.expectEqual(Flags{ .qr = 1, .ra = 1, .rd = 1 }, h.flags);
    try testing.expectEqual(null, h.err());

    const q = try r.query();
    try testing.expectEqualStrings("gmail.google.com", q.domain);
    try testing.expectEqual(1, q.class);
    try testing.expectEqual(.a, q.query_type);

    var a = (try r.answer()).?;
    try testing.expectEqual(.cname, a.query_type);
    try testing.expectEqualStrings("gmail.google.com", a.domain);
    try testing.expectEqualStrings("www3.l.google.com", a.addr);

    a = (try r.answer()).?;
    try testing.expectEqual(.a, a.query_type);
    try testing.expectEqualStrings("www3.l.google.com", a.domain);
    try testing.expectEqualSlices(u8, &.{ 192, 178, 25, 174 }, a.addr);
    try testing.expectEqual(60, a.ttl);
}

test "cname answer2" {
    var r = Response.init(testdata.answer_with_two_label_compressions);

    const h = try r.header();
    try testing.expectEqual(1, h.transaction_id);
    try testing.expectEqual(1, h.query_count);
    try testing.expectEqual(2, h.answer_count);
    try testing.expectEqual(0, h.record_count);
    try testing.expectEqual(1, h.additional_count);
    try testing.expectEqual(Flags{ .qr = 1, .ra = 1, .rd = 1 }, h.flags);
    try testing.expectEqual(null, h.err());

    const q = try r.query();
    try testing.expectEqualStrings("gmail.google.com", q.domain);
    try testing.expectEqual(1, q.class);
    try testing.expectEqual(.a, q.query_type);

    var a = (try r.answer()).?;
    try testing.expectEqual(.cname, a.query_type);
    try testing.expectEqualStrings("gmail.google.com", a.domain);
    try testing.expectEqualStrings("www3.l.google.com", a.addr);

    a = (try r.answer()).?;
    try testing.expectEqual(.a, a.query_type);
    try testing.expectEqualStrings("www3.l.google.com", a.domain);
    try testing.expectEqualSlices(u8, &.{ 216, 58, 205, 142 }, a.addr);
    try testing.expectEqual(60, a.ttl);
}

test "dns query" {
    var buf: [256]u8 = undefined;
    const q = try query(&buf, 0x6af8, "www.google.com");
    try testing.expectEqualSlices(u8, testdata.query, q);
}

const testdata = struct {
    const query = &hexToBytes(
        \\ 6a f8 01 00 00 01 00 00 00 00 00 01 03 77 77 77
        \\ 06 67 6f 6f 67 6c 65 03 63 6f 6d 00 00 01 00 01
        \\ 00 00 29 05 c0 00 00 00 00 00 00
    );
    const answer = &hexToBytes(
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
    const answer_with_cname = &hexToBytes(
        \\  00 01 81 80 00 01 00 02 00 00 00 01 05 67 6d 61
        \\  69 6c 06 67 6f 6f 67 6c 65 03 63 6f 6d 00 00 01
        \\  00 01 c0 0c 00 05 00 01 00 00 00 3c 00 13 04 77
        \\  77 77 33 01 6c 06 67 6f 6f 67 6c 65 03 63 6f 6d
        \\  00 c0 2e 00 01 00 01 00 00 00 3c 00 04 c0 b2 19
        \\  ae 00 00 29 10 00 00 00 00 00 00 00
    );

    const answer_with_two_label_compressions = &hexToBytes(
        \\ 00 01 81 80 00 01 00 02 00 00 00 01 05 67 6d 61
        \\ 69 6c 06 67 6f 6f 67 6c 65 03 63 6f 6d 00 00 01
        \\ 00 01 c0 0c 00 05 00 01 00 00 00 3c 00 09 04 77
        \\ 77 77 33 01 6c c0 12 c0 2e 00 01 00 01 00 00 00
        \\ 3c 00 04 d8 3a cd 8e 00 00 29 04 d0 00 00 00 00
        \\ 00 00
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
