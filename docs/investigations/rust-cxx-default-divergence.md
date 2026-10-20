# Rust/Pascal vs C++ 1.0.7: archives differ with default options

> **Status (2026-10-20): fixed in 2.3.0 (2026-10-15).** The cause this note
> found — libstdc++'s `std::sort` reordering matches with the same source in
> the second pass — was fixed by transcribing that sort in both ports; see the
> 2.3.0 entry in the CHANGELOG and `tests/cxx_sort_tie_divergence.sh`. The body
> below is the original investigation from 2026-10-09, kept as the record of
> how it was found; the "not applied" wording and the paths (`Compression/`,
> `pascal/`, `target-own/`) predate the reorganisation that moved the oracles
> to `oracles/`.

Status: **investigated, not fixed** (branch `perf8-cxxdiff`, 2026-10-09).
Nothing in the encoder was changed. This note records the cause, how
common it is, why the suites missed it, and a verified fix that can be applied
later.

## Verdict

* **Cause.** The reviewer's guess was right: it is the **order of ties in the
  second-pass sort**. `srep.cpp:899` sorts every match by `src` with
  `std::sort` and `order_by_LZ_match_src` (`srep.cpp:93-96`), which compares
  `src` only. The Rust (`second_pass.rs`, `matches.sort_by(...)`, a stable
  sort) and the Pascal (`secondpass.pas`, `SortBySrc`, a stable merge sort)
  keep tied matches in the order they were collected (ascending `dest`).
  libstdc++'s `std::sort` does not. Both ports were written on a false
  premise. Their comments say "the encoder never emits two matches with the
  same source", but it does, and often.
* **It is a deviation in the Rust (and the Pascal), not a C++ bug.** The
  comparator is a valid strict weak ordering. There is no UB, no uninitialised
  read and no thread involved. ISO C++ leaves the order of equal elements
  unspecified, but for one standard library it is a deterministic function of
  the input order. Every C++ binary this project ever shipped uses libstdc++
  and gives the same order. I checked: 1.0.7 built here with g++ 14 at `-O3`
  and `-O1`, with `-m32`, with clang++ on libstdc++, and with MinGW-w64 i686
  and x86-64 under wine. The shipped 1.0.5/1.0.6 binaries in `bin/` (Debian
  GCC 14 for Linux x86-64 and i386, GCC 13 MinGW for Win32/Win64) give that
  order too. An MSVC or libc++ build would be free to order ties differently,
  but no such build exists.
* **The Pascal agrees with the Rust**, byte for byte, on Linux and on both
  Windows builds under wine. It inherited the same assumption.
* **Decode compatibility is not at risk.** The order only affects which
  record comes first among records that copy from the same place. Each
  record is applied on its own (the Future-LZ decoders keep pending matches
  keyed by `dest`, which is unique). I ran 552 cross-decodes (C++ 1.0.7, the shipped C++ 1.0.5,
  Rust and Pascal, each decoding both the C++ and the Rust archive of every
  diverging corpus case), plus 54 with a forced spill
  (`-mem=8mb -vmblock=256k`). All were correct. Archive sizes are always
  identical.
* **It is common on real data.** 22 of 220 real files (10%) differ in at
  least one of `-m3/-m4/-m5/-m3f`. Default `-m3`: 20/220.
* **The fix is clear and verified.** The Rust and the Pascal transcribe
  libstdc++'s `std::sort` for this one call (about 180 lines each, diffs
  below). With it, all 228 inputs match the C++ in 11 modes (Rust) or 8 modes
  (Pascal, also checked under wine). The archives pinned in
  `tests/rust_cli_conformance.sh` do not move. But it changes the **v5**
  archives that Rust 2.1.2 writes on these inputs (still decodable either
  way), so it is a user-visible change that needs a CHANGELOG entry. It is
  described below and **not applied**.

## Reproduction

Binaries: C++ 1.0.7 built from `Compression/` (the Makefile's flags, output to
scratch). Rust from this branch (`perf8-int` 5bbef4c,
`target-own/x86_64-unknown-linux-gnu/release/osrep`). Pascal from
`pascal/build.sh`. The C++ always writes v4, so the ports get `--format=v4`.
`--seed=7` everywhere, because without it every run draws a fresh key.

