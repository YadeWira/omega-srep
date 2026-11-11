# OSREP fragmenter API (Phase 1)

**Estado: Fases 1 y 2 completas (2026-11-10).** El modo exacto reproduce el
fragmentador de zpaq-std columna por columna y el lazo real de `add2_scan` ya
usa la API; los archivos ZPAQ son byte a byte idénticos al baseline. El modo
OSREP (FNV de 48 bytes) está implementado y medido: ver
[`zpaq-osrep-mode.md`](zpaq-osrep-mode.md).

## Header

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
    uint32_t mode;       /* ZPAQ (0) exacto; OSREP (1) reservado */
    uint32_t min;
    uint32_t max;
    uint32_t threshold;
} osrep_frag_params;

int osrep_frag_params_zpaq(osrep_frag_params *p, unsigned fragment,
                           uint32_t block_size);
int osrep_frag_params_osrep(osrep_frag_params *p, unsigned fragment,
                            uint32_t block_size);
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
  libera con `osrep_frag_free()`.
- `mode = OSREP_FRAG_MODE_OSREP` usa el CDC de ventana fija de 48 bytes con
  FNV (el de `-m1`); `avg` fija el promedio. `osrep_frag_params_osrep()` mapea
  `-fragment N` a `avg = 64 KiB << (N-9)` con tope 1 KiB–1 MiB: N=6 → 8 KiB,
  N=3 → 1 KiB.
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

`tools/zpaq-vectors/osrep-fragment-integration.patch` cambia el lazo inline:
estado incremental por fragmento (`osrep_frag_state_push`), SHA-1 de OSREP y
copia de `hits`/`o1` para el data-type analysis. `integration-test.sh`
compara el binario baseline y el integrado con `-touch`/`-timestamp` fijos:

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

1. Parche limpio de entrega: mapear `-fragment` en el CLI de zpaq-std (hoy el
   prototipo usa `OSREP_FRAG_AVG`) y quitar el modo de volcado de vectores.
2. Benchmarks con zpaqfranz y un corpus de backup más grande.
3. Empaquetado y coordinación con zpaq-std.

## Reproducir

```sh
bash tests/sha1.sh
bash tests/zpaq_fragments_exact.sh
# vectores nuevos (requiere el patch de tools/zpaq-vectors):
#   OSREP_FRAG_VECTORS=file OSREP_FRAG_N=6 ./zpaq-std > file.tsv
```
