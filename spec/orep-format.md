# OREP stream format, version 3

**Status: draft (OREP 0.0.x). It can change until it is frozen in a
release; a frozen version is never changed again, a new one gets a new
version number.** Version 1 (OREP 0.0.1-0.0.2) had one alignment for the
whole stream in the header; version 2 (0.0.3) has one per block; version 3
(0.0.4) packs the stream header and the end with varints (the chunk is a
power of two, stored as its log2).

OREP is a one-pass streaming long-range dedup, written for PArc as a
replacement of REP (clean-room, MIT; it does not read or write REP's
format). Its output is not entropy-coded: a backend (lzma, zstd...)
compresses it. All integers are little-endian. A varint is LEB128: 7 bits
per byte, low bits first, high bit set on every byte but the last.

## Stream

```
header (15-20 bytes)
block*
end
```

### Header

```
4 bytes   magic `OREP`
1 byte    version = 3
1 byte    log2 of the chunk C, 16 .. 26
varint    window W, 1 .. 0xF0000000 (at most 5 bytes)
varint    the encoder's alignment setting, 0 .. 4096 (0 = per block;
          information only)
varint    the encoder's minimum match length (information only)
u32       CRC-32C of all the header bytes before it
```

CRC-32C is the Castagnoli CRC (polynomial 0x82F63B78 reflected), initial
value 0xFFFFFFFF and final xor 0xFFFFFFFF (the iSCSI one; "123456789" gives
0xE3069283).

### Slots

The output is divided in slots of C bytes: slot k covers positions
`[k*C, (k+1)*C)`. Every block lies inside one slot. A decoder keeps the
data in a ring of `R = ceil(W / C) * C + C` bytes, where position p is at
offset `p mod R`; a block is then always contiguous in the ring and every
match source is still in it.

### Block

```
varint  out_size      1 .. C; 0 marks the end (see below)
varint  n             number of matches, at most out_size / 16
varint  col_size      bytes of the three columns, 3n .. 15n
varint  A             the block's alignment, 1 .. 4096
columns:
  n varints  lit[i]       literal bytes before match i
  n varints  len[i] - 16  match length, >= 16
  n varints  dist[i] - 1  match distance, >= 1
padding               zero bytes, see below
literals              out_size - sum(len) bytes
u32     crc           CRC-32C of the block's out_size output bytes
```

Each varint of a column holds a value below 2^32 (at most 5 bytes).

The padding has `(pos - q) mod A` zero bytes (A of this block), where `pos` is the block's
first output position and `q` the stream offset (from the first header
byte) right after the columns. With it, the first literal of the block sits
at a stream offset equal to its output position modulo A; the encoder makes
every match length a multiple of A, so all literals keep that property,
which the position-dependent contexts of a backend (lzma's pb/lp) use.

Decoding, with `pos` the block's first output position: for i in 0..n-1,
copy `lit[i]` literal bytes, then copy `len[i]` bytes one by one from
`dist[i]` bytes back (the source can overlap the bytes being written, which
repeats them); after the last match, the remaining literals. The literal
bytes are read in order from the literals section.

A block is valid when:

- `out_size <= C` and `(pos mod C) + out_size <= C`;
- `1 <= A <= 4096`;
- `n <= out_size / 16`, `3n <= col_size <= 15n` and the columns use exactly
  `col_size` bytes;
- the padding bytes are zero;
- for every match, `sum(lit[0..i]) + sum(len[0..i]) <= out_size`;
- every `dist[i] <= W` and `dist[i] <=` the output position of match i
  (it never points before the start of the stream);
- the CRC matches.

A decoder that checks these never reads or writes outside its ring.

### End

```
varint  0
varint  total         the number of bytes decoded
```

Nothing follows. A decoder rejects a stream whose total differs, that ends
early, or (for a whole-buffer decode) that has bytes after the end.

## Encoder (non-normative)

The reference encoder (src/orep/orep.pas, src/c/orep_core.c) fills one slot
at a time and searches it when it is full, when the caller flushes, or at
the end. A gear hash marks content-defined anchors (about one position in
`s`, plus a forced one after `4s` positions without one); each anchor's
gram is looked up in a direct-mapped table of the newest anchor per slot,
verified and extended both ways (up to four earlier copies of a gram are
kept, and the one with the longest forward match is used). With alignment
0 each block gets A = 1 when at least 90% of its bytes at offsets k*max(1, n div 4096) are
printable ASCII, tab, CR or LF, else A = 4. A match that reaches the end of a block is
continued at the start of the next one with the same distance. The window
is reduced to the input size (rounded up to a chunk) when the size is known
in advance. For the same parameters the encoder writes the same bytes on
every platform.
