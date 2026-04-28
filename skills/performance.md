# Skill: Performance Analysis

## Goal

Run the benchmarks, read the built-in timer output, and identify where time is spent.

**Prerequisite**: `src/vmc.out` exists and passes the **test** skill.

---

## The two benchmark cases

| | `job_tiny` | `job_middle` |
|---|---|---|
| Lattice | 4×4 Kondo (32 sites) | 10×10 Kondo (200 sites) |
| Electrons (Ne) | 16 | 100 |
| Pfaffian matrix size | 32×32 | 200×200 |
| Projection points (NMPTrans × NSPGaussLeg) | 1×16 = 16 | 4×12 = 48 |
| NVMCSample | 192 | 192 |
| NSROptItrStep | 20 | 20 |
| NSplitSize (MPI ranks/group) | 1 | 4 |
| Reference wall time | ~3s (1 rank, 1 thread) | ~256s (128 ranks, 8 threads) |

Start with `job_tiny` to establish a baseline; `job_middle` is the real scaling target.

---

## Step 1 — Run with timing

### Tiny (development baseline)

```bash
cd job_tiny
OMP_NUM_THREADS=1 ../src/vmc.out multiDir.def
cat Lx4Ly4_J1.0/zvo_HitachiTimer.dat
```

### Middle (production benchmark)

The reference configuration uses 128 MPI ranks × 8 OpenMP threads (matching the K computer job script). Adjust to your available hardware — ensure `nranks` is a multiple of `NSplitSize=4`.

```bash
cd job_middle
# remove opt.init from multiDir.def if absent (same issue as job_tiny)
OMP_NUM_THREADS=8 mpirun -np 128 ../src/vmc.out multiDir.def
cat Lx10Ly10_J1.0/zvo_HitachiTimer.dat
```

For a quick local run with fewer resources:
```bash
OMP_NUM_THREADS=4 mpirun -np 4 ../src/vmc.out multiDir.def
```

---

## Step 2 — Read the timer

The timer file (`zvo_HitachiTimer.dat`) is a two-level tree of wall-clock seconds. Key sections:

```
All                         [0]   <total>
  Initialization            [1]   ~0   (negligible)
  VMCParaOpt                [2]   ≈ All
    VMCMakeSample           [3]   MC sampling loop
      makeInitialSample    [30]   one-time burn-in
      make candidate       [31]   propose electron moves
      hopping update       [32]   single-electron hop accept/reject
        CalculateNewPfM2   [61]     rank-1 Pfaffian update
        UpdateMAll         [63]     rank-1 inverse update
      exchange update      [33]   two-electron swap accept/reject  ← usually dominant
        CalculateNewPfMTwo2[66]     rank-2 Pfaffian update
        UpdateMAllTwo      [68]     rank-2 inverse update          ← single biggest cost
      recal PfM and InvM   [34]   periodic full recompute (numerical stability)
    VMCMainCal              [4]   compute E and SR matrices per sample
      CalculateMAll        [40]   full Pfaffian + inverse recompute per sample
      LocEnergyCal         [41]   Hamiltonian application
      ReturnSlaterElmDiff  [42]   gradient ∂ln(Ψ)/∂αi
      calculate OO and HO  [43]   DGER/DAXPY accumulation into SR matrices
    StochasticOpt           [5]   solve S·Δα = g (SR step)
    WeightAverage          [21]   MPI Allreduce of E, OO, HO       ← scales with MPI groups
```

---

## Step 3 — Compute the key ratios

Extract these numbers from the timer and compute the ratios. They tell you where to focus optimization effort.

