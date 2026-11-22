//! Compact heightfields built by hand, not as `buildCompactHeightfield`
//! builds them: connections that name a span past the neighbour column's
//! own, columns that share spans, spans stored out of the columns' order.
//! The original reads only memory inside the field on all of these, and the
//! port must give its output; the distance field takes its fast passes only
//! on fields laid out as `buildCompactHeightfield` lays them out.

const std = @import("std");
const recast = @import("recast");
const upstream = @import("upstream.zig");
const oracle = @import("oracle.zig");
const testing = std.testing;
const gpa = testing.allocator;

const shim_chf_replace = upstream.shim_chf_replace;
const shim_chf_set_max_regions = upstream.shim_chf_set_max_regions;

/// How often, per thousand, `gen` makes a connection name a span past the
/// neighbour column's own (`spill`), a column also hold the span before it
/// (`overlap`), a connection missing (`nc`) and a span another area.
const Mode = struct { spill: u32 = 0, overlap: u32 = 0, nc: u32 = 30, area2: u32 = 20 };

const Field = struct {
    w: i32,
    h: i32,
    cells: []recast.CompactCell,
    spans: []recast.CompactSpan,
    areas: []u8,
};

fn gen(random: std.Random, w: i32, h: i32, mode: Mode) !Field {
    const wu: usize = @intCast(w);
    const hu: usize = @intCast(h);
    const n = wu * hu;
    const cells = try gpa.alloc(recast.CompactCell, n);
    const spans = try gpa.alloc(recast.CompactSpan, n);
    const areas = try gpa.alloc(u8, n);
    for (cells, 0..) |*c, i| c.* = .{ .index = @intCast(i), .count = 1 };
    // Overlapping ranges: a column also holds the span before it.
    for (cells, 0..) |*c, i| {
        if (i > 0 and random.uintLessThan(u32, 1000) < mode.overlap) c.* = .{ .index = @intCast(i - 1), .count = 2 };
    }
    for (areas) |*a| a.* = if (random.uintLessThan(u32, 1000) < mode.area2) 2 else 1;
    const dx = [4]i32{ -1, 0, 1, 0 };
    const dy = [4]i32{ 0, 1, 0, -1 };
    for (0..hu) |y| for (0..wu) |x| {
        const i = x + y * wu;
        var con: u24 = 0;
        for (0..4) |d| {
            var v: u24 = 0x3f;
            const nx = @as(i32, @intCast(x)) + dx[d];
            const ny = @as(i32, @intCast(y)) + dy[d];
            if (nx >= 0 and ny >= 0 and nx < w and ny < h and random.uintLessThan(u32, 1000) >= mode.nc) {
                const ncol: usize = @intCast(nx + ny * w);
                const base: usize = cells[ncol].index;
                v = 0;
                if (random.uintLessThan(u32, 1000) < mode.spill) {
                    const room = @min(0x3e, n - 1 - base);
                    if (room > 0) v = @intCast(1 + random.uintLessThan(usize, room));
                }
            }
            con |= v << @intCast(d * 6);
        }
        spans[i] = .{ .y = 0, .reg = 0, .con = con, .h = 0 };
    };
    // Disconnect any connection that some column holding the span would
    // take out of the field or the spans: those are UB in the original.
    const steps = [4]isize{ -1, w, 1, -w };
    var changed = true;
    while (changed) {
        changed = false;
        var seen: std.AutoHashMapUnmanaged([2]usize, void) = .empty;
        defer seen.deinit(gpa);
        var stack: std.ArrayList([2]usize) = .empty;
        defer stack.deinit(gpa);
        for (cells, 0..) |c, col| for (c.index..@as(usize, c.index) + c.count) |si| {
            if (!(try seen.getOrPut(gpa, .{ col, si })).found_existing) try stack.append(gpa, .{ col, si });
        };
        while (stack.pop()) |p| {
            const col = p[0];
            const si = p[1];
            for (0..4) |d| {
                const v = (spans[si].con >> @intCast(d * 6)) & 0x3f;
                if (v == 0x3f) continue;
                const ncol = @as(isize, @intCast(col)) + steps[d];
                const ok = ncol >= 0 and ncol < @as(isize, @intCast(n)) and
                    @as(usize, cells[@intCast(ncol)].index) + v < n;
                if (!ok) {
                    spans[si].con |= @as(u24, 0x3f) << @intCast(d * 6);
                    changed = true;
                    continue;
                }
                const q: [2]usize = .{ @intCast(ncol), @as(usize, cells[@intCast(ncol)].index) + v };
                if (!(try seen.getOrPut(gpa, q)).found_existing) try stack.append(gpa, q);
            }
        }
    }
    return .{ .w = w, .h = h, .cells = cells, .spans = spans, .areas = areas };
}

