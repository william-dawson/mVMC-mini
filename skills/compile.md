# Skill: Compile mVMC-mini

## Goal

Produce a working `src/vmc.out` executable.

---

## Prerequisites

| Dependency | Required | Notes |
|---|---|---|
| C compiler + MPI | yes | `mpicc` must be on PATH |
| Fortran compiler + MPI | yes | `mpif90` must be on PATH (links pfapack) |
| OpenMP runtime | yes | bundled with GCC; on macOS needs `libomp` from Homebrew |
| BLAS + LAPACK | yes | Accelerate on macOS; MKL or system ATLAS elsewhere |
| ScaLAPACK + BLACS | only without `-D_lapack` | skip by adding `-D_lapack` to OPTION |

---

## Build targets

All builds run from `src/`. The top-level `src/Makefile` dispatches:

```bash
cd src
make mac      # macOS: Apple Clang + Open MPI + Accelerate (dev/laptop)
make intel    # Intel MPI + MKL (RIKEN, most HPC clusters)
make kashiwa  # Kashiwa cluster
make kei      # K computer / FX10
make pgi      # PGI compiler
make clean    # remove all build artifacts
```

---

## Key compile-time flags (set via `OPTION` in the Makefile)

| Flag | Effect |
|---|---|
| `-D_mpi_use` | Enable MPI. Omit for a pure serial build (stubs in `vmcmain.h` cover all MPI calls). |
| `-D_lapack` | Use serial LAPACK solver (`stcopt_dposv.c`, calls `dposv_`). Without it, the parallel ScaLAPACK solver (`stcopt_pdposv.c`) is compiled in, which requires BLACS. Prefer `-D_lapack` for single-node development. |
| `-D_lapack_small_nounderscore` | Use `dposv` / `dgetrf` etc. without trailing underscore (rare LAPACK installs). Default is trailing underscore, which is correct for MKL, Accelerate, and most ATLAS builds. |
| `-D_SYSTEM_A` | Use uppercase names (`DPOSV`, `DGETRF`) — for Fujitsu systems. |

---

## Build structure

The entire C source is a **single translation unit**: `vmcmain.c` `#include`s every other `.c` file via `vmcmain.h`. Only one `.o` is produced from C. Three components are linked together:

```
vmcmain.o          ← all C source (compiled once)
pfapack/libpfapack.a  ← Pfaffian library (Fortran, built by sub-make)
sfmt/SFMT.o        ← SIMD Mersenne Twister RNG (C, built by sub-make)
```

Each platform Makefile drives the sub-libraries with their own sub-Makefile (e.g. `pfapack/Makefile_mac`, `sfmt/Makefile_mac`).

---

## Adding a new platform

1. Copy `src/Makefile_skeleton` → `src/Makefile_<platform>`.
2. Set `CC`, `FC`, `CFLAGS`, `FFLAGS`, `OPTION`, and `LIB`.
3. Copy `src/pfapack/Makefile_gnu` → `src/pfapack/Makefile_<platform>` and set `FORT`/`FFLAGS`.
4. Copy `src/sfmt/Makefile_mac` → `src/sfmt/Makefile_<platform>` and set `CC`/`CFLAGS`.
5. Point pfapack/sfmt sub-make targets in your new Makefile at those files.
6. Add a target in `src/Makefile`.

---

## macOS specifics (`Makefile_mac`)

- `mpicc` wraps Apple Clang. OpenMP requires `-Xpreprocessor -fopenmp -I$(LIBOMP)/include` at compile time and `-L$(LIBOMP)/lib -lomp` at link time, where `LIBOMP = /usr/local/opt/libomp` (install with `brew install libomp`).
- Final link is done with `mpicc` (not `mpif90`) to avoid mixing Apple libomp and GNU libgomp runtimes. Add `-lgfortran` explicitly for the pfapack Fortran runtime; the library lives at `/usr/local/Cellar/gcc/<version>/lib/gcc/current/libgfortran.dylib` — update `GFORTRAN_LIB` in `Makefile_mac` if you upgrade GCC.
- BLAS/LAPACK: `-framework Accelerate`. No separate install needed.
- Use `-D_lapack` (no ScaLAPACK required).

---

## Verifying the build

```bash
ls -lh src/vmc.out        # should exist, ~100–200 KB
file src/vmc.out           # should be a valid Mach-O or ELF executable
```

The binary is ready when `vmc.out` exists and `file` reports a valid executable for your platform. Proceed to the **test** skill to verify correctness.

---

## Common failures

| Symptom | Likely cause | Fix |
|---|---|---|
| `mpicc: command not found` | MPI not loaded | `module load openmpi` or check PATH |
| `ld: library 'gfortran' not found` (macOS) | GCC library path not set | Update `GFORTRAN_LIB` in `Makefile_mac` to match your GCC version |
| `Undefined symbols: _PDPOSV` or similar | ScaLAPACK missing but `-D_lapack` not set | Add `-D_lapack` to `OPTION` in the Makefile |
| `clang: error: unsupported option '-openmp'` | Intel OpenMP flag used with Clang | Use `-Xpreprocessor -fopenmp` instead |
| `ld: warning: ignoring duplicate libraries: '-lmpi'` | MPI linked twice (harmless) | Safe to ignore |
