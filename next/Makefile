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

test:
	$(call odin_each,test,$(TEST_PKGS),$(TEST_OPT),)

# The x86-64 tiers a baseline build can be: v2 takes the SSE paths, v3 the AVX2 ones. On Apple silicon they run under
# Rosetta; AVX-512 runs only on a machine that has it.
test-x86:
	$(call odin_each,test,$(TEST_PKGS),$(TEST_OPT) -target:darwin_amd64 -microarch:x86-64-v2, (x86-64-v2))
	$(call odin_each,test,$(TEST_PKGS),$(TEST_OPT) -target:darwin_amd64 -microarch:x86-64-v3, (x86-64-v3))

test-asan:
	$(call odin_each,test,$(TEST_PKGS),$(TEST_OPT) -sanitize:address -debug, (address))

# Host, then the other architectures' sources: x86-64 and a target with neither NEON nor x86 vectors.
lint:
	$(call odin_each,check,$(LIB_PKGS) $(TEST_PKGS),-no-entry-point $(LINT_FLAGS),)
	$(ODIN) check bench $(LINT_FLAGS)
	$(call odin_each,check,$(LIB_PKGS) $(TEST_PKGS),-no-entry-point $(LINT_FLAGS) -target:linux_amd64, (linux_amd64))
	$(call odin_each,check,$(LIB_PKGS),-no-entry-point $(LINT_FLAGS) -target:linux_riscv64, (linux_riscv64))

# Kernel timings at release optimization. ROUNDS, CASES and COUNT pass through to run.py.
bench:
	@mkdir -p $(BUILD)
	$(ODIN) build bench -o:speed -out:$(BUILD)/bench
	python3 -I bench/run.py $(BUILD)/bench $(ROUNDS)
