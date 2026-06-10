const std = @import("std");
const Allocator = std.mem.Allocator;
const Allocating = std.Io.Writer.Allocating;

const Callback = fn (ip: IP, subnet: u8) void;

pub const IPv4 = struct {
    ip: IP,
    subnet: u8 = 32,

    pub fn new(str: []const u8) !IPv4 {
        var result: u32 = 0;
        var iterator = std.mem.splitScalar(u8, str, '.');
        var i: u8 = 0;

        while (iterator.next()) |part| : (i += 1) {
            if (i >= 4) return error.TooManyOctets;
            const octet = try std.fmt.parseInt(u8, part, 10);
            result = (result << 8) | octet;
        }

        if (i != 4) return error.TooFewOctets;
        return IPv4{ .ip = IP{ .v4 = result } };
    }

    pub fn withSubnet(str: []const u8) !IPv4 {
        const slash = std.mem.indexOfScalar(u8, str, '/') orelse return error.MissingSubnet;
        var result = try new(str[0..slash]);
        result.subnet = try std.fmt.parseInt(u8, str[slash + 1 ..], 10);
        if (result.subnet > 32) return error.InvalidSubnet;
        return result;
    }
};

pub const IPv6 = struct {
    ip: IP,
    subnet: u8 = 128,

    pub fn new(str: []const u8) !IPv6 {
        return .{ .ip = .{ .v6 = try parseAddr(str) } };
    }

    pub fn withSubnet(str: []const u8) !IPv6 {
        const slash = std.mem.indexOfScalar(u8, str, '/') orelse return error.MissingSubnet;
        var result = try new(str[0..slash]);
        result.subnet = try std.fmt.parseInt(u8, str[slash + 1 ..], 10);
        if (result.subnet > 128) return error.InvalidSubnet;
        return result;
    }

    fn parseAddr(str: []const u8) !u128 {
        const double = std.mem.indexOf(u8, str, "::");

        if (double) |dc| {
            return parseCompressed(str[0..dc], str[dc + 2 ..]);
        } else {
            return parseFull(str);
        }
    }

    fn parseFull(str: []const u8) !u128 {
        var result: u128 = 0;
        var it = std.mem.splitScalar(u8, str, ':');
        var i: u8 = 0;

        while (it.next()) |part| : (i += 1) {
            if (i >= 8) return error.TooManyGroups;
            const group = try std.fmt.parseInt(u16, part, 16);
            result = (result << 16) | group;
        }

        if (i != 8) return error.TooFewGroups;
        return result;
    }

    fn parseCompressed(left: []const u8, right: []const u8) !u128 {
        var groups: [8]u16 = std.mem.zeroes([8]u16);
        var count: u8 = 0;

        if (left.len > 0) {
            var it = std.mem.splitScalar(u8, left, ':');
            while (it.next()) |part| : (count += 1) {
                if (count >= 8) return error.TooManyGroups;
                groups[count] = try std.fmt.parseInt(u16, part, 16);
            }
        }

        const left_count = count;

        var right_groups: [8]u16 = std.mem.zeroes([8]u16);
        var right_count: u8 = 0;
        if (right.len > 0) {
            var it = std.mem.splitScalar(u8, right, ':');
            while (it.next()) |part| : (right_count += 1) {
                if (right_count >= 8) return error.TooManyGroups;
                right_groups[right_count] = try std.fmt.parseInt(u16, part, 16);
            }
        }

        if (left_count + right_count >= 8) return error.TooManyGroups;

        const gap_start = 8 - right_count;
        for (0..right_count) |i| {
            groups[gap_start + i] = right_groups[i];
        }

        var result: u128 = 0;
        for (groups) |g| {
            result = (result << 16) | g;
        }
        return result;
    }
};

