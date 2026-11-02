ODIN ?= $(or $(wildcard $(abspath ../../Odin-master/bin/odin)),odin)

# The library packages, and the test packages that read them.
LIB_PKGS  := core/spell core core/kernel core/build json dsv
TEST_PKGS := core/kernel/test json/test dsv/test
# The packages the tests share, checked by `lint` and built through their imports.
SUPPORT_PKGS := walktest
# The test packages that read `-define:TIER`.
TIER_PKGS := core/kernel/test
TEST_OPT  := -o:minimal
BUILD     := build

# One target per compile, so `make -j` builds the tests in parallel and each compile writes its own binary.
TEST_MINIMAL  := $(foreach p,$(TEST_PKGS),$(BUILD)/test/minimal/$(p))
TEST_SPEED    := $(foreach p,$(TEST_PKGS),$(BUILD)/test/speed/$(p))
TEST_TARGETS  := $(TEST_MINIMAL) $(TEST_SPEED)
ASAN_TARGETS  := $(foreach p,$(TEST_PKGS),$(BUILD)/test/asan/$(p))

VET := -vet-unused-variables -vet-shadowing -vet-using-stmt -vet-cast -vet-semicolon -vet-tabs -vet-unused-imports -strict-style
LINT_FLAGS := $(VET) -warnings-as-errors -terse-errors -max-error-count:500

.PHONY: test test-x86 test-asan lint bench bench-doc fixtures size surface \
	$(TEST_TARGETS) $(ASAN_TARGETS)

# The document lanes' probe and peers, and the fixtures they read.
BENCH      := $(BUILD)/bench
BENCH_CC    ?= cc
BENCH_CXX   ?= c++
BENCH_CARGO ?= cargo
BENCH_FILES ?= logs.json citm_catalog.json table.csv

# `$(call odin_each,VERB,PACKAGES,FLAGS,LABEL)` runs `odin VERB` over each package and stops at the first failure.
define odin_each
@d=$$(mktemp -d) && trap 'rm -rf $$d' EXIT && for p in $(2); do \
	echo "== $$p$(4)"; $(ODIN) $(1) $$p $(3) $(if $(filter test,$(1)),-out:$$d/test) || exit 1; \
done
endef

# The tests at -o:minimal and at -o:speed, where the optimizer reasons about loads that the walk makes past an input's
# end. Each compile is its own target, so `make -j test` runs them at once.
test: $(TEST_TARGETS)

$(TEST_MINIMAL): $(BUILD)/test/minimal/%:
	@mkdir -p $(@D)
	@echo "== $* (-o:minimal)"
	@$(ODIN) test $* $(TEST_OPT) -out:$@ || { echo "== $* (-o:minimal) failed"; exit 1; }

$(TEST_SPEED): $(BUILD)/test/speed/%:
	@mkdir -p $(@D)
	@echo "== $* (-o:speed)"
	@$(ODIN) test $* -o:speed -out:$@ || { echo "== $* (-o:speed) failed"; exit 1; }

# The x86-64 tiers v2 and v3 in a build for Odin's default CPU, as a caller's build is, at -o:none, where no kernel
# is inlined into the tier's procedures, and at -o:speed. TIER picks the kernels' tier and WALK_TIER the walks'.
# On Apple silicon they run under Rosetta. v4 runs only on a machine with AVX-512 (TIER=2), and `lint` compiles it.
test-x86:
	$(call x86_tier,none,0, (v2 -o:none))
	$(call x86_tier,speed,0, (v2))
	$(call x86_tier,none,1, (v3 -o:none))
	$(call x86_tier,speed,1, (v3))

# `$(call x86_tier,OPT,TIER,LABEL)` runs the tests at one tier, `TIER` defined only where it is read.
define x86_tier
$(call odin_each,test,$(TIER_PKGS),-o:$(1) -target:darwin_amd64 -define:TIER=$(2) -define:WALK_TIER=$(2),$(3))
$(call odin_each,test,$(filter-out $(TIER_PKGS),$(TEST_PKGS)),-o:$(1) -target:darwin_amd64 -define:WALK_TIER=$(2),$(3))
endef

test-asan: $(ASAN_TARGETS)

