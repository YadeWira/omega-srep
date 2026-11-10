# Omega SREP 3.0.0 vs upstream SREP 3.93a

Side-by-side measurement of the shipped Omega SREP 3.0.0 binary and the last
upstream SREP release, **SREP 3.93a beta (October 11, 2014)**. The point is
twofold: confirm that the fork's v4 container still produces the upstream
match stream, and measure what the Pascal port and the v6 container cost.

## Setup

- Host: Intel Xeon E5-2697A v4 @ 2.60 GHz, 64 logical CPUs, Linux
  6.12.115+deb13.1-amd64. A shared machine; the runs were pinned to one core
  with `taskset -c 2` and report the median of five.
- Upstream: `SREP 3.93a beta`, built from the last upstream tree
  (`/home/forum/git/srep`, commit `48f4b97`) with `make bin/srep`
  (g++ 14.2.0, `-O3 -msse2 -static`).
- Omega: the 3.0.0 release binary `osrep-linux-x86_64` (FPC 3.2.2, `-O2`),
  default v6 and `--format=v4` for the legacy container; `--seed=7` so the
  archives are reproducible. The archived Omega C++ 1.0.7 oracle is included
  to separate "the fork" from "the Pascal port": it is the same generation as
  upstream.
- Input: `real64.bin`, the first 64 MiB of a real tarball of mixed files
  (`real.tar`), plus the repository's `text.bin` (4 MiB) and `mixed.bin`
  (6.25 MiB) for the small-file behaviour.
- One thread (`-t1`), default block size (`-b8mb`), default hash (VMAC).
  Times are wall-clock and include process start; the machine's frequency
  scaling was left alone, so the absolute MB/s are not a peak measurement,
  only a same-core comparison.

## real64.bin — 64 MiB, 67,108,864 bytes

| method | tool | archive bytes | ratio | comp s | dec s |
|---|---|---:|---:|---:|---:|
| -m3 | SREP 3.93a | 58,333,128 | 86.92% | 0.25 | 0.08 |
| -m3 | Omega C++ 1.0.7 | 58,333,128 | 86.92% | 0.22 | 0.07 |
| -m3 | Omega 3.0.0 v4 | 58,333,128 | 86.92% | 0.33 | 0.10 |
| -m3 | Omega 3.0.0 v6 | 58,291,120 | 86.86% | 0.50 | 0.24 |
| -m4 | SREP 3.93a | 57,476,487 | 85.65% | 0.20 | 0.07 |
| -m4 | Omega C++ 1.0.7 | 57,476,487 | 85.65% | 0.20 | 0.07 |
| -m4 | Omega 3.0.0 v4 | 57,476,487 | 85.65% | 0.30 | 0.10 |
| -m4 | Omega 3.0.0 v6 | 57,435,228 | 85.59% | 0.45 | 0.23 |
| -m5 | SREP 3.93a | 56,695,400 | 84.48% | 0.28 | 0.07 |
| -m5 | Omega C++ 1.0.7 | 56,695,400 | 84.48% | 0.30 | 0.07 |
| -m5 | Omega 3.0.0 v4 | 56,695,400 | 84.48% | 0.38 | 0.10 |
| -m5 | Omega 3.0.0 v6 | 56,642,607 | 84.40% | 0.53 | 0.23 |

Small inputs (`text.bin` and `mixed.bin`, same three methods): upstream,
Omega C++ 1.0.7 and Omega v4 produce exactly the same archive size; v6 adds 7
to 14 bytes per archive (the per-block header and footer CRCs are a larger
fraction when the whole archive is a few hundred bytes).

## What the numbers say

1. **The fork did not change the LZ stream.** In every one of the nine
   corpus × method cells, Omega 3.0.0 with `--format=v4` writes exactly the
   same number of bytes as SREP 3.93a; only the magic, the per-run seed and
   the per-block digests differ, never the match stream. The golden suite pins
   those bytes against Omega's own C++ and Rust. The v4 container is the
   interoperability path, and it is still the upstream algorithm.

2. **v6 is smaller on real data, not bigger.** The v5/v6 record encoding
   (varint) replaces v4's fixed 12-byte records: 42,008 bytes less on `-m3`,
   41,259 on `-m4` and 52,793 on `-m5` for the same 64 MiB, 0.06–0.08% of the
   input. The per-block CRC and footer cost is tiny by comparison, and on
   archives of a few hundred bytes it is the 7–14 bytes of overhead. Integrity
   is not paid for with a worse ratio at this scale; it is paid for in speed.

3. **The Pascal port is 1.3–1.5× slower than the two C++s.** For the same v4
   container, compression goes from 0.20–0.30 s (C++) to 0.30–0.38 s
   (Pascal), and decompression from 0.07 s to 0.10 s. Upstream and the
   archived Omega C++ are within noise of each other, so the difference is the
   implementation/toolchain (FPC 3.2.2 `-O2` against g++ 14 `-O3`), not the
   fork.

4. **v6's CRCs cost ~0.14 s per 64 MiB on decode** (0.10 s → 0.23–0.24 s) and
   ~0.15 s on encode (0.33–0.38 s → 0.45–0.53 s) on this CPU. That is the
   software CRC-32C over every block, and the reason the native C/asm plan
   starts with a hardware CRC-32C: the integrity layer is cheap in bytes and
   expensive in Pascal arithmetic.

## Feature comparison

| | SREP 3.93a (2014) | Omega SREP 3.0.0 |
|---|---|---|
| implementation | C++ | Free Pascal (C/asm planned for the hot paths) |
| platforms | Linux, Windows | Linux x86/x64/ARM64, Windows 7+ x86/x64, macOS 11+ ARM64 |
| default container | legacy `.srep` (`SREP` magic) | v6 (`OSR6`), frozen |
| read formats | its own | v1-v6; v5 is read-only |
| write formats | its own | v6 (default) and v4 (`OSRP`, 1.0.x interop) |
| integrity | none | CRC-32C per block + `blocks_crc`; `--verify` without decompressing |
| deterministic archives | no seed option | `--seed=N`, `OSREP_SEED_HEX` |
| dedup pre-pass | no | `-dup` (Omega F5) |
| info | header line | `-i` for v1-v6, `-dup` metadata |

## Reproduce

The upstream tree is not in this repository (it is Bulat's). With it at
`/home/forum/git/srep`:

```bash
  $ make -C /home/forum/git/srep bin/srep
  $ head -c 64M /path/to/real.tar > /tmp/real64.bin
  $ taskset -c 2 /home/forum/git/srep/bin/srep -t1 -m3 /tmp/real64.bin /tmp/u.srep
  $ taskset -c 2 pascal/bin/osrep-linux-x86_64 -t1 -m3 --format=v4 --seed=7 \
        /tmp/real64.bin /tmp/v4.osr
  $ taskset -c 2 pascal/bin/osrep-linux-x86_64 -t1 -m3 --seed=7 \
        /tmp/real64.bin /tmp/v6.osr
```

Compare sizes with `stat -c%s` and times with `/usr/bin/time` or
`tests/measure.py`. The v6 archive must decode with the 3.0.0 binary; the
upstream `.srep` is decoded by the upstream binary (the magic changed from
`SREP` to `OSRP` in the fork, so the three do not cross-decode).
