# OSREP fragmenter API (Phase 1)

**Estado: API y modo exacto hechos (2026-11-10).** `osrep_fragment_buffer()`
reproduce el fragmentador de zpaq-std columna por columna: `offset`, `size`,
`hits`, SHA-1 y `o1`. Falta enchufarlo en el lazo `add()` de zpaq-std y la
prueba de archivo ZPAQ byte a byte.

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
- `mode = OSREP_FRAG_MODE_OSREP` (gear/FNV) devuelve `ENOTSUP` por ahora.
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

## Pendiente para cerrar Phase 1

1. Enchufar `osrep_fragment_buffer()` en `fragment_buffer`/`add2()` y en el
   lazo de `add()` de zpaq-std (hoy el lazo inline sigue siendo el original).
2. Probar que un archivo ZPAQ creado con el zpaq-std parcheado es **byte a
   byte idéntico** al del zpaq-std sin parchear, con el mismo input, orden y
   `--seed`.
3. API de streaming para archivos que no entran en RAM (el buffer API es
   whole-file); el integrador puede leer por bloques, pero conviene exponer
   un contexto incremental.

## Reproducir

```sh
bash tests/sha1.sh
bash tests/zpaq_fragments_exact.sh
# vectores nuevos (requiere el patch de tools/zpaq-vectors):
#   OSREP_FRAG_VECTORS=file OSREP_FRAG_N=6 ./zpaq-std > file.tsv
```
