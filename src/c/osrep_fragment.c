/* OSREP fragmenter API: zpaq-std's order-1 CDC (exact mode), OSREP's
   48-byte FNV rolling CDC and the gear CDC with normalized chunking that
   -osrep uses, with SHA-1 and the order-1 state zpaq's data-type analysis
   consumes.

   Pure functions, no globals, thread-safe. The exact-mode loop is the same as
   zpaq-std's fragment_buffer(); tests/fixtures/zpaq-fragments pin it. */
#include "osrep_fragment.h"

#include <stdlib.h>
#include <string.h>

#define HASH_MULT_HIT UINT32_C(314159265)
#define HASH_MULT_MISS UINT32_C(271828182)
#define FNV_PRIME UINT64_C(0x100000001B3)
#define OSREP_WINDOW 48
#define ZPAQ_DEFAULT_BLOCK (UINT32_C(64) * 1024 * 1024)
#define GEAR_WINDOW 64

/* -osrep parameters, as a function of the average A = 1024 << N: min
   A >> 1, a single threshold (normalization level 0) and max = zpaq's
   8128 << N. docs/experiments/frag-normalized.md measured min A/2, A/4,
   A/8, A/16 and levels 0..3 and picked these. They are fixed on purpose:
   the archive format does not depend on them, but the cuts, and so the
   dedup between two archives made by two builds, do.
   osrep_frag_params_gear() keeps the other policies for experiments. */
#define OSREP_GEAR_MIN_SHIFT 1u
#define OSREP_GEAR_LEVEL 0u

/* Base threshold T = ((2^64 - 1) / A >> 16) * gear_k[s-1][L]: K / 2^16 is
   p * A, with p the cut probability per byte that makes the expected
   fragment on random data exactly A with min A >> s, switch at A and max
   8128 << N. Computed offline in double precision for A = 8 KiB (the model
   is in tools/zpaq-vectors/frag_sim.c); it moves by less than 0.2 % between
   N = 0 and N = 21, and only integers reach the cut decision. */
static const uint32_t gear_k[4][4] = {
    {131040, 152022, 166399, 175014}, /* min A/2  */
    {87364, 101360, 110958, 116729},  /* min A/4  */
    {74878, 86883, 95113, 100066},    /* min A/8  */
    {69880, 81092, 88774, 93400}      /* min A/16 */
};

/* Gear table: 256 fixed 64-bit constants, splitmix64 from the seed
   0x4F5352455047454E ("OSREPGEN"), entry i the (i+1)-th output, except
   entry 0, which is 0: 64 zero bytes give h = 0 and a cut once the fragment
   is past min. That anchors cuts in the zero padding of tar headers,
   executables and documents, as the FNV hash does; see the report. */