```sh
osrep-cpp            --seed=7 -m3 in out.cpp
osrep --format=v4    --seed=7 -m3 in out.rust      # Rust and Pascal alike
cmp out.cpp out.rust                               # differs; same size
```

First 256 KiB of the reviewer's `noisy16m` (md5 of the 16 MiB file
`ee2f60405cc8e39434e4ec218e18b7e9`; 256 KiB prefix
`d5cdf1012af2d89b54b3b64c0fe64840`):

| options | C++ = Rust? | Rust = Pascal? |
|---|---|---|
| (default), `-m3`, `-m4`, `-m5`, `-m3f`, `-m4f`, `-m5f`, `-m4 -b1mb` | **differ** (same size) | equal |
| `-m3o`, `-m4o`, `-m5o`, `-m0`, `-m1`, `-m2` | equal | equal |

Only modes with a second pass are affected. `-mNo` writes the match lists
inline and never sorts. `-m0` is affected only when it emits enough tied
matches for `std::sort` to reorder them (3/220 corpus files). `-m1/-m2` (CDC) emitted no ties at all in
the survey.

About `noisy16m`: the file in `fase8/lparam/` predates
`fase8/lparam/scripts/gen_noisy.py` and that script does **not** regenerate it
byte for byte. The script's shape is right: a random 4096-byte unit, repeated,
with 1-40 random bytes inserted after a copy with probability 0.05, seed
20261009. It produces inputs that diverge the same way (`noisy4m`, `nn2m`,
`nn16m`, `nz1m` all diverge). For a self-contained reproducer, use the
generator in `tests/cxx_sort_tie_divergence.sh` below.

### Smallest reproducer

The divergence needs (a) several copies of a block that the match finder
resolves to one **shared** earlier occurrence, and (b) more than 16 matches in
total. libstdc++ finishes with a plain insertion sort, which is stable, below
17 elements (`_S_threshold = 16`). Only the introsort partitioning step
reorders equal keys.

(a) comes from an insertion whose length is not a multiple of the `-l` chunk.
Before it, the copies sit at chunk-aligned offsets and the hash table records
them. After it, the copies are misaligned by the inserted length, so no later
chunk-aligned hash ever overwrites the entry for the unit's first chunk. Every
later copy is then found through the same stored occurrence. In the
reviewer's input that is offset 24576, the last aligned copy before the first
insertion. In the 91136-byte prefix (`cee21a06e6c5c12928d3efa283bc5aa3`, the
smallest prefix of `noisy16m` that still differs with `-m3`), 16 of its 17
matches have `src = 24576`.

Minimal synthetic input (`unit` = 512 random bytes, `Random(1)`):
`unit*2 + 1 random byte + unit*18` = **10241 bytes**
(md5 `68d27d59d779fa29b871acd256ffee30`). It differs with default options,
`-m3`, `-m4`, `-m5` and `-m4f`. `unit*2 + byte + unit*16` (9217 bytes) differs
only with `-m5`: `-m5` finds 17 matches there, `-m3` only 15, and 15 ties do
not get reordered.

First difference, minimal input, default options: archive byte 1619 of 1913
(17 differing bytes, all in the match list). The C++ sorted list (from an
instrumented 1.0.7) puts the 17 matches, all `src = 512, len = 512`, in `dest`
order `5121, 9217, 8705, 8193, 7681, 7169, 6657, 6145, 5633, 1025, 4609, 4097,
3585, 3073, 2561, 2049, 1537`. The Rust and the Pascal emit ascending `dest`
(`1025, 1537, ..., 9217`).

### Proof that the sort is the whole story

Patched C++ variants, built from a scratch copy of `Compression/`:

| C++ variant | vs Rust (v4) on every diverging case |
|---|---|
| unchanged `std::sort` | differs |
| `std::stable_sort` | **identical** |
| `std::sort` with a `(src, dest)` comparator | **identical** |

I also checked a Python transcription of libstdc++'s `std::sort` (GCC 14
`bits/stl_algo.h` + `bits/stl_heap.h`):

