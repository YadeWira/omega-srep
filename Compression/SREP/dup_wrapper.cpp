// F5.3b: native -dup flag for osrep.
//
// This file is #include'd at the very end of srep.cpp. It defines
// the program's `int main`, parses for -dup / chunk-* options, and
// either passes argv straight through to srep_main (the renamed
// original main) or wraps it with the same pre/post-process pipeline
// that tests/dup_roundtrip.sh exercises:
//
//   compress:   input -> dedup encode_split -> meta + body
//               body  -> srep_main -> body.osr (at user's output path)
//               append: meta || u64_le(meta_size) || "ODUP"
//
//   decompress: read last 4 bytes of input; if "ODUP", carve off the
//               trailer + meta + body.osr to a tempfile, run
//               srep_main on body.osr -> decoded body, then run
//               dedup decode_split(meta, body) -> final output.
//               If no "ODUP" trailer, srep_main runs untouched.
//
// stdin / stdout (`-`) are not supported in -dup mode (the trailer
// scheme requires a seekable file).

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <string>
#include <vector>

// Portable 64-bit file seek/tell. Plain fseek/ftell take long, which
// is 32-bit on Windows even on x86_64 — they overflow on archives or
// inputs > 2 GiB. Match dedup.cpp's osrep_fseek64 helper.
static inline int dup_fseek64(FILE* f, int64_t off, int whence) {
#ifdef _WIN32
    return _fseeki64(f, (long long)off, whence);
#else
    return fseeko(f, (off_t)off, whence);
#endif
}
static inline int64_t dup_ftell64(FILE* f) {
#ifdef _WIN32
    return (int64_t)_ftelli64(f);
#else
    return (int64_t)ftello(f);
#endif
}

// srep_main's parser walks `while (argv[1])` and expects POSIX argv
// (NULL-terminated past argc). std::vector<char*>::data() does not
// guarantee a NULL terminator, so this helper always appends one
// before calling through.
static int call_srep_main(std::vector<char*>& v) {
    v.push_back(NULL);
    int rc = srep_main((int)v.size() - 1, v.data());
    v.pop_back();
    return rc;
}