static const uint64_t osrep_gear[256] = {
    UINT64_C(0x0000000000000000), UINT64_C(0x5B279A3AC0345931),
    UINT64_C(0x22D81789CEB6D0E3), UINT64_C(0x34CEAB52A3FEE9C0),
    UINT64_C(0xD607F2475AFAB041), UINT64_C(0x7E92B0AF43FAABF8),
    UINT64_C(0xB5646BC0F491201A), UINT64_C(0xAB427DD51BC19E3F),
    UINT64_C(0x74C91768A216E657), UINT64_C(0x57ECB6A1188F5234),
    UINT64_C(0x0FFDFC09A8D4939D), UINT64_C(0xCDC90F6192033CE3),
    UINT64_C(0xE5A044B862DB9B58), UINT64_C(0x2D662305AF55F632),
    UINT64_C(0xC3972258022F318C), UINT64_C(0xDF7AC31C2C54956A),
    UINT64_C(0x24CA4418ABA1DF6A), UINT64_C(0x0C248C354899302F),
    UINT64_C(0x275A82D4C923CA5F), UINT64_C(0x09CFE885100ECB8C),
    UINT64_C(0x52932516C671555A), UINT64_C(0xD1A7E46721684CBF),
    UINT64_C(0x974D290AE79E4544), UINT64_C(0xEF258AC97298ECF0),
    UINT64_C(0x5D8F5F363A1DEADA), UINT64_C(0x1F8A03BABC845088),
    UINT64_C(0x9580833BF7B9E6C0), UINT64_C(0x483CFD0CF4FE7A94),
    UINT64_C(0xB229D48A39352AF3), UINT64_C(0x4E2FD8CDA220CA91),
    UINT64_C(0x9FC0612DAFEA04AC), UINT64_C(0xAEC23C6BD279AD32),
    UINT64_C(0x147F1526B8996F10), UINT64_C(0x8F51FE1993E274F7),
    UINT64_C(0xCEA12E5BDF32206E), UINT64_C(0xBC8AD274F27D5B6A),
    UINT64_C(0xF73E62B83F66C049), UINT64_C(0xCCF4E4AC0B5B347B),
    UINT64_C(0x46ED2050419D92D2), UINT64_C(0x26DD79952DE37550),
    UINT64_C(0x9FEFED3DC7133F09), UINT64_C(0x6E628E1802A0E449),
    UINT64_C(0xC7BD7FEB204884E3), UINT64_C(0x4C20E6CA707B6397),
    UINT64_C(0x60A12B871635781B), UINT64_C(0x08EE1FF747EF4CED),
    UINT64_C(0x56AC599C3BCEF7B5), UINT64_C(0x68A911356DED53E8),
    UINT64_C(0x85B704EB00BB92A8), UINT64_C(0xEF1F7D3611865F69),
    UINT64_C(0xD719C424F51D5FF9), UINT64_C(0xFDF0AE187F2F01FE),
    UINT64_C(0xB678181223CCC8A4), UINT64_C(0x44F74C5EE78DECD3),
    UINT64_C(0xECA5F172F91B94E3), UINT64_C(0x2A24531654B3480D),
    UINT64_C(0xD72F566ABAC0F713), UINT64_C(0x2B2C8B5EA5C9346D),
    UINT64_C(0xB0A2606D8D852AD1), UINT64_C(0x1FC3D612B6158F23),
    UINT64_C(0x7F2C7D76960F4B4C), UINT64_C(0x590D198C873844D7),
    UINT64_C(0xD1C075D2C7E76222), UINT64_C(0x74970A192B995DCB),
    UINT64_C(0xDA008581FE761494), UINT64_C(0x783BAB3315402F08),
    UINT64_C(0xC404C7C555AC6702), UINT64_C(0x5E6668A640E6593B),
    UINT64_C(0x44B21F617EADAAA0), UINT64_C(0xF36B6747719FD8A7),
    UINT64_C(0xAC5D08F2736D358B), UINT64_C(0xFCFAB932311B8428),
    UINT64_C(0x80866485D4C6376F), UINT64_C(0x46D1C935D26690AE),
    UINT64_C(0x040C90DABD6F62C0), UINT64_C(0x7F2AA73064823819),
    UINT64_C(0x2CD140DD88B3740B), UINT64_C(0x3A78D60514F4DF3F),
    UINT64_C(0x519C2582E218089A), UINT64_C(0x9183A23AE06AB110),
    UINT64_C(0xEFAA4094581A223B), UINT64_C(0xFBB7F1FDAE2F0E85),
    UINT64_C(0xD33A7CB2E3F7F5C9), UINT64_C(0xE4AA8F828DC8436D),
    UINT64_C(0x51357920F39FF75C), UINT64_C(0xE7EBEB2E581B5873),
    UINT64_C(0xDC0311C001DF725B), UINT64_C(0x7AFFB84BC79DFE6B),
    UINT64_C(0x28EF1A5E41CFA836), UINT64_C(0xD1A756DD9971C2E3),
    UINT64_C(0x4D6C2180FD8AAE3D), UINT64_C(0xF48EC47883A5B160),
    UINT64_C(0xFCC74243CDF2A477), UINT64_C(0x1A83B077D52234BA),
    UINT64_C(0x17DD908D6C783E40), UINT64_C(0xFA22DC13322BA698),
    UINT64_C(0xAE4EF06DE3D82E07), UINT64_C(0xAC2A28DDE4E24516),
    UINT64_C(0x103DDB446B4FFEE0), UINT64_C(0x324688364C0F4A55),
    UINT64_C(0x2CEBB0C46FD54648), UINT64_C(0xC280D017B484D6BF),
    UINT64_C(0x526138A03C21AE8F), UINT64_C(0xC254FDCA71BE9EEF),
    UINT64_C(0xE2D54FA03FD0C981), UINT64_C(0x10C2133C8F54C242),
    UINT64_C(0xBACF0D9858AC05FB), UINT64_C(0x3ECB91A4ACC75A8A),
    UINT64_C(0x4344B45BF5B046D5), UINT64_C(0x7EBBEAEF4A93F9E2),
    UINT64_C(0xD710770737F8EDB5), UINT64_C(0x88F5E0454B8B9CD7),
    UINT64_C(0x8B4DF365682FFA27), UINT64_C(0x75B916709A55F73D),
    UINT64_C(0x50C6BC592DDEA8EE), UINT64_C(0x73E449107A5F7C82),
    UINT64_C(0xBDE87877B8CDAE4C), UINT64_C(0x01796E530E68BFB7),
    UINT64_C(0xF5448C0CA55C0CD8), UINT64_C(0x03EE0A30115A10A8),
    UINT64_C(0xC8DEECEC32BDE4D9), UINT64_C(0x64F8071342CDC5C0),
    UINT64_C(0x2B7D27CC24FA3230), UINT64_C(0x2B45840BD1D52C91),
    UINT64_C(0x75627E87402E5EE9), UINT64_C(0xE068992886AAAF3C),
    UINT64_C(0xCCD107D1068E9379), UINT64_C(0xE16E7AB25FC012F2),
    UINT64_C(0x24F6DCBF4F8D186C), UINT64_C(0xCB4792CE45A01883),
    UINT64_C(0xCB17E1B5ED4A2830), UINT64_C(0x0BD24400083F92EA),
    UINT64_C(0xF53D90750161F5DB), UINT64_C(0xBAC00246B6A4CD9F),
    UINT64_C(0x16CA3DA0D6EA463A), UINT64_C(0x15DE913662DC3311),
    UINT64_C(0x07ECD5846819537F), UINT64_C(0xAEE0B2D4F267806D),
    UINT64_C(0x9D0EF0399DF70654), UINT64_C(0xA5E26B069B18F47F),
    UINT64_C(0xBD0A65F33320D15F), UINT64_C(0xEDE4FFAF4B754462),
    UINT64_C(0xF74AEB56DCE8B88C), UINT64_C(0x66736BAE6BA29F8B),
    UINT64_C(0xD769ECEFCC1209E5), UINT64_C(0x6BAD6FB3C714235A),
    UINT64_C(0x8C37FCFD818970BB), UINT64_C(0x7162E6159236841F),
    UINT64_C(0x644B5757195626C5), UINT64_C(0x3E5D36669F6748A5),
    UINT64_C(0x29E990BE00871097), UINT64_C(0xF4CB529473D29FBE),
    UINT64_C(0x55F3C481D69AB589), UINT64_C(0xF8282593F4C0A6FD),
    UINT64_C(0xFB41BD16EB5A3ED2), UINT64_C(0xE6A4A60FC9DC66F6),
    UINT64_C(0x849FDCAE190A989A), UINT64_C(0x83F3FC6522890CB8),
    UINT64_C(0x49B25D6A1613DBC5), UINT64_C(0x41DCD3B1FEC1A3E8),
    UINT64_C(0x70D8572E8B3451E1), UINT64_C(0xDB085EF06746D123),
    UINT64_C(0x624970F5CDB84C0F), UINT64_C(0x6D29EC7709F99972),
    UINT64_C(0x45BC2F36E4C661B8), UINT64_C(0x702BD2BF9532E8D4),
    UINT64_C(0x0B4DE210FDCC5591), UINT64_C(0xA8B0527027630A11),
    UINT64_C(0x3285742855EE6263), UINT64_C(0x523E78FB923A8807),
    UINT64_C(0xD92D655547BE388B), UINT64_C(0x575D66F22E291ED7),
    UINT64_C(0xF0CBA50172FBA930), UINT64_C(0x2FC45761508EA9BC),
    UINT64_C(0x07A049AE4443F558), UINT64_C(0x2E289DC9A0547723),
    UINT64_C(0x91819A571759737A), UINT64_C(0xB8D57E9F8594E346),
    UINT64_C(0xEB56E8FF136AA741), UINT64_C(0x28DF0D05B761E626),
    UINT64_C(0xBE50C32374046719), UINT64_C(0xE50EA356AD7D4271),
    UINT64_C(0xEB2AF9F785951263), UINT64_C(0xC283925402DB87DD),
    UINT64_C(0x50F18237C3F5B046), UINT64_C(0x1EC3087BCBD62D8E),
    UINT64_C(0x21382626DAA16C5B), UINT64_C(0xE23B9EC965DDA72D),
    UINT64_C(0x82EF840AD4398411), UINT64_C(0x5FE44C946ABC156D),
    UINT64_C(0x1B129E4F0C0DC22D), UINT64_C(0x1FF46AA1475B6C93),
    UINT64_C(0x7C9BCE151B0F1CDC), UINT64_C(0x88C91EB0D63ED00A),
    UINT64_C(0x941EF1A060A0B257), UINT64_C(0x64FA4196F9EAFDED),
    UINT64_C(0x8D7BA21A57971939), UINT64_C(0x83A20A4B0E73BBBA),
    UINT64_C(0x6D58A49346E04A1F), UINT64_C(0x224CD3B90113563B),
    UINT64_C(0x296FA814F8ED6075), UINT64_C(0x035C2917EDAB55AB),
    UINT64_C(0x369E8209E9D5B06F), UINT64_C(0x9728687F11486E75),
    UINT64_C(0x43627E43A35D1A69), UINT64_C(0xDEFE4DE341122EF7),
    UINT64_C(0xFC714D1BB4057ABD), UINT64_C(0xD90BDF17CE82183D),
    UINT64_C(0xF6946829FDA24C89), UINT64_C(0x8401402F545BDBCE),
    UINT64_C(0xDE5486AB5A604845), UINT64_C(0x52CA531E992D312E),
    UINT64_C(0x385ECC20B455BA61), UINT64_C(0x971C6A83389D3E73),
    UINT64_C(0x5E3F08F717A77684), UINT64_C(0x524757F7A1E259FD),
    UINT64_C(0x9A85E30972B19369), UINT64_C(0x14A5C956C67067EA),
    UINT64_C(0x90B374ECC70CD41A), UINT64_C(0x738A67150966F62E),
    UINT64_C(0x38A879E131389E74), UINT64_C(0x3FFF4EAC02238EE6),
    UINT64_C(0xF1BDF07E24D5424A), UINT64_C(0xCA48FFC67E830CDD),
    UINT64_C(0x8B7EFC8512194469), UINT64_C(0x2FD2564987FE950B),
    UINT64_C(0x42A41F28A0CB9AE9), UINT64_C(0xBB48B9AF5E0B8830),
    UINT64_C(0x369ECCB486CED79B), UINT64_C(0xACDA955D74F7E93C),
    UINT64_C(0xF5A9FBDF1F7E578D), UINT64_C(0x43FC9A07A4323C17),
    UINT64_C(0x3BFBA8BA802A4764), UINT64_C(0x4CFBC9BEFC02DB8B),
    UINT64_C(0x7753F1C949BA37AE), UINT64_C(0x4AA11B98333E615F),
    UINT64_C(0x39A66D074DF45040), UINT64_C(0xB2CEE32DE36B2FBB),
    UINT64_C(0x89A0744BE0E405E5), UINT64_C(0xF13A64BA9765F134),
    UINT64_C(0x7B0B1A215BA91589), UINT64_C(0x84F954E732D7BA8D),
    UINT64_C(0x6F9D23A508E125E1), UINT64_C(0xF8341333B5F8B8CB),
    UINT64_C(0x871692E6D5DBAC85), UINT64_C(0x450CAC6640741EAB),
    UINT64_C(0x38C82A30E5C5AA5F), UINT64_C(0xFBC08AC9A134AB97),
    UINT64_C(0x00019636B08941BC), UINT64_C(0xF419580CA62C8E6E),
    UINT64_C(0xEB1471CAD77CA9C3), UINT64_C(0x21558EE232975D6F),
    UINT64_C(0x18FC34188BF6F2A8), UINT64_C(0xEECECB58EAC060DE),
    UINT64_C(0x3F5620445C8258C9), UINT64_C(0xF04284AED805FA53)
};

