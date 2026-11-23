// An altered version of Recast from recastnavigation 1.6.0, translated to
// Zig. Copyright (c) 2009-2010 Mikko Mononen memon@inside.org; zlib licence,
// see LICENSE.

//! Region partitioning of a compact heightfield: the distance field, and the
//! watershed, monotone and layer partitions that split the walkable spans
//! into regions. Translated from RecastRegion.cpp.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const recast = @import("recast.zig");
const grid = @import("grid.zig");
const Context = recast.Context;
const CompactHeightfield = recast.CompactHeightfield;
const getCon = recast.getCon;
const getDirOffsetX = recast.getDirOffsetX;
const getDirOffsetY = recast.getDirOffsetY;
const border_reg = recast.border_reg;
const not_connected = recast.not_connected;
const null_area = recast.null_area;

/// How building regions can fail.
pub const BuildRegionsError = Allocator.Error || error{
    /// The watershed needs more region ids than 16 bits hold.
    RegionIdOverflow,
};

const directions = [4]u2{ 0, 1, 2, 3 };

/// A span waiting in a level stack: its column, and its index, or -1 once
/// it has a region.
const LevelStackEntry = struct {
    x: i32,
    y: i32,
    index: i32,
};

/// The index of span `con` of column (x, y): how a connection names a
/// neighbour.
fn spanIndexAt(chf: *const CompactHeightfield, x: i32, y: i32, con: i32) usize {
    const first: usize = chf.cells[@intCast(x + y * chf.width)].index;
    return first + @as(usize, @intCast(con));
}

/// A compact heightfield's columns, spans and areas for the distance field
/// and its blur, held by value: read through the heightfield's pointer,
/// they would be loaded again after every store to a span's distance.
/// Columns are named by their index in `cells`, x + y * width, so the
/// neighbour column in a direction is a fixed step from it.
const DistanceView = struct {
    cells: [*]const recast.CompactCell,
    spans: [*]const recast.CompactSpan,
    areas: [*]const u8,
    width: usize,
    height: usize,
    columns: usize,
    /// The number of spans, and of distances.
    spans_len: usize,

    fn of(chf: *const CompactHeightfield) DistanceView {
        const w: usize = @intCast(@max(chf.width, 0));
        const h: usize = @intCast(@max(chf.height, 0));
        return .{
            .cells = chf.cells.ptr,
            .spans = chf.spans.ptr,
            .areas = chf.areas.ptr,
            .width = w,
            .height = h,
            .columns = w * h,
            .spans_len = @intCast(@max(chf.span_count, 0)),
        };
    }

    /// The cell `dx`, `dy` columns from column `col`, where the original
    /// finds it: x + dx + (y + dy) * width, which off the west or east edge
    /// is a column of the row before or after. Past the start or end of
    /// `cells`, where the original reads outside the field, an empty cell.
    /// Without `edge`, the cell must be inside `cells`, as it is for every
    /// column of rows 2 to height - 3.
    inline fn cellAt(v: DistanceView, col: usize, comptime dx: i2, comptime dy: i2, comptime edge: bool) recast.CompactCell {
        var c = col;
        if (dx < 0) c -%= 1;
        if (dx > 0) c +%= 1;
        if (dy < 0) c -%= v.width;
        if (dy > 0) c +%= v.width;
        if (!edge) return v.cells[c];
        return if (c < v.columns) v.cells[c] else .{ .index = 0, .count = 0 };
    }

    /// Whether row `y` has columns whose neighbours may fall outside
    /// `cells`: rows 0, 1, height - 2 and height - 1.
    fn edgeRow(v: DistanceView, y: usize) bool {
        return y < 2 or y + 2 >= v.height;
    }
};

/// Connection `dir` of a span's packed connections.
inline fn conOf(con: u32, comptime dir: u2) u32 {
    return (con >> (@as(u5, dir) * 6)) & 0x3f;
}

/// Whether any of the four connections packed in `con` is `not_connected`,
/// all six of its bits set.
inline fn anyNotConnected(con: u32) bool {
    const t = con & (con >> 1) & (con >> 2) & (con >> 3) & (con >> 4) & (con >> 5);
    return t & 0x041041 != 0;
}

comptime {
    assert(not_connected == 0x3f);
}

/// The cells of a column's eight neighbours, as `DistanceView.cellAt`
/// finds them.
const Around = struct {
    w: recast.CompactCell,
    n: recast.CompactCell,
    e: recast.CompactCell,
    s: recast.CompactCell,
    nw: recast.CompactCell,
    ne: recast.CompactCell,
    se: recast.CompactCell,
    sw: recast.CompactCell,

    inline fn of(v: DistanceView, col: usize, comptime edge: bool) Around {
        return .{
            .w = v.cellAt(col, -1, 0, edge),
            .n = v.cellAt(col, 0, 1, edge),
            .e = v.cellAt(col, 1, 0, edge),
            .s = v.cellAt(col, 0, -1, edge),
            .nw = v.cellAt(col, -1, 1, edge),
            .ne = v.cellAt(col, 1, 1, edge),
            .se = v.cellAt(col, 1, -1, edge),
            .sw = v.cellAt(col, -1, -1, edge),
        };
    }

    /// The neighbour cell in direction `dir`.
    inline fn side(a: Around, comptime dir: u2) recast.CompactCell {
        return switch (dir) {
            0 => a.w,
            1 => a.n,
            2 => a.e,
            3 => a.s,
        };
    }

    /// The cell one step `dir` and one step `dir` + 1 away, the diagonal
    /// that the blur and the sweeps reach through the neighbour `dir`.
    inline fn corner(a: Around, comptime dir: u2, comptime dir2: u2) recast.CompactCell {
        const d = [2]u2{ dir, dir2 };
        var dx: i32 = 0;
        var dy: i32 = 0;
        inline for (d) |e| {
            dx += getDirOffsetX(e);
            dy += getDirOffsetY(e);
        }
        if (dx < 0 and dy > 0) return a.nw;
        if (dx > 0 and dy > 0) return a.ne;
        if (dx > 0 and dy < 0) return a.se;
        return a.sw;
    }
};

/// The span that connection `dir` of a span with connections `con` names
/// from the neighbour cell `c`, for a connected one.
inline fn spanOf(c: recast.CompactCell, con: u32, comptime dir: u2) usize {
    return @as(usize, c.index) + conOf(con, dir);
}

/// A byte for each direction with the number of spans of the neighbour
/// column the field's layout allows a connection to name: the column's
/// count, at most 63, or 0 off the field's edge.
inline fn allowedLayers(v: DistanceView, a: Around, x: usize, y: usize) u32 {
    const w: u32 = if (x > 0) @min(a.w.count, 63) else 0;
    const n: u32 = if (y + 1 < v.height) @min(a.n.count, 63) else 0;
    const e: u32 = if (x + 1 < v.width) @min(a.e.count, 63) else 0;
    const s: u32 = if (y > 0) @min(a.s.count, 63) else 0;
    return w | n << 8 | e << 16 | s << 24;
}

/// Nonzero where a connection of `con` names a span past the `allowed`
/// spans of its neighbour column (see `allowedLayers`): four 6-bit fields
/// spread into bytes and compared at once.
inline fn connectionsOutside(con: u32, allowed: u32) u32 {
    const k = (con & 0x3f) | ((con & 0xfc0) << 2) | ((con & 0x3f000) << 4) | ((con & 0xfc0000) << 6);
    // In each byte, k + 128 - allowed keeps its top bit where k >= allowed,
    // and k + 1 has bit 6 set where k is 63, `not_connected`.
    const at_least = ((k | 0x80808080) -% allowed) & 0x80808080;
    const unconnected = ((k +% 0x01010101) & 0x40404040) << 1;
    return at_least & ~unconnected;
}

/// 0 for a span on the border, one with a neighbour missing or of another
/// area, and 0xffff for any other: the start of its distance.
inline fn borderDistance(v: DistanceView, a: Around, i: usize, con: u32) u32 {
    if (anyNotConnected(con)) return 0;
    const area = v.areas[i];
    const a0 = v.areas[spanOf(a.w, con, 0)];
    const a1 = v.areas[spanOf(a.n, con, 1)];
    const a2 = v.areas[spanOf(a.e, con, 2)];
    const a3 = v.areas[spanOf(a.s, con, 3)];
    return if ((a0 ^ area) | (a1 ^ area) | (a2 ^ area) | (a3 ^ area) != 0) 0 else 0xffff;
}

/// The least of `d` and the distances of a span's neighbour in direction
/// `dir` plus 2 and of that neighbour's neighbour in direction `dir2` plus
/// 3, the diagonal; the span's connections are `con`, its neighbours' cells
/// `a`.
inline fn sweepStep(
    v: DistanceView,
    dist: [*]const u16,
    a: Around,
    con: u32,
    d: u32,
    comptime dir: u2,
    comptime dir2: u2,
) u32 {
    var m = d;
    if (conOf(con, dir) != not_connected) {
        const ai = spanOf(a.side(dir), con, dir);
        m = @min(m, @as(u32, dist[ai]) + 2);
        const a_con: u32 = v.spans[ai].con;
        if (conOf(a_con, dir2) != not_connected) {
            const aai = spanOf(a.corner(dir, dir2), a_con, dir2);
            m = @min(m, @as(u32, dist[aai]) + 3);
        }
    }
    return m;
}

/// The blur of span `i`: the rounded mean of its distance and its 8
/// neighbours', a missing neighbour counting as the span itself, where the
/// span is farther than `blur_threshold` from the border.
inline fn blurSpan(v: DistanceView, dist: [*]const u16, a: Around, i: usize) u16 {
    const cd: u32 = dist[i];
    if (cd <= blur_threshold) return @intCast(cd);
    const con: u32 = v.spans[i].con;
    var d: u32 = cd;
    inline for (directions) |dir| {
        if (conOf(con, dir) != not_connected) {
            const ai = spanOf(a.side(dir), con, dir);
            d += dist[ai];

            const dir2 = dir +% 1;
            const a_con: u32 = v.spans[ai].con;
            if (conOf(a_con, dir2) != not_connected) {
                d += dist[spanOf(a.corner(dir, dir2), a_con, dir2)];
            } else {
                d += cd;
            }
        } else {
            d += cd * 2;
        }
    }
    return @intCast((d + 5) / 9);
}

/// The original blurs with a threshold of 1, doubled: spans at most this
/// far from the border keep their distance.
const blur_threshold = 2;

const run_len = grid.run_len;
const Run = grid.Run;
const RowRuns = grid.RowRuns;
const emptyBlock = grid.emptyBlock;
const sparseBlock = grid.sparseBlock;
const RunU32 = @Vector(run_len, u32);
const RunU16 = @Vector(run_len, u16);

/// The `run_len` values of `values` from `i`, widened.
inline fn load16(values: [*]const u16, i: usize) RunU32 {
    const narrow: RunU16 = values[i..][0..run_len].*;
    return narrow;
}

