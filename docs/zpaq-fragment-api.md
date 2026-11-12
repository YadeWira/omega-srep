# OSREP fragmenter API (Phase 1)

**Estado: Fases 1 y 2 completas (2026-11-10); `-osrep` integrado con el
fragmentador gear y los cortes de formato (2026-11-12, rama `frag-int`).** El
modo exacto reproduce el fragmentador de zpaq-std columna por columna y el lazo
real de `add2_scan` ya usa la API; los archivos ZPAQ son byte a byte idénticos
al baseline. Tamaños y tiempos de `-osrep`:
[`zpaq-osrep-mode.md`](zpaq-osrep-mode.md).

## Lo que llama zpaq-std

Esta es la API estable para zpaq-std (`compressors/osrep/`, C99, MIT). Todo lo
demás del header es para pruebas y experimentos y puede cambiar.

```c
/* una vez por add: la política entera de -osrep */
osrep_frag_params p;
if (osrep_frag_params_osrep(&p, (unsigned)fragment, blocksize) != OSREP_FRAG_OK)
    error("-osrep: -fragment must be 0..21");
/* p.max == MAX_FRAGMENT de zpaq (mismo recorte al bloque) */

/* al empezar cada archivo y después de cada corte */
osrep_frag_state st;
osrep_frag_state_reset(&st, &p);

/* por cada byte: 1 = el fragmento termina después de este byte
   (corte por contenido, por formato o por p.max) */
if (osrep_frag_state_push(&st, c)) { /* cerrar el fragmento */ }

/* para el análisis de tipo de datos de zpaq: st.hits y st.o1[256] */
```

- `osrep_frag_params_osrep(p, N, block_size)`: `-fragment N` significa lo
  mismo que en zpaq, un promedio de A = 2^N KiB (N=3 → 8 KiB, N=6 → 64 KiB).
  Fija `mode = OSREP_FRAG_MODE_GEAR`, `min = A/2`, `max = 8128 << N`
  recortado a `block_size - 12` (como `MAX_FRAGMENT`; `block_size = 0` usa
  64 MiB), un umbral `t_small = t_large = ((UINT64_MAX / A) >> 16) * 131040`
  y `flags = OSREP_FRAG_F_FORMAT`. N válido: 0..21. zpaq-std usa N=3 cuando
  no se da `-fragment` con `-osrep`.
- Hash gear: `h = (h << 1) + G[c]`, `G` = splitmix64 con semilla
  `0x4F5352455047454E` y `G[0] = 0`. El hash empieza 64 bytes antes de `min`;
  corta cuando `size >= min && h < t`, o en `max`.
- `OSREP_FRAG_F_FORMAT` = `TAR_AFTER | ZIP_AFTER | ZIP_SIG` (42): cortes
  forzados después de una cabecera ustar/gnu/pax con checksum válido, después
  de la firma `PK\3\4`, después del resto de la cabecera local de zip y
  después de la primera `PK\1\2`. Ignoran el mínimo, nunca hacen retroceder
  un corte y deciden solo con los bytes del fragmento actual.
- El estado depende solo de los bytes desde el último corte (o el inicio del
  archivo). Por eso el lazo simple de `add2()`, los workers de `add2_scan`
  (que reinician el estado en cada corte y en sus inicios adivinados) y
  cualquier número de hilos dan los mismos cortes.
- `osrep_frag_state_scan(st, buf, len, &cut)` hace lo mismo que empujar
  `buf[0..len)` byte a byte y para tras el byte del corte (devuelve los bytes
  consumidos). Con `flags != 0` recorre byte a byte por dentro; sin flags es
  el camino rápido del gear (≈1 GB/s). zpaq-std hoy no lo usa.

## Header completo

`src/c/osrep_fragment.h`:

```c
typedef struct {
    uint64_t off;
    uint32_t size;
    uint8_t  sha1[20];
    uint32_t hits;
    uint8_t  o1[256];
} osrep_frag;

typedef struct {
    uint32_t mode;       /* ZPAQ 0 exacto, OSREP 1 (FNV), GEAR 2 (-osrep) */
    uint32_t min, max;
    uint32_t threshold;  /* modo zpaq */
    uint32_t avg;        /* FNV y gear */
    uint32_t norm;       /* gear: t_small en [min, norm), t_large desde norm */
    uint64_t t_small, t_large;
    uint32_t flags;      /* gear: OSREP_FRAG_F_* */
} osrep_frag_params;

int osrep_frag_params_zpaq(osrep_frag_params *p, unsigned fragment,
                           uint32_t block_size);
int osrep_frag_params_osrep(osrep_frag_params *p, unsigned fragment,
                            uint32_t block_size);
int osrep_frag_params_gear(osrep_frag_params *p, unsigned fragment,
                           uint32_t block_size, unsigned min_shift,
                           unsigned level);          /* experimentos */
int osrep_frag_params_fnv(osrep_frag_params *p, unsigned fragment,
                          uint32_t block_size);      /* el FNV anterior */
void osrep_frag_state_reset(osrep_frag_state *st, const osrep_frag_params *p);
int osrep_frag_state_push(osrep_frag_state *st, uint8_t c);
size_t osrep_frag_state_scan(osrep_frag_state *st, const uint8_t *buf,
                             size_t len, int *cut);
int osrep_fragment_buffer(const uint8_t *buf, size_t len,
                          const osrep_frag_params *p,
                          osrep_frag **out, size_t *out_n);
void osrep_frag_free(osrep_frag *p);
void osrep_sha1(const uint8_t *data, size_t len, uint8_t out[20]);
```