int osrep_frag_params_zpaq(osrep_frag_params *params, unsigned fragment,
                           uint32_t block_size) {
  uint64_t max64, min64;
  if (params == NULL || fragment > 22) return OSREP_FRAG_EINVAL;
  if (block_size == 0) block_size = ZPAQ_DEFAULT_BLOCK;
  if (block_size <= 12) return OSREP_FRAG_EINVAL;
  max64 = (uint64_t)8128u << fragment;
  if (fragment > 19 || max64 > (uint64_t)block_size - 12)
    max64 = (uint64_t)block_size - 12;
  min64 = (uint64_t)64u << fragment;
  if (min64 > max64) min64 = max64;
  params->mode = OSREP_FRAG_MODE_ZPAQ;
  params->min = (uint32_t)min64;
  params->max = (uint32_t)max64;
  params->threshold = (fragment <= 22) ? (UINT32_C(1) << (22 - fragment)) : 0;
  params->avg = 0;
  params->norm = 0;
  params->t_small = params->t_large = 0;
  return OSREP_FRAG_OK;
}

int osrep_frag_params_gear(osrep_frag_params *params, unsigned fragment,
                           uint32_t block_size, unsigned min_shift,
                           unsigned level) {
  uint64_t avg, t;
  if (min_shift < 1 || min_shift > 4 || level > 3 || fragment > 21)
    return OSREP_FRAG_EINVAL;
  if (osrep_frag_params_zpaq(params, fragment, block_size) != OSREP_FRAG_OK)
    return OSREP_FRAG_EINVAL;
  /* zpaq's max (8128 << N, clamped to the block) stays; the average is
     2^N KiB, at most half of max when the block clamps it. */
  avg = UINT64_C(1024) << fragment;
  if (avg > params->max / 2) avg = params->max / 2;
  if (avg < 1024) return OSREP_FRAG_EINVAL;
  t = ((UINT64_MAX / avg) >> 16) * gear_k[min_shift - 1][level];
  params->mode = OSREP_FRAG_MODE_GEAR;
  params->min = (uint32_t)(avg >> min_shift);
  params->avg = (uint32_t)avg;
  params->norm = (uint32_t)avg;
  params->t_small = t >> level;
  params->t_large = t << level;
  params->threshold = 0;
  return OSREP_FRAG_OK;
}

