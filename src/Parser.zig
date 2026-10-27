//! Parses a column of values written in one format: detects the format on
//! the first value and reuses its layout for the rest.
//!
//! A value the cached layout refuses is detected afresh, and so is every
//! value of a format resolved per value (DD/MM against MM/DD), because no
//! layout can carry that answer from one row to the next. The answer is
//! always the one parse would give; only the cost differs.
//!
//! Single-threaded: parse writes the cache. Use one Parser per thread.

const root = @import("root.zig");

const Parser = @This();

options: root.Options,
cache: ?root.Layout = null,

pub fn init(options: root.Options) Parser {
    return .{ .options = options };
}

pub fn parse(p: *Parser, s: []const u8) root.ParseError!root.Result {
    if (p.cache) |*l| {
        if (!l.ambiguity_prone) {
            if (l.parse(s)) |t| {
                return .{ .time = t, .layout = l.*, .ambiguous = l.ambiguous, .kind = .absolute };
            } else |_| {}
        }
    }
    const r = try root.parseWith(s, p.options);
    p.cache = r.layout;
    return r;
}

/// Forgets the cached layout, so the next value is detected afresh.
pub fn reset(p: *Parser) void {
    p.cache = null;
}
