#!/usr/bin/env python3
"""Build a synthetic v6 archive with cross-block matches.

    tests/gen_crossblock.py OUT.osr OUT.expected [BLOCKS] [BLOCK_SIZE]

The output is the same 1 MiB pattern repeated in every block.  Block 0 stores
it as literals and a match to block 1; each following block copies the next
one from its own start.  Every match crosses exactly one block boundary, so a
decoder that cuts only at safe boundaries should use 2-block segments.
"""
import struct
import sys


def crc32c_table():
    table = []
    for i in range(256):
        crc = i
        for _ in range(8):
            crc = (crc >> 1) ^ 0x82F63B78 if crc & 1 else crc >> 1
        table.append(crc)
    return table


CRC_TABLE = crc32c_table()


def crc32c(data, crc=0):
    # OSREP uses the raw CRC-32C state: no initial/final inversion.
    for b in data:
        crc = CRC_TABLE[(crc ^ b) & 0xFF] ^ (crc >> 8)
    return crc


def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    out_path, exp_path = sys.argv[1], sys.argv[2]
    blocks = int(sys.argv[3]) if len(sys.argv) > 3 else 16
    block_size = int(sys.argv[4]) if len(sys.argv) > 4 else 1024 * 1024
    pattern = b"\xAA" * block_size

    data_end = blocks * block_size
    body = bytearray()
    stat_total = 0
    block_crcs = []

    for i in range(blocks):
        start = i * block_size
        records = bytearray()
        literals = bytearray()
        if i == 0:
            # One byte of block 0 is covered by a local match, so the block
            # is not a "stored block with records"; the rest are literals.
            literals += pattern[:-1]
            records += varint(0) + varint(1) + varint(1)
            # source 0 -> destination block 1
            records += varint(0) + varint(block_size) + varint(block_size)
        elif i < blocks - 1:
            # source at this block -> destination the next block
            records += varint(0) + varint(block_size) + varint(block_size)
        else:
            # fully covered by the previous block; a tiny local match keeps
            # statsize > 0 without changing the literal count.
            records += varint(0) + varint(1) + varint(1)

        payload = bytes(records) + bytes(literals)
        block_crc = crc32c(payload)
        block_crcs.append(block_crc)
        body += struct.pack("<IIII", len(literals), block_size, len(records),
                            block_crc)
        body += payload
        stat_total += len(records)

    header = bytearray(28)
    header[0:4] = b"OSR6"
    header[4] = 6
    header[5] = 0
    header[6] = 1  # hash_id = none
    header[7] = 0
    struct.pack_into("<IIQ", header, 8, block_size, blocks, data_end)
    struct.pack_into("<I", header, 24, crc32c(header[:24]))

    blocks_crc = 0
    for c in block_crcs:
        blocks_crc = crc32c(struct.pack("<I", c), blocks_crc)

    footer = bytearray(36)
    footer[0:4] = b"OSRF"
    struct.pack_into("<IQ", footer, 4, blocks, stat_total)
    struct.pack_into("<Q", footer, 16, 0)
    struct.pack_into("<I", footer, 24, 0)
    struct.pack_into("<I", footer, 28, blocks_crc)
    struct.pack_into("<I", footer, 32, crc32c(footer[:32]))

    with open(out_path, "wb") as f:
        f.write(header)
        f.write(body)
        f.write(footer)
    with open(exp_path, "wb") as f:
        f.write(pattern * blocks)


if __name__ == "__main__":
    main()