int osrep_frag_params_osrep(osrep_frag_params *params, unsigned fragment,
                            uint32_t block_size) {
  return osrep_frag_params_gear(params, fragment, block_size,
                                OSREP_GEAR_MIN_SHIFT, OSREP_GEAR_LEVEL);
}

int osrep_frag_params_fnv(osrep_frag_params *params, unsigned fragment,
                          uint32_t block_size) {
  uint64_t avg;
  if (osrep_frag_params_zpaq(params, fragment, block_size) != OSREP_FRAG_OK)
    return OSREP_FRAG_EINVAL;
  /* Default N=6 maps to the 8 KiB OSREP average that benchmarked well for
     -m5; smaller N gives smaller fragments (N=3 -> 1 KiB). */
  avg = UINT64_C(65536);
  if (fragment > 9)
    avg <<= (fragment - 9);
  else if (fragment < 9)
    avg >>= (9 - fragment);
  if (avg < 1024) avg = 1024;
  if (avg > (UINT64_C(1) << 20)) avg = UINT64_C(1) << 20;
  params->mode = OSREP_FRAG_MODE_OSREP;
  params->avg = (uint32_t)avg;
  params->norm = 0;
  params->t_small = params->t_large = 0;
  return OSREP_FRAG_OK;
}

void osrep_frag_state_reset(osrep_frag_state *state,
                            const osrep_frag_params *params) {
  memset(state, 0, sizeof *state);
  state->mode = params->mode;
  state->min = params->min;
  state->max = params->max;
  state->threshold = params->threshold;
  state->avg = params->avg;
  state->norm = params->norm;
  state->t_small = params->t_small;
  state->t_large = params->t_large;
  if (params->mode == OSREP_FRAG_MODE_OSREP) {
    uint64_t p = 1;
    int i;
    for (i = 0; i < OSREP_WINDOW; i++) p *= FNV_PRIME;
    state->pow = p;
  }
}

