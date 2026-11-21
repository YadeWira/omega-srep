# OREP 0.0.10 — stream format 4, tested before the freeze (pre-release)

> **Update 2026-11-21: stream format 4 is frozen.** It will not change again,
> and every later OREP decoder reads version 4 streams with no flags set.
> Before the freeze, PArc's build (with this release vendored unchanged)
> was cross-tested: 42 orep-only archives whose streams decode with both
> builds and the spec oracle and are byte-identical to the CLI's. Eleven
> pinned streams are in `tests/fixtures/orep4/` (commit 4d4ee0e).

**2026-11-20.** Before freezing the stream format, OREP was tested where it
had never been tested, and the open points of the specification were
closed. **The stream format is now version 4**; 0.0.10 does not read
version 3 streams (0.0.4–0.0.9, all pre-releases). The search is the same
as 0.0.9: the blocks hold the same matches and literals, and only the
header and the zero padding before the literals differ.

## Format 4

- The header has a **flags varint** after the minimum match length. No flag
  is defined, so it is 0. A decoder rejects a flag it does not know as an
  unsupported version, not as damaged data, so a later feature that an
  older decoder must not ignore can be marked without a new version.
- The specification no longer leaves points open:
  - every varint has at most 5 bytes and a value below 2^32, except the
    end's total (at most 10 bytes, below 2^64); a varint longer than needed
    is valid within those limits;
  - the header checks run in a set order (varint limits, CRC, ranges, then
    flags), which fixes which error a decoder reports;
  - the minimum match length in the header takes any value (information
    only);
  - a streaming decoder stops at the end and leaves what follows to its
    caller; a whole-buffer decode rejects it.

## Fixes

- **`OrepDecReset` after a rejected header.** When a header was parsed and
  then rejected (for example by the memory limit), the decoder could keep
  memory made for another chunk size, and the next stream with the same
  ring size wrote past it. Valid streams and a memory limit were enough to
  trigger it. The memory is now kept only when it was made for that chunk
  and ring.
- A memory failure halfway through the header no longer leaks.
- On 32-bit targets, `OrepEncodeBuf`/`OrepDecodeBuf` wrapped the buffer
  size when doubling it past 2 GiB; they now return `OREP_E_MEM`.
- A block alignment of 2^32 or more was truncated and accepted; it is now
  rejected, as are block-header varints over 5 bytes and an end total over
  64 bits.
- With a window under 16 bytes, the period candidate of a forced anchor
  could reach further back than the window, and the decoder rejected the
  stream. It is now capped at the window.
- **Big-endian.** The C core assumed a little-endian CPU (CRC, gram hash,
  match lengths). Its loads are now little-endian on any CPU.
  `orep_vselect` takes `cap` and `mcap` as 64-bit values: FPC on big-endian
  ppc64 passed those 32-bit stack arguments in the other half of the
  doubleword from where gcc read them.

## Tests

New in `tests/orep.sh`:
- **`tests/orep_edge.sh`** (`orep_edge.lpr`, about 11 million checks, native
  and reference):
  - input sizes right at the chunk, window and ring edges;
  - a flush at every position;
  - 1-byte input and output buffers, and Peek/Skip;
  - reset and reuse, including a regression test for the reset fix;
  - concatenated streams, and streams cut at every byte;
  - flags and versions.
- **`tests/orep_fuzz.sh`** with **`tests/orep_spec.py`**. The oracle is a
  Python decoder written only from the specification. It builds streams
  with correct CRCs and hostile fields (about 60 structural mutations), and
  both binaries must give the oracle's verdict and bytes.

Run separately, because they take longer or need extra tools:
- **`tests/orep_big.sh`** (`tests/orep_bigsrc.c`): streams of 5 and 9 GiB with
  repeats that cross 2^31, 2^32 and 2^33, at 1 and 2 GB windows. It runs
  on x86_64 and i386, and checks that both give the same bytes.
- **`tests/orep_be.sh`**: powerpc64 big-endian under qemu-user, both builds.
  It checks the same bytes as x86_64 and cross decodes in both directions.

Results:
- **Over 4 GiB:** 5 GiB (and 9 GiB before the last fixes) round trip with
  `-w1024m` at 1 and 4 threads and with `-w2040m -l512`; native, reference
  and i386 give the same bytes, and i386 decodes the x86_64 stream.
  Encoder 2.1–2.4 GB, decoder 1.05–2.1 GB.
- **Fuzzing:** over 80,000 cases before and after the fixes (about 320,000
  decoder runs, from a file and from stdin): no crash, hang or disagreement
  with the oracle. A decoder build with range and overflow checks and
  valgrind memcheck found no errors.
- **Big-endian:** the reference and native builds give the same bytes as
  x86_64 for 8 inputs and 8 option sets, cross decodes work both ways, and
  120 corrupt streams are rejected without a crash.

The six binaries give the same stream as the Linux x86_64 one, with round
trips. Options: `-t1`, `-t4 -y0`, `-l32 -b64k -w1m -t3`
and `-l256 -c2 -r512 -t2`. They were run on the host (x86_64 and x86),
under qemu (arm64), under wine, on a real Windows 10 (x64 and x86), and in
the macOS CI (the whole test suite).

## Files

`orep-linux-x86_64`, `orep-linux-x86`, `orep-linux-arm64`,
`orep-windows-x86_64.exe`, `orep-windows-x86.exe`, `orep-macos-arm64`,
`orep-unit-0.0.10.tar.gz`, `SHA256SUMS`.

## License

MIT.