fn check(f: Field, contours: bool) !bool {
    var logs = try oracle.Logs.init();
    defer logs.deinit();
    const ctx = logs.port();
    const bmin: [3]f32 = .{ 0, 0, 0 };
    const bmax: [3]f32 = .{ 1, 10, 1 };
    var hf = try recast.Heightfield.init(gpa, 1, 1, &bmin, &bmax, 1, 0.1);
    defer hf.deinit(gpa);
    const ohf = upstream.shim_hf_create(logs.original, 1, 1, &bmin, &bmax, 1, 0.1).?;
    defer upstream.shim_hf_free(ohf);
    var chf = try recast.buildCompactHeightfield(ctx, gpa, 2, 1, &hf);
    defer chf.deinit(gpa);
    const ochf = upstream.shim_chf_build(logs.original, 2, 1, ohf).?;
    defer upstream.shim_chf_free(ochf);
    gpa.free(chf.cells);
    gpa.free(chf.spans);
    gpa.free(chf.areas);
    chf.cells = try gpa.dupe(recast.CompactCell, f.cells);
    chf.spans = try gpa.dupe(recast.CompactSpan, f.spans);
    chf.areas = try gpa.dupe(u8, f.areas);
    chf.width = f.w;
    chf.height = f.h;
    chf.span_count = @intCast(f.spans.len);
    shim_chf_replace(ochf, f.w, f.h, chf.span_count, @ptrCast(f.cells.ptr), @ptrCast(f.spans.ptr), f.areas.ptr);
    try recast.buildDistanceField(ctx, gpa, &chf);
    try testing.expect(upstream.shim_distance_field(logs.original, ochf) != 0);
    oracle.expectSameDump("distance", &chf, ochf) catch return false;
    if (contours) {
        const r = recast.buildRegions(ctx, gpa, &chf, 0, 0, 0);
        const ro = upstream.shim_regions(logs.original, ochf, 0, 0, 0);
        if (oracle.succeeded(r) != (ro != 0)) return false;
        oracle.expectSameDump("regions", &chf, ochf) catch return false;
    }
    return true;
}

fn freeField(f: Field) void {
    gpa.free(f.cells);
    gpa.free(f.spans);
    gpa.free(f.areas);
}

test "hand-built fields of one span a column build the distance field as the original" {
    var prng: std.Random.DefaultPrng = .init(1);
    const random = prng.random();
    const sizes = [_][2]i32{ .{ 1, 1 }, .{ 3, 3 }, .{ 17, 3 }, .{ 18, 3 }, .{ 19, 5 }, .{ 34, 4 }, .{ 40, 40 } };
    var bad: usize = 0;
    for (sizes) |s| for (0..30) |_| {
        const f = try gen(random, s[0], s[1], .{});
        defer freeField(f);
        if (!try check(f, false)) bad += 1;
    };
    try testing.expectEqual(0, bad);
}

test "connections past the neighbour column's spans build the distance field as the original" {
    var prng: std.Random.DefaultPrng = .init(2);
    const random = prng.random();
    const sizes = [_][2]i32{ .{ 3, 3 }, .{ 5, 5 }, .{ 18, 3 }, .{ 40, 40 } };
    var bad: usize = 0;
    var total: usize = 0;
    for (sizes) |s| for (0..50) |_| {
        const f = try gen(random, s[0], s[1], .{ .spill = 50, .nc = 5, .area2 = 5 });
        defer freeField(f);
        total += 1;
        if (!try check(f, false)) bad += 1;
    };
    try testing.expectEqual(@as(usize, 0), bad);
    try testing.expect(total > 0);
}

