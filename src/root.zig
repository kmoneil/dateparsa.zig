//! dateparsa: date parsing for input whose format you do not control.
//!
//! A Zig port of dateparsa (github.com/kmoneil/dateparsa). Detection and
//! parsing are separate problems: parse detects the format once and hands
//! back a reusable Layout that re-parses the same format with no detection
//! and no allocation.
//!
//! Nothing here allocates, reads a clock, or touches the filesystem. All
//! detection tables are comptime data.

const std = @import("std");

pub const DateTime = @import("DateTime.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("signature.zig");
    _ = @import("compile.zig");
    _ = @import("fast.zig");
    _ = @import("trie.zig");
    _ = @import("detect.zig");
    _ = @import("ambiguity.zig");
    _ = @import("formats.zig");
}
