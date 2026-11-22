// Part of zig-recast, a translation of Recast from recastnavigation 1.6.0
// to Zig; zlib licence, see LICENSE.

//! Runs of columns of a compact heightfield that form a plain grid, where
//! the passes over the whole field (the distance field, its blur and the
//! contours' boundaries) can take 16 spans at a time: in such a run every
//! neighbour of a span is the span of the neighbouring column, at a fixed
//! step in `spans` from it.

const std = @import("std");
const assert = std.debug.assert;

const recast = @import("recast.zig");
const CompactCell = recast.CompactCell;
const CompactSpan = recast.CompactSpan;

/// Columns a run takes: 16 lanes of 32 bits, one AVX-512 register.
pub const run_len = 16;

/// A run of `run_len` columns in a row whose columns, and the columns
/// around them from one before it to one after it in the rows below, at
/// and above it, each hold one span, connected to the span of the column
/// next to it on every side, and whose rows' spans follow one another.
/// `below`, `at` and `above` are the spans of the run's first column and of
/// the columns below and above it.
pub const Run = struct {
    below: usize,
    at: usize,
    above: usize,

    /// The run from column `col` of a field `width` columns wide, or null
    /// where its columns are not as `Run` needs. `col` must be at least a
    /// row and a column from every edge of the field, and `run_len` columns
    /// and one more from the east one, as `RowRuns` puts it.
    pub fn of(cells: [*]const CompactCell, spans: [*]const CompactSpan, width: usize, col: usize) ?Run {
        const below = row(cells, spans, col - width) orelse return null;
        const at = row(cells, spans, col) orelse return null;
        const above = row(cells, spans, col + width) orelse return null;
        return .{ .below = below, .at = at, .above = above };
    }

    /// The span of column `col` if columns `col` - 1 to `col` + `run_len`
    /// each hold one span, with connections of index 0 on every side, at
    /// consecutive indices; null otherwise. `col` must be at least a column
    /// from the start of `cells` and `run_len` columns and one more from its
    /// end.
    pub fn row(cells: [*]const CompactCell, spans: [*]const CompactSpan, col: usize) ?usize {
        const Words = @Vector(run_len, u32);
        const words: [*]const u32 = @ptrCast(cells);
        const first = words[col - 1];
        // One span, and an index that the run's last does not carry past
        // the 24 bits of `index` into `count`.
        if (first >> 24 != 1 or (first & 0xffffff) + run_len + 1 > 0xffffff) return null;
        const want: Words = @as(Words, @splat(first)) + std.simd.iota(u32, run_len);
        const lo: Words = words[col - 1 ..][0..run_len].*;
        const hi: Words = words[col + 1 ..][0..run_len].*;
        if (@reduce(.Or, lo != want) or @reduce(.Or, hi != want + @as(Words, @splat(2)))) return null;
        // Every connection 0: all 24 bits of `con` clear.
        const span_first: usize = first & 0xffffff;
        const Spans = @Vector(run_len, u64);
        const span_words: [*]const u64 = @ptrCast(spans);
        const con_mask: Spans = @splat(@as(u64, 0xffffff) << 32);
        const s_lo: Spans = span_words[span_first..][0..run_len].*;
        const s_hi: Spans = span_words[span_first + 2 ..][0..run_len].*;
        if (@reduce(.Or, (s_lo | s_hi) & con_mask) != 0) return null;
        return span_first + 1;
    }
};

comptime {
    // `Run.row` reads the cells and spans as words.
    assert(@bitSizeOf(CompactCell) == 32 and @bitOffsetOf(CompactCell, "count") == 24);
    assert(@bitSizeOf(CompactSpan) == 64 and @bitOffsetOf(CompactSpan, "con") == 32);
}

/// The region ids of the `run_len` spans from `i`.
pub inline fn regions(spans: [*]const CompactSpan, i: usize) @Vector(run_len, u16) {
    const Spans = @Vector(run_len, u64);
    const span_words: [*]const u64 = @ptrCast(spans);
    const words: Spans = span_words[i..][0..run_len].*;
    return @truncate(words >> @splat(@bitOffsetOf(CompactSpan, "reg")));
}

/// Where row `y`'s runs start and end, as column indices: from column 1 of
/// the row, as many whole runs as leave a column after them. Rows 0 and
/// `h` - 1 have none.
pub const RowRuns = struct {
    first: usize,
    end: usize,

    pub fn of(w: usize, h: usize, y: usize) RowRuns {
        const start = y * w;
        if (y == 0 or y + 1 >= h or w < run_len + 2) return .{ .first = start, .end = start };
        const runs = (w - 2) / run_len;
        return .{ .first = start + 1, .end = start + 1 + runs * run_len };
    }
};
