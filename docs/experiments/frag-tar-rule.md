# La regla tar de `-osrep` con `-m3`/`-m5` (2026-11-25)

Punto 1 de "Dónde pierde todavía" en [`scoreboard.md`](../scoreboard.md):
PJA y `versions.tar` con `-m5` pierden contra zpaq-std aunque `-osrep`
deduplica más. Las dos ideas anotadas eran **quitar `OSREP_FRAG_F_TAR_AFTER`
desde `-m3`** y **calibrar N contra el fragmento medio real**. Las dos se
midieron y **ninguna sirve**: la regla se queda como está.

## Cómo se midió

- zpaq-std 2.11.0 sin parche contra el parcheado (`-osrep`) de
  `/mnt/IA_LAB/agentes/osrep/score/zpaq-2.11.0{,-osrep}`, con
  `tools/zpaq-vectors/bench_fair.py` (`-threads 4`; cada caso se extrae con
  el baseline y se compara: **0 fallos** en los 178 casos guardados).
- El parcheado de prueba lee dos variables de entorno (solo prototipo, no en
  el repo): `OSREP_FLAGS` reemplaza las reglas de corte (42 = tar + zip, lo
  que usa `-osrep`; 40 = solo zip; 0 = ninguna) y `OSREP_TARMIN=k` hace el
  corte tar solo si el fragmento ya mide `min >> k` (min = A/2).
- Tars del scoreboard: `pja.tar` (5 versiones, 33,6 MB), `versions.tar` (4,
  130,5 MB), `zpaqstd-history.tar` (8 tags, 241,7 MB). `-m1`, `-m3`, `-m5`;
  N = 0, 3, 6, y 7, 8, 9 con `-m5`.
- Datos: [`frag-tar-rule-data/`](frag-tar-rule-data/).

En estos tars las reglas de zip no se activan: 40 y 0 dan los mismos cortes
(mismos tamaños salvo N=0, a menos de 0,03 %), así que "40" es "sin regla
tar".

## Sin compresor (`frag_stats`)

| tar | N | fragmento medio zpaq / con regla / sin regla | únicos (MB) con / sin |
|---|---:|---:|---:|
| versions | 3 | 9,2 / 6,6 / 7,8 KiB | 36,6 / 45,8 |
| versions | 6 | 73,5 / 23,3 / 57,4 KiB | 56,5 / 72,7 |
| pja | 6 | 66,8 / 22,6 / 54,1 KiB | 13,9 / 18,9 |
| zpaqstd-history | 3 | 9,2 / 6,6 / 7,7 KiB | 59,3 / 79,6 |
| zpaqstd-history | 6 | 72,3 / 22,1 / 56,0 KiB | 112,5 / 145,1 |

La regla deduplica bastante más (alinea cada miembro del tar), y a cambio
el fragmento medio con N=6 baja a un tercio del nominal.

## Quitar la regla desde `-m3`: no

Tamaño contra zpaq al mismo N (negativo = gana `-osrep`):

| tar | `-m` | N=3 con / sin | N=6 con / sin |
|---|---|---:|---:|
| pja | `-m3` | −10,2 / −3,6 % | −7,3 / −2,6 % |
| versions | `-m3` | −8,9 / −3,6 % | −20,3 / −6,5 % |
| zpaqstd-history | `-m3` | −27,4 / −8,4 % | −25,1 / −9,8 % |
| pja | `-m5` | +1,5 / +0,6 % | +4,3 / +0,3 % |
| versions | `-m5` | +3,5 / +0,8 % | −16,7 / −7,3 % |
| zpaqstd-history | `-m5` | −21,5 / −3,0 % | −24,4 / −10,4 % |

Con `-m3` la regla gana en todo, de 5 a 19 puntos. Con `-m5`, el mejor N de
cada uno (N de 0 a 9):

| tar | zpaq | con regla | sin regla |
|---|---:|---:|---:|
| versions | 3.749.055 (N=3) | +1,0 % (N=7) | +0,8 % (N=3) |
| pja | 962.083 (N=9) | +4,7 % (N=9) | +0,3 % (N=9) |
| zpaqstd-history | 5.461.215 (N=0) | **−15,7 %** (N=3) | +1,0 % (N=0) |

Sin la regla, `-m5` pasa de "gana mucho en el historial, pierde en pja" a
"pierde un poco en los tres". Peor.

## Calibrar N: no

Con la regla, el fragmento real es ~1/3 del nominal, y la idea era pedir un
N más alto. Con `-m5`, pja pierde +4,2 a +4,7 % **con cualquier N de 0 a 9**:
no es el tamaño del fragmento.

## Corte tar solo con fragmentos grandes (`OSREP_TARMIN`): no

| tar | `-m` | N | con regla | k=1 (≥ A/4) | k=0 (≥ A/2) = sin regla |
|---|---|---:|---:|---:|---:|
| pja | `-m5` | 6 | +4,3 % | +0,6 % | +0,3 % |
| versions | `-m5` | 3 | +3,5 % | +1,0 % | +0,8 % |
| zpaqstd-history | `-m5` | 3 | −21,5 % | −9,8 % | −3,0 % |
| zpaqstd-history | `-m1` | 3 | −35,0 % | −23,0 % | −19,4 % |

El umbral reparte entre los dos extremos y no gana en ninguno: lo que recupera
en pja lo pierde en el historial. Con k=0 los cortes tar no se dan nunca (el
gear ya cortó antes) y el resultado es el de "sin regla", byte a byte.

## Por qué pierde pja con `-m5`

`pja.tar` mete las 5 versiones en un tar y se agrega de una vez: con 33 MB,
todo cabe en un bloque de `-m5` y el modelo de contexto ya ve la redundancia
entre versiones. Deduplicar más no ahorra casi nada ahí, y cuesta: 3× más
fragmentos (índice) y cortes donde el modelo tenía contexto. En el historial
(241 MB) las versiones no caben en un bloque y la deduplicación es lo que
gana.

Un backup real agrega cada versión aparte. pja como 5 carpetas agregadas una
tras otra al mismo archivo (`bench_versions.py`; ahí no hay cabeceras tar, la
regla no actúa):

| `-m` | zpaq N=3 / 6 / 9 | `-osrep` N=3 / 6 / 9 | mejor contra mejor |
|---|---:|---:|---:|
| `-m1` | 1.881.091 / **1.839.163** / 1.861.017 | 1.876.291 / **1.845.375** / 1.860.916 | +0,34 % |
| `-m5` | 1.117.476 / 1.095.115 / **1.093.006** | 1.122.613 / 1.099.514 / **1.098.339** | +0,49 % |

La pérdida de +4 % es del caso "todas las versiones en un tar, en un solo
`a`". Como backup, pja pierde +0,3/+0,5 %, que es el problema de los árboles
de archivos chicos (punto 3 del scoreboard, el mínimo A/2), no el de la
regla tar.

## Decisión

- `OSREP_FRAG_F_TAR_AFTER` se queda en todos los métodos.
- Lo siguiente es el mínimo en árboles de archivos chicos
  (`min(A/2, 4 KiB)` u otro tope; pendiente 2 de
  [`zpaq-osrep-mode.md`](../zpaq-osrep-mode.md#pendiente)), medido con
  carpetas (src-omega, pja como versiones) y `-m1`/`-m5`.
