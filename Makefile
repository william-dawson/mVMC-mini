VMC    := src/vmc.out
TINY   := job_tiny
MIDDLE := job_middle
REF    := result/Lx4Ly4_J1.0

# Physical core count — used as default OMP thread count
NCORES := $(shell sysctl -n hw.physicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)

# MPI rank count for bench target — override with: make bench NRANKS=128
NRANKS ?= 4

.PHONY : mac intel kei kashiwa pgi clean test perf bench

# ---- Build targets (delegate to src/) ----

mac :
	$(MAKE) -C src -f Makefile_mac

intel :
	$(MAKE) -C src -f Makefile_intel

kei fx :
	$(MAKE) -C src -f Makefile_kei

kashiwa :
	$(MAKE) -C src -f Makefile_kashiwa

pgi :
	$(MAKE) -C src -f Makefile_pgi

clean :
	$(MAKE) -C src clean

# ---- Correctness test ----
# Runs job_tiny (1 thread) and checks all 20 energy steps are within 5% of reference.

test :
	@test -x $(VMC) || { echo "ERROR: $(VMC) not found — run a build target first (e.g. make mac)"; exit 1; }
	@echo "=== Running job_tiny ==="
	@cd $(TINY) && OMP_NUM_THREADS=1 ../$(VMC) multiDir.def 2>&1 | grep -v fileInitPara; \
	paste Lx4Ly4_J1.0/zvo_out_000.dat ../$(REF)/zvo_out_000.dat | \
	awk 'BEGIN{fail=0} \
	  { d=$$1-$$4; if(d<0)d=-d; ref=($$4<0)?-$$4:$$4; pct=100*d/ref; \
	    if(pct>5){printf "FAIL step %d: got %g ref %g (%.1f%%)\n",NR,$$1,$$4,pct; fail=1} } \
	  END{if(!fail)printf "PASS: all %d steps within 5%% of reference\n",NR; exit fail}'

# ---- Thread scaling ----
# Sweeps OMP_NUM_THREADS over powers of 2 up to NCORES, then prints key ratios.

perf :
	@test -x $(VMC) || { echo "ERROR: $(VMC) not found — run a build target first (e.g. make mac)"; exit 1; }
	@echo "=== Thread scaling on job_tiny ($(NCORES) physical cores) ==="
	@echo "Threads  Wall(s)  Speedup  Efficiency"
	@echo "-------  -------  -------  ----------"
	@cd $(TINY) && \
	base=""; last=-1; \
	for t in 1 2 4 8 16 32 64 $(NCORES); do \
	  [ $$t -gt $(NCORES) ] && continue; \
	  [ $$t -eq $$last ] && continue; \
	  last=$$t; \
	  OMP_NUM_THREADS=$$t ../$(VMC) multiDir.def 2>/dev/null; \
	  wall=$$(awk '/^All / {print $$NF}' Lx4Ly4_J1.0/zvo_HitachiTimer.dat); \
	  [ -z "$$base" ] && base=$$wall; \
	  awk -v t=$$t -v w=$$wall -v b=$$base \
	    'BEGIN{sp=b/w; printf "%-7d  %-8.3f  %-7.2fx  %s\n", t, w, sp, sprintf("%.0f%%",100*sp/t)}'; \
	done
	@echo ""
	@echo "=== Key ratios (last run) ==="
	@awk ' \
	  /^All /           { total=$$NF } \
	  /VMCMakeSample /  { samp=$$NF } \
	  /exchange update/ { exch=$$NF } \
	  /UpdateMAllTwo /  { umall=$$NF } \
	  /VMCMainCal /     { cal=$$NF } \
	  /CalculateMAll /  { pfcal=$$NF } \
	  /WeightAverage /  { wavg=$$NF } \
	  END { \
	    printf "VMCMakeSample  / All:           %.1f%%\n", 100*samp/total; \
	    printf "exchange update/ VMCMakeSample: %.1f%%\n", 100*exch/samp; \
	    printf "UpdateMAllTwo  / All:           %.1f%%\n", 100*umall/total; \
	    printf "VMCMainCal     / All:           %.1f%%\n", 100*cal/total; \
	    printf "CalculateMAll  / VMCMainCal:    %.1f%%\n", 100*pfcal/cal; \
	    printf "WeightAverage  / All:           %.1f%%\n", 100*wavg/total; \
	  }' \
	$(TINY)/Lx4Ly4_J1.0/zvo_HitachiTimer.dat

# ---- Full benchmark ----
# Runs job_middle with NCORES threads and NRANKS MPI ranks.
# Override ranks: make bench NRANKS=128

bench :
	@test -x $(VMC) || { echo "ERROR: $(VMC) not found — run a build target first (e.g. make mac)"; exit 1; }
	@echo "=== Running job_middle ($(NRANKS) ranks × $(NCORES) threads) ==="
	@cd $(MIDDLE) && OMP_NUM_THREADS=$(NCORES) mpirun -np $(NRANKS) ../$(VMC) multiDir.def 2>/dev/null
	@echo ""
	@echo "=== Timer ==="
	@cat $(MIDDLE)/Lx10Ly10_J1.0/zvo_HitachiTimer.dat
	@echo ""
	@echo "=== Key ratios ==="
	@awk ' \
	  /^All /           { total=$$NF } \
	  /VMCMakeSample /  { samp=$$NF } \
	  /exchange update/ { exch=$$NF } \
	  /UpdateMAllTwo /  { umall=$$NF } \
	  /VMCMainCal /     { cal=$$NF } \
	  /CalculateMAll /  { pfcal=$$NF } \
	  /WeightAverage /  { wavg=$$NF } \
	  END { \
	    printf "VMCMakeSample  / All:           %.1f%%\n", 100*samp/total; \
	    printf "exchange update/ VMCMakeSample: %.1f%%\n", 100*exch/samp; \
	    printf "UpdateMAllTwo  / All:           %.1f%%\n", 100*umall/total; \
	    printf "VMCMainCal     / All:           %.1f%%\n", 100*cal/total; \
	    printf "CalculateMAll  / VMCMainCal:    %.1f%%\n", 100*pfcal/cal; \
	    printf "WeightAverage  / All:           %.1f%%\n", 100*wavg/total; \
	  }' \
	$(MIDDLE)/Lx10Ly10_J1.0/zvo_HitachiTimer.dat