* It matched the real `std::sort` and `std::partial_sort(first, last, last)`
  on 6000 random arrays (heavy ties, sorted, reversed, organ-pipe; 1565 of
  them reached the heapsort fallback).
* On the C++ encoder's own pre/post-sort match lists (224 files x
  `-m0/-m3/-m4/-m5`), feeding it the collection order (ascending `dest`)
  reproduced the C++ order exactly in **896/896** cases.

So the C++ order is a pure, reproducible function of data the Rust and the
Pascal already have.

## How common is it

Sample: 20 files from each of 11 corpus categories (`archive image text video
document audio music poly executable font other`), sizes 4 KiB-6 MiB,
`shuf --random-source=<(yes 20261009)`, copied to scratch: 220 files, 187 MB.
Plus the phase-8 synthetic inputs and `real16.tar` (16 MiB of real files).

| mode | corpus files that differ |
|---|---|
| `-m3` (default) | 20 / 220 |
| `-m4` | 16 / 220 |
| `-m5` | 15 / 220 |
| `-m3f` | 20 / 220 |
| `-m0` | 3 / 220 |
| `-m1`, `-m2`, `-mNo` | 0 / 220 |
| any of the above | **22 / 220** |

By category (`-m3/-m4/-m5`, file-mode pairs): archive 14/60, video 15/60,
image 6/60, document 3/60, font 3/60, text 3/60, other 3/60, poly 2/60,
audio 1/60, music 1/60, executable 0/60. `real16.tar` differs in all three
modes. `noisy4m`, `noisy16m`, `nn2m`, `nn16m` and `nz1m` differ in all three.
`rep16m`, `mixed1m` and `text1m` do not.

A file differs **if and only if** the C++ sorted list has a tie it reorders.
Across 1603 (file, mode) results there was no exception in either direction,
apart from the `-m2` flake described below.

## Why the suites did not catch it

* `tests/corpus/*` and the harness inputs of `encode_conformance.sh` /
  `pascal_encode_conformance.sh` (`dup4m`, `dup20m`: one unit repeated with
  no insertion) never produce more than 16 matches sharing a `src`. Pure
  repetition yields one long overlapping match per block, not one match per
  copy.
* `tests/rust_cli_conformance.sh` does generate a noisy input (`noisy2m`), but
  it only uses it with `-l1000`/`-l2000` and pins the Rust's own md5. Those
  combinations happen not to reorder ties: they match 1.0.7, with and without
  the fix. With default options `noisy2m` diverges in `-m0/-m3/-m4/-m5/-m4f`.
* libstdc++ sorts 16 elements or fewer stably, so small tests can never see
  it.

## Recommended fix (verified, not applied)

### Rust: `crates/osrep-core/src/second_pass.rs`

