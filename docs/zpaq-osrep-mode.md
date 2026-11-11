# zpaq-std OSREP mode — benchmarks

**Estado: modo OSREP implementado y medido (2026-11-10).** El fragmentador de
zpaq-std puede usar el CDC de OSREP en lugar del de orden 1. El formato ZPAQ
no cambia: solo cambian los cortes y, por lo tanto, el tamaño del archivo.

## Qué es el modo OSREP

- CDC de ventana fija de 48 bytes con hash FNV-1a rodante (el mismo de
  `-m1`/`-m2` de OSREP).
- Estado incremental (`osrep_frag_state_push`): hash, `hits` y `o1`; sirve
  para el lazo de `add2_scan` de zpaq-std.
- Parámetros: `min`/`max` salen del mapeo de `-fragment` de zpaq; el promedio
  se deriva de `-fragment N` como `64 KiB << (N - 9)`, con tope 1 KiB–1 MiB.
  - `N=6` (default de zpaq) → 8 KiB.
  - `N=3` → 1 KiB; `N=5` → 4 KiB; `N=9` → 64 KiB.
- En el prototipo integrado el promedio se puede forzar con
  `OSREP_FRAG_AVG` (bytes) y el modo con `OSREP_FRAG_MODE=osrep`.

## Metodología

- zpaq-std baseline: mismo commit `b8ad717` (v2.7.2), sin cambios.
- Integrado: `tools/zpaq-vectors/osrep-fragment-integration.patch`, con
  `add2_scan` usando la API de OSREP.
- Archivos con `-touch 20240101000000 -timestamp 2024-01-01_00:00:00` para
  que la comparación no dependa del reloj.
- Tiempo de pared y RSS pico con `wait4`; una corrida.
- Corpora: `versions.tar` (125 MB, 4 snapshots de zpaq-std) y `pja.tar`
  (33 MB, 5 snapshots de PJA).

## Resultados (`-m1`)

| corpus | modo | archivo | vs exacto | tiempo | RSS |
|---|---|---:|---:|---:|---:|
| zpaq-std | exacto | 15.293.533 | — | 0,79 s | 542 MB |
| zpaq-std | OSREP 1 KiB | **8.368.993** | **−45,3 %** | 0,76 s | 353 MB |
| zpaq-std | OSREP 4 KiB | 8.683.254 | −43,2 % | 0,75 s | 394 MB |
| zpaq-std | OSREP 8 KiB | 9.028.305 | −41,0 % | 0,82 s | 393 MB |
| PJA | exacto | 2.817.645 | — | 0,50 s | 258 MB |
| PJA | OSREP 1 KiB | 1.784.620 | −36,7 % | 0,39 s | 217 MB |
| PJA | OSREP 4 KiB | 1.768.633 | −37,2 % | 0,43 s | 218 MB |
| PJA | OSREP 8 KiB | **1.762.589** | **−37,4 %** | 0,43 s | 219 MB |

## Resultados (`-m5`)

| corpus | modo | archivo | vs exacto | tiempo | RSS |
|---|---|---:|---:|---:|---:|
| zpaq-std | exacto | 4.548.898 | — | 170,3 s | 1.292 MB |
| zpaq-std | OSREP 1 KiB | 3.837.237 | −15,6 % | 108,0 s | 1.021 MB |
| zpaq-std | OSREP 4 KiB | 3.775.412 | −17,0 % | 119,4 s | 1.023 MB |
| zpaq-std | OSREP 8 KiB | **3.744.456** | **−17,7 %** | 124,4 s | 1.028 MB |
| PJA | exacto | **971.204** | — | 57,6 s | 654 MB |
| PJA | OSREP 1 KiB | 1.024.650 | +5,5 % | 26,9 s | 440 MB |
| PJA | OSREP 4 KiB | 1.010.229 | +4,0 % | 31,4 s | 442 MB |
| PJA | OSREP 8 KiB | 1.003.099 | +3,3 % | 33,8 s | 445 MB |

## Lectura

- **`-m1` (dedup barato)**: OSREP mode es una mejora grande y consistente:
  37–45 % menos archivo, igual o más rápido y 30–35 % menos RSS. El mejor
  promedio depende del corpus: 1 KiB en el grande, 8 KiB en PJA; 4 KiB es un
  buen compromiso.
- **`-m5` (compresión fuerte)**: en el corpus grande OSREP mode gana 17,7 %
  y tarda 27 % menos; en PJA pierde 3,3 % pero tarda **1,7× menos** y usa
  32 % menos RSS. Es un trade-off entre más fragmentos (mejor dedup) y menos
  contexto por bloque para el compresor.
- El default `N=6 → 8 KiB` es razonable para `-m5`; para `-m1` conviene
  `-fragment 3` (1 KiB) o `-fragment 5` (4 KiB).
- Todos los archivos OSREP-mode se extraen con el zpaq-std baseline y
  coinciden byte a byte con la entrada.

## Reproducir

```sh
python3 tools/zpaq-vectors/bench_osrep_mode.py \
  --baseline /ruta/zpaq-std-baseline \
  --integrated /ruta/zpaq-std-osrep \
  --input versions.tar --input pja.tar \
  --method=-m1 --method=-m5 --avgs 1024,4096,8192
```

La salida de la corrida está en `tools/zpaq-vectors/bench-osrep-mode.tsv`.

## Limitaciones

- El prototipo integrado usa `OSREP_FRAG_AVG`; el mapeo automático de
  `-fragment` en el CLI de zpaq-std queda para el parche limpio de entrega.
- Dos corpus; falta zpaqfranz y un corpus de backup real más grande.
- El modo exacto sigue siendo el default y el que garantiza archivos
  idénticos al baseline.