test "columns that share spans build the distance field as the original" {
    var prng: std.Random.DefaultPrng = .init(3);
    const random = prng.random();
    const sizes = [_][2]i32{ .{ 3, 3 }, .{ 5, 5 }, .{ 18, 3 }, .{ 40, 40 } };
    var bad: usize = 0;
    var total: usize = 0;
    for (sizes) |s| for (0..50) |_| {
        const f = try gen(random, s[0], s[1], .{ .overlap = 30, .nc = 5, .area2 = 5 });
        defer freeField(f);
        total += 1;
        if (!try check(f, false)) bad += 1;
    };
    try testing.expectEqual(@as(usize, 0), bad);
    try testing.expect(total > 0);
}

/// A w x h grid, one span per column, the span of column c at index
/// order[c], every span joined to its neighbours inside the field, area 1.
fn plainGrid(w: usize, h: usize, order: []const usize) !Field {
    const n = w * h;
    const cells = try gpa.alloc(recast.CompactCell, n);
    const spans = try gpa.alloc(recast.CompactSpan, n);
    const areas = try gpa.alloc(u8, n);
    @memset(areas, 1);
    for (cells, 0..) |*c, col| c.* = .{ .index = @intCast(order[col]), .count = 1 };
    for (0..h) |y| for (0..w) |x| {
        var con: u24 = 0;
        if (x == 0) con |= 0x3f << 0;
        if (y + 1 == h) con |= 0x3f << 6;
        if (x + 1 == w) con |= 0x3f << 12;
        if (y == 0) con |= 0x3f << 18;
        spans[order[x + y * w]] = .{ .y = 0, .reg = 0, .con = con, .h = 0 };
    };
    return .{ .w = @intCast(w), .h = @intCast(h), .cells = cells, .spans = spans, .areas = areas };
}

test "a connection to a span of a later column, on the border, marks as the original" {
    var order: [49]usize = undefined;
    for (&order, 0..) |*o, i| o.* = i;
    const f = try plainGrid(7, 7, &order);
    defer freeField(f);
    // The centre (3,3)'s west neighbour, column (2,3) = 23, names layer 25
    // of it: span 48, the corner (6,6), on the border.
    f.spans[24].con = (f.spans[24].con & ~@as(u24, 0x3f)) | 25;
    try testing.expect(try check(f, false));
}

test "a span in two columns, on the border from the first, marks as the original" {
    // Column (3,3) = 24's span stored right after column (6,1) = 13's, and
    // column 13 holds both.
    var order: [49]usize = undefined;
    var k: usize = 0;
    for (0..49) |c| {
        if (c == 24) continue;
        order[c] = k;
        k += 1;
        if (c == 13) {
            order[24] = k;
            k += 1;
        }
    }
    const f = try plainGrid(7, 7, &order);
    defer freeField(f);
    f.cells[13].count = 2;
    // Seen from column 13, the centre's east neighbour is column 14, (0,2),
    // made another area.
    f.areas[order[14]] = 2;
    try testing.expect(try check(f, false));
}

test "rows stored top first blur as the original" {
    const w = 12;
    const h = 9;
    // Rows stored top first: column (x, y) at (h - 1 - y) * w + x.
    var order: [w * h]usize = undefined;
    for (0..h) |y| for (0..w) |x| {
        order[x + y * w] = (h - 1 - y) * w + x;
    };
    const f = try plainGrid(w, h, &order);
    defer freeField(f);
    // Another area at (6,3), so (5,2)'s distance falls in the sweep down.
    f.areas[order[6 + 3 * w]] = 2;
    // (7,4)'s west neighbour, column (6,4), names the span of (4,2).
    const s = order[7 + 4 * w];
    const via = order[6 + 4 * w];
    const t = order[4 + 2 * w];
    f.spans[s].con = (f.spans[s].con & ~@as(u24, 0x3f)) | @as(u24, @intCast(t - via));
    try testing.expect(try check(f, false));
}

