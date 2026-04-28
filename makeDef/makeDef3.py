#!/usr/bin/env python3
"""
Generate mVMC-mini input files for a 2D square Kondo lattice.

Usage: python3 makeDef3.py <Lx> <Ly> [J]

Outputs a job directory Lx{Lx}Ly{Ly}_J{J}/ in the current directory.
"""
import sys, os, random, time
from math import *

T = {(1,0): 1.0, (-1,0): 1.0, (0,1): 1.0, (0,-1): 1.0}

if len(sys.argv) < 3:
    print("Usage: python3 makeDef3.py Lx Ly [J]")
    sys.exit(1)

Lx = int(sys.argv[1])
Ly = int(sys.argv[2])
J  = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0

Nsite     = 2 * Lx * Ly
Nlattice  = Lx * Ly
Nelectron = Nsite // 2   # half-filling

Sx, Sy = 2, 2
Nsub      = Sx * Sy
NQPTrans  = 4             # translations (Nsub) × no rotations for simplicity

NSplitSize  = 1           # one rank per GPU
NVMCSample  = 512
NSPGaussLeg = 16
NSROptItrStep = 20

time.sleep(0.1)
seed = int(time.time())

sep = '--------------------\n'

# ---- helpers ----

def indexToPosition(i):
    return (i % Lx, i // Lx)

def positionToIndex(r):
    x = (r[0] + Lx) % Lx
    y = (r[1] + Ly) % Ly
    return x + Lx * y

def neighborIndex(i, dr):
    bi, ri = i // Nlattice, i % Nlattice
    x, y   = indexToPosition(ri)
    return positionToIndex([x + dr[0], y + dr[1]]) + bi * Nlattice

def direction(i, j):
    rx, ry = indexToPosition(i)
    sx, sy = indexToPosition(j)
    dx = (sx - rx + Lx) % Lx
    dy = (sy - ry + Ly) % Ly
    return (dx, dy)

def locgrnIdx(i, j, s):
    return (Nsite * i + j) + s * Nsite * Nsite

def subIndex(i):
    r = indexToPosition(i)
    return (r[0] % Sx) + Sx * (r[1] % Sy)

# ---- output directory ----

outdir = 'Lx{0}Ly{1}_J{2}'.format(Lx, Ly, J)
if os.path.exists(outdir):
    print("error: '{0}' already exists".format(outdir))
    sys.exit(1)
os.makedirs(outdir)
os.chdir(outdir)

# ---- file list ----

pre = 'z'
files = [
    'xnamelist.def',
    pre+'modpara.def',
    pre+'locspn.def',
    pre+'transfer.def',
    pre+'coulomb.def',
    pre+'interaction.def',
    pre+'gutzwilleridx.def',
    pre+'jastrowidx.def',
    pre+'orbitalidx.def',
    pre+'qptransidx.def',
    pre+'cisajs.def',
    pre+'cisajscktalt.def',
]

# xnamelist.def
with open(files[0], 'w') as f:
    for x in files[1:]:
        f.write(x + '\n')

# zmodpara.def
with open(files[1], 'w') as f:
    f.write(
        sep + "Model_Parameters  0\n" +
        sep + "VMC_Cal_Parameters\n" +
        sep + "CDataFileHead  zvo\nCParaFileHead  zqp\n" +
        sep + "NVMCCalMode    0\nNLanczosMode   0\n" +
        sep + "NDataIdxStart  0\nNDataQtySmp    10\n" +
        sep +
        "Nsite          {0}\n".format(Nsite) +
        "Nelectron      {0}\n".format(Nelectron) +
        "NSPGaussLeg    {0}\n".format(NSPGaussLeg) +
        "NSPStot        0\n" +
        "NMPTrans       {0}\n".format(NQPTrans) +
        "NSROptItrStep  {0}\n".format(NSROptItrStep) +
        "NSROptItrSmp   5\n" +
        "NSROptFixSmp   1\n" +
        "DSROptRedCut   1e-10\n" +
        "DSROptStaDel   0.01\n" +
        "DSROptStepDt   0.01\n" +
        "NVMCWarmUp     10\n" +
        "NVMCIniterval  1\n" +
        "NVMCSample     {0}\n".format(NVMCSample) +
        "NExUpdatePath  1\n" +
        "RndSeed        {0}\n".format(seed) +
        "NSplitSize     {0}\n".format(NSplitSize)
    )

# zlocspn.def
with open(files[2], 'w') as f:
    f.write(sep + "NLocalSpin\t{0}\n".format(Nlattice) +
            sep + "i_0LocSpn_1IteElc\n" + sep)
    for i in range(Nsite):
        f.write("{0}\t{1}\n".format(i, 1 if i < Nlattice else 0))

# ztransfer.def — nearest-neighbour hopping (conduction electrons only)
paraList = sorted(
    [ri, neighborIndex(ri, dr), t]
    for ri in range(Nlattice)
    for dr, t in T.items()
)
with open(files[3], 'w') as f:
    f.write(sep + "NTransfer\t{0}\n".format(2 * len(paraList)) +
            sep + "i_j_s_tijs\n" + sep)
    for s in [0, 1]:
        for p in paraList:
            f.write("{0}\t{1}\t{2}\t{3}\n".format(p[0], p[1], s, p[2]))

# J couplings: conduction site i ↔ local moment i+Nlattice
jList = sorted([i, i + Nlattice, J] for i in range(Nlattice))

# zcoulomb.def
with open(files[4], 'w') as f:
    f.write(sep + "NCoulomb\t{0}\n".format(4 * len(jList)) +
            sep + "i_s_j_t_Visjt\n" + sep)
    for p in jList:
        v = 0.25 * p[2]
        f.write("{0}\t0\t{1}\t0\t{2}\n".format(p[0], p[1],  v))
        f.write("{0}\t0\t{1}\t1\t{2}\n".format(p[0], p[1], -v))
        f.write("{0}\t1\t{1}\t0\t{2}\n".format(p[0], p[1], -v))
        f.write("{0}\t1\t{1}\t1\t{2}\n".format(p[0], p[1],  v))

# zinteraction.def
with open(files[5], 'w') as f:
    f.write(sep + "NInteraction\t{0}\n".format(2 * len(jList)) +
            sep + "i_j_s_k_l_t_Jijsklt\n" + sep)
    for p in jList:
        v = -0.5 * p[2]
        f.write("{0}\t{1}\t0\t{1}\t{0}\t1\t{2}\n".format(p[0], p[1], v))
        f.write("{0}\t{1}\t1\t{1}\t{0}\t0\t{2}\n".format(p[0], p[1], v))

# zgutzwilleridx.def
NGutz = 2
with open(files[6], 'w') as f:
    f.write(sep + "NGutzwillerIdx\t{0}\n".format(NGutz) +
            sep + "i_GutzwillerIdx\n" + sep)
    for i in range(Nsite):
        f.write("{0}\t{1}\n".format(i, 0 if i < Nlattice else 1))
    for idx in range(NGutz):
        f.write("{0}\t1\n".format(idx))

# zjastrowidx.def
jastrow = {}
idx = -1
for i in range(Nlattice):
    dr = indexToPosition(i)
    dr_rev = (Lx - dr[0], Ly - dr[1])
    if dr_rev in jastrow:
        jastrow[dr] = jastrow[dr_rev]
    elif dr[0] == 0 and dr[1] > Ly // 2:
        jastrow[dr] = jastrow[(0, Ly - dr[1])]
    elif dr[1] == 0 and dr[0] > Lx // 2:
        jastrow[dr] = jastrow[(Lx - dr[0], 0)]
    else:
        idx += 1
        jastrow[dr] = idx
NJastrow = idx + 1

with open(files[7], 'w') as f:
    f.write(sep + "NJastrowIdx\t{0}\n".format(NJastrow) +
            sep + "i_j_JastrowIdx\n" + sep)
    for i in range(Nsite):
        for j in range(Nsite):
            if i == j:
                continue
            elif i < Nlattice and j < Nlattice:
                f.write("{0}\t{1}\t{2}\n".format(i, j, jastrow[direction(i, j)]))
            else:
                f.write("{0}\t{1}\t{2}\n".format(i, j, NJastrow - 1))
    for k in range(NJastrow):
        f.write("{0}\t1\n".format(k))

# zorbitalidx.def
NOrbital = 4 * Nsub * Nlattice
orbital = [[dj + isub * Nlattice for dj in range(Nlattice)] for isub in range(Nsub)]
with open(files[8], 'w') as f:
    f.write(sep + "NOrbitalIdx\t{0}\n".format(NOrbital) +
            sep + "i_j_OrbitalIdx\n" + sep)
    for i in range(Nsite):
        for j in range(Nsite):
            bi, ri = i // Nlattice, i % Nlattice
            bj, rj = j // Nlattice, j % Nlattice
            isub = subIndex(ri)
            dj   = positionToIndex(direction(ri, rj))
            oidx = orbital[isub][dj] + (2 * bi + bj) * Nsub * Nlattice
            f.write("{0}\t{1}\t{2}\n".format(i, j, oidx))
    for k in range(NOrbital):
        f.write("{0}\t1\n".format(k))

# zqptransidx.def
with open(files[9], 'w') as f:
    f.write(sep + "NQPTrans\t{0}\n".format(NQPTrans) +
            sep + "TrIdx_TrWeight_and_TrIdx_i_xi\n" + sep)
    for k in range(NQPTrans):
        f.write("{0}\t1.0\n".format(k))
    for k in range(NQPTrans):
        dr = (k % Sx, k // Sx)
        for i in range(Nsite):
            f.write("{0}\t{1}\t{2}\n".format(k, i, neighborIndex(i, dr)))

# zcisajs.def
with open(files[10], 'w') as f:
    f.write(sep + "NCisAjs\t{0}\n".format(Nsite * Nsite * 2) +
            sep + "idx_i_j_s\n" + sep)
    for s in [0, 1]:
        for i in range(Nsite):
            for j in range(Nsite):
                f.write("{0}\t{1}\t{2}\t{3}\n".format(locgrnIdx(i, j, s), i, j, s))

# zcisajscktalt.def
with open(files[11], 'w') as f:
    f.write(sep + "NCisAjsCktAltDC\t{0}\n".format(Nlattice) +
            sep + "i_j_s_k_l_t\n" + sep)
    for i in range(Nlattice):
        f.write("{0}\t{1}\t0\t{1}\t{1}\t1\n".format(i, i))

print("Generated {0} (Nsite={1}, Nelectron={2}, NQPTrans={3}, NVMCSample={4}, NSplitSize={5})".format(
    outdir, Nsite, Nelectron, NQPTrans, NVMCSample, NSplitSize))
