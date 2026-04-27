// Standalone test tool for Compression/SREP/dedup.cpp.
//
// Mirrors tests/dup_prototype.py's CLI:
//   dedup_test selftest
//   dedup_test encode <in> <out> [--avg N --min N --max N]
//   dedup_test decode <in> <out>
//
// `selftest` runs round-trips on synthetic inputs and asserts
// decode(encode(x)) == x. `encode`/`decode` use the same .dupref
// format as the Python prototype, so blobs round-trip through either
// tool (modulo 64-bit hash collisions, statistically irrelevant).

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <vector>

#include "../Compression/SREP/dedup.cpp"

using namespace osrep_dedup;

static int read_file(const char* path, std::vector<uint8_t>& out) {
    FILE* f = fopen(path, "rb");
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

static int write_file(const char* path, const uint8_t* buf, size_t n) {
    FILE* f = fopen(path, "wb");
    if (!f) { perror(path); return 1; }
    if (n > 0 && fwrite(buf, 1, n, f) != n) {
        perror("fwrite"); fclose(f); return 1;
    }
    fclose(f);
    return 0;
}

// xorshift64 — deterministic, locale-independent.
static uint64_t xorshift64(uint64_t* s) {
    uint64_t x = *s;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    *s = x;
    return x;
}

static void fill_random(std::vector<uint8_t>& buf, size_t n, uint64_t seed) {
    buf.resize(n);
    uint64_t s = seed ? seed : 1;
    for (size_t i = 0; i < n; ++i) buf[i] = (uint8_t)(xorshift64(&s) & 0xFF);
}

static int check_roundtrip(const char* name, const std::vector<uint8_t>& in,
                           size_t* enc_size_out)
{
    uint8_t* enc = NULL; size_t enc_size = 0;
    int rc = encode(in.data(), in.size(), &enc, &enc_size);
    if (rc != DEDUP_OK) {
        fprintf(stderr, "%s: encode failed rc=%d\n", name, rc); return 1;
    }
    uint8_t* dec = NULL; size_t dec_size = 0;
    rc = decode(enc, enc_size, &dec, &dec_size);
    if (rc != DEDUP_OK) {
        fprintf(stderr, "%s: decode failed rc=%d\n", name, rc);
        free_buf(enc); return 1;
    }
    if (dec_size != in.size() || (in.size() && memcmp(dec, in.data(), in.size()) != 0)) {
        fprintf(stderr, "%s: round-trip mismatch (in=%zu out=%zu)\n",
                name, in.size(), dec_size);
        free_buf(enc); free_buf(dec); return 1;
    }
    *enc_size_out = enc_size;
    free_buf(enc); free_buf(dec);
    return 0;
}

static int cmd_selftest() {
    struct Case { const char* name; std::vector<uint8_t> data; };
    std::vector<Case> cases;

    cases.push_back({"empty", std::vector<uint8_t>()});

    {
        Case c; c.name = "zeros-64k"; c.data.assign(65536, 0);
        cases.push_back(c);
    }
    {
        Case c; c.name = "text-1m";
        const char* unit = "Omega SREP dup test payload ";
        size_t ulen = strlen(unit);
        c.data.resize(1000000);
        for (size_t i = 0; i < c.data.size(); ++i) c.data[i] = (uint8_t)unit[i % ulen];
        cases.push_back(c);
    }
    {
        Case c; c.name = "dup-pattern";
        c.data.reserve(819200);
        for (int rep = 0; rep < 100; ++rep) {
            for (int i = 0; i < 4096; ++i) c.data.push_back('A');
            for (int i = 0; i < 4096; ++i) c.data.push_back('B');
        }
        cases.push_back(c);
    }
    {
        Case c; c.name = "random-256k"; fill_random(c.data, 262144, 42);
        cases.push_back(c);
    }
    {
        Case c; c.name = "doubled-random-256k";
        std::vector<uint8_t> half; fill_random(half, 131072, 7);
        c.data.reserve(262144);
        c.data.insert(c.data.end(), half.begin(), half.end());
        c.data.insert(c.data.end(), half.begin(), half.end());
        cases.push_back(c);
    }

    printf("%-22s %8s %9s %8s\n", "case", "in_size", "enc_size", "enc_pct");
    for (size_t i = 0; i < cases.size(); ++i) {
        size_t enc_size = 0;
        if (check_roundtrip(cases[i].name, cases[i].data, &enc_size) != 0) return 1;
        size_t in = cases[i].data.size();
        int pct = in ? (int)((100ULL * enc_size) / in) : 0;
        printf("%-22s %8zu %9zu %7d%%\n", cases[i].name, in, enc_size, pct);
    }
    printf("all round-trips OK\n");
    return 0;
}

static int cmd_encode(int argc, char** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: dedup_test encode <in> <out> [--avg N --min N --max N]\n");
        return 2;
    }
    const char* in_path  = argv[2];
    const char* out_path = argv[3];
    size_t avg = DEFAULT_AVG, mn = DEFAULT_MIN, mx = DEFAULT_MAX;
    for (int i = 4; i < argc; ++i) {
        if (i + 1 >= argc) { fprintf(stderr, "missing value for %s\n", argv[i]); return 2; }
        if      (strcmp(argv[i], "--avg") == 0) { avg = (size_t)strtoull(argv[++i], NULL, 10); }
        else if (strcmp(argv[i], "--min") == 0) { mn  = (size_t)strtoull(argv[++i], NULL, 10); }
        else if (strcmp(argv[i], "--max") == 0) { mx  = (size_t)strtoull(argv[++i], NULL, 10); }
        else { fprintf(stderr, "unknown flag: %s\n", argv[i]); return 2; }
    }
    std::vector<uint8_t> data;
    if (read_file(in_path, data) != 0) return 1;
    uint8_t* enc = NULL; size_t enc_size = 0;
    int rc = encode(data.data(), data.size(), &enc, &enc_size, avg, mn, mx);
    if (rc != DEDUP_OK) { fprintf(stderr, "encode failed rc=%d\n", rc); return 1; }
    int wr = write_file(out_path, enc, enc_size);
    double ratio = data.size() ? (double)enc_size / (double)data.size() : 0.0;
    printf("input=%zu output=%zu ratio=%.4f\n", data.size(), enc_size, ratio);
    free_buf(enc);
    return wr;
}