int osrep_frag_state_push(osrep_frag_state *state, uint8_t c) {
  uint8_t pred = state->o1[state->c1];
  state->hits += (c == pred);
  state->o1[state->c1] = c;
  state->c1 = c;
  ++state->size;

  if (state->mode == OSREP_FRAG_MODE_GEAR) {
    /* The hash only sees the last 64 bytes, so starting it 64 bytes before
       min gives the same values as starting it at the cut. */
    if (state->size + GEAR_WINDOW > state->min) {
      state->h64 = (state->h64 << 1) + osrep_gear[c];
      if (state->size >= state->min &&
          state->h64 < (state->size < state->norm ? state->t_small
                                                  : state->t_large))
        return 1;
    }
    return state->size >= state->max;
  }

  if (state->mode == OSREP_FRAG_MODE_OSREP) {
    state->h64 = state->h64 * FNV_PRIME + c;
    if (state->winlen >= OSREP_WINDOW)
      state->h64 -= (uint64_t)state->win[state->winpos] * state->pow;
    state->win[state->winpos] = c;
    state->winpos = (state->winpos + 1) % OSREP_WINDOW;
    if (state->winlen < OSREP_WINDOW) ++state->winlen;
    if (state->size >= state->min && state->avg != 0 &&
        (state->h64 < UINT64_MAX / state->avg || state->size >= state->max))
      return 1;
    return 0;
  }

  state->h = (state->h + (uint32_t)c + 1u) *
             ((c == pred) ? HASH_MULT_HIT : HASH_MULT_MISS);
  if (state->threshold != 0 && state->h < state->threshold &&
      state->size >= state->min)
    return 1;
  return 0;
}

