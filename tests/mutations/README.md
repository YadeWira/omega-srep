# Mutation audit

Each `NN-*.py` patches one place in a copy of HEAD (`git archive`), the
runner builds the Pascal there with FPC and runs `tests/gates.sh core`:

* **CAUGHT**: the core failed, so the suite sees that defect.
* **SURVIVED**: the core passed. A case is missing; add one to the golden (or
  a gate) and repeat.
* **BROKEN**: the patch does not apply or the mutated tree does not build.

    tests/mutations/run.sh            # all of them
    tests/mutations/run.sh 08         # one (substring of the file name)
    OSREP_MUTATION_LOGS=dir tests/mutations/run.sh

The runner exports HEAD, not the working tree: commit the mutation before
auditing it. Logs (build and each gate) go to `OSREP_MUTATION_LOGS` or a
temporary directory that is removed when everything is caught.

`equivalent/` holds the mutations whose change does not alter the bytes on
any input measured, with the measurement in its README. They are not
coverage holes.

The current list and which gate catches each one are in
`docs/retire-oracles.md` (Fase D).