namespace osrep_dup {

static const int OK            = 0;
static const int ERR_CMDLINE   = 2;
static const int ERR_IO        = 3;
static const int ERR_DEDUP     = 4;
static const char ODUP_MAGIC[5] = "ODUP";

struct ParseResult {
    bool dup_mode;
    bool decompress;
    bool dup_paranoid;       // --dup-paranoid: byte-compare on every hash hit
    int  method;            // -1 if not specified
    size_t chunk_avg;
    size_t chunk_min;
    size_t chunk_max;
    size_t chunk_buf;
    int  chunk_hash;         // osrep_dedup::CDC_HASH_FNV (default) or CDC_HASH_GEAR
    std::vector<char*> filtered;        // argv minus our flags
    std::vector<int>   positional_idx;  // indices in filtered[] of non-flag args
};

static bool starts_with(const char* s, const char* p) {
    return strncmp(s, p, strlen(p)) == 0;
}

static ParseResult parse_args(int argc, char** argv) {
    ParseResult r;
    r.dup_mode      = false;
    r.decompress    = false;
    r.dup_paranoid  = false;
    r.method        = -1;
    r.chunk_avg     = osrep_dedup::DEFAULT_AVG;
    r.chunk_min     = osrep_dedup::DEFAULT_MIN;
    r.chunk_max     = osrep_dedup::DEFAULT_MAX;
    r.chunk_buf     = 8 * 1024 * 1024;  // 8 MiB default for native -dup
    r.chunk_hash    = osrep_dedup::DEFAULT_CHUNK_HASH;  // FNV; --chunk-hash=gear opts in
    r.filtered.push_back(argv[0]);

    bool past_dashdash = false;
    for (int i = 1; i < argc; ++i) {
        char* a = argv[i];
        if (past_dashdash) {
            r.positional_idx.push_back((int)r.filtered.size());
            r.filtered.push_back(a);
            continue;
        }
        if (strcmp(a, "--") == 0) {
            past_dashdash = true;
            r.filtered.push_back(a);
            continue;
        }
        if (strcmp(a, "-dup") == 0)         { r.dup_mode = true; continue; }
        if (strcmp(a, "--dup-paranoid") == 0) { r.dup_paranoid = true; continue; }
        if (starts_with(a, "--seed=")) {
            ::osrep_user_seed_specified = 1;
            ::osrep_user_seed_value     = strtoull(a + 7, NULL, 0);
            continue;
        }
        if (starts_with(a, "--chunk-avg=")) { r.chunk_avg = (size_t)strtoull(a + 12, NULL, 10); continue; }
        if (starts_with(a, "--chunk-min=")) { r.chunk_min = (size_t)strtoull(a + 12, NULL, 10); continue; }
        if (starts_with(a, "--chunk-max=")) { r.chunk_max = (size_t)strtoull(a + 12, NULL, 10); continue; }
        if (starts_with(a, "--chunk-buf=")) { r.chunk_buf = (size_t)strtoull(a + 12, NULL, 10); continue; }
        if (starts_with(a, "--chunk-hash=")) {
            const char* v = a + 13;
            if      (strcmp(v, "fnv")  == 0) r.chunk_hash = osrep_dedup::CDC_HASH_FNV;
            else if (strcmp(v, "gear") == 0) r.chunk_hash = osrep_dedup::CDC_HASH_GEAR;
            else                              r.chunk_hash = -1;  // invalid; rejected in run_compress
            continue;
        }
        if (strcmp(a, "-d") == 0) { r.decompress = true; r.filtered.push_back(a); continue; }
        if (starts_with(a, "-m") && (a[2] >= '0' && a[2] <= '9')) {
            r.method = a[2] - '0';
            r.filtered.push_back(a);
            continue;
        }
        if (a[0] != '-' || strcmp(a, "-") == 0) {
            r.positional_idx.push_back((int)r.filtered.size());
        }
        r.filtered.push_back(a);
    }
    return r;
}

static int read_entire_file(const char* path, std::vector<uint8_t>& out) {
    FILE* f = fopen(path, "rb");
    if (!f) return ERR_IO;
    if (dup_fseek64(f, 0, SEEK_END) != 0) { fclose(f); return ERR_IO; }
    int64_t sz = dup_ftell64(f);
    if (sz < 0) { fclose(f); return ERR_IO; }
    rewind(f);
    out.resize((size_t)sz);
    size_t got = sz > 0 ? fread(out.data(), 1, (size_t)sz, f) : 0;
    fclose(f);
    return ((size_t)sz == got) ? OK : ERR_IO;
}

static int write_entire_file(const char* path, const uint8_t* buf, size_t n) {
    FILE* f = fopen(path, "wb");
    if (!f) return ERR_IO;
    size_t put = n > 0 ? fwrite(buf, 1, n, f) : 0;
    fclose(f);
    return (put == n) ? OK : ERR_IO;
}

static int append_bytes(const char* path, const uint8_t* buf, size_t n) {
    FILE* f = fopen(path, "ab");
    if (!f) return ERR_IO;
    size_t put = n > 0 ? fwrite(buf, 1, n, f) : 0;
    fclose(f);
    return (put == n) ? OK : ERR_IO;
}

static int make_tempfile(const char* tag, std::string& path_out) {
    // Delegate to Common.cpp's helper so Windows uses GetTempFileName
    // (honoring %TEMP%/%TMP%) and POSIX uses mkstemp under TMPDIR.
    char prefix[64];
    snprintf(prefix, sizeof(prefix), "osrep-dup-%s", tag);
    char* p = osrep_make_unique_tempfile_path(prefix);
    if (!p) return ERR_IO;
    path_out = p;
    free(p);
    return OK;
}

// ---- compress ----------------------------------------------------------

static int run_compress(const ParseResult& p, char* finame, char* foname) {
    if (p.method == 0) {
        fprintf(stderr, "\n  ERROR! -dup is incompatible with -m0; use -m3/-m4/-m5\n");
        return ERR_CMDLINE;
    }
    if (p.method == 1 || p.method == 2) {
        fprintf(stderr, "  WARNING: -dup with -m%d does CDC twice; -m3/-m4/-m5 recommended\n",
                p.method);
    }
    if (p.chunk_hash != osrep_dedup::CDC_HASH_FNV && p.chunk_hash != osrep_dedup::CDC_HASH_GEAR) {
        fprintf(stderr, "\n  ERROR! --chunk-hash must be 'fnv' or 'gear'\n");
        return ERR_CMDLINE;
    }

    // F5.3c: streaming encode reads `finame` in chunks, writes the
    // body file as it goes, and only retains the meta blob in memory.
    // Peak RAM ~= 2 * chunk_buf + chunk_table; independent of input
    // size.
    std::string body_path;
    if (make_tempfile("body", body_path) != OK) {
        fprintf(stderr, "\n  ERROR! mkstemp failed for body tempfile\n");
        return ERR_IO;
    }
    uint8_t* meta = NULL; size_t meta_size = 0;
    int erc = osrep_dedup::encode_streaming(
        finame, body_path.c_str(),
        &meta, &meta_size,
        p.chunk_avg, p.chunk_min, p.chunk_max, p.chunk_buf,
        p.dup_paranoid, p.chunk_hash);
    if (erc != osrep_dedup::DEDUP_OK) {
        unlink(body_path.c_str());
        fprintf(stderr, "\n  ERROR! dedup encode_streaming rc=%d\n", erc);
        return ERR_DEDUP;
    }

    // Substitute the input filename in the filtered argv with the body
    // tempfile so srep_main compresses the unique-chunk stream rather
    // than the user's original input.
    std::vector<char*> srep_argv = p.filtered;
    int in_argv_idx = p.positional_idx[0];
    srep_argv[in_argv_idx] = (char*)body_path.c_str();

    int srep_rc = ::call_srep_main(srep_argv);
    unlink(body_path.c_str());
    if (srep_rc != 0) {
        osrep_dedup::free_buf(meta);
        return srep_rc;
    }

    // Append trailer: meta || u64_le(meta_size) || "ODUP"
    int arc = append_bytes(foname, meta, meta_size);
    if (arc == OK) {
        uint64_t ms_le = (uint64_t)meta_size;  // x86_64 only -> already LE
        arc = append_bytes(foname, (uint8_t*)&ms_le, 8);
    }
    if (arc == OK) {
        arc = append_bytes(foname, (const uint8_t*)ODUP_MAGIC, 4);
    }
    osrep_dedup::free_buf(meta);
    if (arc != OK) {
        fprintf(stderr, "\n  ERROR! Can't append ODUP trailer to %s\n", foname);
        return ERR_IO;
    }
    return OK;
}

// ---- decompress --------------------------------------------------------

static int run_decompress_or_passthrough(const ParseResult& p,
                                         char* finame, char* foname) {
    // Sniff last 4 bytes for ODUP magic. Any failure here means we
    // fall back to plain srep_main behavior (the file may not exist
    // yet, may be `-`, etc.; let srep_main report the real error).
    FILE* fi = fopen(finame, "rb");
    if (!fi) return srep_main((int)p.filtered.size(), (char**)p.filtered.data());
    if (dup_fseek64(fi, 0, SEEK_END) != 0) {
        fclose(fi);
        return ::call_srep_main(const_cast<std::vector<char*>&>(p.filtered));
    }
    int64_t file_sz_l = dup_ftell64(fi);
    if (file_sz_l < 12) {
        fclose(fi);
        return ::call_srep_main(const_cast<std::vector<char*>&>(p.filtered));
    }
    if (dup_fseek64(fi, file_sz_l - 4, SEEK_SET) != 0) {
        fclose(fi);
        return ::call_srep_main(const_cast<std::vector<char*>&>(p.filtered));
    }
    char tail[5] = {0};
    if (fread(tail, 1, 4, fi) != 4 || memcmp(tail, ODUP_MAGIC, 4) != 0) {
        fclose(fi);
        return ::call_srep_main(const_cast<std::vector<char*>&>(p.filtered));
    }

    size_t file_sz = (size_t)file_sz_l;
    uint8_t ms_bytes[8];
    if (dup_fseek64(fi, (int64_t)(file_sz - 12), SEEK_SET) != 0 ||
        fread(ms_bytes, 1, 8, fi) != 8) {
        fclose(fi);
        fprintf(stderr, "\n  ERROR! Bad ODUP trailer in %s\n", finame);
        return ERR_DEDUP;
    }
    uint64_t meta_size_u64;
    memcpy(&meta_size_u64, ms_bytes, 8);
    size_t meta_size = (size_t)meta_size_u64;
    if (meta_size > file_sz - 12) {
        fclose(fi);
        fprintf(stderr, "\n  ERROR! ODUP meta_size=%zu exceeds file size\n", meta_size);
        return ERR_DEDUP;
    }
    size_t body_osr_size = file_sz - 12 - meta_size;

    std::vector<uint8_t> meta(meta_size);
    if (dup_fseek64(fi, (int64_t)body_osr_size, SEEK_SET) != 0 ||
        (meta_size > 0 && fread(meta.data(), 1, meta_size, fi) != meta_size)) {
        fclose(fi);
        fprintf(stderr, "\n  ERROR! Can't read ODUP meta from %s\n", finame);
        return ERR_DEDUP;
    }

    // Structural guard: the meta blob must start with the .dupref
    // magic (DUPR = 0x52505544 LE). If it doesn't, the trailing
    // "ODUP" was almost certainly a coincidence in a non-dup
    // archive (probability of both magics aligning by chance is
    // about 1/2^64). Refuse rather than feed nonsense to srep_main.
    if (meta_size < 4 || meta[0] != 0x44 || meta[1] != 0x55 ||
        meta[2] != 0x50 || meta[3] != 0x52) {
        fclose(fi);
        fprintf(stderr, "\n  ERROR! ODUP trailer present in %s but meta "
                        "header is not DUPR -- archive may be corrupted "
                        "or this is not actually a -dup archive.\n",
                finame);
        return ERR_DEDUP;
    }

    std::string body_osr_path;
    if (make_tempfile("body-osr", body_osr_path) != OK) {
        fclose(fi);
        fprintf(stderr, "\n  ERROR! mkstemp for body.osr failed\n");
        return ERR_IO;
    }
    {
        FILE* fb = fopen(body_osr_path.c_str(), "wb");
        if (!fb) {
            fclose(fi); unlink(body_osr_path.c_str());
            fprintf(stderr, "\n  ERROR! Can't open body.osr tempfile\n");
            return ERR_IO;
        }
        rewind(fi);
        uint8_t buf[64 * 1024];
        size_t remaining = body_osr_size;
        while (remaining > 0) {
            size_t take = remaining < sizeof(buf) ? remaining : sizeof(buf);
            if (fread(buf, 1, take, fi) != take ||
                fwrite(buf, 1, take, fb) != take) {
                fclose(fi); fclose(fb); unlink(body_osr_path.c_str());
                fprintf(stderr, "\n  ERROR! body.osr copy failed\n");
                return ERR_IO;
            }
            remaining -= take;
        }
        fclose(fb);
    }
    fclose(fi);

    std::string body_dec_path;
    if (make_tempfile("body-dec", body_dec_path) != OK) {
        unlink(body_osr_path.c_str());
        fprintf(stderr, "\n  ERROR! mkstemp for body-dec failed\n");
        return ERR_IO;
    }

    std::vector<char*> srep_argv = p.filtered;
    int in_idx  = p.positional_idx[0];
    int out_idx = p.positional_idx[1];
    srep_argv[in_idx]  = (char*)body_osr_path.c_str();
    srep_argv[out_idx] = (char*)body_dec_path.c_str();

    int srep_rc = ::call_srep_main(srep_argv);
    unlink(body_osr_path.c_str());
    if (srep_rc != 0) {
        unlink(body_dec_path.c_str());
        return srep_rc;
    }

    // F5.3c: streaming decode reads body sequentially and uses fseek
    // on the output file to materialize ref expansions; no per-input
    // allocation.
    int drc = osrep_dedup::decode_streaming(
        meta.data(), meta.size(), body_dec_path.c_str(), foname);
    unlink(body_dec_path.c_str());
    if (drc != osrep_dedup::DEDUP_OK) {
        fprintf(stderr, "\n  ERROR! dedup decode_streaming rc=%d\n", drc);
        return ERR_DEDUP;
    }
    return OK;
}

}  // namespace osrep_dup