/// Each lane the least of itself and the lanes `stride`, 2 `stride`, ...
/// before it (`up`) or after it (not `up`), in log2(`run_len` / `stride`)
/// steps.
inline fn scanMin(x: RunU32, comptime stride: usize, comptime up: bool) RunU32 {
    var r = x;
    const fill: RunU32 = @splat(std.math.maxInt(u32));
    comptime var shift: i32 = stride;
    inline while (shift < run_len) : (shift *= 2) {
        const mask = comptime blk: {
            var m: [run_len]i32 = undefined;
            for (&m, 0..) |*e, k| {
                const from: i32 = if (up) @as(i32, k) - shift else @as(i32, k) + shift;
                e.* = if (from >= 0 and from < run_len) from else -1;
            }
            break :blk m;
        };
        r = @min(r, @shuffle(u32, r, fill, mask));
    }
    return r;
}

/// Lane k: `values[i + k % layers]`, widened.
inline fn repeatLayers(values: [*]const u16, i: usize, comptime layers: usize) RunU32 {
    const few: @Vector(layers, u16) = values[i..][0..layers].*;
    const mask = comptime blk: {
        var m: [run_len]i32 = undefined;
        for (&m, 0..) |*e, k| e.* = @intCast(k % layers);
        break :blk m;
    };
    return @shuffle(u16, few, undefined, mask);
}

/// Lane k: k / `layers`, the column of the lane's span in a vector of a
/// run's spans.
inline fn laneColumns(comptime layers: usize) RunU32 {
    return std.simd.iota(u32, run_len) / @as(RunU32, @splat(layers));
}

/// The mark and the sweep up over a run: each span's distance is the least
/// of its mark and of its west neighbour's plus 2, south-west's plus 3,
/// south's plus 2 and south-east's plus 3, and its west neighbour's is the
/// one just found. With `e` the least of the others, d[k] = min(e[k],
/// d[k - layers] + 2) is the least over the lanes j of k's floor up to k of
/// e[j] + 2 (k - j) / layers, and over the distance of that floor's span
/// before the run plus 2 (k / layers + 1), a scan.
inline fn sweepUpRun(v: DistanceView, dist: [*]u16, run: Run) void {
    // One floor inline; two or four out of line, so that their code does
    // not crowd the one-floor loops.
    if (run.layers == 1) return sweepUpRunLayers(v, dist, run, 1);
    @call(.never_inline, sweepUpRunDeeper, .{ v, dist, run });
}

fn sweepUpRunDeeper(v: DistanceView, dist: [*]u16, run: Run) void {
    switch (run.layers) {
        inline 2, 4 => |layers| sweepUpRunLayers(v, dist, run, layers),
        else => unreachable,
    }
}

inline fn sweepUpRunLayers(v: DistanceView, dist: [*]u16, run: Run, comptime layers: usize) void {
    inline for (0..layers) |part| {
        sweepUpPart(v, dist, run.at + part * run_len, run.below + part * run_len, run.above + part * run_len, layers);
    }
}

inline fn sweepUpPart(v: DistanceView, dist: [*]u16, at: usize, below: usize, above: usize, comptime layers: usize) void {
    const Areas = @Vector(run_len, u8);
    const area: Areas = v.areas[at..][0..run_len].*;
    const west: Areas = v.areas[at - layers ..][0..run_len].*;
    const east: Areas = v.areas[at + layers ..][0..run_len].*;
    const north: Areas = v.areas[above..][0..run_len].*;
    const south: Areas = v.areas[below..][0..run_len].*;
    const same = (area == west) & (area == east) & (area == north) & (area == south);
    const mark: RunU32 = @select(u32, same, @as(RunU32, @splat(0xffff)), @as(RunU32, @splat(0)));

    const two: RunU32 = @splat(2);
    const three: RunU32 = @splat(3);
    var e = @min(mark, load16(dist, below) + two);
    e = @min(e, load16(dist, below - layers) + three);
    e = @min(e, load16(dist, below + layers) + three);

    const columns = run_len / layers;
    const lift = (@as(RunU32, @splat(columns - 1)) - laneColumns(layers)) * two;
    const before = repeatLayers(dist, at - layers, layers) + @as(RunU32, @splat(2 * columns));
    const least = @min(scanMin(e + lift, layers, true), before);
    // At most 0xffff, as the mark is.
    dist[at..][0..run_len].* = @as(RunU16, @intCast(least - lift));
}

/// The sweep down over a run, as `sweepUpRun` without the mark, from the
/// east: d[k] = min(e[k], d[k + layers] + 2).
inline fn sweepDownRun(dist: [*]u16, run: Run) void {
    // One floor inline; two or four out of line, so that their code does
    // not crowd the one-floor loops.
    if (run.layers == 1) return sweepDownRunLayers(dist, run, 1);
    @call(.never_inline, sweepDownRunDeeper, .{ dist, run });
}

fn sweepDownRunDeeper(dist: [*]u16, run: Run) void {
    switch (run.layers) {
        inline 2, 4 => |layers| sweepDownRunLayers(dist, run, layers),
        else => unreachable,
    }
}

inline fn sweepDownRunLayers(dist: [*]u16, run: Run, comptime layers: usize) void {
    inline for (0..layers) |p| {
        const part = layers - 1 - p;
        sweepDownPart(dist, run.at + part * run_len, run.above + part * run_len, layers);
    }
}

inline fn sweepDownPart(dist: [*]u16, at: usize, above: usize, comptime layers: usize) void {
    const two: RunU32 = @splat(2);
    const three: RunU32 = @splat(3);
    var e = @min(load16(dist, at), load16(dist, above) + two);
    e = @min(e, load16(dist, above - layers) + three);
    e = @min(e, load16(dist, above + layers) + three);

    const columns = run_len / layers;
    const lift = laneColumns(layers) * two;
    const after = repeatLayers(dist, at + run_len, layers) + @as(RunU32, @splat(2 * columns));
    const least = @min(scanMin(e + lift, layers, false), after);
    dist[at..][0..run_len].* = @as(RunU16, @intCast(least - lift));
}

/// The blur over a run: every span has all eight neighbours.
inline fn blurRun(src: [*]const u16, dst: [*]u16, run: Run) void {
    // One floor inline; two or four out of line, so that their code does
    // not crowd the one-floor loops.
    if (run.layers == 1) return blurRunLayers(src, dst, run, 1);
    @call(.never_inline, blurRunDeeper, .{ src, dst, run });
}

fn blurRunDeeper(src: [*]const u16, dst: [*]u16, run: Run) void {
    switch (run.layers) {
        inline 2, 4 => |layers| blurRunLayers(src, dst, run, layers),
        else => unreachable,
    }
}

inline fn blurRunLayers(src: [*]const u16, dst: [*]u16, run: Run, comptime layers: usize) void {
    inline for (0..layers) |part| {
        blurPart(src, dst, run.at + part * run_len, run.below + part * run_len, run.above + part * run_len, layers);
    }
}

inline fn blurPart(src: [*]const u16, dst: [*]u16, at: usize, below: usize, above: usize, comptime layers: usize) void {
    const cd = load16(src, at);
    var d = cd + load16(src, at - layers) + load16(src, at + layers);
    d += load16(src, above - layers) + load16(src, above) + load16(src, above + layers);
    d += load16(src, below - layers) + load16(src, below) + load16(src, below + layers);
    const mean = (d + @as(RunU32, @splat(5))) / @as(RunU32, @splat(9));
    const keep = cd <= @as(RunU32, @splat(blur_threshold));
    dst[at..][0..run_len].* = @as(RunU16, @intCast(@select(u32, keep, cd, mean)));
}

/// No span yet: the first column with spans may start anywhere.
const no_span = std.math.maxInt(usize);

/// Marks and sweeps up the spans of column (x, y). Sets `odd` where the
/// column's spans do not start at `next_span`, where the spans of the
/// columns before it end, or where a connection names a span outside its
/// neighbour column or leaves the field.
inline fn sweepUpColumn(
    v: DistanceView,
    dist: [*]u16,
    x: usize,
    y: usize,
    odd: *u32,
    next_span: *usize,
    comptime edge: bool,
) void {
    const col = y * v.width + x;
    const c = v.cells[col];
    if (c.count == 0) return;
    const first: usize = c.index;
    odd.* |= @intFromBool(next_span.* != no_span and first != next_span.*);
    next_span.* = first + c.count;
    const a: Around = .of(v, col, edge);
    const allowed = allowedLayers(v, a, x, y);
    for (first..first + c.count) |i| {
        const con: u32 = v.spans[i].con;
        odd.* |= connectionsOutside(con, allowed);
        var d = borderDistance(v, a, i, con);
        // (0,-1) and (1,-1), (-1,0) and (-1,-1).
        d = sweepStep(v, dist, a, con, d, 3, 2);
        d = sweepStep(v, dist, a, con, d, 0, 3);
        // At most 0xffff, as it started at most that.
        dist[i] = @intCast(d);
    }
}

/// Sweeps down the spans of column `col`.
inline fn sweepDownColumn(v: DistanceView, dist: [*]u16, col: usize, comptime edge: bool) void {
    const c = v.cells[col];
    if (c.count == 0) return;
    const a: Around = .of(v, col, edge);
    const first: usize = c.index;
    for (first..first + c.count) |i| {
        const con: u32 = v.spans[i].con;
        var d: u32 = dist[i];
        // (0,1) and (-1,1), (1,0) and (1,1).
        d = sweepStep(v, dist, a, con, d, 1, 0);
        d = sweepStep(v, dist, a, con, d, 2, 1);
        dist[i] = @intCast(d);
    }
}

/// Blurs the spans of column `col`.
inline fn blurColumn(v: DistanceView, src: [*]const u16, dst: [*]u16, col: usize, comptime edge: bool) void {
    const c = v.cells[col];
    if (c.count == 0) return;
    const a: Around = .of(v, col, edge);
    const first: usize = c.index;
    for (first..first + c.count) |i| dst[i] = blurSpan(v, src, a, i);
}

/// Nonzero where a connection of `con`, a span's of column `col`, names a
/// span past its neighbour column's; for a column off the field's edge and
/// the edge rows.
inline fn outsideColumns(v: DistanceView, col: usize, con: u32) u32 {
    var outside: u32 = 0;
    inline for (directions) |dir| {
        const k = conOf(con, dir);
        if (k != not_connected) {
            const n = switch (dir) {
                0 => col - 1,
                1 => col + v.width,
                2 => col + 1,
                3 => col - v.width,
            };
            outside |= @intFromBool(k >= v.cells[n].count);
        }
    }
    return outside;
}

