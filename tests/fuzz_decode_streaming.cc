// libFuzzer harness for osrep_dedup::decode_streaming.
//
// decode_streaming is the F5.3c file-based decoder used by dup_wrapper:
// meta blob in memory, body bytes streamed from disk, output streamed
// to disk with seek-back for ref records. This harness splits each
// fuzz input into (meta_len, meta_bytes, body_bytes) using a uint32 LE
// length prefix and feeds them through.
//
// Build (from project root):
//   clang++ -O1 -g -fsanitize=fuzzer,address,undefined \
//           -I . -I Compression -I Compression/SREP \
//           tests/fuzz_decode_streaming.cc \
//           -o bin/fuzz_decode_streaming
//
// Run:
//   bin/fuzz_decode_streaming -max_total_time=300 -max_len=16777216 \
//                             -artifact_prefix=tests/fuzz-artifacts/
//
// Temp files are created once per process under $TMPDIR (or /tmp) and
// reused; they are removed on exit.

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "Compression/SREP/dedup.cpp"

static char g_body_path[1024];
static char g_out_path[1024];
static bool g_initialized = false;

static void cleanup_paths() {
    if (g_initialized) {
        unlink(g_body_path);
        unlink(g_out_path);
    }
}

static void init_paths() {
    if (g_initialized) return;
    const char* tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) tmp = "/tmp";
    snprintf(g_body_path, sizeof(g_body_path), "%s/osrep-fuzz-ds-body-%d", tmp, (int)getpid());
    snprintf(g_out_path,  sizeof(g_out_path),  "%s/osrep-fuzz-ds-out-%d",  tmp, (int)getpid());
    atexit(cleanup_paths);
    g_initialized = true;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    init_paths();
    if (size < 4) return 0;

    uint32_t meta_len =
        (uint32_t)data[0] | ((uint32_t)data[1] << 8) |
        ((uint32_t)data[2] << 16) | ((uint32_t)data[3] << 24);

    size_t avail = size - 4;
    if (meta_len > avail) meta_len = (uint32_t)avail;

    const uint8_t* meta = data + 4;
    const uint8_t* body = data + 4 + meta_len;
    size_t body_len = avail - meta_len;

    FILE* fb = fopen(g_body_path, "wb");
    if (!fb) return 0;
    if (body_len) {
        if (fwrite(body, 1, body_len, fb) != body_len) {
            fclose(fb);
            return 0;
        }
    }
    if (fclose(fb) != 0) return 0;

    int rc = osrep_dedup::decode_streaming(meta, meta_len,
                                           g_body_path, g_out_path);
    (void)rc;
    return 0;
}
