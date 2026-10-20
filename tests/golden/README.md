# Golden suite

Casos congelados: para cada línea de `cases.txt`, el sha256 del archivo, el
exit code y la ida y vuelta. `check.sh` los reproduce **con el Pascal solo**,
sin C++ ni Rust.

```
bash tests/golden/make.sh     # graba manifest.tsv (necesita los oráculos)
bash tests/golden/check.sh    # verifica (no necesita los oráculos)
```

## Para qué

Las compuertas diferenciales comparan contra el C++ 1.0.7 y el Rust en cada
corrida. Eso es la medida más fuerte que tiene el proyecto, pero ata cada
corrida a dos toolchains y a un pin de Rust que Windows 7 congela para
siempre. Esta suite es el reemplazo gradual: los casos se graban una vez,
verificados por los dos oráculos y por el port, y después se replayed contra
el Pascal solo.

Un caso entra en `cases.txt` únicamente si el oráculo es confiable para él:

* `--format=v4`: el C++ y el Rust tienen que escribir lo mismo, dos corridas
  cada uno (una corrida que cambia no se fija: es la carrera documentada del
  C++ con bloques chicos).
* `--format=v5`: solo el Rust puede escribirlo.

No entran los dos lugares donde el C++ 1.0.7 no hace ida y vuelta: `-dup` con
un `-l` que no es potencia de dos (pierde el trailer ODUP) y `-m4`/`-m5` con
`-l` por debajo de `-c` (el wrap sin signo del filtro de slices). Esos están
fijados a propósito, con su explicación, en `tests/pascal_encode_conformance.sh`
y `tests/rust_cli_conformance.sh`.

## Reglas

* **`make.sh` no graba nada si un caso falla.** El manifiesto se escribe en
  un temporal y se mueve al final.
* **Un manifiesto que cambia es un cambio de formato.** Al re-grabar, revisar
  el diff: cada línea distinta es un archivo distinto. Si el cambio no es
  deliberado, es un bug.
* **Los oráculos tienen que ser la versión actual.** `make.sh` compara
  `--version` del Rust y del port y se niega si no coinciden: un
  `target/release/osrep` viejo convierte una comparación cuidadosa en una
  comparación contra otra versión (pasó el 2026-10-20 con un Rust 2.2.1).
* **Las entradas son deterministas** y salen de `tests/gen_corpus.sh` y de
  `inputs.sh`; no se guardan binarios en el repo.

## Estado

Primera versión (2026-10-20): 35 casos, v4 y v5, modos m0..m5, los tres
contenedores viejos (`o`), Future-LZ (`f`), hashes, `-dup` y las opciones que
cambian los bytes (`-a`, `-ia-`, `-l/-c`, `--chunk-*`). Es una semilla, no el
reemplazo completo: las suites diferenciales siguen cubriendo mucho más.

## Cuando los oráculos se vayan

1. Que `check.sh` corra en las compuertas junto a las diferenciales, y que las
   diferenciales pasen a ser opcionales.
2. Congelar más casos hasta que las diferenciales no encuentren nada que la
   suite no cubra.
3. Archivar `oracles/cxx` y `oracles/rust` en un tag, sacarlos de `main`, y
   dejar `docs/format-spec*.md` y este manifiesto como la definición.
