ODIN ?= odin

BUILD := build

VET := -vet-unused-variables -vet-shadowing -vet-using-stmt -vet-cast -vet-semicolon -vet-tabs -strict-style
LINT_FLAGS := $(VET) -terse-errors -max-error-count:500

.PHONY: test-oracle lint bench-doc golden

# The document lanes' files, run by `bench-doc`.
BENCH_FILES ?= logs.json citm_catalog.json table.csv

# Copies next/ and the oracle packages to a temporary tree and renames next's `core` and `json` packages, since a
# program cannot hold two packages of one name. Sets the shell variable `d` to the tree.
define tree
d=$$(mktemp -d) && trap 'rm -rf $$d' EXIT && mkdir -p $$d/next $$d/compare && \
	cp -R ../next/core ../next/json ../next/dsv ../next/walktest $$d/next/ && \
	cp -R json_oracle dsv_oracle $$d/compare/ && \
	sed -i.orig 's/^package core$$/package next_core/' $$d/next/core/*.odin && \
	sed -i.orig 's/^package json$$/package next_json/' $$d/next/json/*.odin && \
	sed -i.orig 's/^package spell$$/package next_spell/' $$d/next/core/spell/*.odin && \
	sed -i.orig 's/^package build$$/package next_build/' $$d/next/core/build/*.odin
endef

# The walks against the current tree's `json` and `csv`, from a copy whose next packages are renamed. SEED and ROUNDS
# pass through.
SEED ?= 1
test-oracle: ROUNDS ?= 100000
test-oracle:
	@$(tree); for p in json_oracle dsv_oracle; do echo "== $$p oracle"; \
		$(ODIN) test $$d/compare/$$p -o:speed -collection:stury=$(abspath ..) -define:SEED=$(SEED) -define:ROUNDS=$(ROUNDS) -out:$$d/oracle || exit 1; \
	done

# Writes next/json/test/golden: the old tree's answer for every suite file per spec. Through the same renamed copy,
# since both trees name a package `json` and a package `core`.
golden:
	@$(tree); cp -R golden $$d/compare/ && \
		$(ODIN) run $$d/compare/golden -collection:stury=$(abspath ..) -- \
			$(abspath ../next/json/test/golden)

# The oracle packages against next/, through the same renamed copy.
lint:
	@$(tree); cp -R golden $$d/compare/ && for p in json_oracle dsv_oracle golden; do echo "== $$p"; \
		$(ODIN) check $$d/compare/$$p -no-entry-point $(LINT_FLAGS) -collection:stury=$(abspath ..) || exit 1; \
	done
	$(ODIN) check found_probe $(LINT_FLAGS) -collection:stury=$(abspath ..)

# The old tree's document probe, then next/bench's probe on the same files and lanes. ROUNDS and BENCH_FILES pass
# through.
bench-doc: ROUNDS ?= 5
bench-doc:
	@mkdir -p $(BUILD)
	$(ODIN) build found_probe -o:speed -collection:stury=$(abspath ..) -out:$(BUILD)/found
	$(ODIN) build ../next/bench/doc -o:speed -out:$(BUILD)/doc
	ROUNDS=$(ROUNDS) python3 found_probe/run.py $(BUILD)/found $(BUILD)/doc $(BENCH_FILES)