/// `sweepUpColumn` for a column off the field's edge and the edge rows,
/// whose neighbours and diagonals all lie inside the field. A span on the
/// border keeps 0 through both sweeps, so only the others are swept, and
/// those have all four neighbours.
inline fn sweepUpColumnInner(v: DistanceView, dist: [*]u16, col: usize, odd: *u32, next_span: *usize) void {
    const c = v.cells[col];
    if (c.count == 0) return;
    const first: usize = c.index;
    odd.* |= @intFromBool(next_span.* != no_span and first != next_span.*);
    next_span.* = first + c.count;
    const w = v.width;
    for (first..first + c.count) |i| {
        const con: u32 = v.spans[i].con;
        if (anyNotConnected(con)) {
            odd.* |= outsideColumns(v, col, con);
            dist[i] = 0;
            continue;
        }
        const cw = v.cells[col - 1];
        const cn = v.cells[col + w];
        const ce = v.cells[col + 1];
        const cs = v.cells[col - w];
        const k0 = conOf(con, 0);
        const k1 = conOf(con, 1);
        const k2 = conOf(con, 2);
        const k3 = conOf(con, 3);
        odd.* |= @intFromBool(k0 >= cw.count) | @intFromBool(k1 >= cn.count) |
            @intFromBool(k2 >= ce.count) | @intFromBool(k3 >= cs.count);
        const iw = @as(usize, cw.index) + k0;
        const is = @as(usize, cs.index) + k3;
        const area = v.areas[i];
        const differ = (v.areas[iw] ^ area) | (v.areas[@as(usize, cn.index) + k1] ^ area) |
            (v.areas[@as(usize, ce.index) + k2] ^ area) | (v.areas[is] ^ area);
        if (differ != 0) {
            dist[i] = 0;
            continue;
        }
        // (0,-1) and (1,-1), (-1,0) and (-1,-1).
        var d: u32 = @as(u32, dist[is]) + 2;
        const s_con: u32 = v.spans[is].con;
        if (conOf(s_con, 2) != not_connected) {
            d = @min(d, @as(u32, dist[@as(usize, v.cells[col - w + 1].index) + conOf(s_con, 2)]) + 3);
        }
        const w_con: u32 = v.spans[iw].con;
        if (conOf(w_con, 3) != not_connected) {
            d = @min(d, @as(u32, dist[@as(usize, v.cells[col - 1 - w].index) + conOf(w_con, 3)]) + 3);
        }
        d = @min(d, @as(u32, dist[iw]) + 2);
        dist[i] = @intCast(@min(d, 0xffff));
    }
}

/// `sweepDownColumn` for a column as `sweepUpColumnInner` takes. A span
/// whose distance is above 0 has all four neighbours, in any field: its
/// mark was 0xffff.
inline fn sweepDownColumnInner(v: DistanceView, dist: [*]u16, col: usize) void {
    const c = v.cells[col];
    if (c.count == 0) return;
    const w = v.width;
    const first: usize = c.index;
    for (first..first + c.count) |i| {
        if (dist[i] == 0) continue;
        const con: u32 = v.spans[i].con;
        // (1,0) and (1,1), (0,1) and (-1,1), lowering the distance in
        // place as the original does: a store under a branch, which the
        // processor runs ahead of, where a running least would make each
        // step wait for its loads.
        const ie = @as(usize, v.cells[col + 1].index) + conOf(con, 2);
        lower(dist, i, @as(u32, dist[ie]) + 2);
        const e_con: u32 = v.spans[ie].con;
        if (conOf(e_con, 1) != not_connected) {
            lower(dist, i, @as(u32, dist[@as(usize, v.cells[col + 1 + w].index) + conOf(e_con, 1)]) + 3);
        }
        const in = @as(usize, v.cells[col + w].index) + conOf(con, 1);
        lower(dist, i, @as(u32, dist[in]) + 2);
        const n_con: u32 = v.spans[in].con;
        if (conOf(n_con, 0) != not_connected) {
            lower(dist, i, @as(u32, dist[@as(usize, v.cells[col + w - 1].index) + conOf(n_con, 0)]) + 3);
        }
    }
}

/// Sets `dist[i]` to `d` where that is less.
inline fn lower(dist: [*]u16, i: usize, d: u32) void {
    if (d < dist[i]) dist[i] = @intCast(d);
}

/// `blurColumn` for a column as `sweepUpColumnInner` takes. A span farther
/// than the threshold from the border has all four neighbours.
inline fn blurColumnInner(v: DistanceView, src: [*]const u16, dst: [*]u16, col: usize) void {
    const c = v.cells[col];
    if (c.count == 0) return;
    const w = v.width;
    const first: usize = c.index;
    for (first..first + c.count) |i| {
        const cd: u32 = src[i];
        if (cd <= blur_threshold) {
            dst[i] = @intCast(cd);
            continue;
        }
        const con: u32 = v.spans[i].con;
        var d: u32 = cd;
        inline for (directions) |dir| {
            const step: [2]usize = switch (dir) {
                0 => .{ col - 1, col - 1 + w },
                1 => .{ col + w, col + w + 1 },
                2 => .{ col + 1, col + 1 - w },
                3 => .{ col - w, col - w - 1 },
            };
            const ai = @as(usize, v.cells[step[0]].index) + conOf(con, dir);
            d += src[ai];
            const dir2 = dir +% 1;
            const a_con: u32 = v.spans[ai].con;
            if (conOf(a_con, dir2) != not_connected) {
                d += src[@as(usize, v.cells[step[1]].index) + conOf(a_con, dir2)];
            } else {
                d += cd;
            }
        }
        dst[i] = @intCast((d + 5) / 9);
    }
}

/// Whether every span of a block's `sparse` spans has a distance of at
/// most `limit`; false where the spans' vector would run past `count`.
inline fn allAtMost(dist: [*]const u16, count: usize, sparse: grid.Sparse, limit: u16) bool {
    if (sparse.first + run_len > count) return false;
    const in = std.simd.iota(u32, run_len) < @as(RunU32, @splat(@intCast(sparse.n)));
    const d: RunU16 = dist[sparse.first..][0..run_len].*;
    return !@reduce(.Or, in & (d > @as(RunU16, @splat(limit))));
}

/// Blurs row `y` of `src` into `dst`.
fn blurRow(v: DistanceView, src: [*]const u16, dst: [*]u16, y: usize) void {
    const w = v.width;
    const row = y * w;
    if (v.edgeRow(y) or w < 3) {
        for (row..row + w) |col| blurColumn(v, src, dst, col, true);
        return;
    }
    blurColumn(v, src, dst, row, false);
    var col = row + 1;
    const runs: RowRuns = .of(w, v.height, y);
    while (col < runs.end) : (col += run_len) {
        if (Run.of(v.cells, v.spans, w, col)) |run| {
            blurRun(src, dst, run);
        } else if (sparseBlock(v.cells, col)) |sparse| {
            if (allAtMost(src, v.spans_len, sparse, blur_threshold)) {
                // Every span keeps its distance.
                const in = std.simd.iota(u32, run_len) < @as(RunU32, @splat(@intCast(sparse.n)));
                const kept: RunU16 = dst[sparse.first..][0..run_len].*;
                const d: RunU16 = src[sparse.first..][0..run_len].*;
                dst[sparse.first..][0..run_len].* = @select(u16, in, d, kept);
            } else {
                for (col..col + run_len) |c| blurColumnInner(v, src, dst, c);
            }
        } else if (!emptyBlock(v.cells, col)) {
            for (col..col + run_len) |c| blurColumnInner(v, src, dst, c);
        }
    }
    for (col..row + w - 1) |c| blurColumnInner(v, src, dst, c);
    blurColumn(v, src, dst, row + w - 1, false);
}

/// Marks and sweeps up row `y`; see `sweepUpColumn`.
fn sweepUpRow(v: DistanceView, dist: [*]u16, y: usize, odd: *u32, next_span: *usize) void {
    const w = v.width;
    const row = y * w;
    if (v.edgeRow(y) or w < 3) {
        for (0..w) |x| sweepUpColumn(v, dist, x, y, odd, next_span, true);
        return;
    }
    sweepUpColumn(v, dist, 0, y, odd, next_span, false);
    var col = row + 1;
    const runs: RowRuns = .of(w, v.height, y);
    while (col < runs.end) : (col += run_len) {
        if (Run.of(v.cells, v.spans, w, col)) |run| {
            odd.* |= @intFromBool(next_span.* != no_span and run.at != next_span.*);
            next_span.* = run.at + run_len * run.layers;
            sweepUpRun(v, dist, run);
        } else if (!emptyBlock(v.cells, col)) {
            for (col..col + run_len) |c| sweepUpColumnInner(v, dist, c, odd, next_span);
        }
    }
    for (col..row + w - 1) |c| sweepUpColumnInner(v, dist, c, odd, next_span);
    sweepUpColumn(v, dist, w - 1, y, odd, next_span, false);
}

/// Sweeps down row `y`, east to west.
fn sweepDownRow(v: DistanceView, dist: [*]u16, y: usize) void {
    const w = v.width;
    const row = y * w;
    if (v.edgeRow(y) or w < 3) {
        var col = row + w;
        while (col > row) {
            col -= 1;
            sweepDownColumn(v, dist, col, true);
        }
        return;
    }
    sweepDownColumn(v, dist, row + w - 1, false);
    const runs: RowRuns = .of(w, v.height, y);
    // The columns after the runs, then the runs, east to west.
    var col = row + w - 1;
    const first = if (runs.end > runs.first) runs.end else row + 1;
    while (col > first) {
        col -= 1;
        sweepDownColumnInner(v, dist, col);
    }
    while (col > row + 1) {
        col -= run_len;
        if (Run.of(v.cells, v.spans, w, col)) |run| {
            sweepDownRun(dist, run);
        } else if (sparseBlock(v.cells, col)) |sparse| {
            // Spans at 0 keep 0.
            if (!allAtMost(dist, v.spans_len, sparse, 0)) {
                var c = col + run_len;
                while (c > col) {
                    c -= 1;
                    sweepDownColumnInner(v, dist, c);
                }
            }
        } else if (!emptyBlock(v.cells, col)) {
            var c = col + run_len;
            while (c > col) {
                c -= 1;
                sweepDownColumnInner(v, dist, c);
            }
        }
    }
    sweepDownColumn(v, dist, row, false);
}

/// Each span's distance to the nearest border or area change into `src`, 2
/// per step along an axis and 3 per diagonal step; returns the largest.
/// Every span in no column keeps a distance of 0xffff.
///
/// The steps are the original's: mark the border spans 0 and the others
/// 0xffff; sweep the rows up, each west to east, taking each span's
/// distance as the least of its own and of its west, south-west, south and
/// south-east neighbours' plus 2 or 3; then sweep the rows down, each east
/// to west, the same with the other four neighbours. The original goes over
/// the whole field for each. Here a span is marked just before the sweep up
/// reaches it, as its mark needs only areas, so the field is read twice,
/// not three times. A span marked 0 keeps 0 through both sweeps, so only
/// the others are swept, and those have all four neighbours.
///
/// That gives the original's distances where the spans of the columns that
/// have any follow one another in the order of the columns, and every
/// connection names a span of its neighbour column inside the field, as in
/// every field that `buildCompactHeightfield` builds with at most 255
/// spans a column: then each step reads only distances that the original's
/// same step reads, after the same steps have written them. The sweep up
/// checks both, each span's own connections once, which covers every
/// diagonal too, as a diagonal is reached through a neighbour's own
/// connection. It returns null at the end of the first row where either
/// fails; the caller then uses `distancesInOrder`.
///
/// Where a run of columns is a grid one, two or four floors deep (see
/// `Run`), its spans are done `run_len` at a time, each sweep as a scan
/// along the row; a block of `run_len` columns with no spans is skipped.
fn distances(chf: *const CompactHeightfield, src: []u16) ?u16 {
    @memset(src, 0xffff);
    const v: DistanceView = .of(chf);
    if (v.columns == 0) return maxOf(src);
    const dist = src.ptr;
    var odd: u32 = 0;
    var next_span: usize = no_span;

    // Mark and sweep up, rows up, each west to east.
    for (0..v.height) |y| {
        sweepUpRow(v, dist, y, &odd, &next_span);
        if (odd != 0) return null;
    }

    // Sweep down, rows down, each east to west.
    var y = v.height;
    while (y > 0) {
        y -= 1;
        sweepDownRow(v, dist, y);
    }
    return maxOf(src);
}

