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

## Running

- **Tiny benchmark:** `cd job_tiny && mpirun -np 4 ../src/vmc.out multiDir.def`
- The message `Error: opt.init does not exist` is expected and harmless (documented in README).
- Output lands in `job_tiny/Lx4Ly4_J1.0/zvo_out_000.dat`; compare column 1 (energy) against `result/Lx4Ly4_J1.0/zvo_out_000.dat`. Values differ by run due to MC stochasticity but the converging trend must match.
- **Medium benchmark:** `job_middle/` — use this for timing baselines before and after GPU changes.
