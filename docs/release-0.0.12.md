# OSREP 0.0.12 — presupuesto de memoria (pre-release)

**2026-11-10.** Checkpoint que agrega `-mem`, el presupuesto de memoria del
encoder LZ, y `max_match` en `-i`. Seis binarios, mismas plataformas que
0.0.11. Pre-release.

## Qué cambia desde 0.0.11

- **`-memN`**: presupuesto de memoria. Sin sufijo es MB (`-mem128`); acepta
  `kb`/`mb`/`gb` (`-mem192mb`). El encoder elige el mayor bloque potencia de
  dos que quepa y, si hace falta, limita los hilos.
- El bloque se elige para 8 hilos (el máximo automático) y **no depende de
  `-t`**: `-mem128 -t1` y `-mem128 -t8` escriben el mismo archivo.
- `-mem` solo aplica a `-m3..-m5`; `-m0..-m2` no reservan las tablas LZ.
- `-i` imprime `max_match=N` (el campo 8 del header), además de los campos
  anteriores.

## Números (`real64.bin`, `-m5`, Linux x86_64)

| ajustes | bloque | salida | ratio | tiempo | RSS |
|---|---:|---:|---:|---:|---:|
| default | 8 MiB | 38.083.480 | 56,75 % | 1,24 s | 640 MB |
| `-mem192` | 2 MiB | 38.336.931 | 57,13 % | 1,14 s | 160 MB |
| `-mem128` | 1 MiB | 38.619.776 | 57,55 % | 1,40 s | 82 MB |
| `-mem64` | 512 KiB | 39.102.508 | 58,27 % | 1,82 s | 41 MB |
| `-mem128 -t1` | 1 MiB | 38.619.776 | 57,55 % | 4,04 s | 15 MB |

- **128 MB** es el punto dulce: 82 MB reales y +1,4 % de ratio (+0,54 MB).
- `-mem192` deja 160 MB y +0,7 % (+0,25 MB), casi sin costo de tiempo.
- 64 MB y menos empiezan a costar ratio y tiempo.

El modelo es `8 MiB + hilos * (9 * bloque + head)`, con `head` de 4 bytes por
bucket (tope 2^22); está documentado en `docs/implementation-notes.md` §5.1.

## Pruebas

`v6_read`, `v6_encode`, `native_cdc`, `native_match`, `lib.sh` (73/103),
`memory_budget.sh` (nuevo: bloque por presupuesto, determinismo con `-t`,
`-m1` intacto y presupuesto mínimo), `windows_cross.sh`, `arm64_cross.sh`,
`linux_x86_cross.sh` y el workflow de macOS.

## Limitaciones

- El decoder no cambia: sigue reconstruyendo toda la salida en memoria
  (210 MB en `real64.bin`). Es el próximo trabajo de memoria.
- `-dup` y la entrada por stdin bufferizan la entrada completa; `-mem` no
  limita eso.
- Ratio a igual `-l64 -c64` sigue por detrás de Omega `-m4`.
- Windows 8 no está disponible; Windows 10 y 7 SP1 son los validados.

## Licencia

MIT desde el primer commit de la rama `osrep`. El legado (`main`, tags hasta
`v3.0.0`) no está cubierto.
