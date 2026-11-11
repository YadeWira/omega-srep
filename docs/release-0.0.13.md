# OSREP 0.0.13 — decoder por bloques (pre-release)

**2026-11-10.** Checkpoint de memoria de decodificación: el decoder trabaja
bloque a bloque cuando puede, y el `-dup` deja de ser O(n²). Seis binarios,
mismas plataformas que 0.0.12. Pre-release.

## Qué cambia desde 0.0.12

- **Decoder por bloques**: un primer pase comprueba que todos los matches
  caen dentro de su bloque (lo que escribe OSREP) y después cada bloque se
  decodifica en su propio buffer, con sus literales, sus matches locales y su
  digest. Ya no se reconstruye toda la salida en memoria.
- **Fallback global** para archivos legacy con matches que cruzan bloques
  (p. ej. `text-b1mb-m3.osr` de Omega SREP): el camino anterior sigue
  disponible y se usa solo en ese caso.
- **`-dup` sin O(n²)**: `RestoreDup`/`RestoreDupToStream` referencian los
  chunks únicos del body por offset (sin copiarlos), preasignan la salida o
  la escriben en streaming, y validan tamaños. Antes copiaba cada chunk y
  hacía crecer el buffer de salida de a un chunk.
- **`DecodeToBytes`** (API en memoria) usa el camino por bloques: el buffer
  de salida es el resultado, sin la copia global de literales y matches.

## Números (`real64.bin`, 64 MiB, archivo `-m5`)

| versión | flujo | salida | tiempo | RSS |
|---|---|---|---:|---:|---:|
| 0.0.12 | `-d` | 67.108.864 | 1,45 s | 210 MB |
| **0.0.13** | `-d` por bloques | 67.108.864 | **1,10 s** | **42 MB** |
| 0.0.12 | `-d` de `-dup -m5` | 67.108.864 | 11,9 s | 3.225 MB |
| **0.0.13** | `-d` de `-dup -m5` | 67.108.864 | **1,10 s** | **106 MB** |

Con esto el decode de OSREP queda en el mismo orden que SREP/Omega (20–38 MB)
en el caso normal, y muy por debajo del `-dup` anterior.

## Pruebas

- `tests/decode_blockwise.sh` (nuevo): 25 bloques, round-trip, salida a
  stdout, fixture legacy con matches cruzados, `-m1`/`-dup -m5` (chunks
  únicos y referencias) y corrupción de bloque (exit 4).
- `v6_read`, `v6_encode`, `native_cdc`, `native_match`, `memory_budget`,
  `lib.sh` (73/103), `windows_cross.sh`, `arm64_cross.sh`,
  `linux_x86_cross.sh` y el workflow de macOS (que ahora corre también el
  test nuevo).

## Limitaciones

- El body de un archivo `-dup` se mantiene en memoria para restaurar los
  chunks; en un corpus casi sin duplicados son ~106 MB para 64 MiB. Un body
  mayor que la RAM sigue siendo un límite.
- Los archivos legacy con matches que cruzan bloques usan el camino global
  (210 MB en el peor caso).
- Ratio a igual `-l64 -c64` sigue por detrás de Omega `-m4`.
- Windows 8 no está disponible; Windows 10 y 7 SP1 son los validados.

## Licencia

MIT desde el primer commit de la rama `osrep`. El legado (`main`, tags hasta
`v3.0.0`) no está cubierto.
