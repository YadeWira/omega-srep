# Tope al mínimo del gear en árboles de archivos chicos (2026-11-26)

Punto 3 del scoreboard ("árboles de fuentes chicos a N fijo") y pendiente 2
de [`zpaq-osrep-mode.md`](../zpaq-osrep-mode.md#pendiente): con N grande, el
mínimo A/2 de `-osrep` (32 KiB en N=6) es más que casi todos los archivos de
un árbol de fuentes, así que un archivo cambiado se guarda entero. La idea
era un mínimo con tope, `min(A/2, C)`. **Rechazado**: mejora N=6 en algunos
árboles, pero nunca le gana al mejor N de hoy, y empeora otros.

## Cómo se midió

- zpaq-std 2.11.0 sin parche contra el parcheado (`-osrep`), con
  `tools/zpaq-vectors/bench_versions.py` (cada versión se copia sobre la
  misma carpeta y se agrega al mismo archivo; `-threads 4`; todo en el mismo
  workdir, porque la ruta mueve el tamaño). Se extrae la última versión y se
  compara: 98 casos, **0 fallos**.
- El prototipo lee `OSREP_MINCAP=<bytes>` (solo en el clon de prueba): usa el
  menor desplazamiento s de 1 a 4 con `A >> s` ≤ tope, con el umbral ya
  calibrado de ese s, así que el promedio no cambia. Con N ≤ 3 no cambia nada;
  con 4 KiB, N=6 queda en A/16 y N=9 en A/16 (32 KiB).
- Corpus: `src-omega` (40 versiones, 62 MB), `pja` (las 5 versiones de
  `pja.tar` como carpetas), `bin-releases` (39), `src-zpaqstd` (16, solo
  `-m1`), `mixed` (una carpeta). zpaq y `-osrep` con N = 0, 3, 6, 9; el tope de
  4 y 8 KiB con N = 6 y 9 (8 KiB con `-m5` no se terminó: con N=9 da lo mismo
  que 4 KiB, y la tendencia ya era clara).
- Datos: [`frag-mincap-data/`](frag-mincap-data/) (`an.py` arma las tablas).

## Resultado

Tamaño contra zpaq al mismo N (negativo = gana `-osrep`), y el mejor N de
cada uno:

| corpus | `-m` | N=6 hoy / tope 4K | N=9 hoy / tope 4K | mejor contra mejor (hoy) |
|---|---|---:|---:|---:|
| src-omega | `-m1` | +2,8 / −0,7 % | +0,2 / +0,2 % | −4,1 % (N=0) |
| src-omega | `-m5` | +11,1 / +19,6 % | +0,1 / +0,1 % | −3,7 % (N=0) |
| bin-releases | `-m1` | −3,2 / −3,7 % | −1,4 / −5,3 % | −1,6 % (N=0) |
| bin-releases | `-m5` | −3,0 / −3,6 % | −1,2 / −5,0 % | −1,5 % (N=0) |
| src-zpaqstd | `-m1` | −2,2 / +2,9 % | +2,0 / +17,0 % | −5,1 % (N=3) |
| pja | `-m1` | +0,4 / +1,1 % | −0,0 / −0,2 % | +0,4 % |
| pja | `-m5` | +0,5 / +0,5 % | +0,5 / +0,4 % | +0,5 % |
| mixed | `-m1` | +0,2 / +0,1 % | +0,3 / +0,3 % | +0,3 % |
| mixed | `-m5` | +0,1 / — | +0,0 / — | +0,0 % |

- El tope arregla src-omega `-m1` en N=6 (+2,8 → −0,7 %), pero N=6 no es el
  mejor N de src-omega: con N=0, donde el tope no actúa, `-osrep` ya gana
  −4,1 %. Con `-m5` lo empeora (+11 → +20 %).
- En src-zpaqstd lo empeora mucho (N=9 +2 → +17 %).
- Mejor contra mejor no cambia en ningún corpus salvo pja `-m5` (+0,49 →
  +0,37 %), que no paga lo que cuesta en los otros.

## Dónde pierde pja como carpetas

Solo la primera versión de pja, sin las otras, empata o gana:

| `-m` | N=6 zpaq / `-osrep` | N=9 zpaq / `-osrep` |
|---|---:|---:|
| `-m1` | 1.720.571 / 1.719.769 (−0,05 %) | 1.717.861 / 1.717.771 (−0,01 %) |
| `-m5` | 979.408 / 978.648 (−0,08 %) | 976.832 / 976.746 (−0,01 %) |

Las versiones siguientes cambian solo ~10 archivos de texto (`ci.yml`,
`pjaheap.pas`, `LIBRARY.md`, `README.md`, `pja.h`…). Lo que cuesta guardarlos
es ~4,6 KB más con `-osrep` (`-m5` N=9: 121,6 KB contra 117,0 KB). El hash de
orden 1 de zpaq corta el texto predecible más seguido que su promedio nominal,
así que reaprovecha más de un archivo de texto que cambió; el gear de `-osrep`
corta igual en texto que en binario. Es la misma causa que ya anotaba el
punto 3 del scoreboard. Cuesta +0,4/+0,5 % en un corpus donde casi nada
cambia; en src-omega y src-zpaqstd, los árboles de texto con más cambios,
`-osrep` gana con su mejor N.

## Decisión

- El mínimo se queda en A/2. `OSREP_MINCAP` vive solo en el clon de prueba.
- Lo que queda de pja (+0,4/+0,5 %) es cortar el texto más fino que el
  binario. Un gear que adapte el umbral al tipo de contenido es un cambio
  mayor (y `-osrepauto`, el promedio adaptativo por archivo, ya se probó y
  se rechazó: [`frag-adaptive.md`](frag-adaptive.md)); no se intenta por
  ahora.