```diff
diff --git a/crates/osrep-core/src/second_pass.rs b/crates/osrep-core/src/second_pass.rs
index bcab334..d8c15af 100644
--- a/crates/osrep-core/src/second_pass.rs
+++ b/crates/osrep-core/src/second_pass.rs
@@ -72,11 +72,12 @@ pub fn second_pass<R: Read + Seek, W: Write>(
         }
     }
 
-    // 2. Sort by source (`srep.cpp:882`). The C++ uses `std::sort`, which is
-    //    unstable; the comparator is strict on `src` and the encoder never
-    //    emits two matches with the same source, so a stable sort is the
-    //    reproducible choice.
-    matches.sort_by(|a, b| a.src.cmp(&b.src));
+    // 2. Sort by source (`srep.cpp:899`). The comparator looks at `src` only,
+    //    and matches with equal `src` are common (every copy of a block that
+    //    the match finder resolves to the same earlier occurrence), so the
+    //    order of those ties is part of the archive. The C++ gets it from
+    //    libstdc++'s `std::sort`; `libstdcxx_sort` reproduces it exactly.
+    libstdcxx_sort(&mut matches, |a, b| a.src < b.src);
 
     // 3. Walk the blocks, re-emitting the matches whose source starts in each
     //    (`srep.cpp:894-961`).
@@ -245,3 +246,189 @@ pub fn second_pass<R: Read + Seek, W: Write>(
     }
     Ok(compsize)
 }
+
+// ---------------------------------------------------------------------------
+// libstdc++'s `std::sort`, transcribed (GCC `bits/stl_algo.h` `__sort`,
+// `__introsort_loop`, `__final_insertion_sort`; `bits/stl_heap.h` for the
+// depth-limit fallback). It is not stable, and which way it breaks ties is a
+// pure function of the input order, so following it step by step is what makes
+// the second pass emit equal-`src` matches in the C++ encoder's order. The
+// algorithm has been the same in every libstdc++ that built a C++ release
+// (Linux g++, MinGW-w64 for Windows, 32 and 64 bit).
+
+const SORT_THRESHOLD: usize = 16; // `_S_threshold`
+
+fn libstdcxx_sort<T: Copy, F: Fn(&T, &T) -> bool>(v: &mut [T], less: F) {
+    let n = v.len();
+    if n == 0 {
+        return;
+    }
+    // `std::__lg(n) * 2`
+    let depth = 2 * (usize::BITS - 1 - n.leading_zeros()) as usize;
+    introsort_loop(v, 0, n, depth, &less);
+    // `__final_insertion_sort`
+    if n > SORT_THRESHOLD {
+        insertion_sort(v, 0, SORT_THRESHOLD, &less);
+        for i in SORT_THRESHOLD..n {
+            unguarded_linear_insert(v, i, &less);
+        }
+    } else {
+        insertion_sort(v, 0, n, &less);
+    }
+}
+
+fn introsort_loop<T: Copy, F: Fn(&T, &T) -> bool>(
+    v: &mut [T],
+    first: usize,
+    mut last: usize,
+    mut depth: usize,
+    less: &F,
+) {
+    while last - first > SORT_THRESHOLD {
+        if depth == 0 {
+            heap_sort(v, first, last, less);
+            return;
+        }
+        depth -= 1;
+        // `__unguarded_partition_pivot`
+        let mid = first + (last - first) / 2;
+        move_median_to_first(v, first, first + 1, mid, last - 1, less);
+        let cut = unguarded_partition(v, first + 1, last, first, less);
+        introsort_loop(v, cut, last, depth, less);
+        last = cut;
+    }
+}
+
+fn move_median_to_first<T: Copy, F: Fn(&T, &T) -> bool>(
+    v: &mut [T],
+    result: usize,
+    a: usize,
+    b: usize,
+    c: usize,
+    less: &F,
+) {
+    let pick = if less(&v[a], &v[b]) {
+        if less(&v[b], &v[c]) {
+            b
+        } else if less(&v[a], &v[c]) {
+            c
+        } else {
+            a
+        }
+    } else if less(&v[a], &v[c]) {
+        a
+    } else if less(&v[b], &v[c]) {
+        c
+    } else {
+        b
+    };
+    v.swap(result, pick);
+}
+
+fn unguarded_partition<T: Copy, F: Fn(&T, &T) -> bool>(
+    v: &mut [T],
+    mut first: usize,
+    mut last: usize,
+    pivot: usize,
+    less: &F,
+) -> usize {
+    loop {
+        while less(&v[first], &v[pivot]) {
+            first += 1;
+        }
+        last -= 1;
+        while less(&v[pivot], &v[last]) {
+            last -= 1;
+        }
+        if first >= last {
+            return first;
+        }
+        v.swap(first, last);
+        first += 1;
+    }
+}
+
+/// `std::__partial_sort(first, last, last)`: `__make_heap` + `__sort_heap`.
+fn heap_sort<T: Copy, F: Fn(&T, &T) -> bool>(v: &mut [T], first: usize, last: usize, less: &F) {
+    let len = last - first;
+    if len >= 2 {
+        let mut parent = (len - 2) / 2;
+        loop {
+            let value = v[first + parent];
+            adjust_heap(v, first, parent, len, value, less);
+            if parent == 0 {
+                break;
+            }
+            parent -= 1;
+        }
+    }
+    let mut end = last;
+    while end - first > 1 {
+        end -= 1;
+        // `__pop_heap(first, end, end)`
+        let value = v[end];
+        v[end] = v[first];
+        adjust_heap(v, first, 0, end - first, value, less);
+    }
+}
+
+fn adjust_heap<T: Copy, F: Fn(&T, &T) -> bool>(
+    v: &mut [T],
+    base: usize,
+    mut hole: usize,
+    len: usize,
+    value: T,
+    less: &F,
+) {
+    let top = hole;
+    let mut second = hole;
+    while second < (len - 1) / 2 {
+        second = 2 * (second + 1);
+        if less(&v[base + second], &v[base + second - 1]) {
+            second -= 1;
+        }
+        v[base + hole] = v[base + second];
+        hole = second;
+    }
+    if len & 1 == 0 && second == (len - 2) / 2 {
+        second = 2 * (second + 1);
+        v[base + hole] = v[base + second - 1];
+        hole = second - 1;
+    }
+    // `__push_heap`
+    while hole > top {
+        let parent = (hole - 1) / 2;
+        if !less(&v[base + parent], &value) {
+            break;
+        }
+        v[base + hole] = v[base + parent];
+        hole = parent;
+    }
+    v[base + hole] = value;
+}
+
+fn insertion_sort<T: Copy, F: Fn(&T, &T) -> bool>(v: &mut [T], first: usize, last: usize, less: &F) {
+    if first == last {
+        return;
+    }
+    for i in first + 1..last {
+        if less(&v[i], &v[first]) {
+            let val = v[i];
+            v.copy_within(first..i, first + 1);
+            v[first] = val;
+        } else {
+            unguarded_linear_insert(v, i, less);
+        }
+    }
+}
+
+fn unguarded_linear_insert<T: Copy, F: Fn(&T, &T) -> bool>(v: &mut [T], mut last: usize, less: &F) {
+    let val = v[last];
+    let mut next = last - 1;
+    while less(&val, &v[next]) {
+        v[last] = v[next];
+        last = next;
+        next -= 1;
+    }
+    v[last] = val;
+}
```

