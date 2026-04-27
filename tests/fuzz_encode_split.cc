// libFuzzer harness for osrep_dedup::encode_split.
//
// encode_split is the in-memory two-output encoder: given an input
// buffer, it returns the meta blob (header + chunk table) and the body
// (concatenated unique chunks) as separate heap allocations. Internally
// it calls encode() then walks the produced chunk table to find the
// header/body boundary, so this harness exercises both encode() and
// the post-encode walker.
//
// Build (from project root):
//   clang++ -O1 -g -fsanitize=fuzzer,address,undefined \
//           -I . -I Compression -I Compression/SREP \
//           tests/fuzz_encode_split.cc \
//           -o bin/fuzz_encode_split
//
// Run:
//   bin/fuzz_encode_split -max_total_time=300 -max_len=16777216 \
//                         -artifact_prefix=tests/fuzz-artifacts/
//
// As a bonus, when the encode succeeds we feed the meta blob back
// through decode() to exercise the round-trip parser path on every
// successfully-encoded input.

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include "Compression/SREP/dedup.cpp"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    uint8_t* meta = nullptr;
    uint8_t* body = nullptr;
    size_t   meta_size = 0, body_size = 0;

    int rc = osrep_dedup::encode_split(data, size,
                                       &meta, &meta_size,
                                       &body, &body_size);
    if (rc == osrep_dedup::DEDUP_OK) {
        uint8_t* dec = nullptr;
        size_t   dec_size = 0;
        int drc = osrep_dedup::decode(meta, meta_size, &dec, &dec_size);
        if (drc == osrep_dedup::DEDUP_OK && dec) {
            osrep_dedup::free_buf(dec);
        }
    }
    if (meta) osrep_dedup::free_buf(meta);
    if (body) osrep_dedup::free_buf(body);
    return 0;
}
