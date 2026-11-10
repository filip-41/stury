// Blaze's jobs for bench/schema.py, in the timing protocol of the other peers: WARMUP untimed calls, then TIMED timed
// ones, the median as key=value tokens. Each job parses every instance of FILE (a JSONL text, else one document) and
// judges it, dropping it before the next.
//   blaze_bench verdict SCHEMA FILE   FastValidation, the bool form of validate
//   blaze_bench errors SCHEMA FILE    Exhaustive, every error collected by SimpleOutput
// `check` is the number of instances the schema accepts and `errors` the entries SimpleOutput listed. BENCH_PASSES=N
// makes N untimed passes and prints `check` alone, for the runner's instruction counts. BENCH_VERDICTS=PATH writes one
// 0 or 1 per instance, in order, to PATH.
#include <sourcemeta/core/json.h>
#include <sourcemeta/core/jsonschema.h>

#include <sourcemeta/blaze/compiler.h>
#include <sourcemeta/blaze/evaluator.h>
#include <sourcemeta/blaze/output.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <iostream>
#include <iterator>
#include <string>
#include <string_view>
#include <vector>

#include "../bench_common.h"

namespace {

// The instances of `text`: one per line of a JSONL text, else the whole text as one document.
std::vector<std::string_view> instance_texts(const std::string &text, bool lines) {
  std::vector<std::string_view> out;
  if (!lines) {
    out.emplace_back(text);
    return out;
  }
  std::size_t at = 0;
  while (at < text.size()) {
    std::size_t end = text.find('\n', at);
    if (end == std::string::npos) {
      end = text.size();
    }
    if (end > at) {
      out.emplace_back(text.data() + at, end - at);
    }
    at = end + 1;
  }
  return out;
}

sourcemeta::blaze::Template compile_schema(const std::string &schema_text, sourcemeta::blaze::Mode mode) {
  const auto schema = sourcemeta::core::parse_json(schema_text);
  return sourcemeta::blaze::compile(
      schema, sourcemeta::core::schema_walker,
      sourcemeta::core::schema_resolver,
      sourcemeta::blaze::default_schema_compiler,
      mode);
}

int run(int argc, char **argv) {
  if (argc != 4) {
    std::cerr << "usage: blaze_bench verdict|errors SCHEMA FILE\n";
    return 2;
  }
  const std::string mode{argv[1]};
  if (mode != "verdict" && mode != "errors") {
    std::cerr << "blaze_bench: no mode " << mode << "\n";
    return 2;
  }
  const std::string schema_text = slurp(argv[2]);
  const std::string path{argv[3]};
  const std::string text = slurp(argv[3]);
  const bool lines = path.size() > 6 && path.compare(path.size() - 6, 6, ".jsonl") == 0 ||
                     path.size() > 7 && path.compare(path.size() - 7, 7, ".ndjson") == 0;
  const auto pieces = instance_texts(text, lines);
  const bool verdict = mode == "verdict";
  const auto compiled = compile_schema(schema_text, verdict ? sourcemeta::blaze::Mode::FastValidation
                                                            : sourcemeta::blaze::Mode::Exhaustive);
  sourcemeta::blaze::Evaluator evaluator;
  std::size_t errors = 0;
  const auto pass = [&] {
    std::size_t valid = 0;
    errors = 0;
    for (const auto piece : pieces) {
      const auto instance = sourcemeta::core::parse_json(piece);
      if (verdict) {
        valid += evaluator.validate(compiled, instance) ? 1 : 0;
      } else {
        sourcemeta::blaze::SimpleOutput output{compiled, instance};
        valid += evaluator.validate(compiled, instance, std::ref(output)) ? 1 : 0;
        errors += static_cast<std::size_t>(std::distance(output.begin(), output.end()));
      }
    }
    return valid;
  };
  if (const char *path = std::getenv("BENCH_VERDICTS")) {
    std::string marks;
    for (const auto piece : pieces) {
      marks += evaluator.validate(compiled, sourcemeta::core::parse_json(piece)) ? '1' : '0';
    }
    std::ofstream{path} << marks;
  }
  if (const char *passes = std::getenv("BENCH_PASSES")) {
    std::size_t valid = 0;
    for (int i = 0, n = std::atoi(passes); i < n; i++) {
      valid = pass();
    }
    std::printf("check=%zu\n", valid);
    return 0;
  }
  std::size_t valid = 0;
  const auto ns = median_ns([&] {
    const auto start = std::chrono::steady_clock::now();
    valid = pass();
    return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - start).count();
  });
  std::printf("gb_per_s=%.4f ns=%lld check=%zu errors=%zu\n",
              static_cast<double>(text.size()) / static_cast<double>(ns), static_cast<long long>(ns), valid, errors);
  return 0;
}

} // namespace

int main(int argc, char **argv) {
  try {
    return run(argc, argv);
  } catch (const std::exception &e) {
    std::cerr << "blaze_bench: " << e.what() << "\n";
    return 1;
  }
}
