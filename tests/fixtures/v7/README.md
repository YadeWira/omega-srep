# Pinned v7 fixtures (format frozen in OSREP 0.0.15)

These `.osr` files were written by the **OSREP 0.0.15 encoder** (`-m6`,
format v7, `--seed=7`). The format is frozen: every later reader must
decode them to the same bytes, and their sha256 must not change. They are
checked by `tests/v7_longrange.sh` ("pinned v7 fixtures") with the native
and the reference (`-dOSREP_NO_NATIVE`) builds.

`manifest.tsv` is:

```
sha256 <TAB> id <TAB> input <TAB> args
```

The archive is `<id>.osr`. `text.bin`, `zeros.bin` and `tiny.bin` come from
`tests/gen_corpus.sh`; `empty.bin` is empty; `rversions.bin` is the first
64 KiB of `random.bin` three times, each copy with 12 four-byte edits:

```python
r = open('random.bin', 'rb').read()[:65536]
out = bytearray()
for v in range(3):
    b = bytearray(r)
    for k in range(12):
        p = (k * 7919 + v * 104729) % (len(b) - 8)
        b[p:p + 4] = b'v%03d' % v
    out += b
```

What they cover: an empty archive (no blocks, empty table); one match
overlapping its source (`distance < length`) inside one block (`text-m6`,
`tiny-m6-l32`, `zeros-m6-hashnone` without digests) and across 64 blocks of
64 KiB (`text-m6-l32-a1-b64kb`); 44 matches whose sources are in earlier
blocks (`rversions-m6-l64-b64kb`).