// Print a one-line version banner. Used by --version / -V.
static void print_version() {
    extern char *program_version, *program_date;
    printf("%s (%s)\n", program_version, program_date);
}

// Print a brief usage synopsis. Used by --help / -h / -?.
static void print_help() {
    extern char *program_version, *program_date, *program_description,
                *program_homepage;
    printf(
        "%s (%s)\n"
        "%s\n"
        "%s\n"
        "\n"
        "Usage:\n"
        "  osrep [options] -mN  input  output       compress\n"
        "  osrep [options] -d   archive output      decompress\n"
        "  osrep -i archive                         show archive info\n"
        "\n"
        "Compression methods:\n"
        "  -m0       REP only (in-memory; works with -dBYTES)\n"
        "  -m1, -m2  Content-defined chunking (CDC)\n"
        "  -m3       Digest-comparison match search (default)\n"
        "  -m4       Full match search (best ratio for general data)\n"
        "  -m5       Exhaustive match search (slowest, best ratio)\n"
        "\n"
        "Common options:\n"
        "  -lN, -cN          minimum-match / chunk-size tuning\n"
        "  -bN               buffer size (default 8mb)\n"
        "  -tN               worker thread count for -m1/-m2\n"
        "  -dBYTES           dictionary size for -m0\n"
        "  -hash=NAME        select hash (vmac, sha1, ...)\n"
        "  -mmap, -nommap    enable/disable POSIX mmap reads\n"
        "  -temp=PATH        tempfile path override\n"
        "  --seed=N          deterministic hash seed (uint64; default is\n"
        "                    random per-run). Same seed + same input ->\n"
        "                    byte-identical archive. Useful for content-\n"
        "                    addressed storage and reproducible builds.\n"
        "  -bar              emit \"PROGRESS <done> <total>\" to stderr every\n"
        "                    ~0.5s, plus a guaranteed final line at\n"
        "                    done==total. Machine-parseable, for wrapping\n"
        "                    osrep as a subprocess.\n"
        "\n"
        "Dedup pre-pass (Omega F5):\n"
        "  -dup              enable FA-style dedup pre-pass\n"
        "  --dup-paranoid    byte-compare on every dedup hit (slower, no\n"
        "                    silent corruption on 64-bit hash collision)\n"
        "  --chunk-avg=N     CDC average chunk size (default 4096)\n"
        "  --chunk-min=N     CDC minimum chunk size (default 1024)\n"
        "  --chunk-max=N     CDC maximum chunk size (default 16384)\n"
        "  --chunk-buf=N     buffer-bounded CDC, bytes (default 8388608)\n"
        "  --chunk-hash=NAME CDC boundary hash: fnv (default) or gear.\n"
        "                    gear = Gear-hash CDC with an implicit ~64-byte\n"
        "                    content window (FastCDC-style normalized\n"
        "                    chunking); finds non-buffer-aligned duplicates\n"
        "                    that fnv's unwindowed rolling hash misses.\n"
        "                    Opt-in; does not change the .dupref format.\n"
        "\n"
        "Help:\n"
        "  --help, -h, -?    this synopsis\n"
        "  --version, -V     version line\n"
        "\n"
        "Project page: %s\n",
        program_version, program_date, program_description, program_homepage,
        program_homepage);
}

