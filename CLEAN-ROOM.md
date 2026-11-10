# Clean-room rules for the implementation session

You are **Team B**. You write the OSREP implementation. Team A wrote `spec/`
and `tests/fixtures/` by observing the legacy project; you must not read the
legacy code.

## What you may read

- Everything in this branch: `spec/`, `tests/fixtures/`, `docs/`, README.
- Public format documentation and public-domain reference code (LibTomCrypt,
  VMAC, LZMA2, SipHash) if a component needs it.
- The test vectors and the v6 fixtures as data.

## What you must not read

- The `main` branch, any tag up to `v3.0.0`, the `legacy` refs, the release
  assets, the archived C++/Rust oracles, or any `.pas` from the old project.
- Do not run the old binary to infer behaviour. If a detail is missing, ask
  Team A to add it to `spec/`; do not derive it from the old source.

## How to get a clean checkout

```bash
  git clone --single-branch --branch osrep https://github.com/YadeWira/omega-srep.git osrep
```

Do not fetch other branches or tags into that clone.

## What Team A read

- The legacy Pascal/C++/Rust sources and the 3.0.0 binary, to produce the
  functional spec, the CLI contract, the v6 fixtures and the pair of
  behaviours this project keeps.
- No old code was copied into `spec/`; it contains behaviour, layouts,
  formulas and test data only.

## What "done" means

- Every behaviour you implement is traceable to a line in `spec/` or to a
  fixture in `tests/fixtures/`.
- If the spec is silent, you stop and ask; you do not guess from the legacy
  code.
- `docs/clean-room-plan.md` has the phases and the acceptance criteria.
