VMC    := src/vmc.out
TINY   := job_tiny
MIDDLE := job_middle
REF    := result/Lx4Ly4_J1.0

# Override these on the command line:
#   make perf  NRANKS=4 NTHREADS=8
#   make bench NRANKS=128 NTHREADS=8
NRANKS   ?= 1
NTHREADS ?= 1

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
# Runs job_tiny (1 rank, 1 thread) and checks all 20 energy steps are within 5% of reference.

test :
	@test -x $(VMC) || { echo "ERROR: $(VMC) not found — run a build target first (e.g. make mac)"; exit 1; }
	@echo "=== Running job_tiny ==="
	@cd $(TINY) && OMP_NUM_THREADS=1 mpirun -np 1 ../$(VMC) multiDir.def 2>&1 | grep -v fileInitPara; \
	paste Lx4Ly4_J1.0/zvo_out_000.dat ../$(REF)/zvo_out_000.dat | \
	awk 'BEGIN{fail=0} \
	  { d=$$1-$$4; if(d<0)d=-d; ref=($$4<0)?-$$4:$$4; pct=100*d/ref; \
	    if(pct>5){printf "FAIL step %d: got %g ref %g (%.1f%%)\n",NR,$$1,$$4,pct; fail=1} } \
	  END{if(!fail)printf "PASS: all %d steps within 5%% of reference\n",NR; exit fail}'

# ---- Performance run (job_tiny) ----
# Runs job_tiny with the given NRANKS and NTHREADS, then prints the timer and key ratios.
# Example: make perf NRANKS=4 NTHREADS=8

perf :
	@test -x $(VMC) || { echo "ERROR: $(VMC) not found — run a build target first (e.g. make mac)"; exit 1; }
	@echo "=== job_tiny: $(NRANKS) rank(s) x $(NTHREADS) thread(s) ==="
	@cd $(TINY) && OMP_NUM_THREADS=$(NTHREADS) mpirun -np $(NRANKS) ../$(VMC) multiDir.def 2>/dev/null
	@echo "=== Timer ==="
	@cat $(TINY)/Lx4Ly4_J1.0/zvo_HitachiTimer.dat
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
	$(TINY)/Lx4Ly4_J1.0/zvo_HitachiTimer.dat

# ---- Full benchmark (job_middle) ----
# Runs job_middle with the given NRANKS and NTHREADS, then prints the timer and key ratios.
# Example: make bench NRANKS=128 NTHREADS=8

bench :
	@test -x $(VMC) || { echo "ERROR: $(VMC) not found — run a build target first (e.g. make mac)"; exit 1; }
	@echo "=== job_middle: $(NRANKS) rank(s) x $(NTHREADS) thread(s) ==="
	@cd $(MIDDLE) && OMP_NUM_THREADS=$(NTHREADS) mpirun -np $(NRANKS) ../$(VMC) multiDir.def 2>/dev/null
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