#define O1_STEP(c)                 \
  do {                             \
    uint8_t pred_ = o1[c1];        \
    hits += ((c) == pred_);        \
    o1[c1] = (c);                  \
    c1 = (c);                      \
  } while (0)

size_t osrep_frag_state_scan(osrep_frag_state *state, const uint8_t *buf,
                             size_t len, int *cut) {
  size_t i = 0, end;
  uint32_t size, min, hstart, norm, max;
  uint64_t h, t;
  uint32_t hits;
  uint8_t c1, *o1;

  *cut = 0;
  if (state->mode != OSREP_FRAG_MODE_GEAR) {
    while (i < len) {
      int r = osrep_frag_state_push(state, buf[i++]);
      if (r || state->size >= state->max) {
        *cut = 1;
        break;
      }
    }
    return i;
  }
  size = state->size;
  min = state->min;
  max = state->max;
  norm = state->norm;
  hstart = min > GEAR_WINDOW ? min - GEAR_WINDOW : 0;
  h = state->h64;
  hits = state->hits;
  c1 = state->c1;
  o1 = state->o1;
  /* sizes up to hstart: order-1 only */
  if (size < hstart) {
    end = hstart - size;
    if (end > len) end = len;
    for (; i < end; i++) O1_STEP(buf[i]);
    size += (uint32_t)end;
  }
  /* bytes that end below min: hash, no cut */
  if (i < len && size + 1 < min) {
    end = i + (min - 1 - size);
    if (end > len) end = len;
    for (; i < end; i++) {
      uint8_t c = buf[i];
      O1_STEP(c);
      h = (h << 1) + osrep_gear[c];
    }
    size = state->size + (uint32_t)i;
  }
  /* bytes that end at min or later: hash and cut, t_small while the size
     after the byte is below norm, t_large from norm to max */
  while (i < len && size < max) {
    if (size + 1 < norm) {
      t = state->t_small;
      end = i + (norm - 1 - size);
    } else {
      t = state->t_large;
      end = i + (max - size);
    }
    if (end > len) end = len;
    for (; i < end; i++) {
      uint8_t c = buf[i];
      O1_STEP(c);
      h = (h << 1) + osrep_gear[c];
      if (h < t) {
        ++i;
        *cut = 1;
        break;
      }
    }
    size = state->size + (uint32_t)i;
    if (*cut) break;
  }
  if (!*cut && i > 0 && size >= max) *cut = 1;
  state->size = size;
  state->h64 = h;
  state->hits = hits;
  state->c1 = c1;
  return i;
}