/// Blurs `src` into `dst`, row by row: each span farther than 2 from the
/// border gets the rounded mean of its distance and its 8 neighbours', a
/// missing neighbour counting as the span itself. Reading only `src` and
/// writing each span's own `dst`, in the original's order of columns, it
/// gives the original's blur on any field.
fn blur(chf: *const CompactHeightfield, src: []const u16, dst: []u16) void {
    const v: DistanceView = .of(chf);
    for (0..v.height) |y| blurRow(v, src.ptr, dst.ptr, y);
}

/// The distances as `distances` gives them, for any field, in the
/// original's order: the mark and each sweep over the whole field in turn.
fn distancesInOrder(chf: *const CompactHeightfield, src: []u16) u16 {
    @memset(src, 0xffff);
    const v: DistanceView = .of(chf);
    const dist = src.ptr;
    for (0..v.height) |y| {
        if (v.edgeRow(y)) markRowInOrder(v, dist, y, true) else markRowInOrder(v, dist, y, false);
    }
    for (0..v.height) |y| {
        if (v.edgeRow(y)) sweepUpRowInOrder(v, dist, y, true) else sweepUpRowInOrder(v, dist, y, false);
    }
    // Pass 2, without the runs: a run's rows may share spans in such a
    // field.
    var col = v.columns;
    while (col > 0) {
        col -= 1;
        const y = col / v.width;
        const x = col - y * v.width;
        if (v.edgeRow(y) or x == 0 or x + 1 == v.width) {
            sweepDownColumn(v, dist, col, true);
        } else {
            sweepDownColumnInner(v, dist, col);
        }
    }
    return maxOf(src);
}

/// The original's mark of row `y`: a border span's distance to 0, the
/// others left as they are.
inline fn markRowInOrder(v: DistanceView, dist: [*]u16, y: usize, comptime edge: bool) void {
    for (y * v.width..y * v.width + v.width) |col| {
        const c = v.cells[col];
        if (c.count == 0) continue;
        const a: Around = .of(v, col, edge);
        const first: usize = c.index;
        for (first..first + c.count) |i| {
            if (borderDistance(v, a, i, v.spans[i].con) == 0) dist[i] = 0;
        }
    }
}

/// The original's pass 1 over row `y`. A span whose distance is 0 keeps it
/// and any other has all four neighbours, as in `sweepUpColumnInner`. A
/// span read through a connection may be the span itself in such a field,
/// which leaves its distance as it is, as in the original.
inline fn sweepUpRowInOrder(v: DistanceView, dist: [*]u16, y: usize, comptime edge: bool) void {
    for (y * v.width..y * v.width + v.width) |col| {
        const c = v.cells[col];
        if (c.count == 0) continue;
        const a: Around = .of(v, col, edge);
        const first: usize = c.index;
        for (first..first + c.count) |i| {
            var d: u32 = dist[i];
            if (d == 0) continue;
            const con: u32 = v.spans[i].con;
            d = sweepStep(v, dist, a, con, d, 0, 3);
            d = sweepStep(v, dist, a, con, d, 3, 2);
            dist[i] = @intCast(d);
        }
    }
}

/// The largest of `values`, or 0 for none.
fn maxOf(values: []const u16) u16 {
    const lanes = std.simd.suggestVectorLength(u16) orelse 1;
    const V = @Vector(lanes, u16);
    var acc: V = @splat(0);
    var i: usize = 0;
    while (i + lanes <= values.len) : (i += lanes) {
        acc = @max(acc, @as(V, values[i..][0..lanes].*));
    }
    var max_dist: u16 = @reduce(.Max, acc);
    for (values[i..]) |d| max_dist = @max(d, max_dist);
    return max_dist;
}

/// Floods region `r` from span `i` of column (x, y) over the connected spans
/// of the same area at least `level` - 2 from the border, stopping at spans
/// next to another region. Returns whether any span joined the region.
fn floodRegion(
    gpa: Allocator,
    x: i32,
    y: i32,
    i: usize,
    level: u16,
    r: u16,
    chf: *const CompactHeightfield,
    src_reg: []u16,
    src_dist: []u16,
    stack: *std.ArrayList(LevelStackEntry),
) Allocator.Error!bool {
    const area = chf.areas[i];

    // Flood fill mark region.
    stack.clearRetainingCapacity();
    try stack.append(gpa, .{ .x = x, .y = y, .index = @intCast(i) });
    src_reg[i] = r;
    src_dist[i] = 0;

    const lev: u16 = if (level >= 2) level - 2 else 0;
    var count: i32 = 0;

    while (stack.pop()) |back| {
        const cx = back.x;
        const cy = back.y;
        const ci: usize = @intCast(back.index);

        const cs = chf.spans[ci];

        // Check if any of the neighbours already have a valid region set.
        var ar: u16 = 0;
        for (directions) |dir| {
            // 8 connected
            if (getCon(cs, dir) != not_connected) {
                const ax = cx + getDirOffsetX(dir);
                const ay = cy + getDirOffsetY(dir);
                const ai = spanIndexAt(chf, ax, ay, getCon(cs, dir));
                if (chf.areas[ai] != area) continue;
                const nr = src_reg[ai];
                // Do not take borders into account.
                if ((nr & border_reg) != 0) continue;
                if (nr != 0 and nr != r) {
                    ar = nr;
                    break;
                }

                const a_span = chf.spans[ai];

                const dir2 = dir +% 1;
                if (getCon(a_span, dir2) != not_connected) {
                    const ax2 = ax + getDirOffsetX(dir2);
                    const ay2 = ay + getDirOffsetY(dir2);
                    const ai2 = spanIndexAt(chf, ax2, ay2, getCon(a_span, dir2));
                    if (chf.areas[ai2] != area) continue;
                    const nr2 = src_reg[ai2];
                    if (nr2 != 0 and nr2 != r) {
                        ar = nr2;
                        break;
                    }
                }
            }
        }
        if (ar != 0) {
            src_reg[ci] = 0;
            continue;
        }

        count += 1;

        // Expand neighbours.
        for (directions) |dir| {
            if (getCon(cs, dir) != not_connected) {
                const ax = cx + getDirOffsetX(dir);
                const ay = cy + getDirOffsetY(dir);
                const ai = spanIndexAt(chf, ax, ay, getCon(cs, dir));
                if (chf.areas[ai] != area) continue;
                if (chf.dist[ai] >= lev and src_reg[ai] == 0) {
                    src_reg[ai] = r;
                    src_dist[ai] = 0;
                    try stack.append(gpa, .{ .x = ax, .y = ay, .index = @intCast(ai) });
                }
            }
        }
    }

    return count > 0;
}

/// A change to a span's region, kept until a pass of `expandRegions` ends so
/// the pass reads only the regions it started with.
const DirtyEntry = struct {
    index: i32,
    region: u16,
    distance2: u16,
};

/// Grows the regions into the unassigned spans of `stack`, or with
/// `fill_stack` into every unassigned span at least `level` from the border,
/// a ring per pass: each span joins the neighbouring region it is closest to
/// through. Stops when a pass assigns nothing, or after `max_iter` passes
/// when `level` is above 0.
fn expandRegions(
    gpa: Allocator,
    max_iter: i32,
    level: u16,
    chf: *const CompactHeightfield,
    src_reg: []u16,
    src_dist: []u16,
    stack: *std.ArrayList(LevelStackEntry),
    fill_stack: bool,
) Allocator.Error!void {
    const w = chf.width;
    const h = chf.height;

    if (fill_stack) {
        // Find cells revealed by the raised level.
        stack.clearRetainingCapacity();
        var y: i32 = 0;
        while (y < h) : (y += 1) {
            var x: i32 = 0;
            while (x < w) : (x += 1) {
                const c = chf.cells[@intCast(x + y * w)];
                const first: usize = c.index;
                for (first..first + c.count) |i| {
                    if (chf.dist[i] >= level and src_reg[i] == 0 and chf.areas[i] != null_area) {
                        try stack.append(gpa, .{ .x = x, .y = y, .index = @intCast(i) });
                    }
                }
            }
        }
    } else {
        // Mark all cells which already have a region.
        for (stack.items) |*entry| {
            if (src_reg[@intCast(entry.index)] != 0) entry.index = -1;
        }
    }

    var dirty_entries: std.ArrayList(DirtyEntry) = .empty;
    defer dirty_entries.deinit(gpa);
    var iter: i32 = 0;
    while (stack.items.len > 0) {
        var failed: usize = 0;
        dirty_entries.clearRetainingCapacity();

        for (stack.items) |*entry| {
            const x = entry.x;
            const y = entry.y;
            if (entry.index < 0) {
                failed += 1;
                continue;
            }
            const i: usize = @intCast(entry.index);

            var r = src_reg[i];
            var d2: u16 = 0xffff;
            const area = chf.areas[i];
            const s = chf.spans[i];
            for (directions) |dir| {
                if (getCon(s, dir) == not_connected) continue;
                const ax = x + getDirOffsetX(dir);
                const ay = y + getDirOffsetY(dir);
                const ai = spanIndexAt(chf, ax, ay, getCon(s, dir));
                if (chf.areas[ai] != area) continue;
                if (src_reg[ai] > 0 and (src_reg[ai] & border_reg) == 0) {
                    if (@as(i32, src_dist[ai]) + 2 < d2) {
                        r = src_reg[ai];
                        d2 = src_dist[ai] + 2;
                    }
                }
            }
            if (r != 0) {
                // Mark as used.
                entry.index = -1;
                try dirty_entries.append(gpa, .{
                    .index = @intCast(i),
                    .region = r,
                    .distance2 = d2,
                });
            } else {
                failed += 1;
            }
        }

        // Copy entries that differ between src and dst to keep them in sync.
        for (dirty_entries.items) |entry| {
            const index: usize = @intCast(entry.index);
            src_reg[index] = entry.region;
            src_dist[index] = entry.distance2;
        }

        if (failed == stack.items.len) break;

        if (level > 0) {
            iter += 1;
            if (iter >= max_iter) break;
        }
    }
}

/// Clears `stacks` and puts each unassigned walkable span in the stack of its
/// distance band below `start_level`, 2^`log_levels_per_stack` levels per
/// stack; spans above `start_level` go to the first stack, spans below the
/// last band to none.
fn sortCellsByLevel(
    gpa: Allocator,
    start_level: u16,
    chf: *const CompactHeightfield,
    src_reg: []const u16,
    stacks: []std.ArrayList(LevelStackEntry),
    log_levels_per_stack: u4,
) Allocator.Error!void {
    const w = chf.width;
    const h = chf.height;
    const start = start_level >> log_levels_per_stack;

    for (stacks) |*stack| stack.clearRetainingCapacity();

    // Put all cells in the level range into the appropriate stacks.
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];
            const first: usize = c.index;
            for (first..first + c.count) |i| {
                if (chf.areas[i] == null_area or src_reg[i] != 0) continue;

                const level: i32 = chf.dist[i] >> log_levels_per_stack;
                var s_id: i32 = @as(i32, start) - level;
                if (s_id >= @as(i32, @intCast(stacks.len))) continue;
                if (s_id < 0) s_id = 0;

                try stacks[@intCast(s_id)].append(gpa, .{ .x = x, .y = y, .index = @intCast(i) });
            }
        }
    }
}