```bash
awk '
  /All /           { total=$NF }
  /VMCMakeSample / { samp=$NF }
  /exchange update/{ exch=$NF }
  /UpdateMAllTwo / { umall=$NF }
  /VMCMainCal /    { cal=$NF }
  /CalculateMAll / { pfcal=$NF }
  /WeightAverage / { wavg=$NF }
  END {
    printf "VMCMakeSample  / All          = %.1f%%\n", 100*samp/total
    printf "exchange update/ VMCMakeSample= %.1f%%\n", 100*exch/samp
    printf "UpdateMAllTwo  / All          = %.1f%%\n", 100*umall/total
    printf "VMCMainCal     / All          = %.1f%%\n", 100*cal/total
    printf "CalculateMAll  / VMCMainCal   = %.1f%%\n", 100*pfcal/cal
    printf "WeightAverage  / All          = %.1f%%\n", 100*wavg/total
  }
' Lx4Ly4_J1.0/zvo_HitachiTimer.dat
```

### Reference values (what to expect)

|  | Tiny (1 rank, 1 thread) | Middle (128 ranks, 8 threads) |
|---|---|---|
| VMCMakeSample / All | 61% | 79% |
| exchange update / VMCMakeSample | 73% | 79% |
| **UpdateMAllTwo / All** | **19%** | **43%** |
| VMCMainCal / All | 38% | 18% |
| CalculateMAll / VMCMainCal | 55% | 82% |
| WeightAverage / All | < 1% | 2% |

---

## Step 4 — Interpret the results

### Normal profile

- **VMCMakeSample dominates** (60–80%): expected. The MC loop runs `NVMCSample × NVMCIniterval × NExUpdatePath` Metropolis steps per SR iteration.
- **`UpdateMAllTwo [68]` is the single biggest hotspot**: rank-2 inverse update after a two-electron exchange. It is O(Ne²) per accepted move and dominates at large Ne. This is the primary GPU porting target.
- **`CalculateMAll [40]` is large inside VMCMainCal**: full Pfaffian + LU inverse recompute via pfapack for each sample. Also O(Ne³) but called once per sample rather than once per move.
- **`WeightAverage [21]` grows with NSplitSize**: MPI Allreduce across groups. If this exceeds 5%, the inter-group communication is becoming a bottleneck.

### Signs of a problem

| Symptom | Likely cause |
|---|---|
| `StochasticOpt [5]` > 10% of total | ScaLAPACK DPOSV slow — check `-D_lapack` flag or matrix conditioning |
| `WeightAverage [21]` > 5% | Too many MPI groups relative to NVMCSample; increase NVMCSample or reduce NSplitSize |
| `recal PfM and InvM [34]` > 10% | Numerical instability forcing frequent recomputes; check Pfaffian values |
| `CalculateLogIP [62/67]` surprisingly large | Many rejected moves; check projection or parameter initialization |

---

## Step 5 — Scaling experiment

To measure strong scaling (fixed problem, more resources):

1. Fix `NVMCSample=192`, `NSROptItrStep=20` in `zmodpara.def`.
2. Run with `NSplitSize=1` (all ranks in one group) through the rank counts you care about, keeping `nranks = k × NSplitSize`.
3. Record `Timer[0]` (the `All` row) for each run.
4. Plot wall time vs rank count; ideal scaling halves time on each doubling.

Note: `NSplitSize` controls how many independent MC groups there are. With `nranks=128, NSplitSize=4`, you get 32 groups of 4 ranks each — the 4 ranks within each group are only used if the ScaLAPACK solver is active (no `-D_lapack`). With `-D_lapack`, all MC groups run independently and only communicate during `WeightAverage`.

---

## Performance levers (in order of impact)

| Lever | Effect |
|---|---|
| Increase `OMP_NUM_THREADS` | Parallelizes inner loops (`UpdateMAllTwo`, `UpdateMAll`) via OpenMP |
| Increase MPI ranks (more groups) | More MC samples per SR step → better statistics, same wall time |
| Increase `NVMCSample` | More samples per group → lower variance, linear cost increase |
| Reduce `NSPGaussLeg` | Fewer spin-projection quadrature points → smaller `NQPFull`, faster `CalculateMAll` |
| Reduce `NMPTrans` | Fewer momentum-projection operators → smaller `NQPFull` |
| GPU port of `UpdateMAllTwo` | Targets the single biggest hotspot; O(Ne²) per move |
