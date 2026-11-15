# Mínimo del gear más bajo (A/8, A/16) en `-osrep`: rechazado

**Fecha: 2026-11-15.** Prototipo interno sobre zpaq-std 2.11.0 + `-osrep`
(clon `score/zpaq-2.11.0-osrep`, sin publicar). `frag_stats` predecía que bajar
el mínimo del gear de A/2 a A/8–A/16 era la palanca más grande del marcador de
dedup (imagen de disco e `insert` pasaban a victorias). Se midió con archivos
reales.

## Cómo

- `osrep_frag_params_osrep()` lee `OSREP_MIN_SHIFT=1..4` (solo en el
  prototipo; s=1 es `-osrep` de hoy, s=3 es A/8, s=4 es A/16). Mismos cortes de
  formato, mismo umbral.
- `bench_versions.py` y `bench_fair.py` (`--kinds osrep` para no repetir zpaq),
  `-m1`, `-threads 4`, mismo workdir. Corpus: los de `corpus6`, los tres tars y
  los sintéticos de `make_weakspots.py` **regenerados** (sin la carpeta
  `disksrc`, que ya no existía: la imagen de disco ocupa 327 MiB en vez de 501,
  así que sus números no se comparan con los del marcador del mismo día).
- Datos y scripts en `frag-minimum-data/` (`minsum.py` arma la tabla).

## Resultado (`-m1`, tamaño del archivo, negativo = gana `-osrep`)

Mejor N de cada uno contra el mejor N de zpaq, y default contra default:

| corpus | A/2 mejor | A/8 mejor | A/16 mejor | A/2 d | A/8 d | A/16 d |
|---|---:|---:|---:|---:|---:|---:|
| versions.tar | −8,0 % | **−10,4 %** | −6,9 % | −49,1 % | −50,5 % | −48,5 % |
| pja.tar | −0,6 % | −0,7 % | −0,7 % | −36,9 % | −36,5 % | −36,7 % |
| zpaqstd-history.tar | −9,3 % | −6,9 % | **−9,6 %** | −64,1 % | −65,1 % | −63,1 % |
| src-zpaqstd | **−5,1 %** | −2,5 % | −2,0 % | −24,5 % | −22,4 % | −22,0 % |
| src-omega | −4,1 % | −4,1 % | +3,9 % | −13,6 % | −22,3 % | −21,4 % |
| bin-releases | **−1,6 %** | −0,9 % | −0,8 % | −11,9 % | −11,6 % | −11,5 % |
| mixed | +0,2 % | +0,1 % | +0,1 % | +0,3 % | +0,4 % | +0,6 % |
| disk | **−0,6 %** | −0,3 % | −0,2 % | −9,8 % | −9,5 % | −9,5 % |
| insert | +0,1 % | −0,0 % | +0,1 % | −7,3 % | −7,4 % | −7,3 % |
| db4k | **−1,1 %** | −0,4 % | −0,3 % | −52,8 % | −53,4 % | −53,3 % |
| db8k | −0,6 % | −0,7 % | −0,4 % | −43,1 % | −43,1 % | −43,0 % |
| db16k | **−2,8 %** | −2,3 % | −2,2 % | −30,0 % | −29,7 % | −29,6 % |

- Con el mejor N de cada uno, A/2 es el mejor o empata en 9 de 12; A/8 gana
  `versions.tar` (−2,4 puntos) y A/16 el historial (−0,3 puntos). Ninguno
  convierte en victoria lo que A/2 pierde (mixed, insert).
- Donde el mínimo bajo sí ayuda es en N=6 (disk −1,5 a −1,6 %, insert −1,2 a
  −1,5 %, src-omega −3,5 %), pero N=6 nunca es el mejor N de esos corpus, y en
  N=3/N=0 empeora: el fragmento medio baja y el índice y los cortes en mitad del
  contexto se comen lo que gana la deduplicación. `frag_stats` solo cuenta bytes
  únicos y no ve ese costo.
- A/16 en N=0 es inestable (src-omega +3,9 % contra −4,1 % de A/2).
- No se corrió `-m5`: con `-m5` los fragmentos de más ya eran la causa de la
  derrota en PJA, así que un mínimo más bajo solo puede empeorarlo.

## Decisión

Queda **mínimo A/2**. El override `OSREP_MIN_SHIFT` vive solo en el clon del
prototipo y no entra al parche. La próxima palanca del lado de zpaq-std es
quitar los cortes de tar desde `-m3` (PJA/tars con `-m5`).
