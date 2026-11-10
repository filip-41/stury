// The timing protocol and file read of the C++ peers (cpp_bench.cpp, blaze/main.cc).
#pragma once
#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

static const int WARMUP = 2;
static const int TIMED = 10;

// Returns the bytes of the file at `path`, or throws.
static std::string slurp(const char* path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error(std::string("cannot read ") + path);
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

// Returns the median nanoseconds of TIMED timed calls after WARMUP calls, or -1 when a call fails. `once`
// returns one call's nanoseconds, or -1.
template <class F>
static int64_t median_ns(F&& once) {
    std::vector<int64_t> times;
    for (int i = 0; i < WARMUP + TIMED; i++) {
        int64_t ns = once();
        if (ns < 0) return -1;
        if (i >= WARMUP) times.push_back(ns);
    }
    std::sort(times.begin(), times.end());
    // The mean of the two middle samples.
    return (times[(TIMED - 1) / 2] + times[TIMED / 2]) / 2;
}
