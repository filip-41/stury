# compare/

Checks that compare `next/` with the old tree this branch replaces: the root's `core`, `json` and `csv`, imported
as `stury:json` and `stury:csv` through `-collection:stury=..`. Nothing here belongs to `next/`, which is a
self-contained drop-in for the repo root. This directory is deleted when the old tree goes.

| Path | Holds |
|---|---|
| `json_oracle/` | `json.validate` and the document against the old tree's `json`, and one edit per round through its `set`, `insert` and `remove` by path |
| `dsv_oracle/` | the dsv walk and document against the old tree's `csv`, on the specs and on run-time dialects |
| `golden/` | writes `next/json/test/golden`: the old tree's answer for every suite file per spec |
| `found_probe/` | the old tree's document lanes on the work `next/bench/doc` does: one build, a read of every value with next's tags, decoded lengths and number bits, and a key lookup with one column resolve per sample, with `run.py` timing them beside `next/bench/doc` |

Equal work means both probes build once per call, read every value once in document order, and look one key up in
every object or record; `run.py` refuses to time a file whose lanes' `check` values or counts differ. Three
differences remain by construction: the old build decodes escapes and cells at build time where next decodes them at
read time, the two builds reserve nodes by different rules, and a dsv record is an `Object` and an empty cell `Null`
in the old tree but `Array` and an empty `Plain` cell in next, which the checksum maps to one tag.

The edit rounds against their own models live in the private `stury-tests` repo, under `next/model/`.

## Running

From `compare/`, with the same `ODIN` argument `next/Makefile` takes:

```
make ODIN=/path/to/odin lint
make ODIN=/path/to/odin test-oracle ROUNDS=50000 SEED=7
make ODIN=/path/to/odin golden
make ODIN=/path/to/odin bench-doc ROUNDS=5
```

`test-oracle` and `golden` copy `next/` to a temporary tree and rename its `core` and `json` packages, because a
program cannot hold two packages of one name. `golden` writes the file the test in `next/json/test` reads, and it
writes the same bytes each run. `lint` checks the oracle packages through the same copy, and
`found_probe` against the old tree alone. `bench-doc` builds the old tree's probe and `next/bench/doc`, compares each
lane's `check` and counts between the arms, then prints each lane's best and median GB/s for both arms with next's
delta in percent. It holds `next/build/bench/timing.lock` and kills a child that passes 1 GB of RSS.