### Pascal: `pascal/src/secondpass.pas`

Replace the whole `SortBySrc` (comment included, today a stable merge sort)
with the same transcription. The call site (`SortBySrc(matches)`) does not
change. It uses `Int64` indices and `while` loops, with no `SizeInt` and no
64-bit `for` (see "Trampas conocidas").

```pascal
{ Orden por Src con el MISMO desempate que el C++: transcripcion del
  std::sort de libstdc++ (bits/stl_algo.h __sort/__introsort_loop/
  __final_insertion_sort, y bits/stl_heap.h para el corte por profundidad).
  No es estable, pero como rompe los empates es funcion pura del orden de
  entrada, y los matches con el mismo origen son comunes (todas las copias
  de un bloque que el buscador resuelve a la misma aparicion anterior).
  Indices Int64 y bucles while: nada de SizeInt ni de for con 64 bits. }
procedure SortBySrc(var M: TMatches);
const Threshold = 16;   { _S_threshold }

  function Less(const a, b: TLzMatch): Boolean; inline;
  begin
    Result := a.Src < b.Src;
  end;

  procedure Swap(i, j: Int64);
  var t: TLzMatch;
  begin
    t := M.W[i]; M.W[i] := M.W[j]; M.W[j] := t;
  end;

  procedure UnguardedLinearInsert(last: Int64);
  var val: TLzMatch; next: Int64;
  begin
    val := M.W[last];
    next := last - 1;
    while Less(val, M.W[next]) do
    begin
      M.W[last] := M.W[next];
      last := next;
      Dec(next);
    end;
    M.W[last] := val;
  end;

  procedure InsertionSort(first, last: Int64);
  var i, k: Int64; val: TLzMatch;
  begin
    if first = last then Exit;
    i := first + 1;
    while i < last do
    begin
      if Less(M.W[i], M.W[first]) then
      begin
        val := M.W[i];
        k := i;
        while k > first do begin M.W[k] := M.W[k - 1]; Dec(k); end;
        M.W[first] := val;
      end
      else
        UnguardedLinearInsert(i);
      Inc(i);
    end;
  end;

  procedure AdjustHeap(base, hole, len: Int64; const value: TLzMatch);
  var top, second, parent: Int64;
  begin
    top := hole;
    second := hole;
    while second < (len - 1) div 2 do
    begin
      second := 2 * (second + 1);
      if Less(M.W[base + second], M.W[base + second - 1]) then Dec(second);
      M.W[base + hole] := M.W[base + second];
      hole := second;
    end;
    if ((len and 1) = 0) and (second = (len - 2) div 2) then
    begin
      second := 2 * (second + 1);
      M.W[base + hole] := M.W[base + second - 1];
      hole := second - 1;
    end;
    { __push_heap }
    while hole > top do
    begin
      parent := (hole - 1) div 2;
      if not Less(M.W[base + parent], value) then Break;
      M.W[base + hole] := M.W[base + parent];
      hole := parent;
    end;
    M.W[base + hole] := value;
  end;

  { std::__partial_sort(first, last, last): __make_heap + __sort_heap }
  procedure HeapSort(first, last: Int64);
  var len, parent, en: Int64; value: TLzMatch;
  begin
    len := last - first;
    if len >= 2 then
    begin
      parent := (len - 2) div 2;
      while True do
      begin
        value := M.W[first + parent];
        AdjustHeap(first, parent, len, value);
        if parent = 0 then Break;
        Dec(parent);
      end;
    end;
    en := last;
    while en - first > 1 do
    begin
      Dec(en);
      value := M.W[en];
      M.W[en] := M.W[first];
      AdjustHeap(first, 0, en - first, value);
    end;
  end;

  procedure MoveMedianToFirst(result, a, b, c: Int64);
  var pick: Int64;
  begin
    if Less(M.W[a], M.W[b]) then
    begin
      if Less(M.W[b], M.W[c]) then pick := b
      else if Less(M.W[a], M.W[c]) then pick := c
      else pick := a;
    end
    else if Less(M.W[a], M.W[c]) then pick := a
    else if Less(M.W[b], M.W[c]) then pick := c
    else pick := b;
    Swap(result, pick);
  end;

  function UnguardedPartition(first, last, pivot: Int64): Int64;
  begin
    while True do
    begin
      while Less(M.W[first], M.W[pivot]) do Inc(first);
      Dec(last);
      while Less(M.W[pivot], M.W[last]) do Dec(last);
      if not (first < last) then Exit(first);
      Swap(first, last);
      Inc(first);
    end;
  end;

  procedure IntrosortLoop(first, last, depth: Int64);
  var cut: Int64;
  begin
    while last - first > Threshold do
    begin
      if depth = 0 then
      begin
        HeapSort(first, last);
        Exit;
      end;
      Dec(depth);
      MoveMedianToFirst(first, first + 1, first + (last - first) div 2, last - 1);
      cut := UnguardedPartition(first + 1, last, first);
      IntrosortLoop(cut, last, depth);
      last := cut;
    end;
  end;

var n, lg, i: Int64;
begin
  n := Int64(M.N);
  if n = 0 then Exit;
  lg := -1; i := n;
  while i > 0 do begin Inc(lg); i := i shr 1; end;   { std::__lg }
  IntrosortLoop(0, n, 2 * lg);
  if n > Threshold then
  begin
    InsertionSort(0, Threshold);
    i := Threshold;
    while i < n do begin UnguardedLinearInsert(i); Inc(i); end;
  end
  else
    InsertionSort(0, n);
end;
```