int main(int argc, char** argv) {
    // Short-circuit --version / --help BEFORE the srep_main parser
    // sees them (it would reject anything starting with '--').
    for (int i = 1; i < argc; ++i) {
        const char* a = argv[i];
        if (strcmp(a, "--version") == 0 || strcmp(a, "-V") == 0) {
            print_version();
            return 0;
        }
        if (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0 ||
            strcmp(a, "-?") == 0) {
            print_help();
            return 0;
        }
    }

    osrep_dup::ParseResult p = osrep_dup::parse_args(argc, argv);

    // Decompress always sniffs for ODUP — auto-detect even without
    // -dup on the command line, matching FA's behavior.
    if (p.decompress && p.positional_idx.size() >= 2) {
        char* finame = p.filtered[p.positional_idx[0]];
        char* foname = p.filtered[p.positional_idx[1]];
        if (strcmp(finame, "-") == 0 || strcmp(foname, "-") == 0) {
            return call_srep_main(p.filtered);
        }
        return osrep_dup::run_decompress_or_passthrough(p, finame, foname);
    }

    if (!p.dup_mode) {
        return call_srep_main(p.filtered);
    }

    if (p.positional_idx.size() < 2) {
        fprintf(stderr, "\n  ERROR! -dup requires explicit input and output filenames\n");
        return osrep_dup::ERR_CMDLINE;
    }
    char* finame = p.filtered[p.positional_idx[0]];
    char* foname = p.filtered[p.positional_idx[1]];
    if (strcmp(finame, "-") == 0 || strcmp(foname, "-") == 0) {
        fprintf(stderr, "\n  ERROR! -dup mode does not support stdin/stdout\n");
        return osrep_dup::ERR_CMDLINE;
    }
    return osrep_dup::run_compress(p, finame, foname);
}
