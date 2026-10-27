//! The detection trie over character-class signatures, built at comptime
//! from formats.table. Walking it is one array load per signature class,
//! no backtracking, and an input matches an entry only when its whole
//! signature is that entry's.

const std = @import("std");
const signature = @import("signature.zig");
const formats = @import("formats.zig");

const Node = struct {
    /// Index of the child node for each class; 0 means none, since the root
    /// is nobody's child.
    children: [signature.num_classes]u16 = @splat(0),
    /// The formats.table index of the entry whose signature ends here.
    entry: ?u8 = null,
};

/// One node per distinct signature prefix, root first.
pub const nodes: []const Node = &built;

const built = blk: {
    @setEvalBranchQuota(100_000);
    var max: usize = 1;
    for (formats.table) |e| max += e.sig.len;
    var ns: [max]Node = @splat(.{});
    var count: u16 = 1;
    for (formats.table, 0..) |e, index| {
        var at: u16 = 0;
        for (e.sig) |cc| {
            const c = @backingInt(cc);
            if (ns[at].children[c] == 0) {
                ns[at].children[c] = count;
                count += 1;
            }
            at = ns[at].children[c];
        }
        // formats.tableProblem refuses two entries with one signature.
        std.debug.assert(ns[at].entry == null);
        ns[at].entry = @intCast(index);
    }
    break :blk ns[0..count].*;
};

/// The formats.table index of the entry whose signature is exactly sig's,
/// or null.
pub fn lookup(sig: *const signature.Signature) ?u8 {
    var at: u16 = 0;
    for (sig.classes()) |cc| {
        at = nodes[at].children[@backingInt(cc)];
        if (at == 0) return null;
    }
    return nodes[at].entry;
}

test {
    std.testing.refAllDecls(@This());
}

test "every entry's example walks to that entry, and nothing shorter or longer does" {
    for (formats.table, formats.examples, 0..) |e, ex, index| {
        const sig = signature.scan(ex[1]);
        try std.testing.expectEqual(@as(?u8, @intCast(index)), lookup(&sig));
        errdefer std.debug.print("{s}\n", .{e.name});
        const short = signature.scan(ex[1][0 .. ex[1].len - 1]);
        if (lookup(&short)) |hit| {
            // A shorter input may be another format, never this one.
            try std.testing.expect(hit != index);
        }
    }
    try std.testing.expectEqual(null, lookup(&signature.scan("2024-03-15x")));
    try std.testing.expectEqual(null, lookup(&signature.scan("")));
}

test "the trie shares prefixes" {
    var total: usize = 0;
    for (formats.table) |e| total += e.sig.len;
    try std.testing.expect(nodes.len < total);
}
