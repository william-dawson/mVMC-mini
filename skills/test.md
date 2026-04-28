# Skill: Test

Run the correctness test from the repo root:

```bash
make test
```

This runs `job_tiny` (32-site Kondo lattice, 20 SR steps) with 1 thread and compares every energy step against the reference in `result/Lx4Ly4_J1.0/`. Prints `PASS` or `FAIL` with per-step details.

**Prerequisite**: `src/vmc.out` must exist. Run a build target first (e.g. `make mac`).

## What's being checked

The energy in column 1 of `zvo_out_000.dat` must be within 5% of the reference at every step. On the same platform with a fixed RNG seed the values should match to <0.01%.

## Interpreting failures

| Symptom | Likely cause |
|---|---|
| `ERROR: src/vmc.out not found` | Binary not built — run `make mac` (or your platform target) |
| `FAIL step N: got X ref Y (Z%)` | Physics output diverged — check build flags, LAPACK linkage, or RNG seed in `zmodpara.def` |
| `Error: opt.init does not exist` | Third field in `multiDir.def` names a missing file — remove it |
| Many `waring: VMCMainCal` lines in output | Numerically bad MC steps early in optimization — a few are normal, a flood is not |
