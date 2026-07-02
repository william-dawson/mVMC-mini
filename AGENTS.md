# AGENTS.md — mVMC-mini GPU Porting Diary

**Rule:** Any agent working on this project must keep this file up to date.
After completing a task, add a brief bullet under the relevant section (or a new section).
Each bullet should state what was done and where to look for details — no long explanations here.

---

## Remote environment

- **Cluster:** R-CCS Cloud (`login.cloud.r-ccs.riken.jp`)
- **Project directory:** `~/fugaku_next/port_mvmc_gpu/mVMC-mini`
- **Branch:** `gpu-port` — all porting work goes here
- GitHub SSH keys are configured on the cluster; use `git pull` to sync changes.

## Building (CPU baseline — Genoa)

- **Makefile:** `src/Makefile_genoa` — GCC 11 + MPICH, OpenBLAS via FlexiBLAS (`-l:libflexiblas.so.3`), `-march=native`, `-D_lapack` (uses serial DPOSV; no ScaLAPACK needed).
- **Sub-library flags:** `pfapack/Makefile_gnu` and `sfmt/Makefile_gnu` must compile with `-fPIC`; Red Hat 9 enforces PIE linking via the mpif90 wrapper spec file.
- **Build job:** submit to the `genoa` partition; compile on the node so `-march=native` resolves to znver4 (EPYC 9684X).
- Module load: `module load system/genoa mpi/mpich-x86_64`

## Building (GPU target — ng-dgx GB10 Grace Blackwell, aarch64)

- **Makefile:** `src/Makefile_ngdgx` — NVHPC 26.3 (`nvc`/`nvfortran`), BLAS/LAPACK from NVHPC SDK at `/opt/nvidia/hpc_sdk/Linux_aarch64/26.3/compilers/lib`, `-mp` for OpenMP, `-tp native` for GB10 target, `-D_lapack`.
- **Key flags:** `-Mnomain` on the link step — `nvfortran` injects `f90main.o` which conflicts with the C `main`; this is the NVHPC equivalent of Intel's `-nofor-main`.
- **Sub-library flags:** `pfapack/Makefile_nvhpc` and `sfmt/Makefile_nvhpc`. SFMT compiled without SSE2 (aarch64 has no x86 SIMD); plain C fallback is sufficient.
- **OS:** Ubuntu (not Rocky Linux) — binaries built here will not run on Genoa nodes and vice versa.
- Module load: `module load system/ng-dgx nvhpc`

## Running

- **Tiny benchmark:** `cd job_tiny && mpirun -np 4 ../src/vmc.out multiDir.def`
- The message `Error: opt.init does not exist` is expected and harmless (documented in README).
- Output lands in `job_tiny/Lx4Ly4_J1.0/zvo_out_000.dat`; compare column 1 (energy) against `result/Lx4Ly4_J1.0/zvo_out_000.dat`. Values differ by run due to MC stochasticity but the converging trend must match.
- **Medium benchmark:** `job_middle/` — use this for timing baselines before and after GPU changes.
- **Binaries are architecture-specific:** Genoa binary (x86-64) will not run on ng-dgx (aarch64) and vice versa. Always build on the target partition before running.

## Building (CPU baseline — Hokusai HBW2, Intel Xeon, x86_64)

- **Makefile:** `src/Makefile_hokusai` — Intel oneAPI 2025.3 (`mpiicx`/`mpiifx`), MKL via `-qmkl`, `-qopenmp -xHost`, `-nofor-main` on link step, `-D_lapack`.
- **Sub-library flags:** `pfapack/Makefile_intel` (`ifx -implicitnone -xHost -fPIC`) and `sfmt/Makefile_intel` (`icx -xHost -fPIC -DHAVE_SSE2`). Note: ifx uses `-implicitnone` (Intel style), not `-fimplicit-none` (GNU style).
- **Module load:** `module load intel/25.3.0` — auto-loads `intelmpi`; gives `mpiicx`, `mpiifx`, MKL at `$MKLROOT`.
- **Do not use `mpiicc`** — wraps deprecated `icc` (not installed in oneAPI 2025); use `mpiicx` instead.
- **Run with `srun`** (not `mpirun`): Intel MPI integrates natively with Slurm. `srun --ntasks=N ./vmc.out multiDir.def` works without `--mpi=pmi2`.
- **sbatch path note:** `$HOME` is NOT expanded in `#SBATCH` directives on Hokusai — always use absolute paths (`/home/wddawson/...`) in `--chdir`, `--output`, `--error`.
- **Repo on Hokusai:** `~/fugaku_next/mVMC-mini` (branch `gpu-port`).
- Sanity check passed 2026-07-02: energy converges monotonically, output matches reference trajectory (MC stochasticity means values differ but trend matches).

## Genoa MPI×OMP scaling (EPYC 9684X, 96 physical cores)

**Final script:** `~/fugaku_next/port_mvmc_gpu/scaling_genoa.sh` (v6). Results in `~/fugaku_next/port_mvmc_gpu/scaling_results5/`.

**Critical binding notes:**
- `NQPFull = NSPGaussLeg × NMPTrans = 12 × 4 = 48` for job_middle — the OMP loop over `qpidx` has only 48 iterations; OMP>48 wastes threads.
- MPICH's `-bind-to core` pins each rank to **1 core** (OMP threads serialize). Fix: use a `taskset` wrapper reading `$PMI_RANK` to assign non-overlapping CPU ranges. See `~/fugaku_next/port_mvmc_gpu/bind_wrapper.sh`.
- `NSplitSize=NP` puts all NP ranks in one collaborative group dividing the QP work per MC step. `NSplitSize=1` (default) makes each rank independent — correct for production throughput, wrong for wall-time scaling study.
- mpirun `--rankfile` is OpenMPI only; MPICH Hydra does not support it.
- srun without `--mpi=pmi2` creates isolated single-rank MPI jobs from each task.

**Amdahl bottleneck:** The serial Markov chain work (MC moves, PRNG, accept/reject) is ~8s regardless of NP — it dominates. MPI only helps the QP calculation (VMCMainCal, 16% of time). Max wall-time speedup from MPI ≈ 1.3×.

**Recommended config (wall time):** NP=12–24, OMP=4–8 — best total ~9.1s (vs 12.0s at NP=1). Plateau is flat from NP=8 to NP=48.

**Recommended config (production throughput):** `NSplitSize=1`, `NP=2`, `OMP=48` — independent chains scale perfectly; OMP=48 saturates NQPFull=48.

| NP | OMP | VMCMake | VMCMain | Total(s) |
|----|-----|---------|---------|----------|
| 1  | 48  | 9.96    | 1.97    | 11.99    |
| 8  | 12  | 8.55    | 0.84    | 9.58     |
| 12 | 8   | 8.21    | 0.75    | **9.19** |
| 24 | 4   | 8.12    | 0.75    | **9.14** |
| 48 | 2   | 8.19    | 0.76    | 9.29     |
| 96 | 1   | 9.55    | 0.82    | 10.97    |

**GPU porting note:** CalculateMAll = 0.92s (7.7% of total at NP=1, OMP=48). GPU won't shift the 8s serial MC work. Larger system sizes needed to see meaningful GPU speedup.
