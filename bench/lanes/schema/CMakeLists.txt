# Blaze, built with its own flags in this directory's scope: only the compiler, the evaluator and the output are built.
FetchContent_Declare(blaze
  URL https://codeload.github.com/sourcemeta/blaze/tar.gz/db923e9b95ec7bcb7b339669fed45b9f1a7f9569
  URL_HASH SHA256=168e2156c9ad188237d4822e3da136aef76627e1bef78c4cdce0ba8ceb0c18e2
  SOURCE_SUBDIR none)
FetchContent_MakeAvailable(blaze)

set(BLAZE_COMPILER ON CACHE BOOL "")
set(BLAZE_EVALUATOR ON CACHE BOOL "")
set(BLAZE_OUTPUT ON CACHE BOOL "")
foreach(option TEST CONFIGURATION ALTERSCHEMA CODEGEN CANONICALIZER CONVERT EDITOR BINPACK DOCUMENTATION INSTALL)
  set(BLAZE_${option} OFF CACHE BOOL "")
endforeach()
set(CMAKE_CXX_STANDARD 20)
include(${blaze_SOURCE_DIR}/vendor/core/cmake/Sourcemeta.cmake)
if(CMAKE_SYSTEM_PROCESSOR MATCHES "arm|aarch64")
  set(NATIVE -mcpu=native)
else()
  set(NATIVE -march=native)
endif()
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} ${NATIVE}")
add_subdirectory(${blaze_SOURCE_DIR} blaze)
add_executable(schema-blaze blaze.cc)
target_include_directories(schema-blaze PRIVATE ${PROJECT_SOURCE_DIR}/timing)
target_link_libraries(schema-blaze PRIVATE sourcemeta::core::json sourcemeta::core::jsonschema
  sourcemeta::blaze::compiler sourcemeta::blaze::evaluator sourcemeta::blaze::output)
