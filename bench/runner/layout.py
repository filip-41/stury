from pathlib import Path

BENCH = Path(__file__).resolve().parent.parent
ROOT = BENCH.parent
BUILD = ROOT / "build" / "bench"
FIXTURES = BENCH / "fixtures"
