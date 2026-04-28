# Skill: Test mVMC-mini

## Goal

Run the `job_tiny` benchmark and verify the output matches the reference results.

**Prerequisite**: `src/vmc.out` exists and is a valid executable. If not, follow the **compile** skill first.

---

## The test case

`job_tiny/` runs a 4×4 Kondo lattice (32 sites, J/t=1.0, half-filling, 16 up-spin electrons) for 20 SR optimization steps. It is deterministic given the fixed `RndSeed` in `zmodpara.def` and produces reproducible output across platforms when using the same MPI layout.

Reference output lives in `result/Lx4Ly4_J1.0/`.

---

## Step 1 — Run

```bash
cd job_tiny
../src/vmc.out multiDir.def
```

**With MPI** (optional; use a rank count that is a multiple of `NSplitSize=1`):

```bash
mpirun -np 4 ../src/vmc.out multiDir.def
```

Expected wall time: ~12 seconds single-rank on a modern laptop.

### What `multiDir.def` controls

```
1
./Lx4Ly4_J1.0 xnamelist.def
```

Format: `<nGroups>` on line 1, then `<jobDir> <defListFile> [<initParamFile>]` per group. The optional third field names a file of initial variational parameters; omit it to start from randomly initialized parameters (normal for a fresh optimization run). If a filename is given but the file is absent, the run aborts with `Error: <file> does not exist.`

Output files appear in `job_tiny/Lx4Ly4_J1.0/`:

| File | Content |
|---|---|
| `zvo_out_000.dat` | Energy per SR step: columns are `E_total`, `variance`, `error` |
| `zvo_var_000.dat` | Variational parameters per step |
| `zvo_time_000.dat` | Wall-clock timestamps |
| `zvo_HitachiTimer.dat` | Hierarchical timer breakdown |

---

## Step 2 — Check for runtime errors

```bash
# Should print only the "fileInitPara is not set" warning (expected when no init file given)
# Any "waring: VMCMainCal" lines mean bad MC steps — a few are normal, many is a bug
../src/vmc.out multiDir.def 2>&1 | grep -v "fileInitPara"
```

Isolated `waring: VMCMainCal rank:0 sample:N w=...` or `e=...` lines (note: typo in source) are normal for early SR steps before parameters converge. A flood of them indicates a problem.

---

## Step 3 — Verify energy convergence

Column 1 of `zvo_out_000.dat` is total energy (not per site). It must decrease (become more negative) as SR optimization proceeds.

```bash
awk '{print NR, $1}' job_tiny/Lx4Ly4_J1.0/zvo_out_000.dat
```

Expected: starts around `-2` and converges to around `-15` by step 20. A flat or upward trend is a bug.

---

## Step 4 — Compare against reference

```bash
paste job_tiny/Lx4Ly4_J1.0/zvo_out_000.dat \
      result/Lx4Ly4_J1.0/zvo_out_000.dat \
  | awk '{
      diff = $1 - $4
      if (diff < 0) diff = -diff
      ref = ($4 < 0) ? -$4 : $4
      pct = 100 * diff / ref
      printf "step %2d: got %+.6e  ref %+.6e  diff %.2e%%\n", NR, $1, $4, pct
    }'
```

**Acceptance**: every step within 5% of reference. On the same platform with the same RNG seed, differences should be < 0.001% (floating-point rounding only).

Quick single-line check (final step only):

```bash
tail -1 job_tiny/Lx4Ly4_J1.0/zvo_out_000.dat   # expect ~ -1.498e+01
tail -1 result/Lx4Ly4_J1.0/zvo_out_000.dat      # reference:  -1.498e+01
```

---

## Step 5 — Timer sanity

```bash
cat job_tiny/Lx4Ly4_J1.0/zvo_HitachiTimer.dat
```

`VMCMainCal [4]` should be the dominant cost. Key sub-timers:

- `CalculateMAll [40]` — Pfaffian computation; expected to be large
- `LocEnergyCal [41]` — Hamiltonian evaluation
- `ReturnSlaterElmDiff [42]` — gradient accumulation

If `StochasticOpt [5]` unexpectedly dominates, check that `-D_lapack` is set (serial solver) and the matrix isn't huge.

---

## Acceptance criteria

| # | Check | Pass condition |
|---|---|---|
| 1 | Binary exists | `src/vmc.out` is a valid executable |
| 2 | Run completes | No `Error:` in stderr; exits 0 |
| 3 | Energy converges | Column 1 of `zvo_out_000.dat` decreasing over at least 15 of 20 steps |
| 4 | Final energy in range | Last step energy within 5% of `-1.498e+01` |
| 5 | Reference match | All 20 steps within 0.01% of reference (same platform) |
