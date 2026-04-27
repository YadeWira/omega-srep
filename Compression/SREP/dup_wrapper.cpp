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
    int  method;            // -1 if not specified
    size_t chunk_avg;
    size_t chunk_min;
    size_t chunk_max;
    size_t chunk_buf;
    std::vector<char*> filtered;        // argv minus our flags
    std::vector<int>   positional_idx;  // indices in filtered[] of non-flag args
};

static bool starts_with(const char* s, const char* p) {
    return strncmp(s, p, strlen(p)) == 0;
}

static ParseResult parse_args(int argc, char** argv) {
    ParseResult r;
    r.dup_mode    = false;
    r.decompress  = false;
    r.method      = -1;
    r.chunk_avg   = osrep_dedup::DEFAULT_AVG;
    r.chunk_min   = osrep_dedup::DEFAULT_MIN;
    r.chunk_max   = osrep_dedup::DEFAULT_MAX;
    r.chunk_buf   = 8 * 1024 * 1024;  // 8 MiB default for native -dup
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
        if (starts_with(a, "--chunk-avg=")) { r.chunk_avg = (size_t)strtoull(a + 12, NULL, 10); continue; }
        if (starts_with(a, "--chunk-min=")) { r.chunk_min = (size_t)strtoull(a + 12, NULL, 10); continue; }
        if (starts_with(a, "--chunk-max=")) { r.chunk_max = (size_t)strtoull(a + 12, NULL, 10); continue; }
        if (starts_with(a, "--chunk-buf=")) { r.chunk_buf = (size_t)strtoull(a + 12, NULL, 10); continue; }
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
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return ERR_IO; }
    long sz = ftell(f);
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
    char tmpl[256];
    const char* dir = getenv("TMPDIR");
    if (!dir || !*dir) dir = "/tmp";
    snprintf(tmpl, sizeof(tmpl), "%s/osrep-dup-%s-XXXXXX", dir, tag);
    int fd = mkstemp(tmpl);
    if (fd < 0) return ERR_IO;
    close(fd);
    path_out = tmpl;
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

    std::vector<uint8_t> input;
    int rc = read_entire_file(finame, input);
    if (rc != OK) {
        fprintf(stderr, "\n  ERROR! Can't read input %s\n", finame);
        return rc;
    }

    uint8_t* meta = NULL; size_t meta_size = 0;
    uint8_t* body = NULL; size_t body_size = 0;
    int erc = osrep_dedup::encode_split(
        input.data(), input.size(),
        &meta, &meta_size, &body, &body_size,
        p.chunk_avg, p.chunk_min, p.chunk_max, p.chunk_buf);
    if (erc != osrep_dedup::DEDUP_OK) {
        fprintf(stderr, "\n  ERROR! dedup encode_split rc=%d\n", erc);
        return ERR_DEDUP;
    }

    std::string body_path;
    if (make_tempfile("body", body_path) != OK) {
        fprintf(stderr, "\n  ERROR! mkstemp failed for body tempfile\n");
        osrep_dedup::free_buf(meta); osrep_dedup::free_buf(body);
        return ERR_IO;
    }
    if (write_entire_file(body_path.c_str(), body, body_size) != OK) {
        fprintf(stderr, "\n  ERROR! Can't write body tempfile %s\n", body_path.c_str());
        unlink(body_path.c_str());
        osrep_dedup::free_buf(meta); osrep_dedup::free_buf(body);
        return ERR_IO;
    }
    osrep_dedup::free_buf(body);

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
    if (fseek(fi, 0, SEEK_END) != 0) {
        fclose(fi);
        return ::call_srep_main(const_cast<std::vector<char*>&>(p.filtered));
    }
    long file_sz_l = ftell(fi);
    if (file_sz_l < 12) {
        fclose(fi);
        return ::call_srep_main(const_cast<std::vector<char*>&>(p.filtered));
    }
    if (fseek(fi, file_sz_l - 4, SEEK_SET) != 0) {
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
    if (fseek(fi, file_sz - 12, SEEK_SET) != 0 ||
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
    if (fseek(fi, body_osr_size, SEEK_SET) != 0 ||
        (meta_size > 0 && fread(meta.data(), 1, meta_size, fi) != meta_size)) {
        fclose(fi);
        fprintf(stderr, "\n  ERROR! Can't read ODUP meta from %s\n", finame);
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

    std::vector<uint8_t> body;
    int brc = read_entire_file(body_dec_path.c_str(), body);
    unlink(body_dec_path.c_str());
    if (brc != OK) {
        fprintf(stderr, "\n  ERROR! Can't read decoded body %s\n", body_dec_path.c_str());
        return ERR_IO;
    }

    uint8_t* out_buf = NULL; size_t out_size = 0;
    int drc = osrep_dedup::decode_split(
        meta.data(), meta.size(), body.data(), body.size(),
        &out_buf, &out_size);
    if (drc != osrep_dedup::DEDUP_OK) {
        fprintf(stderr, "\n  ERROR! dedup decode_split rc=%d\n", drc);
        return ERR_DEDUP;
    }

    int wrc = write_entire_file(foname, out_buf, out_size);
    osrep_dedup::free_buf(out_buf);
    if (wrc != OK) {
        fprintf(stderr, "\n  ERROR! Can't write final output %s\n", foname);
        return ERR_IO;
    }
    return OK;
}

}  // namespace osrep_dup

int main(int argc, char** argv) {
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