/// Appends the entries of `src_stack` still without a region to `dst_stack`.
fn appendStacks(
    gpa: Allocator,
    src_stack: []const LevelStackEntry,
    dst_stack: *std.ArrayList(LevelStackEntry),
    src_reg: []const u16,
) Allocator.Error!void {
    for (src_stack) |entry| {
        const i = entry.index;
        if (i < 0 or src_reg[@intCast(i)] != 0) continue;
        try dst_stack.append(gpa, entry);
    }
}

/// A region while regions are merged and filtered.
const Region = struct {
    /// Number of spans belonging to this region.
    span_count: i32,
    /// The id the region's spans get; merged and removed regions change it.
    id: u16,
    area_type: u8,
    remap: bool,
    visited: bool,
    overlap: bool,
    connects_to_border: bool,
    ymin: u16,
    ymax: u16,
    /// The ids of the neighbouring regions around the region's outline, in
    /// order; 0 where the outline borders no region.
    connections: std.ArrayList(i32),
    /// The ids of the regions above or below the region's spans.
    floors: std.ArrayList(i32),

    fn init(id: u16) Region {
        return .{
            .span_count = 0,
            .id = id,
            .area_type = 0,
            .remap = false,
            .visited = false,
            .overlap = false,
            .connects_to_border = false,
            .ymin = 0xffff,
            .ymax = 0,
            .connections = .empty,
            .floors = .empty,
        };
    }
};

fn deinitRegions(gpa: Allocator, regions: []Region) void {
    for (regions) |*reg| {
        reg.connections.deinit(gpa);
        reg.floors.deinit(gpa);
    }
    gpa.free(regions);
}

/// Removes repeated neighbours next to each other in `reg`'s outline,
/// keeping at least one.
fn removeAdjacentNeighbours(reg: *Region) void {
    const connections = &reg.connections;
    var i: usize = 0;
    while (i < connections.items.len and connections.items.len > 1) {
        const ni = (i + 1) % connections.items.len;
        if (connections.items[i] == connections.items[ni]) {
            // Remove duplicate
            _ = connections.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn replaceNeighbour(reg: *Region, old_id: u16, new_id: u16) void {
    var nei_changed = false;
    for (reg.connections.items) |*connection| {
        if (connection.* == old_id) {
            connection.* = new_id;
            nei_changed = true;
        }
    }
    for (reg.floors.items) |*floor| {
        if (floor.* == old_id) floor.* = new_id;
    }
    if (nei_changed) removeAdjacentNeighbours(reg);
}

fn canMergeWithRegion(rega: *const Region, regb: *const Region) bool {
    if (rega.area_type != regb.area_type) return false;
    var n: i32 = 0;
    for (rega.connections.items) |connection| {
        if (connection == regb.id) n += 1;
    }
    if (n > 1) return false;
    for (rega.floors.items) |floor| {
        if (floor == regb.id) return false;
    }
    return true;
}

fn addUniqueFloorRegion(gpa: Allocator, reg: *Region, n: i32) Allocator.Error!void {
    for (reg.floors.items) |floor| {
        if (floor == n) return;
    }
    try reg.floors.append(gpa, n);
}

/// Merges `regb` into `rega`, joining their outlines where they touch.
/// Returns false, changing nothing, if they do not touch.
fn mergeRegions(gpa: Allocator, rega: *Region, regb: *Region) Allocator.Error!bool {
    const aid = rega.id;
    const bid = regb.id;

    // Duplicate current neighbourhood.
    const acon = try gpa.dupe(i32, rega.connections.items);
    defer gpa.free(acon);
    const bcon = &regb.connections;

    // Find insertion point on A.
    const insa = std.mem.findScalar(i32, acon, bid) orelse return false;

    // Find insertion point on B.
    const insb = std.mem.findScalar(i32, bcon.items, aid) orelse return false;

    // Merge neighbours.
    rega.connections.clearRetainingCapacity();
    {
        const ni = acon.len;
        var i: usize = 0;
        while (i + 1 < ni) : (i += 1) {
            try rega.connections.append(gpa, acon[(insa + 1 + i) % ni]);
        }
    }
    {
        const ni = bcon.items.len;
        var i: usize = 0;
        while (i + 1 < ni) : (i += 1) {
            try rega.connections.append(gpa, bcon.items[(insb + 1 + i) % ni]);
        }
    }

    removeAdjacentNeighbours(rega);

    for (regb.floors.items) |floor| try addUniqueFloorRegion(gpa, rega, floor);
    rega.span_count += regb.span_count;
    regb.span_count = 0;
    regb.connections.clearRetainingCapacity();

    return true;
}

fn isRegionConnectedToBorder(reg: *const Region) bool {
    // Region is connected to border if one of the neighbours is null id.
    for (reg.connections.items) |connection| {
        if (connection == 0) return true;
    }
    return false;
}

/// Whether the neighbour of span `i` of column (x, y) in direction `dir` is
/// missing or in another region.
fn isSolidEdge(
    chf: *const CompactHeightfield,
    src_reg: []const u16,
    x: i32,
    y: i32,
    i: usize,
    dir: u2,
) bool {
    const s = chf.spans[i];
    var r: u16 = 0;
    if (getCon(s, dir) != not_connected) {
        const ax = x + getDirOffsetX(dir);
        const ay = y + getDirOffsetY(dir);
        const ai = spanIndexAt(chf, ax, ay, getCon(s, dir));
        r = src_reg[ai];
    }
    if (r == src_reg[i]) return false;
    return true;
}

/// Walks the outline of the region of span `i` of column (x, y), starting at
/// its edge in direction `dir`, and appends to `cont` the region beyond each
/// stretch of the outline. Removes repeats next to each other after the walk,
/// which can leave `cont` empty.
fn walkContour(
    gpa: Allocator,
    start_x: i32,
    start_y: i32,
    start_i: usize,
    start_dir: u2,
    chf: *const CompactHeightfield,
    src_reg: []const u16,
    cont: *std.ArrayList(i32),
) Allocator.Error!void {
    var x = start_x;
    var y = start_y;
    var i = start_i;
    var dir = start_dir;

    const ss = chf.spans[i];
    var cur_reg: u16 = 0;
    if (getCon(ss, dir) != not_connected) {
        const ax = x + getDirOffsetX(dir);
        const ay = y + getDirOffsetY(dir);
        const ai = spanIndexAt(chf, ax, ay, getCon(ss, dir));
        cur_reg = src_reg[ai];
    }
    try cont.append(gpa, cur_reg);

    var iter: i32 = 1;
    while (iter < 40000) : (iter += 1) {
        const s = chf.spans[i];

        if (isSolidEdge(chf, src_reg, x, y, i, dir)) {
            // Choose the edge corner
            var r: u16 = 0;
            if (getCon(s, dir) != not_connected) {
                const ax = x + getDirOffsetX(dir);
                const ay = y + getDirOffsetY(dir);
                const ai = spanIndexAt(chf, ax, ay, getCon(s, dir));
                r = src_reg[ai];
            }
            if (r != cur_reg) {
                cur_reg = r;
                try cont.append(gpa, cur_reg);
            }

            // Rotate CW
            dir +%= 1;
        } else {
            var ni: i32 = -1;
            const nx = x + getDirOffsetX(dir);
            const ny = y + getDirOffsetY(dir);
            if (getCon(s, dir) != not_connected) {
                const nc = chf.cells[@intCast(nx + ny * chf.width)];
                ni = @as(i32, nc.index) + getCon(s, dir);
            }
            if (ni == -1) {
                // Should not happen.
                return;
            }
            x = nx;
            y = ny;
            i = @intCast(ni);
            // Rotate CCW
            dir +%= 3;
        }

        if (start_i == i and start_dir == dir) break;
    }

    // Remove adjacent duplicates.
    if (cont.items.len > 1) {
        var j: usize = 0;
        while (j < cont.items.len) {
            const nj = (j + 1) % cont.items.len;
            if (cont.items[j] == cont.items[nj]) {
                _ = cont.orderedRemove(j);
            } else {
                j += 1;
            }
        }
    }
}

/// Removes groups of connected regions smaller than `min_region_area` spans
/// that reach no tile border, merges regions of at most `merge_region_size`
/// spans, or not reaching a border, into their smallest mergeable neighbour,
/// and renumbers the regions from 1 in `src_reg`. Regions with spans above
/// one another go to `overlaps`. Returns the largest region id.
fn mergeAndFilterRegions(
    ctx: Context,
    gpa: Allocator,
    min_region_area: i32,
    merge_region_size: i32,
    max_region_id: u16,
    chf: *const CompactHeightfield,
    src_reg: []u16,
    overlaps: *std.ArrayList(i32),
) Allocator.Error!u16 {
    const w = chf.width;
    const h = chf.height;

    const nreg: usize = @as(usize, max_region_id) + 1;
    const regions = gpa.alloc(Region, nreg) catch |err| {
        ctx.log(.err, "mergeAndFilterRegions: Out of memory 'regions' ({d}).", .{nreg});
        return err;
    };
    // Construct regions
    for (regions, 0..) |*reg, i| reg.* = .init(@intCast(i));
    defer deinitRegions(gpa, regions);

    // Find edge of a region and find connections around the contour.
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];
            const first: usize = c.index;
            const end = first + c.count;
            for (first..end) |i| {
                const r = src_reg[i];
                if (r == 0 or r >= nreg) continue;

                const reg = &regions[r];
                reg.span_count += 1;

                // Update floors.
                for (first..end) |j| {
                    if (i == j) continue;
                    const floor_id = src_reg[j];
                    if (floor_id == 0 or floor_id >= nreg) continue;
                    if (floor_id == r) reg.overlap = true;
                    try addUniqueFloorRegion(gpa, reg, floor_id);
                }

                // Have found contour
                if (reg.connections.items.len > 0) continue;

                reg.area_type = chf.areas[i];

                // Check if this cell is next to a border.
                const ndir: ?u2 = for (directions) |dir| {
                    if (isSolidEdge(chf, src_reg, x, y, i, dir)) break dir;
                } else null;

                if (ndir) |dir| {
                    // The cell is at border.
                    // Walk around the contour to find all the neighbours.
                    try walkContour(gpa, x, y, i, dir, chf, src_reg, &reg.connections);
                }
            }
        }
    }

    // Remove too small regions.
    var stack: std.ArrayList(i32) = .empty;
    defer stack.deinit(gpa);
    var trace: std.ArrayList(i32) = .empty;
    defer trace.deinit(gpa);
    for (regions, 0..) |*reg, i| {
        if (reg.id == 0 or (reg.id & border_reg) != 0) continue;
        if (reg.span_count == 0) continue;
        if (reg.visited) continue;

        // Count the total size of all the connected regions.
        // Also keep track of the regions connects to a tile border.
        var connects_to_border = false;
        var span_count: i32 = 0;
        stack.clearRetainingCapacity();
        trace.clearRetainingCapacity();

        reg.visited = true;
        try stack.append(gpa, @intCast(i));

        while (stack.pop()) |ri| {
            const creg = &regions[@intCast(ri)];

            span_count += creg.span_count;
            try trace.append(gpa, ri);

            for (creg.connections.items) |connection| {
                if ((connection & border_reg) != 0) {
                    connects_to_border = true;
                    continue;
                }
                const neireg = &regions[@intCast(connection)];
                if (neireg.visited) continue;
                if (neireg.id == 0 or (neireg.id & border_reg) != 0) continue;
                // Visit
                try stack.append(gpa, neireg.id);
                neireg.visited = true;
            }
        }

        // If the accumulated regions size is too small, remove it.
        // Do not remove areas which connect to tile borders
        // as their size cannot be estimated correctly and removing them
        // can potentially remove necessary areas.
        if (span_count < min_region_area and !connects_to_border) {
            // Kill all visited regions.
            for (trace.items) |t| {
                regions[@intCast(t)].span_count = 0;
                regions[@intCast(t)].id = 0;
            }
        }
    }

    // Merge too small regions to neighbour regions.
    while (true) {
        var merge_count: i32 = 0;
        for (regions) |*reg| {
            if (reg.id == 0 or (reg.id & border_reg) != 0) continue;
            if (reg.overlap) continue;
            if (reg.span_count == 0) continue;

            // Check to see if the region should be merged.
            if (reg.span_count > merge_region_size and isRegionConnectedToBorder(reg)) continue;

            // Small region with more than 1 connection.
            // Or region which is not connected to a border at all.
            // Find smallest neighbour region that connects to this one.
            var smallest: i32 = 0xfffffff;
            var merge_id = reg.id;
            for (reg.connections.items) |connection| {
                if ((connection & border_reg) != 0) continue;
                const mreg = &regions[@intCast(connection)];
                if (mreg.id == 0 or (mreg.id & border_reg) != 0 or mreg.overlap) continue;
                if (mreg.span_count < smallest and
                    canMergeWithRegion(reg, mreg) and
                    canMergeWithRegion(mreg, reg))
                {
                    smallest = mreg.span_count;
                    merge_id = mreg.id;
                }
            }
            // Found new id.
            if (merge_id != reg.id) {
                const old_id = reg.id;
                const target = &regions[merge_id];

                // Merge neighbours.
                if (try mergeRegions(gpa, target, reg)) {
                    // Fixup regions pointing to current region.
                    for (regions) |*other| {
                        if (other.id == 0 or (other.id & border_reg) != 0) continue;
                        // If another region was already merged into current region
                        // change the nid of the previous region too.
                        if (other.id == old_id) other.id = merge_id;
                        // Replace the current region with the new one if the
                        // current regions is neighbour.
                        replaceNeighbour(other, old_id, merge_id);
                    }
                    merge_count += 1;
                }
            }
        }
        if (merge_count <= 0) break;
    }

    // Compress region Ids.
    for (regions) |*reg| {
        reg.remap = false;
        // Skip nil regions.
        if (reg.id == 0) continue;
        // Skip external regions.
        if ((reg.id & border_reg) != 0) continue;
        reg.remap = true;
    }

    var reg_id_gen: u16 = 0;
    for (regions, 0..) |*reg, i| {
        if (!reg.remap) continue;
        const old_id = reg.id;
        reg_id_gen +%= 1;
        const new_id = reg_id_gen;
        for (regions[i..]) |*other| {
            if (other.id == old_id) {
                other.id = new_id;
                other.remap = false;
            }
        }
    }

    // Remap regions.
    for (src_reg) |*r| {
        if ((r.* & border_reg) == 0) r.* = regions[r.*].id;
    }

    // Return regions that we found to be overlapping.
    for (regions) |*reg| {
        if (reg.overlap) try overlaps.append(gpa, reg.id);
    }

    return reg_id_gen;
}

