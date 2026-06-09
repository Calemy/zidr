const std = @import("std");
const Allocator = std.mem.Allocator;
const Allocating = std.Io.Writer.Allocating;

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

    pub fn mask(self: IP, prefix_len: u8) IP {
        return switch (self) {
            .v4 => |v| blk: {
                if (prefix_len == 0) break :blk .{ .v4 = 0 };
                const shift: u5 = @intCast(32 - prefix_len);
                break :blk .{ .v4 = (v >> shift) << shift };
            },
            .v6 => |v| blk: {
                if (prefix_len == 0) break :blk .{ .v6 = 0 };
                const shift: u7 = @intCast(128 - prefix_len);
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

    pub fn insert(self: *Trie, ip: IP, prefix: u8) !bool {
        const addr = ip.mask(prefix);
        const ptr = self.rootPtr(ip);

        if (ptr.* == null) {
            ptr.* = try self.allocator.create(Node);
            ptr.*.?.* = .{};
        }

        var node = ptr.*.?;

        var i: u8 = 0;
        while (i < prefix) : (i += 1) {
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

    pub fn iterate(self: *const Trie, comptime callback: fn (ip: IP, prefix: u8) void) void {
        if (self.v4) |r| walkNode(r, IP{ .v4 = 0 }, 0, callback);
        if (self.v6) |r| walkNode(r, IP{ .v6 = 0 }, 0, callback);
    }

    pub fn walkNode(node: *Node, current: IP, depth: u8, callback: fn (ip: IP, prefix: u8) void) void {
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

test "IPv4: broader prefix subsumes more-specific" {
    var trie = Trie.init(std.testing.allocator);
    defer trie.deinit();

    // Insert 192.168.0.0/16 first, then /24 should be rejected.
    const broad = IP{ .v4 = 0xC0A80000 }; // 192.168.0.0
    const narrow = IP{ .v4 = 0xC0A80100 }; // 192.168.1.0

    try std.testing.expect(try trie.insert(broad, 16));
    try std.testing.expect(!try trie.insert(narrow, 24)); // already covered
}

test "IPv4: insert narrow first, then broad prunes it" {
    var trie = Trie.init(std.testing.allocator);
    defer trie.deinit();

    const broad = IP{ .v4 = 0xC0A80000 };
    const narrow = IP{ .v4 = 0xC0A80100 };

    try std.testing.expect(try trie.insert(narrow, 24));
    try std.testing.expect(try trie.insert(broad, 16)); // inserts and prunes /24

    // /24 is gone; /16 covers it
    try std.testing.expect(trie.contains(IP{ .v4 = 0xC0A80105 }));
}

test "IPv4: contains" {
    var trie = Trie.init(std.testing.allocator);
    defer trie.deinit();

    _ = try trie.insert(IP{ .v4 = 0x0A000000 }, 8); // 10.0.0.0/8

    try std.testing.expect(trie.contains(IP{ .v4 = 0x0A010203 })); // 10.1.2.3 works
    try std.testing.expect(!trie.contains(IP{ .v4 = 0x0B000001 })); // 11.0.0.1 doesn't work
}

test "iterate prints all stored CIDRs" {
    var trie = Trie.init(std.testing.allocator);
    defer trie.deinit();

    _ = try trie.insert(IP{ .v4 = 0x0A000000 }, 8); // 10.0.0.0/8
    _ = try trie.insert(IP{ .v4 = 0xC0A80000 }, 16); // 192.168.0.0/16

    const S = struct {
        fn cb(ip: IP, prefix_len: u8) void {
            var buf: [32]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buf);

            ip.format(&writer) catch {};
            std.debug.print("{s}/{}\n", .{ buf[0..writer.end], prefix_len });
        }
    };
    trie.iterate(S.cb);
}

test "IPv6: basic insert and contains" {
    var trie = Trie.init(std.testing.allocator);
    defer trie.deinit();

    // 2001:db8::/32
    const net: u128 = 0x20010db8_00000000_00000000_00000000;
    _ = try trie.insert(IP{ .v6 = net }, 32);

    const inside: u128 = 0x20010db8_0001_0000_0000_000000000001;
    const outside: u128 = 0x20010db9_0000_0000_0000_000000000001;

    try std.testing.expect(trie.contains(IP{ .v6 = inside }));
    try std.testing.expect(!trie.contains(IP{ .v6 = outside }));
}

test "IPv6: broader subsumes narrower" {
    var trie = Trie.init(std.testing.allocator);
    defer trie.deinit();

    const base: u128 = 0x20010db8_00000000_00000000_00000000;
    try std.testing.expect(try trie.insert(IP{ .v6 = base }, 32));
    try std.testing.expect(!try trie.insert(IP{ .v6 = base }, 48)); // covered
}