static int append_fragment(osrep_frag **arr, size_t *cap, size_t *count,
                           const uint8_t *buf, size_t start, size_t len,
                           uint32_t hits, const uint8_t o1[256]) {
  osrep_frag *f;
  if (*count == *cap) {
    size_t newcap = *cap * 2;
    osrep_frag *grown;
    if (newcap <= *cap || newcap > SIZE_MAX / sizeof(**arr))
      return OSREP_FRAG_ENOMEM;
    grown = (osrep_frag *)realloc(*arr, newcap * sizeof(**arr));
    if (grown == NULL) return OSREP_FRAG_ENOMEM;
    *arr = grown;
    *cap = newcap;
  }
  f = &(*arr)[*count];
  f->off = (uint64_t)start;
  f->size = (uint32_t)len;
  f->hits = hits;
  memcpy(f->o1, o1, 256);
  osrep_sha1(buf + start, len, f->sha1);
  ++*count;
  return OSREP_FRAG_OK;
}

int osrep_fragment_buffer(const uint8_t *buf, size_t len,
                          const osrep_frag_params *params, osrep_frag **out,
                          size_t *out_n) {
  osrep_frag *arr;
  osrep_frag_state st;
  size_t cap, count = 0, start = 0, i;
  int rc;

  if (out == NULL || out_n == NULL || params == NULL) return OSREP_FRAG_EINVAL;
  *out = NULL;
  *out_n = 0;
  if (buf == NULL && len != 0) return OSREP_FRAG_EINVAL;
  if (params->mode != OSREP_FRAG_MODE_ZPAQ &&
      params->mode != OSREP_FRAG_MODE_OSREP &&
      params->mode != OSREP_FRAG_MODE_GEAR)
    return OSREP_FRAG_ENOTSUP;
  if (params->min == 0 || params->max == 0) return OSREP_FRAG_EINVAL;
  if (params->mode != OSREP_FRAG_MODE_ZPAQ && params->avg == 0)
    return OSREP_FRAG_EINVAL;
  if (len == 0) return OSREP_FRAG_OK;

  cap = len / (size_t)params->min + 2;
  if (cap > 1024) cap = 1024;
  if (cap < 8) cap = 8;
  if (cap > SIZE_MAX / sizeof(*arr)) return OSREP_FRAG_ENOMEM;
  arr = (osrep_frag *)malloc(cap * sizeof(*arr));
  if (arr == NULL) return OSREP_FRAG_ENOMEM;

  osrep_frag_state_reset(&st, params);
  for (i = 0; i < len; i++) {
    int cut = osrep_frag_state_push(&st, buf[i]);
    if (cut || st.size >= params->max) {
      rc = append_fragment(&arr, &cap, &count, buf, start, st.size, st.hits,
                           st.o1);
      if (rc != OSREP_FRAG_OK) {
        free(arr);
        return rc;
      }
      start = i + 1;
      osrep_frag_state_reset(&st, params);
    }
  }
  if (st.size != 0) {
    rc = append_fragment(&arr, &cap, &count, buf, start, st.size, st.hits,
                         st.o1);
    if (rc != OSREP_FRAG_OK) {
      free(arr);
      return rc;
    }
  }

  *out = arr;
  *out_n = count;
  return OSREP_FRAG_OK;
}

void osrep_frag_free(osrep_frag *p) { free(p); }