fn addUniqueConnection(gpa: Allocator, reg: *Region, n: i32) Allocator.Error!void {
    for (reg.connections.items) |connection| {
        if (connection == n) return;
    }
    try reg.connections.append(gpa, n);
}

/// Merges neighbouring monotone regions of one area into layers whose spans
/// never lie above one another, removes layers smaller than
/// `min_region_area` spans that reach no tile border, and renumbers the
/// layers from 1 in `src_reg`. Returns the largest region id.
fn mergeAndFilterLayerRegions(
    ctx: Context,
    gpa: Allocator,
    min_region_area: i32,
    max_region_id: u16,
    chf: *const CompactHeightfield,
    src_reg: []u16,
) Allocator.Error!u16 {
    const w = chf.width;
    const h = chf.height;

    const nreg: usize = @as(usize, max_region_id) + 1;

    // Construct regions
    const regions = gpa.alloc(Region, nreg) catch |err| {
        ctx.log(.err, "mergeAndFilterLayerRegions: Out of memory 'regions' ({d}).", .{nreg});
        return err;
    };
    for (regions, 0..) |*reg, i| reg.* = .init(@intCast(i));
    defer deinitRegions(gpa, regions);

    // Find region neighbours and overlapping regions.
    var lregs: std.ArrayList(i32) = .empty;
    defer lregs.deinit(gpa);
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];

            lregs.clearRetainingCapacity();

            const first: usize = c.index;
            for (first..first + c.count) |i| {
                const s = chf.spans[i];
                const area = chf.areas[i];
                const ri = src_reg[i];
                if (ri == 0 or ri >= nreg) continue;
                const reg = &regions[ri];

                reg.span_count += 1;
                reg.ymin = @min(reg.ymin, s.y);
                reg.ymax = @max(reg.ymax, s.y);
                // After the bounds: the compiler may read `ymax` with a wider
                // load over `area_type`, which would wait for this store.
                reg.area_type = area;

                // Collect all region layers.
                try lregs.append(gpa, ri);

                // Update neighbours
                for (directions) |dir| {
                    if (getCon(s, dir) != not_connected) {
                        const ax = x + getDirOffsetX(dir);
                        const ay = y + getDirOffsetY(dir);
                        const ai = spanIndexAt(chf, ax, ay, getCon(s, dir));
                        const rai = src_reg[ai];
                        if (rai > 0 and rai < nreg and rai != ri) {
                            try addUniqueConnection(gpa, reg, rai);
                        }
                        if ((rai & border_reg) != 0) reg.connects_to_border = true;
                    }
                }
            }

            // Update overlapping regions.
            var i: usize = 0;
            while (i + 1 < lregs.items.len) : (i += 1) {
                var j = i + 1;
                while (j < lregs.items.len) : (j += 1) {
                    if (lregs.items[i] != lregs.items[j]) {
                        const region_i = &regions[@intCast(lregs.items[i])];
                        const region_j = &regions[@intCast(lregs.items[j])];
                        try addUniqueFloorRegion(gpa, region_i, lregs.items[j]);
                        try addUniqueFloorRegion(gpa, region_j, lregs.items[i]);
                    }
                }
            }
        }
    }

    // Create 2D layers from regions.
    var layer_id: u16 = 1;

    for (regions) |*reg| reg.id = 0;

    // Merge montone regions to create non-overlapping areas.
    var stack: std.ArrayList(i32) = .empty;
    defer stack.deinit(gpa);
    for (regions[1..], 1..) |*root, i| {
        // Skip already visited.
        if (root.id != 0) continue;

        // Start search.
        root.id = layer_id;

        stack.clearRetainingCapacity();
        try stack.append(gpa, @intCast(i));

        while (stack.items.len > 0) {
            // Pop front
            const reg = &regions[@intCast(stack.items[0])];
            _ = stack.orderedRemove(0);

            for (reg.connections.items) |nei| {
                const regn = &regions[@intCast(nei)];
                // Skip already visited.
                if (regn.id != 0) continue;
                // Skip if different area type, do not connect regions with different area type.
                if (reg.area_type != regn.area_type) continue;
                // Skip if the neighbour is overlapping root region.
                const overlap = std.mem.findScalar(i32, root.floors.items, nei) != null;
                if (overlap) continue;

                // Deepen
                try stack.append(gpa, nei);

                // Mark layer id
                regn.id = layer_id;
                // Merge current layers to root.
                for (regn.floors.items) |floor| try addUniqueFloorRegion(gpa, root, floor);
                root.ymin = @min(root.ymin, regn.ymin);
                root.ymax = @max(root.ymax, regn.ymax);
                root.span_count += regn.span_count;
                regn.span_count = 0;
                root.connects_to_border = root.connects_to_border or regn.connects_to_border;
            }
        }

        layer_id +%= 1;
    }

    // Remove small regions
    for (regions) |*reg| {
        if (reg.span_count > 0 and reg.span_count < min_region_area and !reg.connects_to_border) {
            const reg_id = reg.id;
            for (regions) |*other| {
                if (other.id == reg_id) other.id = 0;
            }
        }
    }

    // Compress region Ids.
    for (regions) |*reg| {
        reg.remap = false;
        // Skip nil regions.
        if (reg.id == 0) continue;
        // Skip external regions.
        if ((reg.id & border_reg) != 0) continue;
        reg.remap = true;
    }

    var reg_id_gen: u16 = 0;
    for (regions, 0..) |*reg, i| {
        if (!reg.remap) continue;
        const old_id = reg.id;
        reg_id_gen +%= 1;
        const new_id = reg_id_gen;
        for (regions[i..]) |*other| {
            if (other.id == old_id) {
                other.id = new_id;
                other.remap = false;
            }
        }
    }

    // Remap regions.
    for (src_reg) |*r| {
        if ((r.* & border_reg) == 0) r.* = regions[r.*].id;
    }

    return reg_id_gen;
}

/// Whether `buildDistanceField` takes its fast passes on `chf` (see
/// `distances`): whether the spans of the columns that have any follow one
/// another in the columns' order, and every connection names a span of its
/// neighbour column inside the field. True for every field that
/// `buildCompactHeightfield` builds with at most 255 spans a column; a
/// caller that builds or edits fields itself can check its own with it.
pub fn layoutAsBuilt(chf: *const CompactHeightfield) bool {
    const v: DistanceView = .of(chf);
    var next_span: usize = no_span;
    for (0..v.height) |y| for (0..v.width) |x| {
        const col = y * v.width + x;
        const c = v.cells[col];
        if (c.count == 0) continue;
        if (next_span != no_span and c.index != next_span) return false;
        next_span = @as(usize, c.index) + c.count;
        const allowed = allowedLayers(v, .of(v, col, true), x, y);
        for (c.index..@as(usize, c.index) + c.count) |i| {
            if (connectionsOutside(v.spans[i].con, allowed) != 0) return false;
        }
    };
    return true;
}

