# Benchmarks

These are measurements on one machine, under the conditions below. They
are not a verdict on either side.

`zig build bench` times the port against the original on the same inputs,
one feature at a time, on one thread, and prints a table for each feature.
The tables below are its output, from this command:

```sh
zig build bench -- --runs 7 --warmup 1 --cpu 2
```

`--runs` sets the number of timed runs (7 by default) and `--warmup` the
runs before them (1). `--cpu` pins the benchmark to one CPU, and
`--only <text>` keeps the inputs whose name holds the text.

## Machine and flags

Measured on 23 November 2026, at commit `1c7f8b0` and, for the figures
before this pass, at `2756f52` (0.1.3), on a cloud virtual machine: an
Intel Xeon of the generation Zig names `graniterapids`, 4 virtual CPUs
under KVM at 2.3 GHz, Linux 6.18.44, pinned to CPU 2. The one-minute load
average was 1.0 during the runs, the benchmark itself.

- **The port:** Zig 0.17.0, ReleaseFast, for the machine's own CPU
  (`graniterapids`, with AVX-512).
- **The original:** recastnavigation 1.6.0 (`9f4ce64`), built from source
  by the clang that Zig 0.17.0 carries (22.1.8), for the same CPU, at `-O3
  -std=c++11 -fno-exceptions -fno-rtti -fno-threadsafe-statics
  -ffp-contract=off -fno-fast-math -fno-sanitize=undefined`, with `NDEBUG`,
  and linked statically. Zig's own flags for the build put `-O2` first; the
  `-O3` after them is the one that applies, as `--verbose-cc` shows.
- **Both:** frame pointers kept, and no fused multiply-adds, which the
  tests need for equal outputs.

Earlier versions of this file gave figures from an AMD Ryzen 9 9950X3D at
commit `c14a021`. That machine was not available for this pass, so every
figure here, before and after, is from the machine above, and the two sets
are not comparable: the same code can rank differently on the two. The
ledge filter, for one, took 0.88 to 0.92 of the original's time on the
Ryzen and takes 1.03 to 1.50 here, at both commits.

## Method

- Each run builds every input on both sides. The two sides take turns tile
  by tile, and the side that goes first changes every run.
- Each step is timed by the monotonic clock, as wall time. A feature's time
  in a run is its sum over the input's tiles.
- Each figure is the median of 7 timed runs after 1 warm-up. The spread is
  the range of the runs, slowest less fastest, as a share of the median.
- Every result goes through `std.mem.doNotOptimizeAway`, so the compiler
  cannot drop the work.
- Neither side logs or times: the port's context is `.none`, and the
  original's has its log and timers switched off.
- The benchmark ran three times at each of the two commits, the two in
  turn. Each row is from the run with the median ratio, and the last
  column gives the three runs' ratios, lowest to highest.
- The ratio is the port's median divided by the original's: below 1, the
  port takes less time. For a feature timed per tile, the worst-tile
  column gives the highest of the tiles' ratios, each of its own medians.

The work column counts what a feature goes through (triangles, cells,
spans, polygons or calls), and each time is followed by that count per
second.

## Inputs

RecastDemo's three meshes (`dungeon.obj`, `nav_test.obj` and
`undulating.obj`) and a 256 m generated terrain, each built whole with
RecastDemo's defaults; and, in 64 m tiles with Loomwork's navmesh
settings (125 mm cells, an agent 1.8 m tall and 0.35 m wide):

- that terrain, and a rolling ground (`vale`) of 256 m and of 1 km;
- `dungeon.obj` and `nav_test.obj`, rooms, stairs and floors above floors;
- two storeys 128 m across, 3 m apart, every column two floors deep;
- flat ground 128 m across with a post 0.25 m across every metre, which
  breaks every row of columns into short runs.

Most features run on all eleven inputs. 16-bit indices fit only
RecastDemo's meshes, and the merges run on the tiled inputs. The heightfield
layers fail on both sides on the whole 256 m terrain, as its regions
overflow their 8-bit ids, and on the posts, so that row has nine inputs.

## Known biases

- **Inlining.** The port is compiled into the benchmark, so the compiler
  can inline its functions into the timing code. The original is a library
  built on its own and reached through the shim's C functions, one call
  more per step. Calling the distance field out of line
  (`@call(.never_inline, …)`) gave the same time. On the two rows timed
  per call (grid size, polygon offset), that call is a sizeable part of
  the original's time.
- **The slope's cosine.** Linked statically, the original's `cosf` binds to
  compiler_rt's, not to glibc's as in the tests. It runs once per call of
  the slope functions, and at the benchmark's slopes (45 and 50 degrees)
  the two give the same threshold.
- **Allocation.** Both sides allocate through the C library's `malloc`:
  the original through its default allocator, the port through
  `std.heap.c_allocator`.
- **No fused multiply-adds.** Clang's default would fuse a multiply and an
  add within an expression on this CPU. That changes the original's output,
  and its speed by an amount not measured here.
- **Wall time.** Time that another process takes from the CPU counts for
  whichever side is running; the turns tile by tile spread it over both.
  Short, memory-bound features (the span count, the span filters, creating
  the heightfield) move the most from run to run, so theirs are the least
  certain figures, as their spreads show.
- **Code layout.** Where a hot loop falls against the CPU's 32- and
  64-byte fetch blocks moves whenever code before it in the binary
  changes size, and a row can move with it by more than its spread with
  no change to its own instructions. At `c14a021` it moved the watershed,
  the low hanging obstacles filter and grid size on the Ryzen. Between
  `2756f52` and this pass it moved rows whose code this pass did not
  touch: the polygon mesh on the rolling ground went from 1.04 and 1.14
  to 1.24 and 1.36 times the original, and the ledge filter on it from
  0.97 and 1.01 to 1.11. Neither side controls this in the benchmark, and
  a program that inlines the port's functions lays them out its own way.
- **A shared machine.** The machine is a cloud virtual machine, whose host
  runs other machines; spreads are larger than on a desktop, and a figure
  can move by a few percent from one run to the next with nothing else
  changed.
- One machine, one core, these inputs.

## Summary

The port's median time divided by the original's, the lowest and the
highest over the inputs a feature runs on (below 1, the port takes less
time), before this pass and after it.

| feature | before (`2756f52`) | after |
| --- | ---: | ---: |
| Whole build | 0.44 to 1.02 | 0.41 to 0.92 |
| Heightfield | 0.97 to 1.22 | 0.96 to 1.22 |
| Walkable triangles | 0.97 to 1.10 | 0.93 to 1.30 |
| Rasterization, int indices | 0.85 to 0.95 | 0.83 to 0.92 |
| Low hanging obstacles filter | 0.77 to 0.98 | 0.73 to 0.92 |
| Ledge filter | 0.97 to 1.48 | 1.03 to 1.50 |
| Low height filter | 0.62 to 0.98 | 0.68 to 0.96 |
| Compact heightfield | 0.86 to 0.92 | 0.87 to 0.94 |
| Erosion | 0.97 to 1.03 | 0.96 to 1.00 |
| Distance field | 1.04 to 1.34 | 0.32 to 0.96 |
| Watershed regions | 0.72 to 0.95 | 0.72 to 0.86 |
| Contours | 0.89 to 1.32 | 0.47 to 0.93 |
| Polygon mesh | 0.89 to 1.14 | 0.89 to 1.36 |
| Detail mesh | 0.14 to 0.87 | 0.15 to 0.95 |
| Span count | 0.51 to 1.01 | 0.55 to 0.93 |
| Unwalkable triangles | 0.72 to 1.05 | 0.54 to 0.99 |
| Rasterization, unsigned short indices | 0.86 to 0.95 | 0.83 to 0.92 |
| Rasterization, unindexed | 0.84 to 0.94 | 0.82 to 0.91 |
| Rasterization, one triangle at a time | 0.86 to 0.95 | 0.82 to 0.91 |
| Adding spans, the rasterized field's again | 0.71 to 0.84 | 0.70 to 0.84 |
| Polygon mesh copy | 0.84 to 1.02 | 0.88 to 1.08 |
| Heightfield layers | 0.96 to 1.01 | 0.96 to 1.02 |
| Monotone regions | 0.57 to 0.92 | 0.54 to 0.96 |
| Layer regions | 0.49 to 1.07 | 0.49 to 1.16 |
| Median area filter | 0.91 to 1.14 | 0.90 to 1.04 |
| Box area | 0.81 to 1.04 | 0.77 to 0.95 |
| Convex area | 0.71 to 0.92 | 0.70 to 0.90 |
| Cylinder area | 0.79 to 0.91 | 0.76 to 0.88 |
| Polygon mesh merge, every tile | 0.90 to 1.16 | 0.91 to 1.21 |
| Detail mesh merge, every tile | 0.60 to 0.88 | 0.66 to 0.86 |
| Bounds | 0.68 to 1.26 | 0.69 to 1.62 |
| Grid size | 1.09 to 1.11 | 0.83 to 0.89 |
| Polygon offset, a hexagon | 0.59 to 0.63 | 0.60 to 0.67 |

## The second performance pass

Three rows were slower than the original at `2756f52`: the distance field,
the contours and grid size. On this machine:

**Distance field**

| input | before | after | after, worst tile |
| --- | ---: | ---: | ---: |
| dungeon.obj | 1.04 | 0.79 |  |
| nav_test.obj | 1.08 | 0.82 |  |
| undulating.obj | 1.14 | 0.46 |  |
| terrain 256 m | 1.14 | 0.48 |  |
| terrain 256 m, 64 m tiles | 1.19 | 0.38 | 0.50 |
| vale 256 m, 64 m tiles | 1.27 | 0.32 | 0.33 |
| vale 1 km, 64 m tiles | 1.25 | 0.32 | 0.36 |
| dungeon.obj, 64 m tiles | 1.07 | 0.54 | 0.72 |
| nav_test.obj, 64 m tiles | 1.09 | 0.58 | 0.64 |
| two storeys 128 m, 64 m tiles | 1.18 | 0.39 | 0.40 |
| posts 128 m, 64 m tiles | 1.34 | 0.96 | 1.00 |

**Contours**

| input | before | after | after, worst tile |
| --- | ---: | ---: | ---: |
| dungeon.obj | 0.89 | 0.87 |  |
| nav_test.obj | 0.94 | 0.93 |  |
| undulating.obj | 1.03 | 0.82 |  |
| terrain 256 m | 1.00 | 0.79 |  |
| terrain 256 m, 64 m tiles | 1.09 | 0.71 | 0.84 |
| vale 256 m, 64 m tiles | 1.15 | 0.47 | 0.53 |
| vale 1 km, 64 m tiles | 1.18 | 0.47 | 0.56 |
| dungeon.obj, 64 m tiles | 0.96 | 0.55 | 0.78 |
| nav_test.obj, 64 m tiles | 1.00 | 0.74 | 0.92 |
| two storeys 128 m, 64 m tiles | 1.09 | 0.57 | 0.61 |
| posts 128 m, 64 m tiles | 1.32 | 0.79 | 0.81 |

**Grid size**

| input | before | after | after, worst tile |
| --- | ---: | ---: | ---: |
| dungeon.obj | 1.10 | 0.89 |  |
| nav_test.obj | 1.10 | 0.89 |  |
| undulating.obj | 1.10 | 0.88 |  |
| terrain 256 m | 1.11 | 0.89 |  |
| terrain 256 m, 64 m tiles | 1.10 | 0.89 |  |
| vale 256 m, 64 m tiles | 1.11 | 0.89 |  |
| vale 1 km, 64 m tiles | 1.10 | 0.88 |  |
| dungeon.obj, 64 m tiles | 1.09 | 0.89 |  |
| nav_test.obj, 64 m tiles | 1.10 | 0.88 |  |
| two storeys 128 m, 64 m tiles | 1.10 | 0.89 |  |
| posts 128 m, 64 m tiles | 1.09 | 0.83 |  |

