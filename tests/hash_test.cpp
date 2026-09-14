// Standalone hash tool: computes a digest with the exact code the
// encoder stores in each block, so the Rust port can be diffed against
// the C++ implementation rather than against published test vectors
// alone (the vendored LibTomCrypt/VHash copies have local patches).
//
//   hash_test <algo> <seed-hex|none> <input-file>
//
// Prints the digest as lowercase hex on stdout. <algo> is one of the
// names accepted by -hash= (md5/sha1/sha512/vmac/siphash); the seed is
// required exactly when the algorithm takes one, and its length must
// match hash_seed_size.

#include <algorithm>
#include <set>
#include <stack>
#include <vector>
#include <malloc.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "../Compression/Common.h"

typedef uint32 STAT;               // matches srep.cpp's prelude
typedef uint64 Offset;
typedef size_t NUMBER;

#include "../Compression/SREP/hashes.cpp"

// Only reachable from cryptographic_prng() when a randomized hash is
// created without an explicit seed, which hash_test never does. Stubbed
// so Common.cpp does not have to be linked in.
int systemRandomData (void *buf, int len)
{
    memset(buf, 0, (size_t)len);
    return len;
}

static int read_file (const char *path, std::vector<unsigned char> &out)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return 1; }
    if (fseek(f, 0, SEEK_END) != 0) { perror("fseek"); fclose(f); return 1; }
    long sz = ftell(f);
    if (sz < 0) { perror("ftell"); fclose(f); return 1; }
    rewind(f);
    out.resize((size_t)sz);
    if (sz > 0 && fread(out.data(), 1, (size_t)sz, f) != (size_t)sz) {
        perror("fread"); fclose(f); return 1;
    }
    fclose(f);
    return 0;
}

static int hex_nibble (char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

int main (int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: %s <algo> <seed-hex|none> <input-file>\n", argv[0]);
        return 2;
    }

    int errcode = 0;
    struct hash_descriptor *d = hash_by_name(argv[1], errcode);
    if (!d || errcode) {
        fprintf(stderr, "unknown hash: %s (want %s)\n", argv[1], HASH_LIST);
        return 2;
    }

    std::vector<unsigned char> seed;
    if (strcmp(argv[2], "none") != 0) {
        const char *h = argv[2];
        size_t n = strlen(h);
        if (n % 2) { fprintf(stderr, "seed hex must have an even length\n"); return 2; }
        seed.resize(n / 2);
        for (size_t i = 0; i < seed.size(); ++i) {
            int hi = hex_nibble(h[2*i]), lo = hex_nibble(h[2*i+1]);
            if (hi < 0 || lo < 0) { fprintf(stderr, "bad hex in seed\n"); return 2; }
            seed[i] = (unsigned char)((hi << 4) | lo);
        }
    }
    if (seed.size() != d->hash_seed_size) {
        fprintf(stderr, "%s needs a %u-byte seed, got %zu\n",
                d->hash_name, d->hash_seed_size, seed.size());
        return 2;
    }

    std::vector<unsigned char> buf;
    if (read_file(argv[3], buf) != 0) return 1;

    void *h = NULL;
    if (d->new_hash) {
        h = d->new_hash(seed.empty() ? NULL : seed.data(), (int)seed.size());
        if (!h) { fprintf(stderr, "new_hash failed\n"); return 1; }
    }

    std::vector<unsigned char> result(d->hash_size ? d->hash_size : 1);
    // LibTomCrypt's process() rejects a NULL pointer (LTC_ARGCHK), which
    // std::vector::data() returns for an empty file, so hand it a valid
    // one-byte buffer in that case.
    unsigned char empty = 0;
    void *in = buf.empty() ? (void*)&empty : (void*)buf.data();
    d->hash_func(h, in, (int)buf.size(), result.data());

    for (unsigned i = 0; i < d->hash_size; ++i) printf("%02x", result[i]);
    printf("\n");
    return 0;
}