pub const IP = union(enum) {
    v4: u32,
    v6: u128,

    pub fn bits(self: IP) u8 {
        return switch (self) {
            .v4 => 32,
            .v6 => 128,
        };
    }

    pub fn bit(self: IP, n: u8) u1 {
        return switch (self) {
            .v4 => |v| @truncate((v >> @intCast(31 - n)) & 1),
            .v6 => |v| @truncate((v >> @intCast(127 - n)) & 1),
        };
    }

    pub fn mask(self: IP, subnet: u8) IP {
        return switch (self) {
            .v4 => |v| blk: {
                if (subnet == 0) break :blk .{ .v4 = 0 };
                const shift: u5 = @intCast(32 - subnet);
                break :blk .{ .v4 = (v >> shift) << shift };
            },
            .v6 => |v| blk: {
                if (subnet == 0) break :blk .{ .v6 = 0 };
                const shift: u7 = @intCast(128 - subnet);
                break :blk .{ .v6 = (v >> shift) << shift };
            },
        };
    }

    pub fn format(self: IP, writer: anytype) !void {
        return switch (self) {
            .v4 => |v| try writer.print("{}.{}.{}.{}", .{
                (v >> 24) & 0xff,
                (v >> 16) & 0xff,
                (v >> 8) & 0xff,
                v & 0xff,
            }),
            .v6 => |v| {
                var i: u8 = 0;
                while (i < 8) : (i += 1) {
                    if (i != 0) try writer.writeByte(':');
                    const shift: u7 = @intCast((7 - i) * 16);
                    try writer.print("{x:0>4}", .{(v >> shift) & 0xffff});
                }
            },
        };
    }

    pub fn formatAlloc(self: IP, alloc: Allocator) ![]u8 {
        return switch (self) {
            .v4 => |v| try std.fmt.allocPrint(alloc, "{}.{}.{}.{}", .{
                (v >> 24) & 0xff,
                (v >> 16) & 0xff,
                (v >> 8) & 0xff,
                v & 0xff,
            }),
            .v6 => |v| {
                var list = try Allocating.initCapacity(alloc, 39);
                errdefer list.deinit();

                var i: u8 = 0;
                while (i < 8) : (i += 1) {
                    if (i != 0)
                        try list.append(':');

                    const shift: u7 = @intCast((7 - i) * 16);
                    try list.writer.print("{x:0>4}", .{(v >> shift) & 0xffff});
                }

                return list.toOwnedSlice();
            },
        };
    }
};

const Node = struct {
    children: [2]?*Node = .{ null, null },
    terminal: bool = false,
};

