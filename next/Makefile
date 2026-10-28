ODIN ?= $(or $(wildcard $(abspath ../../Odin-master/bin/odin)),odin)

# The rebuilt layers, beside the tree they replace until each one moves to the root.
LIB_PKGS  := core/kernel
TEST_PKGS := core/kernel/test
TEST_OPT  := -o:minimal
BUILD     := build

VET := -vet-unused-variables -vet-shadowing -vet-using-stmt -vet-cast -vet-semicolon -vet-tabs -strict-style
LINT_FLAGS := $(VET) -warnings-as-errors -terse-errors -max-error-count:500

.PHONY: test test-x86 test-asan lint bench

# `$(call odin_each,VERB,PACKAGES,FLAGS,LABEL)` runs `odin VERB` over each package and stops at the first failure.
define odin_each
@d=$$(mktemp -d) && trap 'rm -rf $$d' EXIT && for p in $(2); do \
	echo "== $$p$(4)"; $(ODIN) $(1) $$p $(3) $(if $(filter test,$(1)),-out:$$d/test) || exit 1; \
done
endef

# Again at -o:speed, where the optimizer reasons about loads that the walk makes past an input's end.
test:
	$(call odin_each,test,$(TEST_PKGS),$(TEST_OPT),)
	$(call odin_each,test,$(TEST_PKGS),-o:speed, (-o:speed))

# The x86-64 tiers v2 and v3 in a build for Odin's default CPU, as a caller's build is, at -o:none, where no kernel
# is inlined into the tier's procedures, and at -o:speed. On Apple silicon they run under Rosetta. v4 runs only on a
# machine with AVX-512 (TIER=2), and `lint` compiles it.
test-x86:
	$(call odin_each,test,$(TEST_PKGS),-o:none -target:darwin_amd64 -define:TIER=0, (v2 -o:none))
	$(call odin_each,test,$(TEST_PKGS),-o:speed -target:darwin_amd64 -define:TIER=0, (v2))
	$(call odin_each,test,$(TEST_PKGS),-o:none -target:darwin_amd64 -define:TIER=1, (v3 -o:none))
	$(call odin_each,test,$(TEST_PKGS),-o:speed -target:darwin_amd64 -define:TIER=1, (v3))

test-asan:
	$(call odin_each,test,$(TEST_PKGS),-o:speed -sanitize:address -debug, (address))

# Host, then the other architectures' sources: x86-64 and a target with neither NEON nor x86 vectors.
lint:
	$(call odin_each,check,$(LIB_PKGS) $(TEST_PKGS),-no-entry-point $(LINT_FLAGS),)
	$(ODIN) check bench $(LINT_FLAGS)
	$(call odin_each,check,$(LIB_PKGS) $(TEST_PKGS),-no-entry-point $(LINT_FLAGS) -target:linux_amd64, (linux_amd64))
	@d=$$(mktemp -d) && trap 'rm -rf $$d' EXIT && for o in none speed; do \
		echo "== $(TEST_PKGS) (linux_amd64 v4 -o:$$o)"; \
		$(ODIN) test $(TEST_PKGS) -build-mode:obj -target:linux_amd64 -define:TIER=2 -o:$$o $(LINT_FLAGS) -out:$$d/t.o || exit 1; \
	done
	$(call odin_each,check,$(LIB_PKGS),-no-entry-point $(LINT_FLAGS) -target:linux_riscv64, (linux_riscv64))

# Kernel timings at release optimization, of the tier at place TIER of `Tier`. ROUNDS, CASES and COUNT pass through
# to run.py.
TIER ?= 0
bench:
	@mkdir -p $(BUILD)
	$(ODIN) build bench -o:speed -define:TIER=$(TIER) -out:$(BUILD)/bench
	ROUNDS=$(ROUNDS) python3 -I bench/run.py $(BUILD)/bench
