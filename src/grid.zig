// Part of zig-recast, a translation of Recast from recastnavigation 1.6.0
// to Zig; zlib licence, see LICENSE.

//! Runs of columns of a compact heightfield that form a plain grid, one,
//! two or four floors deep, where the passes over the whole field (the
//! distance field, its blur and the contours' boundaries) can take 16
//! spans at a time: in such a run every neighbour of a span is the span of
//! the same floor of the neighbouring column, at a fixed step in `spans`
//! from it.

const std = @import("std");
const assert = std.debug.assert;

const recast = @import("recast.zig");
const CompactCell = recast.CompactCell;
const CompactSpan = recast.CompactSpan;

/// Columns a run takes: 16 lanes of 32 bits, one AVX-512 register.
pub const run_len = 16;

/// The most spans a column of a run may hold.
pub const max_layers = 4;

/// A run of `run_len` columns in a row whose columns, and the columns
/// around them from one before it to one after it in the rows below, at
/// and above it, each hold the same number of spans, `layers` (1, 2 or 4),
/// at consecutive indices along each row, and whose every span is
/// connected on every side to the span of the same layer of the
/// neighbouring column. There a span's neighbour west or east is `layers`
/// spans from it, and the spans of a row's run follow one another, so a
/// run's spans are `layers` vectors of `run_len` spans. `below`, `at` and
/// `above` are the first spans of the run's first column and of the
/// columns below and above it.
pub const Run = struct {
    below: usize,
    at: usize,
    above: usize,
    layers: usize,

    /// The run from column `col` of a field `width` columns wide, or null
    /// where its columns are not as `Run` needs. `col` must be at least a
    /// row and a column from every edge of the field, and `run_len` columns
    /// and one more from the east one, as `RowRuns` puts it.
    pub fn of(cells: [*]const CompactCell, spans: [*]const CompactSpan, width: usize, col: usize) ?Run {
        const at = row(cells, spans, col) orelse return null;
        const below = row(cells, spans, col - width) orelse return null;
        const above = row(cells, spans, col + width) orelse return null;
        if (below.layers != at.layers or above.layers != at.layers) return null;
        return .{ .below = below.at, .at = at.at, .above = above.at, .layers = at.layers };
    }

    /// One row of a run: the first span of column `col` and the spans a
    /// column.
    pub const Row = struct { at: usize, layers: usize };

    /// The row of a run from column `col` if columns `col` - 1 to `col` +
    /// `run_len` each hold the same number of spans, 1, 2 or 4, following
    /// one another, each connected on every side to the same layer of the
    /// neighbouring column; null otherwise. `col` must be at least a column
    /// from the start of `cells` and `run_len` columns and one more from its
    /// end.
    pub fn row(cells: [*]const CompactCell, spans: [*]const CompactSpan, col: usize) ?Row {
        const words: [*]const u32 = @ptrCast(cells);
        const layers = words[col - 1] >> 24;
        // One floor inline; two or four out of line, so that their checks
        // do not crowd the loops that call this.
        if (layers == 1) return rowOf(cells, spans, col, 1);
        if (layers != 2 and layers != 4) return null;
        return @call(.never_inline, rowDeeper, .{ cells, spans, col, layers });
    }

    fn rowDeeper(cells: [*]const CompactCell, spans: [*]const CompactSpan, col: usize, layers: u32) ?Row {
        return switch (layers) {
            inline 2, 4 => |l| rowOf(cells, spans, col, l),
            else => null,
        };
    }

    inline fn rowOf(cells: [*]const CompactCell, spans: [*]const CompactSpan, col: usize, comptime layers: u32) ?Row {
        const Words = @Vector(run_len, u32);
        const words: [*]const u32 = @ptrCast(cells);
        const first = words[col - 1];
        // An index that the run's last does not carry past the 24 bits of
        // `index` into `count`.
        const span_first: usize = first & 0xffffff;
        const span_count = (run_len + 2) * layers;
        if (span_first + span_count > 0xffffff) return null;
        const step = comptime std.simd.iota(u32, run_len) * @as(Words, @splat(layers));
        const want: Words = @as(Words, @splat(first)) + step;
        const lo: Words = words[col - 1 ..][0..run_len].*;
        const hi: Words = words[col + 1 ..][0..run_len].*;
        if (@reduce(.Or, lo != want) or @reduce(.Or, hi != want + @as(Words, @splat(2 * layers)))) return null;
        // Each span's four connections its layer: 0, 1, 2 or 3 in each
        // field.
        const Spans = @Vector(run_len, u64);
        const span_words: [*]const u64 = @ptrCast(spans);
        const con_mask: Spans = @splat(@as(u64, 0xffffff) << 32);
        const chunks = comptime (span_count + run_len - 1) / run_len;
        inline for (0..chunks) |c| {
            const o = comptime @min(c * run_len, span_count - run_len);
            const expected = comptime blk: {
                var e: [run_len]u64 = undefined;
                for (&e, 0..) |*x, k| x.* = (@as(u64, (o + k) % layers) * 0x041041) << 32;
                break :blk e;
            };
            const got: Spans = span_words[span_first + o ..][0..run_len].*;
            if (@reduce(.Or, (got & con_mask) != @as(Spans, expected))) return null;
        }
        return .{ .at = span_first + layers, .layers = layers };
    }
};

/// Whether the `run_len` columns from `col` hold no spans.
pub inline fn emptyBlock(cells: [*]const CompactCell, col: usize) bool {
    const Words = @Vector(run_len, u32);
    const words: [*]const u32 = @ptrCast(cells);
    const block: Words = words[col..][0..run_len].*;
    return @reduce(.Or, block >> @splat(24)) == 0;
}

/// The spans of a block of columns that each hold at most one: `n` of
/// them from `first`.
pub const Sparse = struct { first: usize, n: usize };

/// The spans of the `run_len` columns from `col` where each holds at most
/// one span and those spans follow one another in the columns' order; null
/// otherwise, or where they have none.
pub inline fn sparseBlock(cells: [*]const CompactCell, col: usize) ?Sparse {
    const Words = @Vector(run_len, u32);
    const words: [*]const u32 = @ptrCast(cells);
    const block: Words = words[col..][0..run_len].*;
    const counts = block >> @splat(24);
    if (@reduce(.Or, counts > @as(Words, @splat(1)))) return null;
    const n = @reduce(.Add, counts);
    if (n == 0) return null;
    // The spans before each column in the block, a running sum.
    var before = counts;
    comptime var shift: i32 = 1;
    inline while (shift < run_len) : (shift *= 2) {
        const mask = comptime blk: {
            var m: [run_len]i32 = undefined;
            for (&m, 0..) |*e, k| e.* = if (@as(i32, k) - shift >= 0) @as(i32, k) - shift else -1;
            break :blk m;
        };
        before += @shuffle(u32, before, @as(Words, @splat(0)), mask);
    }
    before -= counts;
    const index = block & @as(Words, @splat(0xffffff));
    const has = counts == @as(Words, @splat(1));
    const first = @reduce(.Min, @select(u32, has, index, @as(Words, @splat(std.math.maxInt(u32)))));
    const want = @as(Words, @splat(first)) + before;
    if (@reduce(.Or, has & (index != want))) return null;
    return .{ .first = first, .n = n };
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
