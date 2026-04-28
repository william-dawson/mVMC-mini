# Skill: Performance Analysis

**Prerequisite**: `src/vmc.out` must exist. Run a build target first (e.g. `make mac`).

## Performance run (job_tiny)

```bash
make perf                        # 1 rank, 1 thread (serial baseline)
make perf NTHREADS=8             # 1 rank, 8 OpenMP threads
make perf NRANKS=4 NTHREADS=8   # 4 MPI ranks, 8 threads each
```

Runs `job_tiny` with the given settings and prints the full timer tree and key hotspot ratios.

## Full benchmark (job_middle)

```bash
make bench                         # 1 rank, 1 thread
make bench NRANKS=128 NTHREADS=8   # production config
```

Runs `job_middle` (200-site system) with the given settings and prints the full timer breakdown and hotspot ratios.

## Interpreting the output

### Expected hotspot profile

The timer output is a wall-clock tree. Key ratios to read:

| Ratio | Expected range | Meaning |
|---|---|---|
| VMCMakeSample / All | 60–80% | MC sampling dominates — normal |
| exchange update / VMCMakeSample | 70–80% | Two-electron swaps dominate sampling |
| UpdateMAllTwo / All | 20–45% | Rank-2 inverse update — primary hotspot, grows with Ne |
| CalculateMAll / VMCMainCal | 55–85% | Full Pfaffian recompute per sample |
| WeightAverage / All | < 5% | MPI reduction — if higher, communication is a bottleneck |

### Thread scaling interpretation

The hot kernels (`UpdateMAllTwo`, `CalculateMAll`, `CalculateNewPfMTwo2`) parallelize with OpenMP and will show better per-kernel speedup than the overall wall time. The gap between them is serial bookkeeping (move proposal, config updates) that is not parallelized and sets an Amdahl ceiling.

Hyperthreading typically hurts for this workload — the kernels are compute- and memory-bound. If efficiency drops sharply above the physical core count, cap `OMP_NUM_THREADS` at physical cores.

### Signs of a problem

| Symptom | Likely cause |
|---|---|
| `StochasticOpt` > 10% of total | LAPACK solver slow — confirm `-D_lapack` is set, or check matrix conditioning |
| `WeightAverage` > 5% | Inter-group MPI cost high — increase `NVMCSample` or reduce `NSplitSize` |
| `recal PfM and InvM` > 10% | Numerical instability triggering frequent recomputes |

### Performance levers

| Lever | Effect |
|---|---|
| `OMP_NUM_THREADS` | Set to physical core count for best single-node throughput |
| More MPI ranks | Linear reduction in wall time; each rank group runs independent MC |
| `NVMCSample` | More samples → lower variance, linear cost |
| `NSPGaussLeg` / `NMPTrans` | Reduce quadrature points → smaller `NQPFull`, faster `CalculateMAll` |
| GPU port of `UpdateMAllTwo` | Largest single hotspot; O(Ne²) per move, attractive at large Ne |
