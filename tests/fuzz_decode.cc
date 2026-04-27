// libFuzzer harness for osrep_dedup::decode.
//
// Build:
//   clang++ -O1 -g -fsanitize=fuzzer,address,undefined \
//           -I Compression -I Compression/SREP \
//           tests/fuzz_decode.cc \
//           -o bin/fuzz_decode
//
// Run (5 min, 16 MiB max input):
//   bin/fuzz_decode -max_total_time=300 -max_len=16777216 \
//                   -artifact_prefix=tests/fuzz-artifacts/
//
// Crashes / hangs / leaks / OOMs surface as artifacts.
//
// Target: the meta-blob parser inside dedup::decode. Real-world
// corruption fuzz (tests/dup_corruption_fuzz.sh) covers 27 hand-
// crafted variants; this harness asks libFuzzer to find the
// remaining surface via coverage-guided mutation.

#include <stdint.h>
#include <stddef.h>
#include "Compression/SREP/dedup.cpp"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    uint8_t* out = nullptr;
    size_t   out_size = 0;
    int rc = osrep_dedup::decode(data, size, &out, &out_size);
    if (rc == osrep_dedup::DEDUP_OK && out != nullptr) {
        // Round-trip is not asserted here — just exercise the
        // parser. Free to avoid LSan complaints.
        osrep_dedup::free_buf(out);
    }
    return 0;
}