- `osrep_frag_params_zpaq()` aplica el mapeo de zpaq: `min = 64 << N`,
  `max = 8128 << N` recortado a `block_size - 12`, umbral `1 << (22 - N)`
  (`0` si `N > 22`); `block_size = 0` usa 64 MiB.
- `osrep_fragment_buffer()` es pura y thread-safe: no hay estado global; el
  que llama decide el orden y el dedup. Devuelve un array `malloc`eado que se
  libera con `osrep_frag_free()`. Rechaza (`1`) flags desconocidos o flags
  fuera del modo gear.
- `mode = OSREP_FRAG_MODE_OSREP` es el CDC FNV de 48 bytes (el de `-m1`);
  `osrep_frag_params_fnv()` conserva su mapeo viejo (`64 KiB << (N-9)`).
  Ya no lo usa `-osrep`.
- `osrep_frag_params_gear()` deja elegir otro mínimo (A >> 1..4) y el nivel
  de chunking normalizado (0..3), para experimentos; sin flags.
- Errores: `0` OK, `1` parámetros, `2` memoria, `3` modo no soportado.

## Validación

- SHA-1: vectores FIPS 180-4 y comparación con `sha1sum`/`shasum` en el
  corpus (`tests/sha1.sh`).
- Fragmentos exactos: `tests/zpaq_fragments_exact.sh` compara **todas** las
  columnas contra los vectores de zpaq-std (commit `b8ad717`) para
  `text`, `mixed`, `zeros`, `random` y `tiny`, y para `-fragment 0, 3, 6, 9`.
- Corpus multi-versión: los 1775 fragmentos de `versions.tar` (125 MB) y los
  503 de `pja.tar` (33 MB) coinciden en offset, tamaño, hits, SHA-1 y o1
  (`tools/zpaq-vectors/vectors/`).
- La comparación con zpaq-std es el oráculo del modo exacto; no se agregó un
  port Pascal del fragmentador porque el objetivo es la C ABI que usará
  zpaq-std y los vectores fijan el comportamiento mejor que una segunda
  implementación.

## Integración en `add()` (hecha)

El prototipo (ya reemplazado por el switch `-osrep`, ver
`docs/zpaq-osrep-mode.md`) cambiaba el lazo inline: estado incremental por
fragmento (`osrep_frag_state_push`), SHA-1 de OSREP y copia de `hits`/`o1`
para el data-type analysis. Con `-touch`/`-timestamp` fijos, el baseline y el
integrado daban (hoy lo comprueba `tools/zpaq-vectors/osrep-switch-test.sh`):

| input | métodos | resultado |
|---|---|---|
| `tests/corpus` (7 archivos, 10,7 MB) | `-m0`, `-m1`, `-m5` | byte-idéntico |
| `versions.tar` (125 MB) | `-m1` | byte-idéntico (15.293.533 bytes) |

## Modo OSREP y benchmarks

`docs/zpaq-osrep-mode.md` tiene la tabla completa. Resumen:

- `-m1`: 37–45 % menos archivo, igual o más rápido y 30–35 % menos RSS.
- `-m5`: −17,7 % en el corpus grande; en PJA +3,3 % de tamaño pero 1,7× más
  rápido y 32 % menos RSS.
- Todos los archivos se extraen con el zpaq-std baseline byte a byte.

## Pendiente

1. ~~Parche limpio de entrega~~: hecho, switch `-osrep`
   (`tools/zpaq-vectors/osrep-fragmenter-zpaq-std-2.7.2.patch`).
2. Benchmarks con zpaqfranz y un corpus de backup más grande.
3. Empaquetado y coordinación con zpaq-std.

## Reproducir

```sh
bash tests/sha1.sh
bash tests/zpaq_fragments_exact.sh
# vectores nuevos (requiere el patch de tools/zpaq-vectors):
#   OSREP_FRAG_VECTORS=file OSREP_FRAG_N=6 ./zpaq-std > file.tsv
```