/// Builds `chf.dist`, each span's distance to the nearest border or area
/// change, blurred, and `chf.max_distance`, the largest before the blur.
/// `buildRegions` needs it. Replaces an existing distance field.
///
/// On a field not laid out as `buildCompactHeightfield` lays it out (see
/// `distances`), the distances are redone in the original's order once the
/// sweep up finds that, which costs up to one more pass over the field.
pub fn buildDistanceField(
    ctx: Context,
    gpa: Allocator,
    chf: *CompactHeightfield,
) Allocator.Error!void {
    ctx.startTimer(.build_distancefield);
    defer ctx.stopTimer(.build_distancefield);

    gpa.free(chf.dist);
    chf.dist = &.{};

    const span_count: usize = @intCast(chf.span_count);
    const src = gpa.alloc(u16, span_count) catch |err| {
        ctx.log(.err, "rcBuildDistanceField: Out of memory 'src' ({d}).", .{chf.span_count});
        return err;
    };
    const dst = gpa.alloc(u16, span_count) catch |err| {
        ctx.log(.err, "rcBuildDistanceField: Out of memory 'dst' ({d}).", .{chf.span_count});
        gpa.free(src);
        return err;
    };
    // The blur writes only spans in a column; any other stays 0.
    @memset(dst, 0);

    {
        ctx.startTimer(.build_distancefield_dist);
        defer ctx.stopTimer(.build_distancefield_dist);

        chf.max_distance = distances(chf, src) orelse distancesInOrder(chf, src);
    }

    {
        ctx.startTimer(.build_distancefield_blur);
        defer ctx.stopTimer(.build_distancefield_blur);

        // Blur
        blur(chf, src, dst);

        // Store distance.
        chf.dist = dst;
    }

    gpa.free(src);
}

/// Sets the region of the walkable spans in columns [minx, maxx) by
/// [miny, maxy) to `reg_id`.
fn paintRectRegion(
    minx: i32,
    maxx: i32,
    miny: i32,
    maxy: i32,
    reg_id: u16,
    chf: *const CompactHeightfield,
    src_reg: []u16,
) void {
    const w = chf.width;
    var y = miny;
    while (y < maxy) : (y += 1) {
        var x = minx;
        while (x < maxx) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];
            const first: usize = c.index;
            for (first..first + c.count) |i| {
                if (chf.areas[i] != null_area) src_reg[i] = reg_id;
            }
        }
    }
}

const null_nei: u16 = 0xffff;

/// A run of spans connected along x in one row of a monotone partition.
const SweepSpan = struct {
    /// Row id.
    rid: u16,
    /// Region id.
    id: u16,
    /// Number of samples.
    ns: u16,
    /// Neighbour id.
    nei: u16,
};

const zero_sweep: SweepSpan = .{ .rid = 0, .id = 0, .ns = 0, .nei = 0 };

/// Paints the four border strips of `border_size` columns with border
/// regions from `id` on; returns the next id.
fn paintBorderRegions(
    chf: *const CompactHeightfield,
    border_size: i32,
    first_id: u16,
    src_reg: []u16,
) u16 {
    const w = chf.width;
    const h = chf.height;
    var id = first_id;
    // Make sure border will not overflow.
    const bw = @min(w, border_size);
    const bh = @min(h, border_size);
    // Paint regions
    paintRectRegion(0, bw, 0, h, id | border_reg, chf, src_reg);
    id += 1;
    paintRectRegion(w - bw, w, 0, h, id | border_reg, chf, src_reg);
    id += 1;
    paintRectRegion(0, w, 0, bh, id | border_reg, chf, src_reg);
    id += 1;
    paintRectRegion(0, w, h - bh, h, id | border_reg, chf, src_reg);
    id += 1;
    return id;
}

/// Gives the walkable spans inside the border monotone regions, a row at a
/// time: spans connected along x form a sweep, and a sweep continues the
/// region of the row before when that region is its only neighbour there
/// and no other sweep touches it; any other sweep gets a new id from
/// `first_id` on. Returns the next unused id. `sweeps` grows when a row has
/// more sweeps than it holds.
fn partitionMonotone(
    gpa: Allocator,
    chf: *const CompactHeightfield,
    border_size: i32,
    first_id: u16,
    src_reg: []u16,
    sweeps: *std.ArrayList(SweepSpan),
) Allocator.Error!u16 {
    const w = chf.width;
    const h = chf.height;
    var id = first_id;

    var prev: std.ArrayList(i32) = .empty;
    defer prev.deinit(gpa);

    // Sweep one line at a time.
    var y = border_size;
    while (y < h - border_size) : (y += 1) {
        // Collect spans from this row.
        try prev.resize(gpa, @as(usize, id) + 1);
        @memset(prev.items, 0);
        var rid: u16 = 1;

        var x = border_size;
        while (x < w - border_size) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];
            const first: usize = c.index;
            for (first..first + c.count) |i| {
                const s = chf.spans[i];
                if (chf.areas[i] == null_area) continue;

                // -x
                var previd: u16 = 0;
                if (getCon(s, 0) != not_connected) {
                    const ax = x + getDirOffsetX(0);
                    const ay = y + getDirOffsetY(0);
                    const ai = spanIndexAt(chf, ax, ay, getCon(s, 0));
                    if ((src_reg[ai] & border_reg) == 0 and chf.areas[i] == chf.areas[ai]) {
                        previd = src_reg[ai];
                    }
                }

                if (previd == 0) {
                    previd = rid;
                    rid +%= 1;
                    // A row can have more sweeps than the field's longer
                    // side, the size the sweeps start with.
                    if (previd >= sweeps.items.len) {
                        const missing = @as(usize, previd) + 1 - sweeps.items.len;
                        try sweeps.appendNTimes(gpa, zero_sweep, missing);
                    }
                    const sweep = &sweeps.items[previd];
                    sweep.rid = previd;
                    sweep.ns = 0;
                    sweep.nei = 0;
                }

                // -y
                if (getCon(s, 3) != not_connected) {
                    const ax = x + getDirOffsetX(3);
                    const ay = y + getDirOffsetY(3);
                    const ai = spanIndexAt(chf, ax, ay, getCon(s, 3));
                    if (src_reg[ai] != 0 and (src_reg[ai] & border_reg) == 0 and
                        chf.areas[i] == chf.areas[ai])
                    {
                        const nr = src_reg[ai];
                        const sweep = &sweeps.items[previd];
                        if (sweep.nei == 0 or sweep.nei == nr) {
                            sweep.nei = nr;
                            sweep.ns +%= 1;
                            prev.items[nr] += 1;
                        } else {
                            sweep.nei = null_nei;
                        }
                    }
                }

                src_reg[i] = previd;
            }
        }

        // Create unique ID.
        {
            var i: usize = 1;
            while (i < rid) : (i += 1) {
                const sweep = &sweeps.items[i];
                if (sweep.nei != null_nei and sweep.nei != 0 and
                    prev.items[sweep.nei] == sweep.ns)
                {
                    sweep.id = sweep.nei;
                } else {
                    sweep.id = id;
                    id +%= 1;
                }
            }
        }

        // Remap IDs
        x = border_size;
        while (x < w - border_size) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];
            const first: usize = c.index;
            for (first..first + c.count) |i| {
                if (src_reg[i] > 0 and src_reg[i] < rid) src_reg[i] = sweeps.items[src_reg[i]].id;
            }
        }
    }

    return id;
}

/// Splits the walkable spans into regions by monotone partitioning: a sweep
/// along each row, so regions never wrap around holes and need no distance
/// field, though they tend to be long and thin. Spans within `border_size`
/// of the field's edge get border regions. Groups of connected regions
/// smaller than `min_region_area` spans that reach no tile border are
/// removed, and regions of at most `merge_region_area` spans merge into a
/// neighbour where they can. Sets each span's `reg`, `chf.max_regions` and
/// `chf.border_size`.
pub fn buildRegionsMonotone(
    ctx: Context,
    gpa: Allocator,
    chf: *CompactHeightfield,
    border_size: i32,
    min_region_area: i32,
    merge_region_area: i32,
) BuildRegionsError!void {
    ctx.startTimer(.build_regions);
    defer ctx.stopTimer(.build_regions);

    var id: u16 = 1;

    const src_reg = gpa.alloc(u16, @intCast(chf.span_count)) catch |err| {
        ctx.log(.err, "rcBuildRegionsMonotone: Out of memory 'src' ({d}).", .{chf.span_count});
        return err;
    };
    defer gpa.free(src_reg);
    @memset(src_reg, 0);

    const nsweeps = @max(chf.width, chf.height);
    var sweeps: std.ArrayList(SweepSpan) = .empty;
    defer sweeps.deinit(gpa);
    sweeps.appendNTimes(gpa, zero_sweep, @intCast(nsweeps)) catch |err| {
        ctx.log(.err, "rcBuildRegionsMonotone: Out of memory 'sweeps' ({d}).", .{nsweeps});
        return err;
    };

    // Mark border regions.
    if (border_size > 0) id = paintBorderRegions(chf, border_size, id, src_reg);

    chf.border_size = border_size;

    id = try partitionMonotone(gpa, chf, border_size, id, src_reg, &sweeps);

    {
        ctx.startTimer(.build_regions_filter);
        defer ctx.stopTimer(.build_regions_filter);

        // Merge regions and filter out small regions.
        var overlaps: std.ArrayList(i32) = .empty;
        defer overlaps.deinit(gpa);
        chf.max_regions = id;
        chf.max_regions = try mergeAndFilterRegions(
            ctx,
            gpa,
            min_region_area,
            merge_region_area,
            chf.max_regions,
            chf,
            src_reg,
            &overlaps,
        );

        // Monotone partitioning does not generate overlapping regions.
    }

    // Store the result out.
    for (chf.spans, src_reg) |*span, reg| span.reg = reg;
}