$(ASAN_TARGETS): $(BUILD)/test/asan/%:
	@mkdir -p $(@D)
	@echo "== $* (address)"
	@$(ODIN) test $* -o:speed -sanitize:address -debug -out:$@ || { echo "== $* (address) failed"; exit 1; }

# Host, then the other architectures' sources: x86-64 and a target with neither NEON nor x86 vectors.
lint:
	python3 tools/checks.py imports
	python3 tools/checks.py words
	$(call odin_each,check,$(LIB_PKGS) $(TEST_PKGS) $(SUPPORT_PKGS),-no-entry-point $(LINT_FLAGS),)
	$(ODIN) check bench $(LINT_FLAGS)
	$(ODIN) check bench/doc $(LINT_FLAGS)
	$(ODIN) check bench/editbench $(LINT_FLAGS)
	$(call odin_each,check,$(LIB_PKGS) $(TEST_PKGS) $(SUPPORT_PKGS),-no-entry-point $(LINT_FLAGS) -target:linux_amd64, (linux_amd64))
	@d=$$(mktemp -d) && trap 'rm -rf $$d' EXIT && for p in $(TIER_PKGS); do for o in none speed; do \
		echo "== $$p (linux_amd64 v4 -o:$$o)"; \
		$(ODIN) test $$p -build-mode:obj -target:linux_amd64 -define:TIER=2 -o:$$o $(LINT_FLAGS) -out:$$d/t.o || exit 1; \
	done; done
	$(call odin_each,check,$(LIB_PKGS),-no-entry-point $(LINT_FLAGS) -target:linux_riscv64, (linux_riscv64))

# The lean lines of each library package, with the sum and the budget. Past the budget the command fails.
size:
	python3 tools/checks.py size

# The public declarations of each library package, sorted, so a review can diff the surface.
surface:
	python3 tools/checks.py surface

# Kernel timings at release optimization, of the tier at place TIER of `Tier`. ROUNDS, CASES and COUNT pass through
# to run.py.
TIER ?= 0
bench: ROUNDS ?= 5
bench:
	@mkdir -p $(BUILD)
	$(ODIN) build bench -o:speed -define:TIER=$(TIER) -out:$(BUILD)/kernelbench
	ROUNDS=$(ROUNDS) python3 -I bench/run.py $(BUILD)/kernelbench

# The document lanes' fixtures: the pinned corpus and peer sources, then the generated JSON and dsv files.
fixtures:
	python3 bench/fetch.py
	python3 bench/gen.py --check

# The document lanes' probe at -o:speed, the peers whose toolchain and sources are present, then doc.py. ROUNDS and
# BENCH_FILES pass through.
bench-doc:
	@mkdir -p $(BENCH)
	$(ODIN) build bench/doc -o:speed -out:$(BENCH)/doc
	@if command -v $(BENCH_CC) >/dev/null && [ -f $(BENCH)/deps/yyjson/yyjson.c ]; then \
		$(BENCH_CC) -O3 -DNDEBUG -o $(BENCH)/yy_bench bench/peers/yy_bench.c \
			$(BENCH)/deps/yyjson/yyjson.c -I$(BENCH)/deps/yyjson && echo "yy: built"; \
	else echo "yy: left out (C compiler or yyjson source missing; run make fixtures)"; fi
	@if command -v $(BENCH_CXX) >/dev/null && [ -f $(BENCH)/deps/simdjson/simdjson.cpp ]; then \
		$(BENCH_CXX) -O3 -DNDEBUG -std=c++17 -o $(BENCH)/cpp_bench bench/peers/cpp_bench.cpp \
			$(BENCH)/deps/simdjson/simdjson.cpp -I$(BENCH)/deps/simdjson && echo "simd: built"; \
	else echo "simd: left out (C++ compiler or simdjson source missing; run make fixtures)"; fi
	@if command -v $(BENCH_CARGO) >/dev/null; then \
		CARGO_TARGET_DIR=$(abspath $(BENCH)/rust) $(BENCH_CARGO) build --release --locked \
			--manifest-path bench/peers/rust/Cargo.toml && echo "sonic: built"; \
	else echo "sonic: left out (cargo missing)"; fi
	ROUNDS=$(ROUNDS) python3 bench/doc.py $(BENCH_FILES)
