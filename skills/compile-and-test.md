# Skill: Compile and Test mVMC-mini

## Goal

Build `src/vmc.out` and verify it produces correct output on the `job_tiny` benchmark.

---

## Step 1 — Choose a build target

All builds happen inside `src/`. The top-level `Makefile` dispatches to a platform-specific file:

| Target | Makefile used | When to use |
|---|---|---|
| `make intel` | `Makefile_intel` | Intel MPI + MKL (RIKEN, most HPC clusters) |
| `make kashiwa` | `Makefile_kashiwa` | Kashiwa cluster |
| `make kei` | `Makefile_kei` | K computer / FX10 |
| `make pgi` | `Makefile_pgi` | PGI compiler |

**To add a new platform**, copy `Makefile_skeleton` and set `CC`, `FC`, `CFLAGS`, and `LIB` (needs BLAS + LAPACK + ScaLAPACK/BLACS). Then add an entry in the top-level `Makefile`.

### Key build flags

- `-D_mpi_use` — enable MPI. **Omit** for a serial build (stubs in `vmcmain.h` handle this).
- `-D_lapack` — use serial LAPACK solver (`stcopt_dposv.c`). **Without it**, the parallel ScaLAPACK solver (`stcopt_pdposv.c`) is used and BLACS + ScaLAPACK are required.
- `-fopenmp` / `-openmp` — OpenMP threading. Required; the workspace allocator uses `omp_get_thread_num()`.

For development on a single node, prefer `-D_mpi_use -D_lapack` to avoid ScaLAPACK dependency.

---

## Step 2 — Build

```bash
cd src
make intel        # or whichever platform target applies
```

This compiles three components:
1. `pfapack/libpfapack.a` — Pfaffian library (Fortran)
2. `sfmt/SFMT.o` — SIMD Mersenne Twister RNG
3. `vmcmain.o` — entire C source (single translation unit; `vmcmain.c` `#include`s everything)

Then links them into `vmc.out`.

**Expected output**: no errors, `vmc.out` present in `src/`.

**Common failures**:
- Missing `mpicc`/`mpif90` → load MPI module or adjust `CC`/`FC`
- Missing MKL → set `LIB` to system LAPACK/BLAS paths
- Missing ScaLAPACK → add `-D_lapack` to `OPTION` in the Makefile

To clean and rebuild from scratch:
```bash
make clean && make intel
```

---

## Step 3 — Run the tiny benchmark

```bash
cd job_tiny
../src/vmc.out multiDir.def
```

`multiDir.def` lists one job directory: `./Lx4Ly4_J1.0 xnamelist.def`. The job runs 20 SR optimization steps on a 32-site Kondo lattice (4×4, J/t=1.0, half-filling, 16 up-spin electrons).

**With MPI** (e.g., 4 ranks, matching `NSplitSize=1` → 4 independent MC groups):
```bash
mpirun -np 4 ../src/vmc.out multiDir.def
```

Expected wall time: ~12 seconds on a single Intel node.

Output files appear in `job_tiny/Lx4Ly4_J1.0/`:
- `zvo_out_000.dat` — energy per SR step (columns: E/site, variance, error)
- `zvo_var_000.dat` — variational parameters per step
- `zvo_time_000.dat` — wall-clock timestamps
- `zvo_HitachiTimer.dat` — hierarchical timer breakdown

---

## Step 4 — Verify the output

### Quick check: energy is converging

```bash
awk '{print NR, $1}' job_tiny/Lx4Ly4_J1.0/zvo_out_000.dat
```

Column 1 is total energy (not per site). It should decrease (become more negative) over the 20 steps. A flat or increasing trend indicates a bug.

### Reference comparison

Reference output is in `result/Lx4Ly4_J1.0/zvo_out_000.dat`. Compare the final energy:

```bash
tail -1 job_tiny/Lx4Ly4_J1.0/zvo_out_000.dat
tail -1 result/Lx4Ly4_J1.0/zvo_out_000.dat
```

The reference final energy is approximately `-1.50e+01` (total, 32 sites → ~`-0.47` per site). Exact bit-for-bit reproducibility requires the same RNG seed, MPI layout, and FP environment. A tolerance of ±5% on the final energy is a reasonable correctness criterion across platforms.

To check all 20 steps at once against the reference:

```bash
paste job_tiny/Lx4Ly4_J1.0/zvo_out_000.dat result/Lx4Ly4_J1.0/zvo_out_000.dat \
  | awk '{diff=$1-$4; if(diff<0) diff=-diff; print NR, $1, $4, diff}'
```

### Timer sanity check

```bash
cat job_tiny/Lx4Ly4_J1.0/zvo_HitachiTimer.dat
```

`VMCMainCal [4]` time should be the dominant cost. If `LocEnergyCal [41]` dominates unexpectedly, the Hamiltonian call is bottlenecked (check interaction file size).

---

## Acceptance criteria

A build+test is considered passing when:
1. `src/vmc.out` exists and is a valid executable.
2. `job_tiny` completes without `warning:` lines in stderr (or only isolated ones for bad MC steps, which is normal).
3. The final energy in `zvo_out_000.dat` is within ±5% of `-1.50e+01`.
4. The energy trend is monotonically decreasing over at least 15 of the 20 steps.
