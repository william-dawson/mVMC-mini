# CLAUDE.md — mVMC-mini

## What this codebase is

mVMC-mini is a miniapp derived from the mVMC (multi-variable Variational Monte Carlo) quantum physics simulation code. It models strongly correlated electron systems (default: 2D square Kondo lattice, J/t=1.0, half-filling) and is used as a compact, portable benchmark for HPC platforms.

The physics: mVMC optimizes a variational wave function (singlet pairing + Gutzwiller/Jastrow correlation factors + quantum-number projection) using the Stochastic Reconfiguration (SR) method, with Monte Carlo sampling over real-space electron configurations. The inner product involves computing the Pfaffian of a skew-symmetric matrix (via the `pfapack` library).

Reference paper: Tahara & Imada, J. Phys. Soc. Jpn. 77, 114701 (2008).

---

## Build system

All source lives in `src/`. Build from the **repo root** using the top-level `Makefile`:

```bash
make mac       # macOS: Apple Clang + Open MPI + Accelerate
make intel     # Intel MPI + MKL
make kei       # K computer / FX10 (Fujitsu)
make kashiwa   # Kashiwa cluster
make pgi       # PGI compiler
make clean
```

Each `src/Makefile_<platform>` sets `CC`, `FC`, `CFLAGS`, and `LIB`. The skeleton is `src/Makefile_skeleton`. Output binary is `src/vmc.out`.

Key build flags (set via `OPTION` in the platform Makefile):
- `-D_mpi_use` — enable MPI; omit for a serial build (stubs in `vmcmain.h`)
- `-D_lapack` — use serial LAPACK SR solver (`stcopt_dposv.c`) instead of ScaLAPACK; recommended for single-node development

Dependencies: MPI, OpenMP, BLAS/LAPACK. ScaLAPACK + BLACS only needed without `-D_lapack`.

The two bundled third-party libraries each have their own sub-Makefiles:
- `src/pfapack/` — Pfaffian computation (Fortran)
- `src/sfmt/` — SIMD-oriented Mersenne Twister RNG

---

## Running and testing

The top-level `Makefile` provides workflow targets:

```bash
make test                          # run job_tiny, verify against reference output
make perf [NRANKS=N] [NTHREADS=N]  # run job_tiny, print timer + hotspot ratios
make bench [NRANKS=N] [NTHREADS=N] # run job_middle, print timer + hotspot ratios
```

`NRANKS` and `NTHREADS` default to 1. `make test` always runs with 1 rank and 1 thread for deterministic reference comparison.

To run the binary directly:
```bash
src/vmc.out <multiDir.def>
```

`multiDir.def` lists one or more job directories. Each job directory has:
- `xnamelist.def` — list of input definition files
- `zmodpara.def` — simulation parameters (NVMCCalMode, Nsite, NVMCSample, NSROptItrStep, NSplitSize, etc.)
- `zlocspn.def`, `zinteraction.def`, `zcisajs.def`, `zcisajscktalt.def` — Hamiltonian/observable definitions
- `zgutzwilleridx.def`, `zqptransidx.def` — variational parameter index maps

Two benchmark cases are included:
- `job_tiny/` — 32-site system (4×4 Kondo lattice, Ne=16), runs in a few seconds single-rank
- `job_middle/` — 200-site system (10×10 Kondo lattice, Ne=100), reference config: 128 ranks × 8 threads

Reference output for correctness checking lives in `result/`.

Output files per job: `zvo_out_*.dat` (energy per SR step), `zvo_var_*.dat` (variational parameters), `zvo_HitachiTimer.dat` (hierarchical timer).

**NVMCCalMode**: `0` = parameter optimization (SR loop), `1` = expectation value calculation with fixed parameters.

---

## Code architecture

All global state is declared in `src/global.h` (included once via `vmcmain.h`). This is a single-translation-unit design: `vmcmain.c` `#include`s every other `.c` file (not compiled separately). Only one `.o` is produced from the C source.

Key source files and their roles:

