# Equivalent mutations

A mutation here is applied and built the same way as the others, but it is
not a coverage hole when the suite passes: the references produce the same
bytes for the mutated code path, so there is nothing to catch.

`tests/mutations/run.sh` skips this directory. To run one by hand:

    tests/mutations/run.sh 01   # matches nothing: use the build recipe below

The runner's recipe is: export HEAD with `git archive`, copy the `.py` to the
scratch tree's `tests/mutations/`, run it, build `pascal/osrep.lpr`, then run
`tests/gates.sh core`.

## 01-m5-plain

`-m5` always takes the plain scan (`accelerator := 0`), ignoring the derived
variant. The C++ 1.0.7 and the Rust also write the same bytes with `-a0` as
with the default accelerator on `-m5` (checked on a 2 MiB slice of the real
corpus), so there is no archive to distinguish: the accelerator only changes
which candidates the heuristic scan visits, and `-m5` re-checks every
position anyway.
