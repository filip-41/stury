# Every C and C++ driver of the lanes, the other libraries' sources pinned by URL_HASH, and Blaze. The drivers land in
# the directory of the build (build/bench) as <lane>-<library>.
cmake_minimum_required(VERSION 3.24)
project(bench LANGUAGES C CXX)

include(FetchContent)

set(CMAKE_BUILD_TYPE Release)
set(CMAKE_C_FLAGS_RELEASE "-O3 -DNDEBUG")
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG")
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(BUILD_SHARED_LIBS OFF)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${BENCH_OUT})
set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

FetchContent_Declare(yyjson
  URL https://github.com/ibireme/yyjson/archive/refs/tags/0.13.0.tar.gz
  URL_HASH SHA256=34e0f62a2bc11ab20d601e8ca1cc2b2079503aa45119a19133d89d19b94a0fae)
FetchContent_Declare(simdjson
  URL https://github.com/simdjson/simdjson/archive/refs/tags/v5.0.5.tar.gz
  URL_HASH SHA256=50bb17769e1054ff1bfcd5dbbfcf33544c77f6ebdb31a318436ea0e47f78f571)
FetchContent_MakeAvailable(yyjson simdjson)

function(driver name source)
  add_executable(${name} ${source})
  target_include_directories(${name} PRIVATE timing)
  target_link_libraries(${name} PRIVATE ${ARGN})
endfunction()

driver(doc-yyjson lanes/doc/yyjson.c yyjson)
driver(write-yyjson lanes/write/yyjson.c yyjson)
foreach(lane IN ITEMS doc paths records write)
  driver(${lane}-simdjson lanes/${lane}/simdjson.cpp simdjson Threads::Threads)
endforeach()

add_subdirectory(lanes/schema)