- **Distance field.** The original goes over the whole field four times:
  the border marks, a sweep up, a sweep down and the blur. The port marks
  each span just before the sweep up reaches it, which needs only areas,
  so it goes over the field three times. A span on the border keeps 0
  through both sweeps, so it is not swept, and any other has all four
  neighbours, so the sweeps do not test for them. Where 16 columns in a
  row and those around them each hold one, two or four spans joined to the
  same floor of their neighbours, those spans are done 16 at a time
  (`@Vector`): the marks and the blur as a stencil, each sweep, d[k] =
  min(e[k], d[k - floors] + 2), as a running minimum taken in four
  shuffles. A block of 16 columns with no spans is skipped, and one whose
  columns hold at most one span each is skipped by the sweep down and the
  blur where its spans are all on or next to the border.
- **Contours.** The same 16-column runs set the boundary flags 16 spans at
  a time. The marking notes which rows hold a span that can start a
  contour, and the scan for contours visits only those.
- **Grid size.** On x86-64 the float-to-int conversion is the one
  instruction C's `(int)` compiles to, `cvttss2si`, or `vcvttss2si` where
  the CPU has AVX, written as inline assembly. Other machines keep the
  range check that gives x86-64's result for values out of range.

The outputs are the original's byte for byte. The fused passes need the
field laid out as `buildCompactHeightfield` lays it out: each column's
spans following the last's, each connection naming a span of its
neighbour column inside the field. They check that as they go;
`layoutAsBuilt` says whether a field passes. A field built or edited by
hand that does not is redone in the original's order once the sweep up
finds it, which costs up to one more pass: the distances in the
original's order take 0.92 to 1.18 of the original's time on these
inputs, and the blur keeps its fast path, which is exact on any field.

The posts are the closest: 0.96 times the original for the distance field,
1.00 on the worst tile. Their columns are broken every metre, so few runs
of 16 qualify, and most spans take the scalar steps.

## Where the port is faster

- **Distance field, 0.32 to 0.96 times**, and **contours, 0.47 to 0.93
  times**; see above.