static int cmd_decode(int argc, char** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: dedup_test decode <in> <out>\n");
        return 2;
    }
    std::vector<uint8_t> blob;
    if (read_file(argv[2], blob) != 0) return 1;
    uint8_t* dec = NULL; size_t dec_size = 0;
    int rc = decode(blob.data(), blob.size(), &dec, &dec_size);
    if (rc != DEDUP_OK) { fprintf(stderr, "decode failed rc=%d\n", rc); return 1; }
    int wr = write_file(argv[3], dec, dec_size);
    printf("input=%zu output=%zu\n", blob.size(), dec_size);
    free_buf(dec);
    return wr;
}

// split-encode <in> <meta> <body> [--avg N --min N --max N]
//   Writes the .dupref header+table to <meta> and the concatenated
//   unique-chunk body to <body>. The body is what feeds SREP in the
//   -dup pipeline; the meta becomes the archive's ODUP trailer.
static int cmd_split_encode(int argc, char** argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: dedup_test split-encode <in> <meta> <body> "
                        "[--avg N --min N --max N]\n");
        return 2;
    }
    const char* in_path   = argv[2];
    const char* meta_path = argv[3];
    const char* body_path = argv[4];
    size_t avg = DEFAULT_AVG, mn = DEFAULT_MIN, mx = DEFAULT_MAX;
    for (int i = 5; i < argc; ++i) {
        if (i + 1 >= argc) { fprintf(stderr, "missing value for %s\n", argv[i]); return 2; }
        if      (strcmp(argv[i], "--avg") == 0) { avg = (size_t)strtoull(argv[++i], NULL, 10); }
        else if (strcmp(argv[i], "--min") == 0) { mn  = (size_t)strtoull(argv[++i], NULL, 10); }
        else if (strcmp(argv[i], "--max") == 0) { mx  = (size_t)strtoull(argv[++i], NULL, 10); }
        else { fprintf(stderr, "unknown flag: %s\n", argv[i]); return 2; }
    }
    std::vector<uint8_t> data;
    if (read_file(in_path, data) != 0) return 1;
    uint8_t* meta = NULL; size_t meta_size = 0;
    uint8_t* body = NULL; size_t body_size = 0;
    int rc = encode_split(data.data(), data.size(),
                          &meta, &meta_size, &body, &body_size, avg, mn, mx);
    if (rc != DEDUP_OK) { fprintf(stderr, "encode_split rc=%d\n", rc); return 1; }
    int wm = write_file(meta_path, meta, meta_size);
    int wb = write_file(body_path, body, body_size);
    printf("input=%zu meta=%zu body=%zu\n", data.size(), meta_size, body_size);
    free_buf(meta); free_buf(body);
    return (wm | wb);
}

// split-decode <meta> <body> <out>
//   Inverse of split-encode: meta + post-SREP-decompressed body ->
//   reconstructed original.
static int cmd_split_decode(int argc, char** argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: dedup_test split-decode <meta> <body> <out>\n");
        return 2;
    }
    std::vector<uint8_t> meta, body;
    if (read_file(argv[2], meta) != 0) return 1;
    if (read_file(argv[3], body) != 0) return 1;
    uint8_t* out = NULL; size_t out_size = 0;
    int rc = decode_split(meta.data(), meta.size(),
                          body.data(), body.size(), &out, &out_size);
    if (rc != DEDUP_OK) { fprintf(stderr, "decode_split rc=%d\n", rc); return 1; }
    int wr = write_file(argv[4], out, out_size);
    printf("meta=%zu body=%zu output=%zu\n", meta.size(), body.size(), out_size);
    free_buf(out);
    return wr;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s {selftest|encode|decode|split-encode|split-decode} ...\n", argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "selftest")     == 0) return cmd_selftest();
    if (strcmp(argv[1], "encode")       == 0) return cmd_encode(argc, argv);
    if (strcmp(argv[1], "decode")       == 0) return cmd_decode(argc, argv);
    if (strcmp(argv[1], "split-encode") == 0) return cmd_split_encode(argc, argv);
    if (strcmp(argv[1], "split-decode") == 0) return cmd_split_decode(argc, argv);
    fprintf(stderr, "unknown command: %s\n", argv[1]);
    return 2;
}