### What was verified with the two prototypes

The prototypes were built into scratch, and the worktree file was restored:
the branch carries no code change.

* Rust prototype vs C++ 1.0.7: 228 inputs (the 220 corpus files plus the
  synthetic ones and `real16.tar`) x `-m0 -m3 -m4 -m5 -m3f -m4f -m5f -m3o
  -m4o -m1 "-m4 -b1mb"`. **0 differences**. The v5 default archive of every
  input round-trips. No new clippy warnings.
* Pascal prototype (Linux) vs C++: 226 inputs x `-m0 -m3 -m4 -m5 -m3f -m4f
  -m4o -m1`. **0 differences**. Its v5 archives are byte-identical to the
  Rust prototype's and round-trip. Win64 and Win32 builds under wine: 48 runs
  on the worst inputs, **0 differences**.
* The 9 archives pinned by md5 in `tests/rust_cli_conformance.sh` are
  unchanged by the fix. `tests/corpus/*` with `-m0/-m3/-m4/-m5/-m4f` were
  already equal to the C++ and stay equal.
* `tests/cxx_sort_tie_divergence.sh` (below) exits 1 on the current Rust and
  Pascal and 0 on both prototypes.

### Consequences to accept before applying

* **v5 archives change bytes** on inputs with reordered ties. With
  `--seed=N`, 2.1.2 and a fixed version would write different (equally valid,
  same size) archives. Anyone who stores `--seed` archive hashes, such as a
  content-addressed cache, would see a one-time change. v4 archives move
  *toward* 1.0.x, which is what ytool's pinned 1.0.5 writes. This needs a
  CHANGELOG `[Unreleased]` / Fixed entry ("archives are byte-identical to the
  1.0.x encoder again on inputs with repeated blocks; v5 archives of such
  inputs change bytes, decoding is unaffected").
* The cost is negligible: one sort of the match list per archive, introsort
  instead of merge sort.

### Regression coverage to add with the fix

* Wire `tests/cxx_sort_tie_divergence.sh` (or its three inputs) into
  `encode_conformance.sh` and `pascal_encode_conformance.sh`. Both already
  compare against `bin/osrep`. Before the fix it fails, as verified above.
* Add a Rust unit test that runs `libstdcxx_sort` on arrays with many ties
  against a golden order produced by the C++ harness, including one array
  that reaches the heapsort fallback. Check the Pascal the same way, through
  the encode harness.
* Fix the false premise in both comments.

### Alternative (not recommended)

Declare the tie order non-normative, keep the stable sort, and narrow the
"byte-exact with the C++" claim to "decode-compatible, byte-exact except for
the order of records with equal source". It costs nothing in code, but the
claim is currently stated without qualification, the gap shows up on 10% of
real files, and the fix is small and fully verified.

## Side finding: the C++ `-m2` encoder is not deterministic

While surveying, one `-m2` result on `real16.tar` (16 MiB) differed and had no
ties. Repeating the **C++** run 30 times with the same seed gave **3 distinct
archives**: 28 x `16314846` bytes, plus `16316988` and `16317146`. With `-t1`:
28 x `16314846`, plus `16315168` and `16335828`. Every variant round-trips.
The Rust and the Pascal always write the majority archive. `-m1` was stable
in 30/30 runs, and `-m3/-m4/-m5` showed no such effect (each of their
differences is explained by a tie). valgrind on the `-O1` build found nothing
in the encoder: only reports inside static glibc, and that run produced the
majority output. A race is the likely cause, but it was not chased.

Consequence: a single `-m2` comparison against the C++ on large inputs can
flake. The C++ oracle needs repeated runs (take the majority) for `-m2`.
Worth a separate investigation. It is a C++-only defect and does not affect
the ports.

## Artifacts (scratch, not committed)

`/mnt/IA_LAB/agentes/osrep/fase8/perf8-cxxdiff/`:

* `osrep-cpp*`: 1.0.7 builds (`-O3`, `-O1`, i686, clang, MinGW w32/w64,
  `-stable`, `-srcdest`, `-dump`). `cxx-*.diff` holds the variant patches.
  `osrep-cpp-dump` writes the sorted list to `$OSREP_DUMP`.
* `stdsort.py`, `check_stdsort.py`, `sortharness.cpp`, `check_dumps.py`: the
  libstdc++ transcription and its checks.
* `rust-fix.diff`, `pascal-fix.diff`, `pascal-sort.inc`, `osrep-rust-fix`,
  `pfix/bin/`: the prototypes.
* `corpus/` (sample copies), `corpus-results*.txt`, `fix-results.txt`,
  `pfix-results.txt`: survey and verification logs.
* `gen_min.py`, `minimize*.sh`, `w/min/`: minimisation.
