# tools/scoreboard

Harness del scoreboard interno (OSREP contra SREP 3.93a, REP de FreeArc,
Omega SREP 3.0.0 y el deduplicador de zpaq-std). Resultados y lectura en
[`docs/scoreboard.md`](../../docs/scoreboard.md).

- `make_corpus.sh <dir>`: copia y arma el corpus (tars reproducibles).
- `scoreboard.py`: corre cada preprocesador solo y con cada backend; tiempo
  de pared, CPU y RSS pico con `os.wait4()`; ida y vuelta con `cmp`; TSV
  fila por fila (se puede cortar y retomar). `--list` muestra las
  configuraciones. Córrelo dentro de la jaula de memoria (ver el
  docstring).
- `report.py <tsv>`: las tablas Markdown del documento.
- `scoreboard-2026-11-14.tsv`: los datos de la medición del documento.

Los binarios se toman de las rutas por defecto o de `OSREP`, `SREP`,
`OMEGA`, `FA`, `ZPAQ`, `XZ` y `ZSTD`.
