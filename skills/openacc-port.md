# Skill: OpenACC Port

## Goal

Port the dominant compute kernels to GPU using OpenACC. Target compiler: NVIDIA HPC SDK (`nvc` / `nvfortran`), the successor to the existing PGI build path.

---

## What to port and why

From `make perf` on `job_middle`:

| Kernel | File | % of total | GPU difficulty |
|---|---|---|---|
| `UpdateMAllTwo [68]` | `pfupdate_two.c` | ~43% | Low — hand-coded loops, no library calls |
| `CalculateNewPfMTwo2 [66]` | `pfupdate_two.c` | included above | Low — same file |
| `CalculateMAll [40]` | `matrix.c` | ~18% | High — calls pfapack (DSKPFA) and LAPACK (DGETRF/DGETRI) |
| `UpdateMAll [63]` | `pfupdate.c` | ~5% | Low — hand-coded loops, no library calls |
| `CalculateNewPfM2 [61]` | `pfupdate.c` | included above | Low — same file |

Start with the low-difficulty kernels (pfupdate.c, pfupdate_two.c). They cover the dominant cost and have no external library dependencies.

---

## Parallelism structure

All hot kernels share the same loop structure:

```
for qpidx in 0..NQPFull:          ← outer: quantum projection states (up to 48)
    for i/j in 0..Nsize:           ← inner: matrix elements (2*Ne, up to 200)
        ... hand-coded linear algebra ...
```

The `qpidx` iterations are fully independent. This is the primary GPU parallel dimension. The inner `Nsize` loops can be further parallelized within each `qpidx` block.

The current OpenMP implementation uses `#pragma omp parallel for private(...)` over `qpidx`. The OpenACC port replaces this with `#pragma acc parallel loop`.

---

## Port phases

### Phase 0 — Compiler baseline (no GPU directives yet)

1. Create `src/Makefile_nvhpc` from `src/Makefile_pgi`, replacing compiler flags:
   - `CC = mpicc` (or `nvc` directly if using NVIDIA MPI)
   - `FC = nvfortran`
   - `CFLAGS = -O3 -mp` (OpenMP, for baseline comparison)
   - OpenACC will be added in later phases: `-acc=gpu -gpu=cc<arch>`
2. Create `src/pfapack/Makefile_nvhpc` and `src/sfmt/Makefile_nvhpc`.
3. Add `make nvhpc` to the top-level `Makefile`.
4. Run `make test` — must pass before adding any GPU directives.

### Phase 1 — Port pfupdate kernels (UpdateMAll, UpdateMAllTwo)

These files have no library dependencies and are the highest-value target.

**Workspace arrays**: The current code uses `WorkSpaceThreadDouble` / `WorkSpaceThreadInt` (one buffer per OpenMP thread). On GPU, each `qpidx` iteration needs its own scratch space. Options:
- Allocate scratch inline as VLAs inside the `acc parallel` region (if supported)
- Pre-allocate a 2D scratch array `[NQPFull][Nsize]` and index by `qpidx`

**Data that must live on GPU** during the MC loop:
- `InvM[NQPFull * Nsize * Nsize]` — updated every accepted MC step
- `PfM[NQPFull]` — updated every accepted MC step
- `SlaterElm[NQPFull * Nsite2 * Nsite2]` — read-only during MC sampling
- `eleIdx[Nsize]`, `eleCfg[Nsite2]`, `eleNum[Nsite2]` — electron configuration (CPU-generated, GPU-read)

Use a `#pragma acc data` region around the MC sampling loop in `vmcmake.c` to keep these resident on GPU for the duration of the loop, avoiding per-step transfers.

**Directive pattern** for `updateMAllTwo_child` (inner kernel):
```c
#pragma acc parallel loop gang vector \
    present(InvM, PfM, SlaterElm, eleIdx)
for (int qpidx = 0; qpidx < qpNum; qpidx++) {
    // inner Nsize loops become vector lanes
    #pragma acc loop vector
    for (int i = 0; i < Nsize; i++) { ... }
}
```

### Phase 2 — Validate and measure

After Phase 1:
- `make test` must still pass (physics correctness)
- `make perf NTHREADS=1` — compare GPU vs CPU-only time
- Check that `UpdateMAllTwo / All` drops significantly; `CalculateMAll` will now be the new bottleneck

### Phase 3 — Port CalculateMAll (matrix.c)

This is harder because it calls:
- `DSKPFA` (pfapack) — Pfaffian of a skew-symmetric matrix
- `DGETRF` / `DGETRI` (LAPACK) — LU factorization and inversion

Two options:

**Option A — GPU LAPACK only (partial port)**
Replace `DGETRF`/`DGETRI` with cuSOLVER batched equivalents. Keep `DSKPFA` on CPU (pull the matrix back for Pfaffian only). This gets the LU inversion on GPU but leaves Pfaffian on CPU.

**Option B — Full GPU port**
Port pfapack to OpenACC Fortran (`nvfortran -acc`). The pfapack routines are self-contained Fortran 77; the key routine is `DSKTRD` (skew-symmetric tridiagonalization) followed by `DSKPFA`. Add `!$acc routine` directives to allow them to be called from GPU kernels.

Option B is higher effort but necessary to eliminate the CPU↔GPU transfer of the `bufM` matrix per sample.

**Memory layout**: `matrix.c` uses column-major `bufM` for LAPACK but row-major `InvM`. The copy loop is a natural place for a GPU transpose kernel.

### Phase 4 — VMCMainCal (sample-level parallelism)

Once Phases 1–3 are done, the sample loop in `vmccal.c` is also parallelizable:

```c
// Each sample is independent — embarrassingly parallel
for (sample = sampleStart; sample < sampleEnd; sample++) {
    CalculateMAll(eleIdx, qpStart, qpEnd);   // GPU kernel
    CalculateHamiltonian(...);                // CPU or GPU
    SlaterElmDiff(...);                       // CPU or GPU
    calculateOO(...);                         // DGER/DAXPY → cuBLAS
}
```

This requires batching all the per-sample kernels and managing separate per-sample copies of `InvM`, `PfM` etc.

---

## Data residency strategy

The key to GPU performance is minimizing CPU↔GPU transfers. The dominant transfer cost is:
- `InvM`: `NQPFull × Nsize² × 8 bytes` = 48 × 200² × 8 = ~15 MB for middle case
- `SlaterElm`: `NQPFull × Nsite2² × 8 bytes` = 48 × 400² × 8 = ~245 MB for middle case

`SlaterElm` is updated once per SR step (in `UpdateSlaterElm`), then read-only during all of `VMCMakeSample` and `VMCMainCal`. Keep it on GPU for the entire inner loop and only sync at SR step boundaries.

---

## Build flag additions for OpenACC

Add to `CFLAGS` / `FFLAGS` in `Makefile_nvhpc`:

```makefile
GPU_ARCH = cc80   # A100; use cc70 for V100, cc90 for H100
CFLAGS  = -O3 -acc=gpu -gpu=$(GPU_ARCH) -mp
FFLAGS  = -O3 -acc=gpu -gpu=$(GPU_ARCH) -mp
LIB     = -cudalib=cublas,cusolver -pgf90libs
```

For CPU-only baseline (Phase 0): omit `-acc=gpu`.

---

## Correctness strategy

At each phase, `make test` must pass. The energy output must match the reference within 5%. Since the Markov chain depends on floating-point order-of-operations, GPU results may differ from CPU in the last few ULP — this is acceptable as long as the energy converges correctly.
