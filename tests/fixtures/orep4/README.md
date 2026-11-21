# Pinned OREP format 4 streams (frozen 2026-11-21)

These `.orp` streams were written by the **OREP 0.0.10 encoder** (CLI,
commit b7b7496), except `versions-overlong.orp`, which was made by hand.
Stream format 4 is frozen (`spec/orep-format.md`): every later decoder must
decode them to the same bytes, and their sha256 must not change. They are
checked by `tests/orep.sh` ("pinned format 4 streams") with the native and
the reference (`-dOREP_NO_NATIVE`) builds, and with the spec oracle
(`tests/orep_spec.py`) when python3 is there.

`manifest.tsv` is:

```
stream sha256 <TAB> id <TAB> input <TAB> output sha256 <TAB> encoder options
```

The stream is `<id>.orp`. The inputs come from `make_inputs.py <dir>`
(Python's `random` with seed 4); the test only needs the output sha256.

What they cover:
- an empty stream (no blocks);
- one block smaller than a chunk, and streams of many 64 KiB chunks;
- runs and overlapping copies (`zeros`, `periods`: the distance is shorter
  than the length);
- matches that cross chunks, and a window as small as the chunk
  (`versions-w64k-l32-b64k`);
- alignment 1 and 4, chosen per block (text) or forced (`-a1`, `-a4`), and
  the zero padding before the literals;
- matches left as literals (`-r512`);
- `versions-overlong`: the blocks of `versions-l16-a1-s8-c1-b64k` written
  again with every varint longer than needed (header fields 5 bytes, the end
  total 10 bytes, block and column varints 2–5 bytes) and a header minimum
  match of 7. The specification allows this, so a decoder must accept it.

Made with `tests/orep_spec.py`:

```python
import orep_spec as S
raw = open('versions-l16-a1-s8-c1-b64k.orp', 'rb').read()
out, st = S.decode(raw, True)
s = S.from_struct(st)
s['hdr']['mm'] = 7
s['hdr']['ov'] = {'W_nb': 5, 'align_nb': 5, 'mm_nb': 5, 'flags_nb': 5}
for blk in s['blocks']:
    blk['ov'] = {'out_size_nb': 5, 'n_nb': 5, 'col_size_nb': 4, 'A_nb': 3,
                 'col_nb': {0: 5, 1: 2, 2: 3}}
s['end'] = {'total_nb': 10}
open('versions-overlong.orp', 'wb').write(S.serialize(s))
```