pub const Trie = struct {
    v4: ?*Node,
    v6: ?*Node,
    allocator: Allocator,

    pub fn init(alloc: Allocator) Trie {
        return .{
            .v4 = null,
            .v6 = null,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *Trie) void {
        if (self.v4) |r| freeNode(self.allocator, r);
        if (self.v6) |r| freeNode(self.allocator, r);
        self.v4 = null;
        self.v6 = null;
    }

    fn freeNode(alloc: std.mem.Allocator, node: *Node) void {
        for (node.children) |child| {
            if (child) |c| freeNode(alloc, c);
        }

        alloc.destroy(node);
    }

    fn rootPtr(self: *Trie, ip: IP) *?*Node {
        return switch (ip) {
            .v4 => &self.v4,
            .v6 => &self.v6,
        };
    }

    pub fn insert(self: *Trie, ip: IP, subnet: u8) !bool {
        const addr = ip.mask(subnet);
        const ptr = self.rootPtr(ip);

        if (ptr.* == null) {
            ptr.* = try self.allocator.create(Node);
            ptr.*.?.* = .{};
        }

        var node = ptr.*.?;

        var i: u8 = 0;
        while (i < subnet) : (i += 1) {
            if (node.terminal) return false;

            const b = addr.bit(i);

            if (node.children[b] == null) {
                node.children[b] = try self.allocator.create(Node);
                node.children[b].?.* = .{};
            }

            node = node.children[b].?;
        }

        if (node.terminal) return false;

        node.terminal = true;
        for (node.children) |child| {
            if (child) |c| freeNode(self.allocator, c);
        }
        node.children = .{ null, null };

        return true;
    }

    pub fn contains(self: *const Trie, ip: IP) bool {
        const root = switch (ip) {
            .v4 => self.v4,
            .v6 => self.v6,
        } orelse return false;

        const bits = ip.bits();
        var node = root;

        var i: u8 = 0;
        while (i < bits) : (i += 1) {
            if (node.terminal) return true;
            const b = ip.bit(i);
            node = node.children[b] orelse return false;
        }

        return node.terminal;
    }

    pub fn scan(self: *const Trie, ip: IP) ?struct { ip: IP, subnet: u8 } {
        const root = switch (ip) {
            .v4 => self.v4,
            .v6 => self.v6,
        } orelse return null;

        var node = root;

        var i: u8 = 0;
        while (i < ip.bits()) : (i += 1) {
            if (node.terminal) return .{ .ip = ip.mask(i), .subnet = i };
            node = node.children[ip.bit(i)] orelse return null;
        }

        if (node.terminal) return .{ .ip = ip.mask(ip.bits()), .subnet = ip.bits() };
        return null;
    }

    pub fn iterate(self: *const Trie, comptime callback: Callback) void {
        if (self.v4) |r| walkNode(r, IP{ .v4 = 0 }, 0, callback);
        if (self.v6) |r| walkNode(r, IP{ .v6 = 0 }, 0, callback);
    }

    pub fn walkNode(node: *Node, current: IP, depth: u8, comptime callback: Callback) void {
        if (node.terminal) {
            callback(current, depth);
            return;
        }

        inline for (0..2) |b| {
            if (node.children[b]) |child| {
                const next = setBit(current, depth, @intCast(b));
                walkNode(child, next, depth + 1, callback);
            }
        }
    }

    fn setBit(ip: IP, pos: u8, bit: u1) IP {
        return switch (ip) {
            .v4 => |v| blk: {
                const shift: u5 = @intCast(31 - pos);
                const cleared = v & ~(@as(u32, 1) << shift);
                break :blk .{ .v4 = cleared | (@as(u32, bit) << shift) };
            },
            .v6 => |v| blk: {
                const shift: u7 = @intCast(127 - pos);
                const cleared = v & ~(@as(u128, 1) << shift);
                break :blk .{ .v6 = cleared | (@as(u128, bit) << shift) };
            },
        };
    }
};

test "IPv4: parse string" {
    const t = try IPv4.new("192.168.0.0");
    try std.testing.expectEqual(0xC0A80000, t.ip.v4);
}

test "IPv4: broader subnet subsumes more-specific" {
    var trie = Trie.init(std.testing.allocator);
    defer trie.deinit();

    // Insert 192.168.0.0/16 first, then /24 should be rejected.
    const broad = try IPv4.new("192.168.0.0");
    const narrow = try IPv4.new("192.168.1.0");

    try std.testing.expect(try trie.insert(broad.ip, 16));
    try std.testing.expect(!try trie.insert(narrow.ip, 24)); // already covered
}

test "IPv4: insert narrow first, then broad prunes it" {
    var trie = Trie.init(std.testing.allocator);
    defer trie.deinit();

    const broad = try IPv4.new("192.168.0.0");
    const narrow = try IPv4.new("192.168.1.0");

    try std.testing.expect(try trie.insert(narrow.ip, 24));
    try std.testing.expect(try trie.insert(broad.ip, 16)); // inserts and prunes /24

    // /24 is gone; /16 covers it
    try std.testing.expect(trie.contains(IP{ .v4 = 0xC0A80105 }));
}

test "IPv4: contains" {
    var trie = Trie.init(std.testing.allocator);
    defer trie.deinit();

    const t = try IPv4.withSubnet("10.0.0.0/8");

    _ = try trie.insert(t.ip, t.subnet); // 10.0.0.0/8

    try std.testing.expect(trie.contains((try IPv4.new("10.1.2.3")).ip)); // should work
    try std.testing.expect(!trie.contains((try IPv4.new("11.0.0.1")).ip)); // should't work
}

test "IPv4: scan" {
    var trie = Trie.init(std.testing.allocator);
    defer trie.deinit();

    const t = try IPv4.withSubnet("10.0.0.0/8");

    _ = try trie.insert(t.ip, t.subnet); // 10.0.0.0/8

    const scan = trie.scan((try IPv4.new("10.1.2.3")).ip);
    if (scan) |match| {
        try std.testing.expectEqual(t.ip, match.ip);
    }

    try std.testing.expect(trie.scan((try IPv4.new("1.0.0.0")).ip) == null);
}

test "iterate prints all stored CIDRs" {
    var trie = Trie.init(std.testing.allocator);
    defer trie.deinit();

    const t1 = try IPv4.withSubnet("10.0.0.0/8");
    const t2 = try IPv4.withSubnet("192.168.0.0/16");

    _ = try trie.insert(t1.ip, t1.subnet); // 10.0.0.0/8
    _ = try trie.insert(t2.ip, t2.subnet); // 192.168.0.0/16

    const S = struct {
        fn cb(ip: IP, subnet: u8) void {
            var buf: [32]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buf);

            ip.format(&writer) catch {};
            std.debug.print("{s}/{}\n", .{ buf[0..writer.end], subnet });
        }
    };
    trie.iterate(S.cb);
}

test "IPv6: parse string" {
    const t = try IPv6.new("2001:db8::");
    try std.testing.expectEqual(t.ip.v6, 0x20010db8_00000000_00000000_00000000);
}

test "IPv6: basic insert and contains" {
    var trie = Trie.init(std.testing.allocator);
    defer trie.deinit();

    // 2001:db8::/32
    const t = try IPv6.withSubnet("2001:db8::/32");
    _ = try trie.insert(t.ip, t.subnet);

    const inside = try IPv6.new("2001:db8:1::1");
    const outside = try IPv6.new("2001:db9::1");

    try std.testing.expect(trie.contains(inside.ip));
    try std.testing.expect(!trie.contains(outside.ip));
}

test "IPv6: broader subsumes narrower" {
    var trie = Trie.init(std.testing.allocator);
    defer trie.deinit();

    const base = try IPv6.new("2001:db8::");
    try std.testing.expect(try trie.insert(base.ip, 32));
    try std.testing.expect(!try trie.insert(base.ip, 48)); // covered
}
