# Skill: Compile

Build `src/vmc.out` by running the appropriate platform target from the repo root:

```bash
make mac       # macOS: Apple Clang + Open MPI + Accelerate
make intel     # Intel MPI + MKL
make kei       # K computer / FX10
make kashiwa   # Kashiwa cluster
make pgi       # PGI compiler
make clean     # remove all build artifacts
```

The build compiles the entire C source as a single translation unit (`vmcmain.c` includes everything), links the pfapack Fortran library and the SFMT RNG, and produces `src/vmc.out`.

## Adding a new platform

Copy `src/Makefile_skeleton` → `src/Makefile_<platform>`. Set:
- `CC` / `FC` — C and Fortran MPI wrappers
- `CFLAGS` / `FFLAGS` — optimization and OpenMP flags (`-fopenmp` or `-Xpreprocessor -fopenmp` for Apple Clang)
- `OPTION` — always include `-D_mpi_use`; add `-D_lapack` to use the serial LAPACK SR solver instead of ScaLAPACK
- `LIB` — BLAS + LAPACK (e.g. `-framework Accelerate` on macOS, MKL on Intel)

Add a sub-Makefile for pfapack (`src/pfapack/Makefile_<platform>`) setting `FORT` and `FFLAGS`, and for sfmt (`src/sfmt/Makefile_<platform>`) setting `CC` and `CFLAGS`. Then add the target to the top-level `Makefile`.

## Key flags

| Flag | Effect |
|---|---|
| `-D_mpi_use` | Enable MPI (required for multi-rank runs) |
| `-D_lapack` | Serial LAPACK SR solver — no ScaLAPACK/BLACS needed; use for single-node development |
| `-fopenmp` | OpenMP threading — required; use `-Xpreprocessor -fopenmp` with Apple Clang |