- **Detail mesh, 0.15 to 0.95 times.** Where the original measures each
  sample against each triangle in turn, the port measures a vector of
  samples at a time against a triangle (`@Vector`, as wide as the CPU's),
  with what depends only on the triangle worked out once. It finds a
  triangulation's edges in a table indexed by their two vertices, where the
  original searches every edge, and it works out once per span whether the
  span borders its region, where the original redoes that for every
  polygon whose patch covers the span.
- **Compact heightfield, 0.87 to 0.94 times.** The port builds a span's
  four connections in a register and stores the span once.
- **Loops that store to bytes.** Zig has no type-based aliasing, so through
  the heightfield's pointer each store to a distance, flag or area makes a
  loop load the field's slices again, as the original's stores to bytes do
  in C++. Erosion, contours and the box and cylinder marks read the field
  through local pointers instead.

## Where the port is slower

These are slower than the original on some input in the median run. None
of their code changed in this pass; the figure in brackets is the same
row at `2756f52`.

- **Ledge filter, 1.03 to 1.50 times** (0.97 to 1.48), most on the whole
  meshes and terrain. Under cachegrind the port runs fewer instructions
  than the original (5.27 against 5.51 billion on the whole terrain) with
  the same cache misses, and on the Ryzen it took 0.88 to 0.92 of the
  original's time; on this machine it takes longer. Why is not known.
- **Polygon mesh on the rolling ground, 1.24 and 1.36 times** (1.04 and
  1.14); 0.89 to 1.03 on the other inputs. See the code layout bias.
- **Polygon mesh merge, 1.04 to 1.21 times** on five of the seven tiled
  inputs (0.90 to 1.16 there), of 10 to 500 µs.
- **Creating the heightfield, 1.02 to 1.22 times** on the tiled inputs
  (1.03 to 1.22): allocating and clearing the columns, a few hundred
  microseconds on both sides.
- **Layer regions, up to 1.16 times**, on `dungeon.obj` in tiles (1.03);
  1.05 on the whole `dungeon.obj` and the rolling ground.
- **Walkable triangles on the two storeys, 1.30 times** (0.99), on 16
  triangles, and 1.13 on `undulating.obj` (1.10), whose spread is wide.
- **Polygon mesh copy on `nav_test.obj`, 1.08 times** (0.99).
- **Bounds on the two storeys, 1.62 times** (1.26), of their 8 vertices,
  and 1.09 on the whole terrain (0.68): a few nanoseconds to a few
  microseconds a call, whose spreads are wide.

Every other feature is within 5% of the original on every input, or
faster; differences of a few percent are within the spread of the runs.

## Every feature

### Whole build

Every step of a navmesh build, in Loomwork's order.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 12.28 ms, 825.3 k/s | 11.31 ms, 895.9 k/s | 0.92 |  | 2.8% / 4.9% | 0.90 to 0.93 |
| nav_test.obj | 1612 triangles | 16.44 ms, 98.1 k/s | 14.28 ms, 112.9 k/s | 0.87 |  | 9.7% / 12.2% | 0.57 to 0.87 |
| undulating.obj | 5202 triangles | 83.78 ms, 62.1 k/s | 37.42 ms, 139.0 k/s | 0.45 |  | 8.9% / 25.5% | 0.44 to 0.46 |
| terrain 256 m | 130.1 k triangles | 211.79 ms, 614.3 k/s | 160.02 ms, 813.1 k/s | 0.76 |  | 13.0% / 24.5% | 0.76 to 0.76 |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 920.84 ms, 148.0 k/s | 699.43 ms, 194.9 k/s | 0.76 |  | 40.4% / 43.5% | 0.76 to 0.78 |
| vale 256 m, 64 m tiles | 137.3 k triangles | 1588.35 ms, 86.4 k/s | 759.36 ms, 180.8 k/s | 0.48 |  | 14.0% / 26.2% | 0.48 to 0.49 |
| vale 1 km, 64 m tiles | 2.22 M triangles | 31495.31 ms, 70.5 k/s | 12854.61 ms, 172.8 k/s | 0.41 |  | 3.8% / 5.7% | 0.40 to 0.41 |
| dungeon.obj, 64 m tiles | 10.3 k triangles | 59.78 ms, 172.0 k/s | 51.45 ms, 199.9 k/s | 0.86 |  | 38.4% / 36.7% | 0.72 to 0.90 |
| nav_test.obj, 64 m tiles | 1901 triangles | 89.33 ms, 21.3 k/s | 74.56 ms, 25.5 k/s | 0.83 |  | 15.6% / 3.8% | 0.82 to 0.83 |
| two storeys 128 m, 64 m tiles | 16 triangles | 338.51 ms, 47/s | 275.27 ms, 58/s | 0.81 |  | 11.1% / 16.3% | 0.79 to 0.82 |
| posts 128 m, 64 m tiles | 202.8 k triangles | 104.11 ms, 1.9 M/s | 92.85 ms, 2.2 M/s | 0.89 |  | 22.6% / 38.0% | 0.89 to 0.91 |

### Heightfield

`rcCreateHeightfield` and `Heightfield.init`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 81.8 k cells | 40.5 µs, 2.02 G/s | 38.7 µs, 2.12 G/s | 0.96 |  | 149.8% / 113.8% | 0.83 to 1.06 |
| nav_test.obj | 78.7 k cells | 36.0 µs, 2.18 G/s | 34.7 µs, 2.27 G/s | 0.96 |  | 82.1% / 31.8% | 0.89 to 0.98 |
| undulating.obj | 109.2 k cells | 41.3 µs, 2.65 G/s | 40.3 µs, 2.71 G/s | 0.98 |  | 109.3% / 72.1% | 0.87 to 1.34 |
| terrain 256 m | 727.6 k cells | 629.1 µs, 1.16 G/s | 629.0 µs, 1.16 G/s | 1.00 |  | 36.1% / 71.1% | 0.97 to 1.00 |
| terrain 256 m, 64 m tiles | 4.39 M cells | 2.78 ms, 1.58 G/s | 3.02 ms, 1.46 G/s | 1.09 | 1.41 | 49.0% / 56.1% | 1.01 to 1.14 |
| vale 256 m, 64 m tiles | 4.39 M cells | 2.95 ms, 1.49 G/s | 3.51 ms, 1.25 G/s | 1.19 | 1.60 | 50.6% / 27.5% | 1.12 to 1.24 |
| vale 1 km, 64 m tiles | 70.29 M cells | 54.83 ms, 1.28 G/s | 64.12 ms, 1.10 G/s | 1.17 | 1.77 | 54.3% / 33.5% | 1.17 to 1.30 |
| dungeon.obj, 64 m tiles | 1.10 M cells | 551.3 µs, 1.99 G/s | 560.1 µs, 1.96 G/s | 1.02 | 1.09 | 32.8% / 32.5% | 0.92 to 1.10 |
| nav_test.obj, 64 m tiles | 1.10 M cells | 587.2 µs, 1.87 G/s | 636.9 µs, 1.72 G/s | 1.08 | 1.17 | 43.0% / 15.2% | 1.02 to 1.09 |
| two storeys 128 m, 64 m tiles | 1.10 M cells | 985.7 µs, 1.11 G/s | 1.04 ms, 1.06 G/s | 1.05 | 1.16 | 31.7% / 24.4% | 1.01 to 1.07 |
| posts 128 m, 64 m tiles | 1.10 M cells | 815.6 µs, 1.35 G/s | 993.5 µs, 1.11 G/s | 1.22 | 1.28 | 53.0% / 35.9% | 0.98 to 1.24 |

### Walkable triangles

`rcMarkWalkableTriangles` and `markWalkableTriangles`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 72.5 µs, 139.7 M/s | 67.4 µs, 150.4 M/s | 0.93 |  | 41.6% / 9.2% | 0.84 to 0.99 |
| nav_test.obj | 1612 triangles | 6.5 µs, 249.8 M/s | 6.6 µs, 245.7 M/s | 1.02 |  | 23.4% / 21.6% | 0.89 to 1.10 |
| undulating.obj | 5202 triangles | 34.8 µs, 149.4 M/s | 39.3 µs, 132.3 M/s | 1.13 |  | 48.4% / 58.1% | 1.09 to 1.36 |
| terrain 256 m | 130.1 k triangles | 1.04 ms, 124.5 M/s | 989.7 µs, 131.5 M/s | 0.95 |  | 25.3% / 11.4% | 0.91 to 0.98 |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 933.1 µs, 146.1 M/s | 884.4 µs, 154.1 M/s | 0.95 | 1.19 | 38.4% / 34.6% | 0.93 to 1.09 |
| vale 256 m, 64 m tiles | 137.3 k triangles | 978.8 µs, 140.3 M/s | 939.2 µs, 146.2 M/s | 0.96 | 1.07 | 14.5% / 16.9% | 0.95 to 1.05 |
| vale 1 km, 64 m tiles | 2.22 M triangles | 16.10 ms, 138.0 M/s | 16.23 ms, 136.9 M/s | 1.01 | 1.51 | 16.5% / 11.0% | 1.00 to 1.02 |
| dungeon.obj, 64 m tiles | 10.3 k triangles | 86.9 µs, 118.3 M/s | 88.4 µs, 116.3 M/s | 1.02 | 0.99 | 15.4% / 45.3% | 0.99 to 1.03 |
| nav_test.obj, 64 m tiles | 1901 triangles | 15.8 µs, 120.0 M/s | 15.0 µs, 126.6 M/s | 0.95 | 0.97 | 18.6% / 13.3% | 0.95 to 1.06 |
| two storeys 128 m, 64 m tiles | 16 triangles | 3.2 µs, 5.0 M/s | 4.1 µs, 3.9 M/s | 1.30 | 2.05 | 104.8% / 42.7% | 1.04 to 1.56 |
| posts 128 m, 64 m tiles | 202.8 k triangles | 1.64 ms, 123.9 M/s | 1.65 ms, 122.8 M/s | 1.01 | 1.04 | 12.1% / 14.1% | 0.95 to 1.06 |

### Rasterization, int indices

`rcRasterizeTriangles` and `rasterizeTriangles`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 6.68 ms, 1.5 M/s | 6.12 ms, 1.7 M/s | 0.92 |  | 5.2% / 5.4% | 0.92 to 0.93 |
| nav_test.obj | 1612 triangles | 4.92 ms, 327.8 k/s | 4.27 ms, 377.6 k/s | 0.87 |  | 9.1% / 17.3% | 0.69 to 0.88 |
| undulating.obj | 5202 triangles | 5.49 ms, 947.9 k/s | 4.89 ms, 1.1 M/s | 0.89 |  | 40.7% / 51.0% | 0.89 to 0.90 |
| terrain 256 m | 130.1 k triangles | 47.04 ms, 2.8 M/s | 42.10 ms, 3.1 M/s | 0.90 |  | 31.4% / 69.0% | 0.89 to 0.91 |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 139.90 ms, 974.3 k/s | 118.60 ms, 1.1 M/s | 0.85 | 0.88 | 9.1% / 9.5% | 0.82 to 0.85 |
| vale 256 m, 64 m tiles | 137.3 k triangles | 139.58 ms, 983.6 k/s | 119.63 ms, 1.1 M/s | 0.86 | 0.89 | 10.9% / 20.9% | 0.85 to 0.87 |
| vale 1 km, 64 m tiles | 2.22 M triangles | 2324.51 ms, 955.8 k/s | 2013.01 ms, 1.1 M/s | 0.87 | 1.20 | 9.8% / 8.5% | 0.85 to 0.89 |
| dungeon.obj, 64 m tiles | 10.3 k triangles | 18.91 ms, 543.8 k/s | 17.13 ms, 600.4 k/s | 0.91 | 0.93 | 37.7% / 43.5% | 0.76 to 0.94 |
| nav_test.obj, 64 m tiles | 1901 triangles | 21.24 ms, 89.5 k/s | 17.97 ms, 105.8 k/s | 0.85 | 0.85 | 0.9% / 10.6% | 0.81 to 0.86 |
| two storeys 128 m, 64 m tiles | 16 triangles | 46.94 ms, 341/s | 38.90 ms, 411/s | 0.83 | 0.83 | 8.2% / 17.0% | 0.83 to 0.84 |
| posts 128 m, 64 m tiles | 202.8 k triangles | 41.41 ms, 4.9 M/s | 35.22 ms, 5.8 M/s | 0.85 | 0.86 | 25.4% / 25.3% | 0.84 to 0.85 |

### Low hanging obstacles filter

`rcFilterLowHangingWalkableObstacles` and `filterLowHangingWalkableObstacles`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 141.1 µs, 369.4 M/s | 127.5 µs, 408.5 M/s | 0.90 |  | 21.6% / 17.6% | 0.82 to 0.91 |
| nav_test.obj | 120.2 k spans | 248.2 µs, 484.2 M/s | 217.3 µs, 553.1 M/s | 0.88 |  | 24.8% / 20.2% | 0.65 to 0.89 |
| undulating.obj | 108.7 k spans | 316.3 µs, 343.7 M/s | 231.3 µs, 470.0 M/s | 0.73 |  | 39.4% / 77.1% | 0.73 to 0.80 |
| terrain 256 m | 741.4 k spans | 2.43 ms, 304.8 M/s | 2.17 ms, 342.0 M/s | 0.89 |  | 48.0% / 42.6% | 0.89 to 0.96 |
| terrain 256 m, 64 m tiles | 4.41 M spans | 9.81 ms, 449.4 M/s | 8.42 ms, 523.3 M/s | 0.86 | 1.03 | 33.1% / 36.4% | 0.84 to 0.86 |
| vale 256 m, 64 m tiles | 4.34 M spans | 11.81 ms, 367.6 M/s | 10.48 ms, 414.4 M/s | 0.89 | 1.15 | 31.8% / 55.0% | 0.89 to 0.96 |
| vale 1 km, 64 m tiles | 70.09 M spans | 184.58 ms, 379.7 M/s | 166.38 ms, 421.3 M/s | 0.90 | 1.47 | 45.2% / 41.3% | 0.86 to 0.93 |
| dungeon.obj, 64 m tiles | 304.5 k spans | 1.42 ms, 213.9 M/s | 1.13 ms, 268.5 M/s | 0.80 | 1.13 | 83.5% / 116.4% | 0.80 to 1.07 |
| nav_test.obj, 64 m tiles | 730.9 k spans | 1.69 ms, 433.3 M/s | 1.55 ms, 471.2 M/s | 0.92 | 0.95 | 33.9% / 20.4% | 0.89 to 0.96 |
| two storeys 128 m, 64 m tiles | 2.15 M spans | 3.27 ms, 656.4 M/s | 2.89 ms, 743.8 M/s | 0.88 | 0.92 | 34.0% / 31.1% | 0.86 to 0.92 |
| posts 128 m, 64 m tiles | 1.09 M spans | 1.85 ms, 588.9 M/s | 1.64 ms, 665.5 M/s | 0.88 | 0.85 | 19.8% / 42.1% | 0.86 to 0.88 |

### Ledge filter

`rcFilterLedgeSpans` and `filterLedgeSpans`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 612.8 µs, 85.0 M/s | 764.0 µs, 68.2 M/s | 1.25 |  | 12.2% / 8.1% | 1.23 to 1.27 |
| nav_test.obj | 120.2 k spans | 1.30 ms, 92.2 M/s | 1.53 ms, 78.5 M/s | 1.18 |  | 8.6% / 37.9% | 0.74 to 1.19 |
| undulating.obj | 108.7 k spans | 1.14 ms, 95.1 M/s | 1.66 ms, 65.5 M/s | 1.45 |  | 17.1% / 43.7% | 1.44 to 1.47 |
| terrain 256 m | 741.4 k spans | 7.50 ms, 98.9 M/s | 11.26 ms, 65.9 M/s | 1.50 |  | 37.3% / 8.9% | 1.47 to 1.55 |
| terrain 256 m, 64 m tiles | 4.41 M spans | 42.61 ms, 103.4 M/s | 52.11 ms, 84.6 M/s | 1.22 | 1.32 | 12.4% / 8.2% | 1.21 to 1.24 |
| vale 256 m, 64 m tiles | 4.34 M spans | 41.10 ms, 105.7 M/s | 45.56 ms, 95.3 M/s | 1.11 | 1.16 | 13.0% / 14.8% | 1.08 to 1.11 |
| vale 1 km, 64 m tiles | 70.09 M spans | 691.40 ms, 101.4 M/s | 764.82 ms, 91.6 M/s | 1.11 | 1.22 | 7.0% / 5.6% | 1.09 to 1.13 |
| dungeon.obj, 64 m tiles | 304.5 k spans | 4.17 ms, 73.0 M/s | 4.30 ms, 70.7 M/s | 1.03 | 1.16 | 38.6% / 50.3% | 0.99 to 1.14 |
| nav_test.obj, 64 m tiles | 730.9 k spans | 7.68 ms, 95.1 M/s | 8.36 ms, 87.4 M/s | 1.09 | 1.17 | 3.7% / 2.8% | 1.05 to 1.12 |
| two storeys 128 m, 64 m tiles | 2.15 M spans | 28.33 ms, 75.8 M/s | 29.62 ms, 72.5 M/s | 1.05 | 1.06 | 20.1% / 7.1% | 1.02 to 1.05 |
| posts 128 m, 64 m tiles | 1.09 M spans | 9.86 ms, 110.6 M/s | 10.20 ms, 106.9 M/s | 1.03 | 1.03 | 27.9% / 19.1% | 0.99 to 1.04 |

### Low height filter

`rcFilterWalkableLowHeightSpans` and `filterWalkableLowHeightSpans`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 123.7 µs, 421.4 M/s | 105.7 µs, 492.8 M/s | 0.86 |  | 38.0% / 11.9% | 0.81 to 0.93 |
| nav_test.obj | 120.2 k spans | 256.6 µs, 468.5 M/s | 212.7 µs, 565.0 M/s | 0.83 |  | 92.1% / 117.5% | 0.68 to 0.88 |
| undulating.obj | 108.7 k spans | 279.5 µs, 389.0 M/s | 191.3 µs, 568.2 M/s | 0.68 |  | 41.7% / 111.2% | 0.67 to 0.73 |
| terrain 256 m | 741.4 k spans | 1.81 ms, 409.0 M/s | 1.74 ms, 427.3 M/s | 0.96 |  | 89.3% / 37.3% | 0.86 to 0.98 |
| terrain 256 m, 64 m tiles | 4.41 M spans | 7.76 ms, 568.3 M/s | 6.54 ms, 674.1 M/s | 0.84 | 0.94 | 64.2% / 74.9% | 0.77 to 0.85 |
| vale 256 m, 64 m tiles | 4.34 M spans | 7.94 ms, 547.1 M/s | 6.52 ms, 666.4 M/s | 0.82 | 1.18 | 47.5% / 54.6% | 0.82 to 0.85 |
| vale 1 km, 64 m tiles | 70.09 M spans | 126.94 ms, 552.2 M/s | 107.05 ms, 654.7 M/s | 0.84 | 1.28 | 24.6% / 26.9% | 0.84 to 0.84 |
| dungeon.obj, 64 m tiles | 304.5 k spans | 1.18 ms, 257.5 M/s | 991.4 µs, 307.1 M/s | 0.84 | 1.05 | 63.0% / 109.3% | 0.76 to 0.89 |
| nav_test.obj, 64 m tiles | 730.9 k spans | 1.49 ms, 489.8 M/s | 1.32 ms, 551.7 M/s | 0.89 | 0.92 | 25.5% / 13.6% | 0.87 to 0.89 |
| two storeys 128 m, 64 m tiles | 2.15 M spans | 2.70 ms, 796.0 M/s | 2.43 ms, 884.9 M/s | 0.90 | 0.91 | 45.1% / 114.0% | 0.81 to 0.96 |
| posts 128 m, 64 m tiles | 1.09 M spans | 1.74 ms, 625.9 M/s | 1.37 ms, 797.9 M/s | 0.78 | 0.92 | 18.9% / 37.6% | 0.74 to 0.88 |

### Compact heightfield

`rcBuildCompactHeightfield` and `buildCompactHeightfield`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 611.5 µs, 85.2 M/s | 531.1 µs, 98.1 M/s | 0.87 |  | 28.8% / 36.7% | 0.83 to 1.07 |
| nav_test.obj | 120.2 k spans | 1.27 ms, 94.3 M/s | 1.12 ms, 107.5 M/s | 0.88 |  | 29.7% / 17.9% | 0.63 to 0.88 |
| undulating.obj | 108.7 k spans | 1.47 ms, 73.8 M/s | 1.32 ms, 82.3 M/s | 0.90 |  | 5.5% / 4.5% | 0.84 to 0.91 |
| terrain 256 m | 741.4 k spans | 11.21 ms, 66.1 M/s | 10.02 ms, 74.0 M/s | 0.89 |  | 56.0% / 13.3% | 0.81 to 0.90 |
| terrain 256 m, 64 m tiles | 4.41 M spans | 68.29 ms, 64.5 M/s | 59.56 ms, 74.0 M/s | 0.87 | 0.93 | 42.4% / 42.0% | 0.86 to 0.92 |
| vale 256 m, 64 m tiles | 4.34 M spans | 65.52 ms, 66.3 M/s | 57.38 ms, 75.7 M/s | 0.88 | 1.00 | 31.7% / 33.4% | 0.88 to 0.91 |
| vale 1 km, 64 m tiles | 70.09 M spans | 1062.01 ms, 66.0 M/s | 941.12 ms, 74.5 M/s | 0.89 | 1.00 | 10.6% / 13.8% | 0.89 to 0.90 |
| dungeon.obj, 64 m tiles | 304.5 k spans | 5.00 ms, 60.9 M/s | 4.70 ms, 64.8 M/s | 0.94 | 1.03 | 52.7% / 52.0% | 0.91 to 0.96 |
| nav_test.obj, 64 m tiles | 730.9 k spans | 8.73 ms, 83.7 M/s | 7.79 ms, 93.8 M/s | 0.89 | 0.94 | 22.3% / 9.8% | 0.87 to 0.89 |
| two storeys 128 m, 64 m tiles | 2.15 M spans | 30.76 ms, 69.8 M/s | 27.39 ms, 78.4 M/s | 0.89 | 0.92 | 8.6% / 17.8% | 0.88 to 0.91 |
| posts 128 m, 64 m tiles | 1.09 M spans | 12.58 ms, 86.7 M/s | 11.13 ms, 97.9 M/s | 0.89 | 0.89 | 26.9% / 35.5% | 0.87 to 0.91 |

### Erosion

`rcErodeWalkableArea` and `erodeWalkableArea`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 571.9 µs, 41.2 M/s | 570.8 µs, 41.3 M/s | 1.00 |  | 6.9% / 68.8% | 0.95 to 1.01 |
| nav_test.obj | 56.8 k compact spans | 1.06 ms, 53.8 M/s | 1.06 ms, 53.7 M/s | 1.00 |  | 8.3% / 9.0% | 0.66 to 1.02 |
| undulating.obj | 105.8 k compact spans | 1.51 ms, 70.0 M/s | 1.49 ms, 71.0 M/s | 0.99 |  | 5.6% / 3.0% | 0.98 to 1.00 |
| terrain 256 m | 686.7 k compact spans | 9.98 ms, 68.8 M/s | 9.95 ms, 69.0 M/s | 1.00 |  | 3.0% / 10.6% | 0.97 to 1.00 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 55.50 ms, 73.8 M/s | 54.37 ms, 75.3 M/s | 0.98 | 1.01 | 12.0% / 10.5% | 0.96 to 1.00 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 49.10 ms, 87.8 M/s | 48.59 ms, 88.7 M/s | 0.99 | 1.01 | 15.9% / 18.1% | 0.95 to 1.02 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 861.32 ms, 80.8 M/s | 841.50 ms, 82.7 M/s | 0.98 | 1.17 | 9.4% / 8.9% | 0.98 to 1.00 |
| dungeon.obj, 64 m tiles | 139.8 k compact spans | 3.88 ms, 36.1 M/s | 3.73 ms, 37.5 M/s | 0.96 | 1.00 | 48.2% / 47.1% | 0.87 to 0.98 |
| nav_test.obj, 64 m tiles | 349.2 k compact spans | 6.17 ms, 56.6 M/s | 6.07 ms, 57.5 M/s | 0.98 | 1.00 | 2.5% / 1.3% | 0.95 to 0.99 |
| two storeys 128 m, 64 m tiles | 2.13 M compact spans | 21.91 ms, 97.2 M/s | 21.37 ms, 99.7 M/s | 0.98 | 0.99 | 6.4% / 10.8% | 0.98 to 0.99 |
| posts 128 m, 64 m tiles | 964.1 k compact spans | 10.40 ms, 92.7 M/s | 10.03 ms, 96.1 M/s | 0.96 | 0.97 | 23.4% / 32.4% | 0.94 to 0.97 |

### Distance field

`rcBuildDistanceField` and `buildDistanceField`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 633.0 µs, 37.2 M/s | 501.1 µs, 47.0 M/s | 0.79 |  | 9.6% / 7.2% | 0.78 to 0.88 |
| nav_test.obj | 56.8 k compact spans | 1.17 ms, 48.4 M/s | 962.8 µs, 59.0 M/s | 0.82 |  | 7.2% / 20.8% | 0.52 to 0.83 |
| undulating.obj | 105.8 k compact spans | 1.80 ms, 58.9 M/s | 819.5 µs, 129.1 M/s | 0.46 |  | 2.6% / 5.9% | 0.46 to 0.47 |
| terrain 256 m | 686.7 k compact spans | 11.96 ms, 57.4 M/s | 5.69 ms, 120.8 M/s | 0.48 |  | 36.9% / 7.9% | 0.48 to 0.49 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 67.59 ms, 60.6 M/s | 25.44 ms, 161.0 M/s | 0.38 | 0.50 | 9.4% / 9.1% | 0.37 to 0.38 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 62.44 ms, 69.0 M/s | 19.91 ms, 216.5 M/s | 0.32 | 0.33 | 15.5% / 14.4% | 0.31 to 0.33 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 1048.64 ms, 66.3 M/s | 335.39 ms, 207.4 M/s | 0.32 | 0.36 | 7.5% / 7.3% | 0.32 to 0.32 |
| dungeon.obj, 64 m tiles | 139.8 k compact spans | 4.46 ms, 31.4 M/s | 2.39 ms, 58.4 M/s | 0.54 | 0.72 | 31.9% / 39.7% | 0.48 to 0.56 |
| nav_test.obj, 64 m tiles | 349.2 k compact spans | 7.64 ms, 45.7 M/s | 4.42 ms, 79.1 M/s | 0.58 | 0.64 | 14.8% / 8.5% | 0.57 to 0.59 |
| two storeys 128 m, 64 m tiles | 2.13 M compact spans | 29.04 ms, 73.3 M/s | 11.31 ms, 188.3 M/s | 0.39 | 0.40 | 30.8% / 13.0% | 0.38 to 0.39 |
| posts 128 m, 64 m tiles | 964.1 k compact spans | 10.81 ms, 89.2 M/s | 10.39 ms, 92.8 M/s | 0.96 | 1.00 | 22.4% / 25.6% | 0.95 to 0.96 |

### Watershed regions

`rcBuildRegions` and `buildRegions`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 1.42 ms, 16.6 M/s | 1.16 ms, 20.3 M/s | 0.82 |  | 15.7% / 23.4% | 0.81 to 0.82 |
| nav_test.obj | 56.8 k compact spans | 3.47 ms, 16.4 M/s | 2.55 ms, 22.2 M/s | 0.74 |  | 9.9% / 16.8% | 0.48 to 0.75 |
| undulating.obj | 105.8 k compact spans | 7.02 ms, 15.1 M/s | 5.05 ms, 21.0 M/s | 0.72 |  | 37.6% / 56.1% | 0.71 to 0.73 |
| terrain 256 m | 686.7 k compact spans | 54.32 ms, 12.6 M/s | 40.48 ms, 17.0 M/s | 0.75 |  | 4.2% / 17.7% | 0.71 to 0.81 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 328.23 ms, 12.5 M/s | 239.29 ms, 17.1 M/s | 0.73 | 0.83 | 44.5% / 56.5% | 0.73 to 0.76 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 328.59 ms, 13.1 M/s | 281.60 ms, 15.3 M/s | 0.86 | 0.94 | 13.4% / 18.9% | 0.81 to 0.87 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 5399.65 ms, 12.9 M/s | 4620.54 ms, 15.1 M/s | 0.86 | 1.02 | 11.1% / 12.7% | 0.85 to 0.86 |
| dungeon.obj, 64 m tiles | 139.8 k compact spans | 12.13 ms, 11.5 M/s | 10.25 ms, 13.6 M/s | 0.85 | 1.01 | 41.7% / 34.6% | 0.72 to 0.92 |
| nav_test.obj, 64 m tiles | 349.2 k compact spans | 24.72 ms, 14.1 M/s | 19.76 ms, 17.7 M/s | 0.80 | 0.90 | 20.6% / 5.6% | 0.78 to 0.83 |
| two storeys 128 m, 64 m tiles | 2.13 M compact spans | 138.63 ms, 15.4 M/s | 113.86 ms, 18.7 M/s | 0.82 | 0.82 | 13.6% / 15.2% | 0.80 to 0.83 |
| posts 128 m, 64 m tiles | 964.1 k compact spans | 11.95 ms, 80.7 M/s | 10.31 ms, 93.5 M/s | 0.86 | 0.88 | 31.3% / 60.0% | 0.83 to 0.91 |

### Contours

`rcBuildContours` and `buildContours`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 374.7 µs, 62.9 M/s | 327.0 µs, 72.1 M/s | 0.87 |  | 4.4% / 9.5% | 0.84 to 0.88 |
| nav_test.obj | 56.8 k compact spans | 638.5 µs, 88.9 M/s | 594.6 µs, 95.5 M/s | 0.93 |  | 10.6% / 18.5% | 0.57 to 1.01 |
| undulating.obj | 105.8 k compact spans | 893.7 µs, 118.4 M/s | 729.0 µs, 145.1 M/s | 0.82 |  | 4.8% / 12.9% | 0.80 to 0.82 |
| terrain 256 m | 686.7 k compact spans | 7.24 ms, 94.9 M/s | 5.70 ms, 120.4 M/s | 0.79 |  | 4.9% / 5.1% | 0.78 to 0.86 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 34.13 ms, 120.0 M/s | 24.23 ms, 169.0 M/s | 0.71 | 0.84 | 41.2% / 51.1% | 0.71 to 0.73 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 23.53 ms, 183.1 M/s | 11.15 ms, 386.4 M/s | 0.47 | 0.53 | 13.6% / 16.7% | 0.46 to 0.47 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 387.36 ms, 179.6 M/s | 182.95 ms, 380.2 M/s | 0.47 | 0.56 | 7.5% / 12.2% | 0.47 to 0.48 |
| dungeon.obj, 64 m tiles | 139.8 k compact spans | 2.55 ms, 54.8 M/s | 1.41 ms, 99.1 M/s | 0.55 | 0.78 | 43.6% / 43.7% | 0.44 to 0.60 |
| nav_test.obj, 64 m tiles | 349.2 k compact spans | 3.49 ms, 100.1 M/s | 2.58 ms, 135.2 M/s | 0.74 | 0.92 | 4.0% / 3.0% | 0.70 to 0.75 |
| two storeys 128 m, 64 m tiles | 2.13 M compact spans | 9.85 ms, 216.3 M/s | 5.65 ms, 377.1 M/s | 0.57 | 0.61 | 6.3% / 12.2% | 0.56 to 0.57 |
| posts 128 m, 64 m tiles | 964.1 k compact spans | 2.86 ms, 337.5 M/s | 2.24 ms, 429.8 M/s | 0.79 | 0.81 | 25.7% / 55.0% | 0.75 to 0.79 |

### Polygon mesh

`rcBuildPolyMesh` and `buildPolyMesh`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 118 polygons | 300.7 µs, 392.4 k/s | 290.6 µs, 406.0 k/s | 0.97 |  | 7.7% / 12.8% | 0.92 to 1.08 |
| nav_test.obj | 155 polygons | 276.7 µs, 560.1 k/s | 245.1 µs, 632.3 k/s | 0.89 |  | 11.6% / 8.1% | 0.81 to 0.96 |
| undulating.obj | 216 polygons | 525.7 µs, 410.9 k/s | 489.6 µs, 441.2 k/s | 0.93 |  | 8.7% / 7.9% | 0.88 to 0.98 |
| terrain 256 m | 2580 polygons | 8.87 ms, 290.9 k/s | 8.52 ms, 302.6 k/s | 0.96 |  | 10.8% / 52.2% | 0.95 to 0.96 |
| terrain 256 m, 64 m tiles | 4098 polygons | 18.56 ms, 220.8 k/s | 18.46 ms, 222.0 k/s | 0.99 | 1.03 | 20.5% / 16.2% | 0.99 to 1.00 |
| vale 256 m, 64 m tiles | 108 polygons | 235.2 µs, 459.1 k/s | 292.1 µs, 369.7 k/s | 1.24 | 1.52 | 22.3% / 21.0% | 1.13 to 1.31 |
| vale 1 km, 64 m tiles | 684 polygons | 2.32 ms, 294.6 k/s | 3.16 ms, 216.7 k/s | 1.36 | 1.82 | 20.9% / 15.6% | 1.36 to 1.41 |
| dungeon.obj, 64 m tiles | 274 polygons | 2.40 ms, 114.1 k/s | 2.28 ms, 119.9 k/s | 0.95 | 1.04 | 36.5% / 26.5% | 0.86 to 0.97 |
| nav_test.obj, 64 m tiles | 253 polygons | 569.1 µs, 444.6 k/s | 557.9 µs, 453.5 k/s | 0.98 | 0.99 | 13.3% / 16.5% | 0.97 to 1.00 |
| two storeys 128 m, 64 m tiles | 80 polygons | 173.2 µs, 462.0 k/s | 178.6 µs, 447.9 k/s | 1.03 | 1.04 | 29.4% / 20.9% | 1.02 to 1.03 |
| posts 128 m, 64 m tiles | 253 polygons | 76.4 µs, 3.3 M/s | 78.4 µs, 3.2 M/s | 1.03 | 1.15 | 64.4% / 28.3% | 0.91 to 1.10 |

### Detail mesh

`rcBuildPolyMeshDetail` and `buildPolyMeshDetail`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 118 polygons | 553.6 µs, 213.1 k/s | 454.1 µs, 259.8 k/s | 0.82 |  | 15.4% / 15.2% | 0.80 to 0.83 |
| nav_test.obj | 155 polygons | 1.64 ms, 94.7 k/s | 1.04 ms, 149.0 k/s | 0.64 |  | 5.6% / 5.8% | 0.44 to 0.66 |
| undulating.obj | 216 polygons | 62.22 ms, 3472/s | 20.00 ms, 10.8 k/s | 0.32 |  | 0.7% / 1.6% | 0.32 to 0.32 |
| terrain 256 m | 2580 polygons | 50.36 ms, 51.2 k/s | 23.93 ms, 107.8 k/s | 0.48 |  | 7.0% / 7.1% | 0.48 to 0.48 |
| terrain 256 m, 64 m tiles | 4098 polygons | 124.93 ms, 32.8 k/s | 79.67 ms, 51.4 k/s | 0.64 | 0.73 | 35.6% / 36.7% | 0.62 to 0.65 |
| vale 256 m, 64 m tiles | 108 polygons | 824.59 ms, 131/s | 152.97 ms, 706/s | 0.19 | 0.24 | 4.6% / 10.7% | 0.19 to 0.19 |
| vale 1 km, 64 m tiles | 684 polygons | 20059.79 ms, 34/s | 3091.24 ms, 221/s | 0.15 | 0.23 | 2.6% / 4.6% | 0.15 to 0.15 |
| dungeon.obj, 64 m tiles | 274 polygons | 1.98 ms, 138.7 k/s | 1.68 ms, 163.3 k/s | 0.85 | 0.98 | 110.4% / 42.1% | 0.82 to 0.86 |
| nav_test.obj, 64 m tiles | 253 polygons | 5.53 ms, 45.7 k/s | 4.00 ms, 63.2 k/s | 0.72 | 0.79 | 15.5% / 6.2% | 0.72 to 0.73 |
| two storeys 128 m, 64 m tiles | 80 polygons | 25.82 ms, 3098/s | 20.37 ms, 3928/s | 0.79 | 0.81 | 30.5% / 19.7% | 0.76 to 0.82 |
| posts 128 m, 64 m tiles | 253 polygons | 136.3 µs, 1.9 M/s | 129.2 µs, 2.0 M/s | 0.95 | 1.10 | 127.6% / 30.8% | 0.91 to 1.01 |

### Span count

`rcGetHeightFieldSpanCount` and `getHeightFieldSpanCount`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 96.2 µs, 541.9 M/s | 73.9 µs, 705.0 M/s | 0.77 |  | 102.1% / 45.9% | 0.70 to 0.81 |
| nav_test.obj | 120.2 k spans | 205.6 µs, 584.4 M/s | 179.0 µs, 671.6 M/s | 0.87 |  | 66.6% / 50.8% | 0.50 to 0.91 |
| undulating.obj | 108.7 k spans | 363.3 µs, 299.2 M/s | 201.2 µs, 540.3 M/s | 0.55 |  | 39.9% / 108.3% | 0.43 to 0.56 |
| terrain 256 m | 741.4 k spans | 2.04 ms, 363.6 M/s | 1.75 ms, 422.5 M/s | 0.86 |  | 61.5% / 44.9% | 0.83 to 0.87 |
| terrain 256 m, 64 m tiles | 4.41 M spans | 10.94 ms, 402.9 M/s | 9.10 ms, 484.3 M/s | 0.83 | 1.17 | 51.0% / 72.6% | 0.82 to 0.85 |
| vale 256 m, 64 m tiles | 4.34 M spans | 11.30 ms, 384.5 M/s | 8.32 ms, 521.9 M/s | 0.74 | 0.92 | 23.7% / 32.2% | 0.73 to 0.83 |
| vale 1 km, 64 m tiles | 70.09 M spans | 194.53 ms, 360.3 M/s | 154.69 ms, 453.1 M/s | 0.80 | 1.15 | 14.8% / 32.4% | 0.71 to 0.85 |
| dungeon.obj, 64 m tiles | 304.5 k spans | 903.0 µs, 337.2 M/s | 784.0 µs, 388.4 M/s | 0.87 | 1.08 | 125.1% / 22.4% | 0.85 to 1.09 |
| nav_test.obj, 64 m tiles | 730.9 k spans | 1.41 ms, 516.6 M/s | 1.18 ms, 621.7 M/s | 0.83 | 0.97 | 39.6% / 26.6% | 0.82 to 0.96 |
| two storeys 128 m, 64 m tiles | 2.15 M spans | 3.80 ms, 564.2 M/s | 3.12 ms, 687.0 M/s | 0.82 | 0.86 | 34.1% / 29.3% | 0.81 to 0.84 |
| posts 128 m, 64 m tiles | 1.09 M spans | 1.34 ms, 811.2 M/s | 1.25 ms, 871.6 M/s | 0.93 | 1.10 | 25.5% / 37.0% | 0.90 to 0.98 |

### Unwalkable triangles

`rcClearUnwalkableTriangles` and `clearUnwalkableTriangles`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 69.5 µs, 145.7 M/s | 65.9 µs, 153.7 M/s | 0.95 |  | 57.5% / 50.6% | 0.89 to 1.07 |
| nav_test.obj | 1612 triangles | 7.5 µs, 215.9 M/s | 7.0 µs, 228.9 M/s | 0.94 |  | 27.2% / 33.3% | 0.73 to 0.99 |
| undulating.obj | 5202 triangles | 49.9 µs, 104.3 M/s | 26.8 µs, 193.8 M/s | 0.54 |  | 96.4% / 122.3% | 0.53 to 0.83 |
| terrain 256 m | 130.1 k triangles | 925.0 µs, 140.7 M/s | 857.2 µs, 151.8 M/s | 0.93 |  | 8.1% / 7.8% | 0.88 to 0.97 |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 1.05 ms, 130.4 M/s | 970.2 µs, 140.5 M/s | 0.93 | 1.11 | 19.4% / 38.7% | 0.90 to 0.96 |
| vale 256 m, 64 m tiles | 137.3 k triangles | 1.09 ms, 125.4 M/s | 1.05 ms, 130.4 M/s | 0.96 | 1.02 | 23.9% / 22.0% | 0.91 to 0.98 |
| vale 1 km, 64 m tiles | 2.22 M triangles | 17.06 ms, 130.2 M/s | 16.29 ms, 136.4 M/s | 0.95 | 1.18 | 6.9% / 18.1% | 0.90 to 0.95 |
| dungeon.obj, 64 m tiles | 10.3 k triangles | 81.8 µs, 125.7 M/s | 81.2 µs, 126.6 M/s | 0.99 | 1.12 | 61.6% / 53.5% | 0.97 to 1.01 |
| nav_test.obj, 64 m tiles | 1901 triangles | 13.6 µs, 139.5 M/s | 13.6 µs, 140.2 M/s | 0.99 | 1.10 | 15.3% / 403.7% | 0.98 to 1.07 |
| two storeys 128 m, 64 m tiles | 16 triangles | 4.1 µs, 3.9 M/s | 3.2 µs, 4.9 M/s | 0.79 | 1.00 | 60.5% / 24.0% | 0.72 to 0.87 |
| posts 128 m, 64 m tiles | 202.8 k triangles | 1.68 ms, 120.6 M/s | 1.67 ms, 121.2 M/s | 0.99 | 1.05 | 21.2% / 20.2% | 0.96 to 1.03 |

### Rasterization, unsigned short indices

`rcRasterizeTriangles` and `rasterizeTriangles`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 6.82 ms, 1.5 M/s | 6.25 ms, 1.6 M/s | 0.92 |  | 1.4% / 1.4% | 0.91 to 0.95 |
| nav_test.obj | 1612 triangles | 5.21 ms, 309.6 k/s | 4.63 ms, 348.2 k/s | 0.89 |  | 10.2% / 18.4% | 0.63 to 0.90 |
| undulating.obj | 5202 triangles | 5.88 ms, 884.9 k/s | 5.23 ms, 995.3 k/s | 0.89 |  | 4.1% / 40.4% | 0.89 to 0.90 |
| dungeon.obj, 64 m tiles | 10.3 k triangles | 18.72 ms, 549.3 k/s | 16.81 ms, 611.7 k/s | 0.90 | 0.90 | 39.5% / 48.9% | 0.86 to 0.93 |
| nav_test.obj, 64 m tiles | 1901 triangles | 21.28 ms, 89.3 k/s | 17.96 ms, 105.8 k/s | 0.84 | 0.86 | 2.3% / 1.1% | 0.84 to 0.85 |
| two storeys 128 m, 64 m tiles | 16 triangles | 48.03 ms, 333/s | 39.69 ms, 403/s | 0.83 | 0.84 | 7.3% / 6.6% | 0.82 to 0.83 |

### Rasterization, unindexed

`rcRasterizeTriangles` and `rasterizeUnindexedTriangles`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 6.55 ms, 1.5 M/s | 5.96 ms, 1.7 M/s | 0.91 |  | 1.7% / 2.7% | 0.91 to 0.92 |
| nav_test.obj | 1612 triangles | 4.82 ms, 334.7 k/s | 4.20 ms, 383.8 k/s | 0.87 |  | 5.8% / 9.1% | 0.65 to 0.87 |
| undulating.obj | 5202 triangles | 5.36 ms, 971.1 k/s | 4.74 ms, 1.1 M/s | 0.88 |  | 2.8% / 45.1% | 0.88 to 0.89 |
| terrain 256 m | 130.1 k triangles | 49.26 ms, 2.6 M/s | 44.06 ms, 3.0 M/s | 0.89 |  | 11.5% / 71.5% | 0.89 to 0.90 |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 146.19 ms, 932.4 k/s | 126.52 ms, 1.1 M/s | 0.87 | 0.89 | 40.9% / 34.0% | 0.86 to 0.89 |
| vale 256 m, 64 m tiles | 137.3 k triangles | 138.17 ms, 993.6 k/s | 116.19 ms, 1.2 M/s | 0.84 | 0.89 | 7.9% / 12.3% | 0.82 to 0.86 |
| vale 1 km, 64 m tiles | 2.22 M triangles | 2283.87 ms, 972.8 k/s | 1970.41 ms, 1.1 M/s | 0.86 | 0.98 | 5.3% / 6.6% | 0.85 to 0.87 |
| dungeon.obj, 64 m tiles | 10.3 k triangles | 18.84 ms, 545.7 k/s | 16.35 ms, 628.9 k/s | 0.87 | 0.90 | 14.2% / 47.5% | 0.85 to 0.90 |
| nav_test.obj, 64 m tiles | 1901 triangles | 21.25 ms, 89.4 k/s | 18.03 ms, 105.5 k/s | 0.85 | 0.88 | 3.5% / 3.1% | 0.84 to 0.86 |
| two storeys 128 m, 64 m tiles | 16 triangles | 45.58 ms, 351/s | 37.37 ms, 428/s | 0.82 | 0.82 | 21.3% / 10.6% | 0.82 to 0.83 |
| posts 128 m, 64 m tiles | 202.8 k triangles | 41.26 ms, 4.9 M/s | 34.98 ms, 5.8 M/s | 0.85 | 0.86 | 11.2% / 27.2% | 0.83 to 0.85 |

### Rasterization, one triangle at a time

`rcRasterizeTriangle` and `rasterizeTriangle`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 6.55 ms, 1.5 M/s | 5.95 ms, 1.7 M/s | 0.91 |  | 1.9% / 3.8% | 0.91 to 0.92 |
| nav_test.obj | 1612 triangles | 4.84 ms, 332.8 k/s | 4.11 ms, 392.1 k/s | 0.85 |  | 7.2% / 9.2% | 0.71 to 0.89 |
| undulating.obj | 5202 triangles | 5.15 ms, 1.0 M/s | 4.59 ms, 1.1 M/s | 0.89 |  | 0.6% / 0.6% | 0.87 to 0.89 |
| terrain 256 m | 130.1 k triangles | 46.94 ms, 2.8 M/s | 42.15 ms, 3.1 M/s | 0.90 |  | 9.3% / 73.1% | 0.89 to 0.95 |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 137.11 ms, 994.2 k/s | 118.63 ms, 1.1 M/s | 0.87 | 0.87 | 15.3% / 11.5% | 0.86 to 0.90 |
| vale 256 m, 64 m tiles | 137.3 k triangles | 136.14 ms, 1.0 M/s | 114.51 ms, 1.2 M/s | 0.84 | 0.87 | 7.3% / 10.8% | 0.82 to 0.86 |
| vale 1 km, 64 m tiles | 2.22 M triangles | 2333.63 ms, 952.1 k/s | 1982.50 ms, 1.1 M/s | 0.85 | 1.11 | 9.1% / 9.5% | 0.85 to 0.87 |
| dungeon.obj, 64 m tiles | 10.3 k triangles | 18.67 ms, 550.9 k/s | 16.66 ms, 617.1 k/s | 0.89 | 0.91 | 5.3% / 46.5% | 0.78 to 0.90 |
| nav_test.obj, 64 m tiles | 1901 triangles | 20.55 ms, 92.5 k/s | 17.25 ms, 110.2 k/s | 0.84 | 0.85 | 1.7% / 2.0% | 0.84 to 0.85 |
| two storeys 128 m, 64 m tiles | 16 triangles | 45.13 ms, 355/s | 36.81 ms, 435/s | 0.82 | 0.82 | 17.7% / 12.0% | 0.82 to 0.83 |
| posts 128 m, 64 m tiles | 202.8 k triangles | 41.39 ms, 4.9 M/s | 34.60 ms, 5.9 M/s | 0.84 | 0.85 | 18.7% / 23.1% | 0.83 to 0.84 |

### Adding spans, the rasterized field's again

`rcAddSpan` and `addSpan`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 638.2 µs, 81.6 M/s | 501.5 µs, 103.9 M/s | 0.79 |  | 48.2% / 17.3% | 0.78 to 0.82 |
| nav_test.obj | 120.2 k spans | 1.27 ms, 94.4 M/s | 1.02 ms, 117.3 M/s | 0.80 |  | 5.6% / 13.3% | 0.78 to 0.86 |
| undulating.obj | 108.7 k spans | 1.21 ms, 89.7 M/s | 935.8 µs, 116.2 M/s | 0.77 |  | 5.5% / 4.1% | 0.76 to 0.84 |
| terrain 256 m | 741.4 k spans | 11.58 ms, 64.0 M/s | 9.50 ms, 78.1 M/s | 0.82 |  | 20.0% / 70.9% | 0.78 to 0.83 |
| terrain 256 m, 64 m tiles | 4.41 M spans | 35.96 ms, 122.6 M/s | 26.19 ms, 168.3 M/s | 0.73 | 0.74 | 11.7% / 12.8% | 0.71 to 0.73 |
| vale 256 m, 64 m tiles | 4.34 M spans | 43.01 ms, 101.0 M/s | 30.10 ms, 144.3 M/s | 0.70 | 0.77 | 42.6% / 28.5% | 0.67 to 0.74 |
| vale 1 km, 64 m tiles | 70.09 M spans | 684.07 ms, 102.5 M/s | 485.14 ms, 144.5 M/s | 0.71 | 0.84 | 18.7% / 24.1% | 0.69 to 0.73 |
| dungeon.obj, 64 m tiles | 304.5 k spans | 2.68 ms, 113.4 M/s | 2.09 ms, 145.4 M/s | 0.78 | 1.59 | 46.0% / 47.6% | 0.76 to 0.81 |
| nav_test.obj, 64 m tiles | 730.9 k spans | 7.68 ms, 95.1 M/s | 6.47 ms, 113.0 M/s | 0.84 | 0.94 | 5.0% / 8.4% | 0.80 to 0.86 |
| two storeys 128 m, 64 m tiles | 2.15 M spans | 23.79 ms, 90.2 M/s | 18.46 ms, 116.3 M/s | 0.78 | 0.78 | 9.8% / 11.5% | 0.77 to 0.80 |
| posts 128 m, 64 m tiles | 1.09 M spans | 12.09 ms, 90.2 M/s | 8.64 ms, 126.2 M/s | 0.71 | 0.72 | 28.8% / 47.5% | 0.69 to 0.72 |

### Polygon mesh copy

`rcCopyPolyMesh` and `copyPolyMesh`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 118 polygons | 65.7 µs, 1.8 M/s | 66.8 µs, 1.8 M/s | 1.02 |  | 72.6% / 60.7% | 0.92 to 1.04 |
| nav_test.obj | 155 polygons | 122.3 µs, 1.3 M/s | 132.2 µs, 1.2 M/s | 1.08 |  | 33.9% / 75.0% | 1.03 to 1.08 |
| undulating.obj | 216 polygons | 166.7 µs, 1.3 M/s | 162.5 µs, 1.3 M/s | 0.97 |  | 47.5% / 61.9% | 0.92 to 1.16 |
| terrain 256 m | 2580 polygons | 931.2 µs, 2.8 M/s | 916.8 µs, 2.8 M/s | 0.98 |  | 10.3% / 4.8% | 0.96 to 1.02 |
| terrain 256 m, 64 m tiles | 4098 polygons | 255.9 µs, 16.0 M/s | 235.4 µs, 17.4 M/s | 0.92 | 1.13 | 101.4% / 95.9% | 0.85 to 1.01 |
| vale 256 m, 64 m tiles | 108 polygons | 229.7 µs, 470.2 k/s | 216.1 µs, 499.7 k/s | 0.94 | 1.33 | 59.8% / 56.7% | 0.90 to 1.01 |
| vale 1 km, 64 m tiles | 684 polygons | 3.93 ms, 174.0 k/s | 3.50 ms, 195.6 k/s | 0.89 | 1.52 | 44.5% / 38.0% | 0.89 to 0.93 |
| dungeon.obj, 64 m tiles | 274 polygons | 23.7 µs, 11.6 M/s | 22.1 µs, 12.4 M/s | 0.93 | 0.98 | 19.7% / 15.4% | 0.84 to 1.16 |
| nav_test.obj, 64 m tiles | 253 polygons | 48.1 µs, 5.3 M/s | 43.9 µs, 5.8 M/s | 0.91 | 1.01 | 73.2% / 81.3% | 0.90 to 0.96 |
| two storeys 128 m, 64 m tiles | 80 polygons | 65.4 µs, 1.2 M/s | 61.4 µs, 1.3 M/s | 0.94 | 0.94 | 126.2% / 118.0% | 0.83 to 0.99 |
| posts 128 m, 64 m tiles | 253 polygons | 36.3 µs, 7.0 M/s | 32.0 µs, 7.9 M/s | 0.88 | 1.00 | 130.1% / 257.5% | 0.78 to 0.93 |

### Heightfield layers

`rcBuildHeightfieldLayers` and `buildHeightfieldLayers`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 1.02 ms, 23.2 M/s | 1.03 ms, 22.8 M/s | 1.02 |  | 6.4% / 14.7% | 1.02 to 1.06 |
| nav_test.obj | 56.8 k compact spans | 1.77 ms, 32.1 M/s | 1.77 ms, 32.0 M/s | 1.00 |  | 5.8% / 122.1% | 0.98 to 1.02 |
| undulating.obj | 105.8 k compact spans | 2.57 ms, 41.1 M/s | 2.48 ms, 42.7 M/s | 0.96 |  | 9.0% / 50.4% | 0.93 to 0.98 |
| terrain 256 m | 686.7 k compact spans | fails | fails |  |  |  | |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 85.23 ms, 48.0 M/s | 85.00 ms, 48.2 M/s | 1.00 | 1.07 | 15.5% / 16.4% | 0.96 to 1.00 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 79.85 ms, 54.0 M/s | 76.94 ms, 56.0 M/s | 0.96 | 0.98 | 15.1% / 13.5% | 0.92 to 0.99 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 1429.36 ms, 48.7 M/s | 1377.39 ms, 50.5 M/s | 0.96 | 1.51 | 12.0% / 15.3% | 0.93 to 0.98 |
| dungeon.obj, 64 m tiles | 139.8 k compact spans | 6.55 ms, 21.3 M/s | 6.63 ms, 21.1 M/s | 1.01 | 1.06 | 97.6% / 56.9% | 0.80 to 1.04 |
| nav_test.obj, 64 m tiles | 349.2 k compact spans | 11.52 ms, 30.3 M/s | 11.39 ms, 30.7 M/s | 0.99 | 1.01 | 6.8% / 16.8% | 0.98 to 0.99 |
| two storeys 128 m, 64 m tiles | 2.13 M compact spans | 40.47 ms, 52.6 M/s | 39.15 ms, 54.4 M/s | 0.97 | 0.97 | 24.2% / 18.4% | 0.95 to 0.99 |
| posts 128 m, 64 m tiles | 964.1 k compact spans | fails | fails |  |  |  | |

### Monotone regions

`rcBuildRegionsMonotone` and `buildRegionsMonotone`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 477.3 µs, 49.4 M/s | 457.6 µs, 51.5 M/s | 0.96 |  | 10.7% / 7.3% | 0.96 to 0.97 |
| nav_test.obj | 56.8 k compact spans | 1.01 ms, 56.4 M/s | 858.1 µs, 66.2 M/s | 0.85 |  | 53.0% / 72.6% | 0.84 to 0.88 |
| undulating.obj | 105.8 k compact spans | 1.49 ms, 71.2 M/s | 1.30 ms, 81.4 M/s | 0.88 |  | 8.9% / 96.5% | 0.87 to 0.91 |
| terrain 256 m | 686.7 k compact spans | 30.96 ms, 22.2 M/s | 16.61 ms, 41.3 M/s | 0.54 |  | 30.5% / 93.3% | 0.52 to 0.58 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 50.62 ms, 80.9 M/s | 45.58 ms, 89.8 M/s | 0.90 | 0.92 | 7.6% / 10.8% | 0.87 to 0.91 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 43.04 ms, 100.1 M/s | 39.94 ms, 107.9 M/s | 0.93 | 0.92 | 15.2% / 23.5% | 0.87 to 0.94 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 729.55 ms, 95.3 M/s | 649.90 ms, 107.0 M/s | 0.89 | 1.10 | 8.3% / 9.2% | 0.89 to 0.90 |
| dungeon.obj, 64 m tiles | 139.8 k compact spans | 3.77 ms, 37.1 M/s | 3.42 ms, 40.9 M/s | 0.91 | 0.95 | 37.9% / 58.7% | 0.89 to 0.93 |
| nav_test.obj, 64 m tiles | 349.2 k compact spans | 6.07 ms, 57.5 M/s | 5.20 ms, 67.2 M/s | 0.86 | 0.89 | 9.7% / 3.9% | 0.85 to 0.90 |
| two storeys 128 m, 64 m tiles | 2.13 M compact spans | 24.24 ms, 87.9 M/s | 18.55 ms, 114.8 M/s | 0.77 | 0.78 | 13.6% / 23.9% | 0.73 to 0.77 |
| posts 128 m, 64 m tiles | 964.1 k compact spans | 10.06 ms, 95.9 M/s | 8.66 ms, 111.3 M/s | 0.86 | 0.89 | 46.6% / 44.7% | 0.86 to 0.88 |

### Layer regions

`rcBuildLayerRegions` and `buildLayerRegions`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 559.8 µs, 42.1 M/s | 588.7 µs, 40.0 M/s | 1.05 |  | 14.0% / 13.3% | 1.04 to 1.06 |
| nav_test.obj | 56.8 k compact spans | 1.24 ms, 45.7 M/s | 1.17 ms, 48.5 M/s | 0.94 |  | 7.5% / 6.8% | 0.93 to 0.97 |
| undulating.obj | 105.8 k compact spans | 1.93 ms, 54.7 M/s | 1.96 ms, 53.9 M/s | 1.01 |  | 1.5% / 3.5% | 1.00 to 1.03 |
| terrain 256 m | 686.7 k compact spans | 14.15 ms, 48.5 M/s | 14.10 ms, 48.7 M/s | 1.00 |  | 14.8% / 81.7% | 0.98 to 1.02 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 76.69 ms, 53.4 M/s | 78.07 ms, 52.4 M/s | 1.02 | 1.06 | 10.6% / 9.5% | 1.01 to 1.02 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 75.82 ms, 56.8 M/s | 79.74 ms, 54.0 M/s | 1.05 | 1.07 | 39.2% / 10.5% | 1.04 to 1.10 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 1225.76 ms, 56.7 M/s | 1286.78 ms, 54.1 M/s | 1.05 | 1.27 | 7.4% / 6.4% | 1.04 to 1.05 |
| dungeon.obj, 64 m tiles | 139.8 k compact spans | 4.61 ms, 30.3 M/s | 5.36 ms, 26.1 M/s | 1.16 | 1.12 | 20.4% / 27.5% | 1.08 to 1.24 |
| nav_test.obj, 64 m tiles | 349.2 k compact spans | 7.91 ms, 44.1 M/s | 7.53 ms, 46.4 M/s | 0.95 | 0.97 | 4.2% / 3.0% | 0.94 to 0.97 |
| two storeys 128 m, 64 m tiles | 2.13 M compact spans | 39.61 ms, 53.8 M/s | 34.83 ms, 61.2 M/s | 0.88 | 0.89 | 17.1% / 19.2% | 0.88 to 0.89 |
| posts 128 m, 64 m tiles | 964.1 k compact spans | 61.48 ms, 15.7 M/s | 29.96 ms, 32.2 M/s | 0.49 | 0.49 | 27.3% / 21.5% | 0.48 to 0.50 |

### Median area filter

`rcMedianFilterWalkableArea` and `medianFilterWalkableArea`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 252.7 µs, 93.3 M/s | 227.4 µs, 103.7 M/s | 0.90 |  | 13.8% / 15.0% | 0.88 to 0.93 |
| nav_test.obj | 56.8 k compact spans | 552.5 µs, 102.8 M/s | 518.0 µs, 109.7 M/s | 0.94 |  | 22.3% / 13.7% | 0.89 to 0.96 |
| undulating.obj | 105.8 k compact spans | 990.2 µs, 106.8 M/s | 929.6 µs, 113.8 M/s | 0.94 |  | 3.3% / 42.3% | 0.94 to 0.97 |
| terrain 256 m | 686.7 k compact spans | 6.09 ms, 112.8 M/s | 5.93 ms, 115.7 M/s | 0.98 |  | 10.9% / 98.7% | 0.97 to 0.99 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 37.13 ms, 110.3 M/s | 35.61 ms, 115.0 M/s | 0.96 | 0.98 | 9.3% / 14.3% | 0.96 to 0.96 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 40.44 ms, 106.6 M/s | 36.65 ms, 117.6 M/s | 0.91 | 0.96 | 10.2% / 7.9% | 0.89 to 0.99 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 689.63 ms, 100.9 M/s | 633.15 ms, 109.9 M/s | 0.92 | 1.10 | 7.9% / 8.5% | 0.92 to 0.94 |
| dungeon.obj, 64 m tiles | 139.8 k compact spans | 1.75 ms, 79.8 M/s | 1.71 ms, 81.6 M/s | 0.98 | 1.14 | 40.8% / 50.7% | 0.90 to 1.00 |
| nav_test.obj, 64 m tiles | 349.2 k compact spans | 3.50 ms, 99.9 M/s | 3.31 ms, 105.5 M/s | 0.95 | 1.01 | 3.3% / 5.1% | 0.95 to 0.97 |
| two storeys 128 m, 64 m tiles | 2.13 M compact spans | 17.63 ms, 120.8 M/s | 16.44 ms, 129.6 M/s | 0.93 | 0.94 | 24.2% / 6.7% | 0.92 to 0.93 |
| posts 128 m, 64 m tiles | 964.1 k compact spans | 2.39 ms, 403.9 M/s | 2.47 ms, 389.9 M/s | 1.04 | 1.08 | 58.6% / 52.3% | 1.00 to 1.07 |

### Box area

`rcMarkBoxArea` and `markBoxArea`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 24.9 µs, 946.7 M/s | 22.3 µs, 1.06 G/s | 0.90 |  | 85.4% / 3.1% | 0.89 to 0.90 |
| nav_test.obj | 56.8 k compact spans | 45.8 µs, 1.24 G/s | 43.4 µs, 1.31 G/s | 0.95 |  | 12.0% / 51.4% | 0.92 to 1.12 |
| undulating.obj | 105.8 k compact spans | 47.4 µs, 2.23 G/s | 40.2 µs, 2.63 G/s | 0.85 |  | 6.4% / 64.1% | 0.84 to 0.87 |
| terrain 256 m | 686.7 k compact spans | 387.1 µs, 1.77 G/s | 358.0 µs, 1.92 G/s | 0.92 |  | 101.1% / 138.8% | 0.86 to 0.99 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 1.99 ms, 2.06 G/s | 1.58 ms, 2.59 G/s | 0.80 | 1.07 | 38.2% / 43.9% | 0.78 to 0.84 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 1.80 ms, 2.40 G/s | 1.38 ms, 3.12 G/s | 0.77 | 0.93 | 40.8% / 51.2% | 0.76 to 0.78 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 29.75 ms, 2.34 G/s | 23.59 ms, 2.95 G/s | 0.79 | 1.13 | 17.6% / 19.2% | 0.79 to 0.79 |
| dungeon.obj, 64 m tiles | 139.8 k compact spans | 231.2 µs, 604.8 M/s | 179.1 µs, 780.9 M/s | 0.77 | 0.87 | 56.3% / 22.0% | 0.76 to 0.86 |
| nav_test.obj, 64 m tiles | 349.2 k compact spans | 278.9 µs, 1.25 G/s | 248.3 µs, 1.41 G/s | 0.89 | 0.92 | 14.2% / 18.5% | 0.81 to 0.92 |
| two storeys 128 m, 64 m tiles | 2.13 M compact spans | 591.0 µs, 3.60 G/s | 528.6 µs, 4.03 G/s | 0.89 | 0.91 | 21.6% / 40.5% | 0.88 to 0.93 |
| posts 128 m, 64 m tiles | 964.1 k compact spans | 518.3 µs, 1.86 G/s | 478.5 µs, 2.01 G/s | 0.92 | 0.90 | 37.3% / 31.9% | 0.90 to 0.95 |

### Convex area

`rcMarkConvexPolyArea` and `markConvexPolyArea`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 41.0 µs, 575.5 M/s | 30.5 µs, 772.3 M/s | 0.75 |  | 36.5% / 55.7% | 0.75 to 0.76 |
| nav_test.obj | 56.8 k compact spans | 110.3 µs, 515.1 M/s | 82.1 µs, 691.5 M/s | 0.75 |  | 26.7% / 32.4% | 0.74 to 0.92 |
| undulating.obj | 105.8 k compact spans | 176.7 µs, 598.7 M/s | 134.5 µs, 786.8 M/s | 0.76 |  | 18.7% / 66.9% | 0.73 to 0.76 |
| terrain 256 m | 686.7 k compact spans | 1.10 ms, 623.3 M/s | 813.2 µs, 844.4 M/s | 0.74 |  | 3.8% / 89.1% | 0.72 to 0.77 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 6.73 ms, 608.3 M/s | 4.94 ms, 828.5 M/s | 0.73 | 0.81 | 14.3% / 11.5% | 0.72 to 0.76 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 7.25 ms, 594.3 M/s | 5.10 ms, 845.2 M/s | 0.70 | 0.80 | 36.8% / 11.0% | 0.70 to 0.74 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 113.26 ms, 614.1 M/s | 81.51 ms, 853.4 M/s | 0.72 | 0.82 | 4.8% / 4.1% | 0.71 to 0.73 |
| dungeon.obj, 64 m tiles | 139.8 k compact spans | 371.9 µs, 376.0 M/s | 307.9 µs, 454.1 M/s | 0.83 | 0.99 | 36.6% / 38.0% | 0.80 to 0.84 |
| nav_test.obj, 64 m tiles | 349.2 k compact spans | 575.6 µs, 606.6 M/s | 443.4 µs, 787.6 M/s | 0.77 | 0.99 | 14.4% / 14.2% | 0.76 to 0.80 |
| two storeys 128 m, 64 m tiles | 2.13 M compact spans | 1.93 ms, 1.10 G/s | 1.37 ms, 1.55 G/s | 0.71 | 0.74 | 25.3% / 5.4% | 0.71 to 0.72 |
| posts 128 m, 64 m tiles | 964.1 k compact spans | 490.6 µs, 1.97 G/s | 441.2 µs, 2.19 G/s | 0.90 | 0.90 | 59.9% / 42.0% | 0.83 to 0.97 |

### Cylinder area

`rcMarkCylinderArea` and `markCylinderArea`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 36.8 µs, 640.3 M/s | 28.8 µs, 819.8 M/s | 0.78 |  | 48.0% / 52.9% | 0.78 to 0.79 |
| nav_test.obj | 56.8 k compact spans | 49.1 µs, 1.16 G/s | 41.9 µs, 1.36 G/s | 0.85 |  | 8.3% / 12.5% | 0.84 to 0.94 |
| undulating.obj | 105.8 k compact spans | 64.0 µs, 1.65 G/s | 51.8 µs, 2.04 G/s | 0.81 |  | 1.2% / 0.8% | 0.81 to 0.87 |
| terrain 256 m | 686.7 k compact spans | 449.4 µs, 1.53 G/s | 366.1 µs, 1.88 G/s | 0.81 |  | 26.4% / 88.4% | 0.77 to 0.83 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 2.36 ms, 1.73 G/s | 1.88 ms, 2.18 G/s | 0.80 | 0.84 | 12.3% / 12.4% | 0.79 to 0.83 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 2.19 ms, 1.97 G/s | 1.70 ms, 2.53 G/s | 0.78 | 0.85 | 49.8% / 21.8% | 0.75 to 0.79 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 38.33 ms, 1.81 G/s | 29.08 ms, 2.39 G/s | 0.76 | 1.24 | 11.4% / 10.9% | 0.75 to 0.77 |
| dungeon.obj, 64 m tiles | 139.8 k compact spans | 481.4 µs, 290.4 M/s | 391.1 µs, 357.5 M/s | 0.81 | 0.87 | 39.9% / 67.3% | 0.75 to 0.91 |
| nav_test.obj, 64 m tiles | 349.2 k compact spans | 490.9 µs, 711.3 M/s | 403.1 µs, 866.2 M/s | 0.82 | 0.89 | 4.0% / 12.3% | 0.78 to 0.86 |
| two storeys 128 m, 64 m tiles | 2.13 M compact spans | 686.1 µs, 3.10 G/s | 539.7 µs, 3.95 G/s | 0.79 | 0.94 | 34.0% / 25.6% | 0.77 to 0.87 |
| posts 128 m, 64 m tiles | 964.1 k compact spans | 486.8 µs, 1.98 G/s | 429.5 µs, 2.24 G/s | 0.88 | 0.85 | 77.7% / 19.4% | 0.78 to 0.88 |

### Polygon mesh merge, every tile

`rcMergePolyMeshes` and `mergePolyMeshes`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| terrain 256 m, 64 m tiles | 4098 polygons | 393.9 µs, 10.4 M/s | 408.4 µs, 10.0 M/s | 1.04 |  | 10.1% / 7.8% | 1.02 to 1.11 |
| vale 256 m, 64 m tiles | 108 polygons | 21.0 µs, 5.1 M/s | 23.0 µs, 4.7 M/s | 1.10 |  | 17.7% / 152.6% | 0.93 to 1.11 |
| vale 1 km, 64 m tiles | 684 polygons | 103.4 µs, 6.6 M/s | 93.8 µs, 7.3 M/s | 0.91 |  | 58.5% / 73.9% | 0.83 to 1.03 |
| dungeon.obj, 64 m tiles | 274 polygons | 26.8 µs, 10.2 M/s | 30.5 µs, 9.0 M/s | 1.14 |  | 27.9% / 70.6% | 1.09 to 1.18 |
| nav_test.obj, 64 m tiles | 253 polygons | 28.5 µs, 8.9 M/s | 30.7 µs, 8.2 M/s | 1.08 |  | 104.3% / 17.6% | 1.06 to 1.11 |
| two storeys 128 m, 64 m tiles | 80 polygons | 10.6 µs, 7.5 M/s | 12.8 µs, 6.2 M/s | 1.21 |  | 72.5% / 32.0% | 1.20 to 1.27 |
| posts 128 m, 64 m tiles | 253 polygons | 19.6 µs, 12.9 M/s | 18.9 µs, 13.4 M/s | 0.97 |  | 119.4% / 54.7% | 0.83 to 1.10 |

### Detail mesh merge, every tile

`rcMergePolyMeshDetails` and `mergePolyMeshDetails`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| terrain 256 m, 64 m tiles | 4098 polygons | 107.0 µs, 38.3 M/s | 73.0 µs, 56.1 M/s | 0.68 |  | 40.1% / 61.2% | 0.64 to 0.70 |
| vale 256 m, 64 m tiles | 108 polygons | 33.3 µs, 3.2 M/s | 22.3 µs, 4.8 M/s | 0.67 |  | 23.4% / 23.4% | 0.53 to 0.69 |
| vale 1 km, 64 m tiles | 684 polygons | 326.8 µs, 2.1 M/s | 217.2 µs, 3.1 M/s | 0.66 |  | 95.6% / 36.1% | 0.61 to 0.72 |
| dungeon.obj, 64 m tiles | 274 polygons | 7.7 µs, 35.7 M/s | 6.6 µs, 41.4 M/s | 0.86 |  | 57.6% / 39.7% | 0.67 to 0.87 |
| nav_test.obj, 64 m tiles | 253 polygons | 9.1 µs, 27.8 M/s | 6.2 µs, 40.8 M/s | 0.68 |  | 55.8% / 28.6% | 0.68 to 0.90 |
| two storeys 128 m, 64 m tiles | 80 polygons | 4.3 µs, 18.5 M/s | 3.0 µs, 26.8 M/s | 0.69 |  | 64.0% / 51.4% | 0.67 to 0.84 |
| posts 128 m, 64 m tiles | 253 polygons | 6.9 µs, 36.8 M/s | 5.1 µs, 49.3 M/s | 0.75 |  | 128.6% / 85.7% | 0.75 to 0.75 |

### Bounds

`rcCalcBounds` and `calcBounds`.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 5101 vertices | 13.1 µs, 389.0 M/s | 9.1 µs, 560.9 M/s | 0.69 |  | 31.7% / 123.8% | 0.52 to 0.71 |
| nav_test.obj | 884 vertices | 2.8 µs, 320.2 M/s | 1.9 µs, 467.0 M/s | 0.69 |  | 99.4% / 124.5% | 0.68 to 0.79 |
| undulating.obj | 2800 vertices | 11.5 µs, 243.3 M/s | 9.9 µs, 282.6 M/s | 0.86 |  | 201.6% / 264.9% | 0.76 to 0.88 |
| terrain 256 m | 66.8 k vertices | 212.0 µs, 315.0 M/s | 231.8 µs, 288.2 M/s | 1.09 |  | 139.1% / 103.6% | 0.93 to 1.12 |
| terrain 256 m, 64 m tiles | 66.8 k vertices | 353.0 µs, 189.3 M/s | 263.3 µs, 253.7 M/s | 0.75 |  | 47.7% / 52.8% | 0.59 to 0.80 |
| vale 256 m, 64 m tiles | 66.0 k vertices | 295.2 µs, 223.8 M/s | 215.3 µs, 306.8 M/s | 0.73 |  | 102.3% / 73.5% | 0.60 to 1.15 |
| vale 1 km, 64 m tiles | 1.05 M vertices | 6.19 ms, 169.6 M/s | 4.39 ms, 239.1 M/s | 0.71 |  | 26.9% / 27.3% | 0.56 to 0.88 |
| dungeon.obj, 64 m tiles | 5101 vertices | 14.3 µs, 357.0 M/s | 13.5 µs, 379.0 M/s | 0.94 |  | 111.7% / 73.4% | 0.65 to 1.26 |
| nav_test.obj, 64 m tiles | 884 vertices | 2.4 µs, 365.9 M/s | 2.3 µs, 386.5 M/s | 0.95 |  | 51.5% / 88.6% | 0.85 to 0.98 |
| two storeys 128 m, 64 m tiles | 8 vertices | 0.2 µs, 36.4 M/s | 0.4 µs, 22.5 M/s | 1.62 |  | 123.2% / 133.1% | 0.94 to 1.62 |
| posts 128 m, 64 m tiles | 393.2 k vertices | 2.45 ms, 160.5 M/s | 1.72 ms, 229.1 M/s | 0.70 |  | 13.6% / 31.7% | 0.58 to 0.81 |

### Grid size

`rcCalcGridSize` and `calcGridSize`, per call.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.0 k calls | 2.0 ns | 1.7 ns | 0.89 |  | 9.8% / 8.5% | 0.89 to 0.90 |
| nav_test.obj | 10.0 k calls | 2.1 ns | 1.9 ns | 0.89 |  | 9.8% / 8.7% | 0.88 to 0.89 |
| undulating.obj | 10.0 k calls | 2.1 ns | 1.9 ns | 0.88 |  | 17.2% / 30.2% | 0.88 to 0.89 |
| terrain 256 m | 10.0 k calls | 2.0 ns | 1.7 ns | 0.89 |  | 4.4% / 4.1% | 0.89 to 0.89 |
| terrain 256 m, 64 m tiles | 10.0 k calls | 2.0 ns | 1.7 ns | 0.89 |  | 3.8% / 22.4% | 0.89 to 0.90 |
| vale 256 m, 64 m tiles | 10.0 k calls | 2.0 ns | 1.7 ns | 0.89 |  | 3.2% / 190.0% | 0.89 to 0.89 |
| vale 1 km, 64 m tiles | 10.0 k calls | 2.2 ns | 1.9 ns | 0.88 |  | 14.6% / 122.0% | 0.80 to 0.97 |
| dungeon.obj, 64 m tiles | 10.0 k calls | 2.1 ns | 1.8 ns | 0.89 |  | 39.5% / 37.2% | 0.88 to 0.89 |
| nav_test.obj, 64 m tiles | 10.0 k calls | 2.1 ns | 1.9 ns | 0.88 |  | 4.9% / 3.0% | 0.88 to 0.89 |
| two storeys 128 m, 64 m tiles | 10.0 k calls | 2.0 ns | 1.7 ns | 0.89 |  | 3.1% / 29.0% | 0.89 to 0.89 |
| posts 128 m, 64 m tiles | 10.0 k calls | 2.1 ns | 1.8 ns | 0.83 |  | 9.9% / 11.9% | 0.83 to 0.89 |

### Polygon offset, a hexagon

`rcOffsetPoly` and `offsetPoly`, per call.

| input | work | original | port | port ÷ original | worst tile | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.0 k calls | 58.6 ns | 38.4 ns | 0.66 |  | 21.1% / 53.3% | 0.62 to 0.66 |
| nav_test.obj | 10.0 k calls | 60.1 ns | 38.4 ns | 0.64 |  | 134.7% / 8.2% | 0.63 to 0.64 |
| undulating.obj | 10.0 k calls | 60.7 ns | 38.1 ns | 0.63 |  | 83.1% / 67.3% | 0.61 to 0.64 |
| terrain 256 m | 10.0 k calls | 55.6 ns | 35.7 ns | 0.64 |  | 82.5% / 38.7% | 0.60 to 0.65 |
| terrain 256 m, 64 m tiles | 10.0 k calls | 53.7 ns | 35.9 ns | 0.67 |  | 48.4% / 23.8% | 0.61 to 0.70 |
| vale 256 m, 64 m tiles | 10.0 k calls | 56.6 ns | 35.2 ns | 0.62 |  | 10.0% / 9.8% | 0.61 to 0.62 |
| vale 1 km, 64 m tiles | 10.0 k calls | 61.7 ns | 36.7 ns | 0.60 |  | 10.9% / 22.8% | 0.59 to 0.60 |
| dungeon.obj, 64 m tiles | 10.0 k calls | 61.2 ns | 38.9 ns | 0.64 |  | 15.3% / 21.0% | 0.62 to 0.64 |
| nav_test.obj, 64 m tiles | 10.0 k calls | 59.9 ns | 37.5 ns | 0.63 |  | 4.0% / 7.4% | 0.60 to 0.64 |
| two storeys 128 m, 64 m tiles | 10.0 k calls | 56.4 ns | 36.6 ns | 0.65 |  | 6.6% / 8.6% | 0.58 to 0.68 |
| posts 128 m, 64 m tiles | 10.0 k calls | 60.3 ns | 37.7 ns | 0.62 |  | 21.1% / 17.1% | 0.61 to 0.63 |