/// Splits the walkable spans into regions by watershed over the distance
/// field, which `buildDistanceField` must build first: regions grow from the
/// spans farthest from any border, giving the roundest regions. Spans within
/// `border_size` of the field's edge get border regions. Groups of connected
/// regions smaller than `min_region_area` spans that reach no tile border
/// are removed, and regions of at most `merge_region_area` spans merge into a
/// neighbour where they can. Sets each span's `reg`, `chf.max_regions` and
/// `chf.border_size`.
pub fn buildRegions(
    ctx: Context,
    gpa: Allocator,
    chf: *CompactHeightfield,
    border_size: i32,
    min_region_area: i32,
    merge_region_area: i32,
) BuildRegionsError!void {
    assert(chf.dist.len == chf.spans.len);

    ctx.startTimer(.build_regions);
    defer ctx.stopTimer(.build_regions);

    const span_count: usize = @intCast(chf.span_count);
    const buf = gpa.alloc(u16, span_count * 2) catch |err| {
        ctx.log(.err, "rcBuildRegions: Out of memory 'tmp' ({d}).", .{chf.span_count * 4});
        return err;
    };
    defer gpa.free(buf);

    // Not stopped when the build fails partway.
    ctx.startTimer(.build_regions_watershed);

    const log_nb_stacks = 3;
    const nb_stacks = 1 << log_nb_stacks;
    var lvl_stacks: [nb_stacks]std.ArrayList(LevelStackEntry) = @splat(.empty);
    defer {
        for (&lvl_stacks) |*lvl_stack| lvl_stack.deinit(gpa);
    }
    for (&lvl_stacks) |*lvl_stack| try lvl_stack.ensureTotalCapacity(gpa, 256);

    var stack: std.ArrayList(LevelStackEntry) = .empty;
    defer stack.deinit(gpa);
    try stack.ensureTotalCapacity(gpa, 256);

    const src_reg = buf[0..span_count];
    const src_dist = buf[span_count..];

    @memset(src_reg, 0);
    @memset(src_dist, 0);

    var region_id: u16 = 1;
    var level: u16 = @truncate((@as(u32, chf.max_distance) + 1) & ~@as(u32, 1));

    // How far the watershed "overflows" and simplifies the regions.
    const expand_iters = 8;

    if (border_size > 0) region_id = paintBorderRegions(chf, border_size, region_id, src_reg);

    chf.border_size = border_size;

    var s_id: i32 = -1;
    while (level > 0) {
        level = if (level >= 2) level - 2 else 0;
        s_id = (s_id + 1) & (nb_stacks - 1);
        const lvl_stack = &lvl_stacks[@intCast(s_id)];

        if (s_id == 0) {
            try sortCellsByLevel(gpa, level, chf, src_reg, &lvl_stacks, 1);
        } else {
            // Copy left overs from last level.
            const last = lvl_stacks[@intCast(s_id - 1)].items;
            try appendStacks(gpa, last, lvl_stack, src_reg);
        }

        {
            ctx.startTimer(.build_regions_expand);
            defer ctx.stopTimer(.build_regions_expand);

            // Expand current regions until no empty connected cells found.
            try expandRegions(gpa, expand_iters, level, chf, src_reg, src_dist, lvl_stack, false);
        }

        {
            ctx.startTimer(.build_regions_flood);
            defer ctx.stopTimer(.build_regions_flood);

            // Mark new regions with IDs.
            var j: usize = 0;
            while (j < lvl_stack.items.len) : (j += 1) {
                const current = lvl_stack.items[j];
                if (current.index < 0) continue;
                const i: usize = @intCast(current.index);
                if (src_reg[i] != 0) continue;
                const flooded = try floodRegion(
                    gpa,
                    current.x,
                    current.y,
                    i,
                    level,
                    region_id,
                    chf,
                    src_reg,
                    src_dist,
                    &stack,
                );
                if (flooded) {
                    if (region_id == 0xffff) {
                        ctx.log(.err, "rcBuildRegions: Region ID overflow", .{});
                        return error.RegionIdOverflow;
                    }
                    region_id += 1;
                }
            }
        }
    }

    // Expand current regions until no empty connected cells found.
    try expandRegions(gpa, expand_iters * 8, 0, chf, src_reg, src_dist, &stack, true);

    ctx.stopTimer(.build_regions_watershed);

    {
        ctx.startTimer(.build_regions_filter);
        defer ctx.stopTimer(.build_regions_filter);

        // Merge regions and filter out small regions.
        var overlaps: std.ArrayList(i32) = .empty;
        defer overlaps.deinit(gpa);
        chf.max_regions = region_id;
        chf.max_regions = try mergeAndFilterRegions(
            ctx,
            gpa,
            min_region_area,
            merge_region_area,
            chf.max_regions,
            chf,
            src_reg,
            &overlaps,
        );

        // If overlapping regions were found during merging, split those regions.
        if (overlaps.items.len > 0) {
            ctx.log(.err, "rcBuildRegions: {d} overlapping regions.", .{overlaps.items.len});
        }
    }

    // Write the result out.
    for (chf.spans, src_reg) |*span, reg| span.reg = reg;
}

/// Splits the walkable spans into regions that never lie above one another,
/// for tiles built in layers: monotone regions of one area merged into
/// non-overlapping layers. Spans within `border_size` of the field's edge get
/// border regions, and layers smaller than `min_region_area` spans that reach
/// no tile border are removed. Sets each span's `reg`, `chf.max_regions` and
/// `chf.border_size`.
pub fn buildLayerRegions(
    ctx: Context,
    gpa: Allocator,
    chf: *CompactHeightfield,
    border_size: i32,
    min_region_area: i32,
) BuildRegionsError!void {
    ctx.startTimer(.build_regions);
    defer ctx.stopTimer(.build_regions);

    var id: u16 = 1;

    const src_reg = gpa.alloc(u16, @intCast(chf.span_count)) catch |err| {
        ctx.log(.err, "rcBuildLayerRegions: Out of memory 'src' ({d}).", .{chf.span_count});
        return err;
    };
    defer gpa.free(src_reg);
    @memset(src_reg, 0);

    const nsweeps = @max(chf.width, chf.height);
    var sweeps: std.ArrayList(SweepSpan) = .empty;
    defer sweeps.deinit(gpa);
    sweeps.appendNTimes(gpa, zero_sweep, @intCast(nsweeps)) catch |err| {
        ctx.log(.err, "rcBuildLayerRegions: Out of memory 'sweeps' ({d}).", .{nsweeps});
        return err;
    };

    // Mark border regions.
    if (border_size > 0) id = paintBorderRegions(chf, border_size, id, src_reg);

    chf.border_size = border_size;

    id = try partitionMonotone(gpa, chf, border_size, id, src_reg, &sweeps);

    {
        ctx.startTimer(.build_regions_filter);
        defer ctx.stopTimer(.build_regions_filter);

        // Merge monotone regions to layers and remove small regions.
        chf.max_regions = id;
        chf.max_regions = try mergeAndFilterLayerRegions(
            ctx,
            gpa,
            min_region_area,
            chf.max_regions,
            chf,
            src_reg,
        );
    }

    // Store the result out.
    for (chf.spans, src_reg) |*span, reg| span.reg = reg;
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "removing repeated neighbours keeps one and wraps around" {
    const gpa = testing.allocator;
    var reg: Region = .init(1);
    defer reg.connections.deinit(gpa);
    try reg.connections.appendSlice(gpa, &.{ 2, 2, 3, 3, 2 });
    removeAdjacentNeighbours(&reg);
    try testing.expectEqualSlices(i32, &.{ 2, 3 }, reg.connections.items);

    reg.connections.clearRetainingCapacity();
    try reg.connections.appendSlice(gpa, &.{ 4, 4, 4 });
    removeAdjacentNeighbours(&reg);
    try testing.expectEqualSlices(i32, &.{4}, reg.connections.items);
}

/// A random field for the tests below: `layers` spans a column at most,
/// with connections that name a span of the neighbour column, or now and
/// then (`odd` per thousand) one past it, one out of the field's west or
/// east edge, or a column that shares the spans before it.
fn testField(gpa: Allocator, random: std.Random, w: usize, h: usize, layers: u8, odd: u32) !CompactHeightfield {
    const cells = try gpa.alloc(recast.CompactCell, w * h);
    errdefer gpa.free(cells);
    var count: usize = 0;
    for (cells) |*c| {
        const n = random.uintAtMost(u8, layers);
        var index = count;
        if (n > 0 and count > 0 and random.uintLessThan(u32, 1000) < odd) index -= 1;
        c.* = .{ .index = @intCast(index), .count = n };
        count = index + n;
    }
    const spans = try gpa.alloc(recast.CompactSpan, count + 64);
    errdefer gpa.free(spans);
    const areas = try gpa.alloc(u8, count + 64);
    errdefer gpa.free(areas);
    for (spans) |*sp| sp.* = .{ .y = 0, .reg = 0, .con = 0xffffff, .h = 0 };
    for (areas) |*a| a.* = if (random.uintLessThan(u32, 100) < 3) 2 else 1;
    const steps = [4]isize{ -1, @intCast(w), 1, -@as(isize, @intCast(w)) };
    for (0..h) |y| for (0..w) |x| {
        const col = y * w + x;
        const c = cells[col];
        for (c.index..@as(usize, c.index) + c.count) |i| {
            var con: u32 = 0;
            for (0..4) |d| {
                var k: u32 = 0x3f;
                const n_col = @as(isize, @intCast(col)) + steps[d];
                const inside = switch (d) {
                    0 => x > 0,
                    1 => y + 1 < h,
                    2 => x + 1 < w,
                    else => y > 0,
                };
                const wraps = !inside and (d == 0 or d == 2) and n_col >= 0 and n_col < w * h;
                if ((inside or (wraps and random.uintLessThan(u32, 1000) < odd)) and random.uintLessThan(u32, 100) < 95) {
                    const nc = cells[@intCast(n_col)];
                    if (nc.count > 0) {
                        k = random.uintLessThan(u32, nc.count);
                        if (random.uintLessThan(u32, 1000) < odd) k = @min(nc.count + random.uintLessThan(u32, 3), 62);
                    }
                }
                con |= k << @intCast(d * 6);
            }
            spans[i].con = @intCast(con);
        }
    };
    return .{
        .width = @intCast(w),
        .height = @intCast(h),
        .span_count = @intCast(count),
        .walkable_height = 0,
        .walkable_climb = 0,
        .border_size = 0,
        .max_distance = 0,
        .max_regions = 0,
        .bmin = @splat(0),
        .bmax = @splat(0),
        .cs = 1,
        .ch = 1,
        .cells = cells,
        .spans = spans,
        .dist = &.{},
        .areas = areas,
    };
}

test "the fast distance passes give the original order's distances, or refuse exactly the fields not laid out as built" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0xd157);
    const random = prng.random();
    const sizes = [_][2]usize{ .{ 1, 1 }, .{ 1, 9 }, .{ 9, 1 }, .{ 3, 3 }, .{ 17, 5 }, .{ 18, 6 }, .{ 35, 20 }, .{ 70, 40 } };
    var refused: usize = 0;
    var taken: usize = 0;
    for (0..300) |round| {
        const size = sizes[round % sizes.len];
        const layers: u8 = @intCast(1 + round % 4);
        const odd: u32 = if (round % 3 == 0) 0 else 4;
        var chf = try testField(gpa, random, size[0], size[1], layers, odd);
        defer chf.deinit(gpa);
        const n: usize = @intCast(chf.span_count);
        const fast = try gpa.alloc(u16, n);
        defer gpa.free(fast);
        const in_order = try gpa.alloc(u16, n);
        defer gpa.free(in_order);
        const in_order_max = distancesInOrder(&chf, in_order);
        if (distances(&chf, fast)) |fast_max| {
            taken += 1;
            try std.testing.expect(layoutAsBuilt(&chf));
            try std.testing.expectEqual(in_order_max, fast_max);
            try std.testing.expectEqualSlices(u16, in_order, fast);
        } else {
            refused += 1;
            try std.testing.expect(!layoutAsBuilt(&chf));
        }
        // The blur, against each column blurred on its own.
        const blurred = try gpa.alloc(u16, n);
        defer gpa.free(blurred);
        const plain = try gpa.alloc(u16, n);
        defer gpa.free(plain);
        @memset(blurred, 0);
        @memset(plain, 0);
        blur(&chf, in_order, blurred);
        const v: DistanceView = .of(&chf);
        for (0..v.columns) |col| blurColumn(v, in_order.ptr, plain.ptr, col, true);
        try std.testing.expectEqualSlices(u16, plain, blurred);
    }
    try std.testing.expect(refused > 20 and taken > 20);
}
