// Expected outputs of libstdc++'s std::sort for the `libstdcxx_sort` unit test
// in oracles/rust/crates/osrep-core/src/second_pass.rs.
//
// The C++ second pass (srep.cpp:899) sorts the match list with std::sort and a
// comparator that looks at `src` only, so the order in which equal-`src`
// matches come out is part of the archive. The Rust and the Pascal transcribe
// libstdc++'s algorithm; this program runs the real one on the same arrays the
// Rust test generates, and prints one FNV-1a hash per array of the resulting
// permutation (the original indices, in sorted order), as Rust source.
//
//   make -C oracles/cxx bin/stdsort_fixture && oracles/cxx/bin/stdsort_fixture
//
// The generator (SplitMix64, the eight shapes, the sizes) must stay identical
// to `stdsort_case` in the Rust test and to `PrintSortFixture` in
// pascal/encodetool.lpr; tests/pascal_encode_conformance.sh diffs the Pascal's
// output against this program's. g++ 14 (native and -m32), clang++ on
// libstdc++ and MinGW-w64 i686/x86-64 all print the same.

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <vector>

struct E { uint64_t key; uint32_t id; };
static bool lt(const E &a, const E &b) { return a.key < b.key; }

static uint64_t splitmix(uint64_t &s) {
  uint64_t z = (s += 0x9E3779B97F4A7C15ull);
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
  return z ^ (z >> 31);
}

static const unsigned SIZES[] = {
  0, 1, 2, 3, 4, 5, 8, 15, 16, 17, 18, 19, 20, 24, 31, 32, 33, 34, 40, 48,
  63, 64, 65, 100, 127, 128, 129, 200, 255, 256, 257, 300, 500, 511, 512, 513,
  777, 1000, 1023, 1024, 1025, 1500, 1999, 2000, 2047, 2048};
static const unsigned KINDS = 8;

// Shapes: 0 few distinct keys, 1 three keys, 2 ascending with ties,
// 3 descending with ties, 4 organ pipe, 5 wide random keys, 6 all equal,
// 7 two interleaved runs with ties (sawtooth).
static std::vector<uint64_t> keys_for(unsigned kind, unsigned n) {
  uint64_t s = (uint64_t)kind * 1000003u + n;
  std::vector<uint64_t> k(n);
  for (unsigned i = 0; i < n; i++) {
    uint64_t r = splitmix(s);
    switch (kind) {
      case 0: k[i] = r % (n / 8 + 1); break;
      case 1: k[i] = r % 3; break;
      case 2: case 3: k[i] = r % (n + 1); break;
      case 4: k[i] = std::min(i, n - i); break;
      case 5: k[i] = r >> 24; break;
      case 6: k[i] = 0; break;
      default: k[i] = (i % 2 ? i / 2 : n - i / 2) / 3; break;
    }
  }
  if (kind == 2) std::sort(k.begin(), k.end());
  if (kind == 3) std::sort(k.begin(), k.end(), [](uint64_t a, uint64_t b) { return a > b; });
  return k;
}

static uint32_t fnv1a(const std::vector<E> &v) {
  uint32_t h = 2166136261u;
  for (const E &e : v)
    for (int b = 0; b < 4; b++) { h ^= (e.id >> (8 * b)) & 0xFF; h *= 16777619u; }
  return h;
}

int main() {
  std::printf("const STDSORT_EXPECTED: [[u32; %u]; %u] = [\n",
              (unsigned)(sizeof SIZES / sizeof *SIZES), KINDS);
  for (unsigned kind = 0; kind < KINDS; kind++) {
    std::printf("    [");
    unsigned col = 0;
    for (unsigned n : SIZES) {
      std::vector<uint64_t> k = keys_for(kind, n);
      std::vector<E> v(n);
      for (unsigned i = 0; i < n; i++) v[i] = E{k[i], i};
      std::sort(v.begin(), v.end(), lt);
      if (col % 7 == 0) std::printf("\n        ");
      else std::printf(" ");
      std::printf("0x%08x,", fnv1a(v));
      col++;
    }
    std::printf("\n    ],\n");
  }
  std::printf("];\n");
  return 0;
}