| File | Role |
|---|---|
| `vmcmain.c` | Entry point, MPI setup, top-level SR loop (`VMCParaOpt`) and measurement loop (`VMCPhysCal`) |
| `vmccal.c` | Per-sample VMC kernel: compute weight, Hamiltonian, and SR matrices (OO, HO) or Green functions |
| `vmcmake.c` | Metropolis Monte Carlo sampling to generate electron configurations |
| `calham.c` | Hamiltonian calculation (hopping + Coulomb + interaction) |
| `calgrn.c` / `locgrn.c` | Green function calculation (one-body and two-body) |
| `slater.c` | Slater (pair orbital) matrix construction and update |
| `pfupdate.c` / `pfupdate_two.c` | Fast Pfaffian/inverse update after single/double electron moves |
| `projection.c` / `qp.c` | Quantum-number projection (spin, translation, point group) |
| `stcopt_dposv.c` / `stcopt_pdposv.c` | Stochastic Reconfiguration solver (serial LAPACK / parallel ScaLAPACK) |
| `average.c` / `avevar.c` | Weighted averaging and variance across MPI ranks |
| `readdef.c` | Parse all `*.def` input files |
| `setmemory.c` / `workspace.c` | Memory allocation |
| `parameter.c` | Variational parameter initialization and sync |
| `initfile.c` | Output file management |
| `matrix.c` | Dense matrix utilities |
| `splitloop.c` | Distribute loop iterations across MPI ranks |
| `safempi.c` | MPI wrappers |
| `gauleg.c` / `legendrepoly.c` | Gauss-Legendre quadrature for spin projection |
| `time.c` | Hierarchical timer |
| `global.h` | All global variables (Nsite, Ne, variational parameters, electron config arrays, etc.) |

### MPI layout

MPI ranks are split into two communicator levels:
- `comm1` — `NSplitSize` ranks per group; each group independently runs Monte Carlo
- `comm2` — one rank from each group; used for ScaLAPACK in the SR solver

Monte Carlo is embarrassingly parallel across groups. SR optimization uses ScaLAPACK across all ranks via `comm0`.

### Key data structures (all in `global.h`)

- `EleIdx[sample][mi+si*Ne]` — electron index → site mapping
- `EleCfg[sample][ri+si*Nsite]` — site → electron index (inverse)
- `EleNum[sample][ri+si*Nsite]` — occupation number per spin-site
- `SlaterElm[QPidx][ri+si*Nsite][rj+sj*Nsite]` — Slater matrix elements for each quantum projection
- `InvM[QPidx][...][...]` — inverse of Slater submatrix (updated incrementally)
- `PfM[QPidx]` — Pfaffian values
- `SROptOO[SROptSize²]`, `SROptHO[SROptSize]` — SR matrices built during VMC

---

## Key parameters in `zmodpara.def`

| Parameter | Meaning |
|---|---|
| `NVMCCalMode` | 0: optimize, 1: measure |
| `Nsite` | Number of lattice sites |
| `Nelectron` | Number of up-spin electrons (Ne); total = 2*Ne |
| `NSPGaussLeg` | Gauss-Legendre points for spin projection |
| `NSROptItrStep` | Total SR optimization steps |
| `NVMCSample` | MC samples per MPI group per step |
| `NSplitSize` | MPI ranks per MC group |
| `RndSeed` | RNG seed (offset by group index at runtime) |

---

## Agent skills

The `skills/` directory contains task-specific guides for AI agents:

| Skill | Command | What it does |
|---|---|---|
| `skills/compile.md` | `make <platform>` | Build `src/vmc.out` for a target platform |
| `skills/test.md` | `make test` | Run correctness check against reference output |
| `skills/performance.md` | `make perf` / `make bench` | Run with timing and interpret the hotspot profile |

---

## Conventions

- All C source is compiled as a single translation unit through `vmcmain.c`.
- Complex numbers are represented as pairs of `double` (real wavefunction).
- Fortran BLAS/LAPACK routines are called directly with trailing underscores (`daxpy_`, `dger_`, etc.).
- Timer IDs: 0=total, 1=init, 2=main loop, 3=MC sampling, 4=main calc, 5=SR opt, 10-23=sub-timers, 40-43=inner loop.
- The `_mpi_use` preprocessor flag gates all MPI calls; without it the code runs serially.