fn checkContours(f: Field, max_regions: u16) !bool {
    var logs = try oracle.Logs.init();
    defer logs.deinit();
    const ctx = logs.port();
    const bmin: [3]f32 = .{ 0, 0, 0 };
    const bmax: [3]f32 = .{ 1, 10, 1 };
    var hf = try recast.Heightfield.init(gpa, 1, 1, &bmin, &bmax, 1, 0.1);
    defer hf.deinit(gpa);
    const ohf = upstream.shim_hf_create(logs.original, 1, 1, &bmin, &bmax, 1, 0.1).?;
    defer upstream.shim_hf_free(ohf);
    var chf = try recast.buildCompactHeightfield(ctx, gpa, 2, 1, &hf);
    defer chf.deinit(gpa);
    const ochf = upstream.shim_chf_build(logs.original, 2, 1, ohf).?;
    defer upstream.shim_chf_free(ochf);
    gpa.free(chf.cells);
    gpa.free(chf.spans);
    gpa.free(chf.areas);
    chf.cells = try gpa.dupe(recast.CompactCell, f.cells);
    chf.spans = try gpa.dupe(recast.CompactSpan, f.spans);
    chf.areas = try gpa.dupe(u8, f.areas);
    chf.width = f.w;
    chf.height = f.h;
    chf.span_count = @intCast(f.spans.len);
    chf.max_regions = max_regions;
    shim_chf_replace(ochf, f.w, f.h, chf.span_count, @ptrCast(f.cells.ptr), @ptrCast(f.spans.ptr), f.areas.ptr);
    shim_chf_set_max_regions(ochf, max_regions);
    const ocset = upstream.shim_contours_build(logs.original, ochf, 1.3, 12, 1);
    defer if (ocset) |o| upstream.shim_contours_free(o);
    var cset = recast.buildContours(ctx, gpa, &chf, 1.3, 12, .default) catch {
        return ocset == null;
    };
    defer cset.deinit(gpa);
    if (ocset == null) return false;
    logs.expectSame("contours") catch return false;
    oracle.expectSameDump("contours", &cset, ocset.?) catch return false;
    return true;
}

test "hand-built fields with regions build contours as the original" {
    var prng: std.Random.DefaultPrng = .init(9);
    const random = prng.random();
    const sizes = [_][2]i32{ .{ 18, 3 }, .{ 19, 4 }, .{ 34, 5 }, .{ 40, 40 }, .{ 66, 20 } };
    var bad: usize = 0;
    var total: usize = 0;
    for (sizes) |s| for (0..40) |round| {
        const mode: Mode = switch (round % 4) {
            0 => .{ .nc = 2, .area2 = 2 },
            1 => .{ .nc = 10, .area2 = 10, .spill = 10 },
            2 => .{ .nc = 5, .overlap = 10 },
            else => .{ .nc = 0, .area2 = 0 },
        };
        const f = try gen(random, s[0], s[1], mode);
        defer freeField(f);
        // Blobs of regions: mostly one, some others, some 0 and border.
        const nreg: u16 = 1 + random.uintLessThan(u16, 6);
        for (f.spans) |*sp| {
            const r = random.uintLessThan(u32, 1000);
            sp.reg = if (r < 900) 1 else if (r < 950) 1 + random.uintLessThan(u16, nreg) else if (r < 980) 0 else 0x8000 | 1;
        }
        total += 1;
        if (!try checkContours(f, nreg + 1)) bad += 1;
    };
    try testing.expectEqual(@as(usize, 0), bad);
    try testing.expect(total > 0);
}

test "hand-built grids of many shapes build the distance field and regions as the original" {
    var prng: std.Random.DefaultPrng = .init(11);
    const random = prng.random();
    const sizes = [_][2]i32{ .{ 1, 20 }, .{ 20, 1 }, .{ 2, 2 }, .{ 17, 17 }, .{ 18, 18 }, .{ 19, 3 }, .{ 33, 3 }, .{ 34, 3 }, .{ 35, 35 }, .{ 50, 2 }, .{ 120, 90 } };
    const modes = [_]Mode{ .{ .nc = 0, .area2 = 0 }, .{ .nc = 0, .area2 = 3 }, .{ .nc = 2, .area2 = 0 }, .{ .nc = 1, .area2 = 1 } };
    var bad: usize = 0;
    for (sizes) |s| for (modes) |m| for (0..6) |_| {
        const f = try gen(random, s[0], s[1], m);
        defer freeField(f);
        if (!try check(f, true)) bad += 1;
    };
    try testing.expectEqual(0, bad);
}
