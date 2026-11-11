# OSREP 0.0.8 — Windows stdin fix (pre-release)

**2026-11-10.** Checkpoint de corrección: el CLI usa los handles de stdin y
stdout del RTL en Windows. Los binarios Windows x86/x64 se probaron en VM Windows 10 y
Windows 7 SP1 reales, no solo wine. Pre-release.

## Qué cambia desde 0.0.7

- **Fix real de Windows**: `THandleStream.Create(0/1)` no es stdin/stdout en
  Win32. Ahora se usan `StdInputHandle`/`StdOutputHandle` en Windows y 0/1 en
  Unix. Antes, `type x | osrep - -` fallaba con "Stream write error".
- `tests/windows_cross.sh` ahora prueba también stdin/stdout bajo wine.
- Verificación en **Windows 10 real** (x64 y x86):
  `--version`, `-m5`, `--verify`, `-d`, `fc /b`, pipe `type | osrep - -` y
  `-dup -m5`. Todos los archivos vuelven byte a byte.

Todo lo de 0.0.7 sigue: Linux x86_64 + Windows x86/x64, `-m0..-m5`, `-dup`,
stdin/stdout, `-t`, CDC/match/CRC nativos y los tests diferenciales.

## Números

Sin cambios de formato ni de rendimiento:

- `-m5` default en `real64.bin`: 38.083.480 en ~1,1 s.
- Dedup `-m1` 8 KiB + zpaq: 8,87 MB vs 15,29 MB de zpaq solo (zpaq-std);
  1,73 MB vs 2,82 MB (PJA).

## Pruebas

`v6_read`, `v6_encode`, `native_cdc`, `native_match`, `lib.sh` (73/103),
`windows_cross.sh` (wine) y la VM Windows 10 real.

## Limitaciones

- Probado en Windows 10 y Windows 7 SP1; falta Windows 8/11 y otras
  ediciones.
- Linux i386/ARM64 y macOS ARM64 pendientes; ARM64 bloqueado por el
  sysroot/crt del cross.
- Ratio a igual `-l64 -c64` por detrás de Omega `-m4`.
- Integración con zpaq-std (fragmentador) pendiente de coordinar.

## Licencia

MIT desde el primer commit de la rama `osrep`. El legado (`main`, tags hasta
`v3.0.0`) no está cubierto.
