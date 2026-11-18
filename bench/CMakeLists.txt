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

# XML: pugixml, libxml2 and expat, and the drivers of each lane that read XML.
FetchContent_Declare(pugixml
  URL https://github.com/zeux/pugixml/archive/refs/tags/v1.15.tar.gz
  URL_HASH SHA256=b39647064d9e28297a34278bfb897092bf33b7c487906ddfc094c9e8868bddcb)
FetchContent_MakeAvailable(pugixml)
driver(doc-pugixml lanes/doc/pugixml.cpp pugixml::pugixml)

FetchContent_Declare(libxml2
  URL https://github.com/GNOME/libxml2/archive/refs/tags/v2.14.6.tar.gz
  URL_HASH SHA256=546ab74561c040df210c88dbd3c652bf509d826954ab2002c8973f1fa8d10130)
foreach(option PYTHON ICONV ICU ZLIB LZMA HTTP MODULES TESTS PROGRAMS)
  set(LIBXML2_WITH_${option} OFF CACHE BOOL "")
endforeach()
FetchContent_MakeAvailable(libxml2)
driver(doc-libxml2 lanes/doc/libxml2.cpp LibXml2::LibXml2)

FetchContent_Declare(expat
  URL https://github.com/libexpat/libexpat/archive/refs/tags/R_2_7_3.tar.gz
  URL_HASH SHA256=7c853a76f7c2a562c3edfd84ca47e487d9eff3966786191dfb60cc441daf82d6
  SOURCE_SUBDIR expat)
foreach(option BUILD_TOOLS BUILD_EXAMPLES BUILD_TESTS BUILD_DOCS SHARED_LIBS)
  set(EXPAT_${option} OFF CACHE BOOL "")
endforeach()
FetchContent_MakeAvailable(expat)
driver(doc-expat lanes/doc/expat.cpp expat::expat)
driver(paths-pugixml lanes/paths/pugixml.cpp pugixml::pugixml)
driver(write-pugixml lanes/write/pugixml.cpp pugixml::pugixml)

# CBOR: the C libraries of the doc and write lanes. Each builds its library only.
FetchContent_Declare(tinycbor
  URL https://github.com/intel/tinycbor/archive/refs/tags/v7.1.tar.gz
  URL_HASH SHA256=08c0a4c0a983000806f3d8c1599ec07995789ae49e9a23034db4cbfccc81c2e5)
FetchContent_Declare(qcbor
  URL https://github.com/laurencelundblade/QCBOR/archive/refs/tags/v1.6.1.tar.gz
  URL_HASH SHA256=286badcef7227533fcd5840386177ff20b1a53ca29f1544092b1fc36d020ade8)
FetchContent_Declare(libcbor
  URL https://github.com/PJK/libcbor/archive/refs/tags/v0.15.0.tar.gz
  URL_HASH SHA256=c94145d3c22e67cff9a3325dc036b4545a49a42231553995be4947d52cf2ef57)
set(BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WITH_CBOR2JSON OFF CACHE BOOL "" FORCE)
set(WITH_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WITH_TESTS OFF CACHE BOOL "" FORCE)
set(SANITIZE OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(tinycbor qcbor libcbor)

driver(doc-tinycbor lanes/doc/tinycbor.c tinycbor)
target_include_directories(doc-tinycbor PRIVATE ${tinycbor_SOURCE_DIR}/src ${tinycbor_BINARY_DIR})
driver(doc-qcbor lanes/doc/qcbor.c qcbor)
driver(doc-libcbor lanes/doc/libcbor.c cbor)
driver(write-tinycbor lanes/write/tinycbor.c tinycbor)
target_include_directories(write-tinycbor PRIVATE ${tinycbor_SOURCE_DIR}/src ${tinycbor_BINARY_DIR})

# YAML: rapidyaml, libfyaml, libyaml. The libraries' drivers share lanes/doc/yaml_doc.h.

# rapidyaml is its release's single header, compiled in the driver that defines RYML_SINGLE_HDR_DEFINE_NOW.
FetchContent_Declare(rapidyaml
  URL https://github.com/biojppm/rapidyaml/releases/download/v0.16.0/rapidyaml.v0.16.0.singlehdr.hpp
  URL_HASH SHA256=0d0b8076174cf62f034406b03529fda542ebc9a17506d3bd6d949aedc4bfa6ab
  DOWNLOAD_NAME ryml_all.hpp
  DOWNLOAD_NO_EXTRACT TRUE)
FetchContent_MakeAvailable(rapidyaml)
driver(doc-rapidyaml lanes/doc/rapidyaml.cpp)
target_include_directories(doc-rapidyaml PRIVATE ${rapidyaml_SOURCE_DIR} lanes/doc)
driver(paths-rapidyaml lanes/paths/rapidyaml.cpp)
target_include_directories(paths-rapidyaml PRIVATE ${rapidyaml_SOURCE_DIR})
driver(write-rapidyaml lanes/write/rapidyaml.cpp)
target_include_directories(write-rapidyaml PRIVATE ${rapidyaml_SOURCE_DIR} lanes/doc)
driver(records-rapidyaml lanes/records/rapidyaml.cpp)
target_include_directories(records-rapidyaml PRIVATE ${rapidyaml_SOURCE_DIR})

FetchContent_Declare(libyaml
  URL https://github.com/yaml/libyaml/archive/refs/tags/0.2.5.tar.gz
  URL_HASH SHA256=fa240dbf262be053f3898006d502d514936c818e422afdcf33921c63bed9bf2e)
set(CMAKE_POLICY_VERSION_MINIMUM 3.5)
FetchContent_MakeAvailable(libyaml)
unset(CMAKE_POLICY_VERSION_MINIMUM)
driver(doc-libyaml lanes/doc/libyaml.cpp yaml)
target_include_directories(doc-libyaml PRIVATE ${libyaml_SOURCE_DIR}/include lanes/doc)
driver(records-libyaml lanes/records/libyaml.cpp yaml)
target_include_directories(records-libyaml PRIVATE ${libyaml_SOURCE_DIR}/include)

set(ENABLE_PORTABLE_TARGET OFF CACHE BOOL "")
set(BUILD_TESTING OFF CACHE BOOL "")
set(ENABLE_NETWORK OFF CACHE BOOL "")
set(ENABLE_REFLECTION OFF CACHE BOOL "")
set(ENABLE_GENERIC OFF CACHE BOOL "")
FetchContent_Declare(libfyaml
  URL https://github.com/pantoniou/libfyaml/archive/refs/tags/v1.0.0-rc2.tar.gz
  URL_HASH SHA256=d8406971663c7624d15768ecbc78e56445de14b4cf40898fbe487925fafae7fd)
FetchContent_MakeAvailable(libfyaml)
driver(doc-libfyaml lanes/doc/libfyaml.cpp fyaml_static)
target_include_directories(doc-libfyaml PRIVATE ${libfyaml_SOURCE_DIR}/include lanes/doc)

# HTML drivers: lexbor and gumbo. gumbo's sources are built here, since the project's own build needs autotools.
FetchContent_Declare(lexbor
  URL https://codeload.github.com/lexbor/lexbor/tar.gz/refs/tags/v2.5.0
  URL_HASH SHA256=d89060bb2fb6f7d0e0f399495155dd15e06697aa2c6568eab70ecd4a43084ba9)
set(LEXBOR_BUILD_SHARED OFF CACHE BOOL "")
set(LEXBOR_BUILD_STATIC ON CACHE BOOL "")
set(LEXBOR_INSTALL_HEADERS OFF CACHE BOOL "")
FetchContent_MakeAvailable(lexbor)
FetchContent_Declare(gumbo
  URL https://codeload.github.com/google/gumbo-parser/tar.gz/refs/tags/v0.10.1
  URL_HASH SHA256=28463053d44a5dfbc4b77bcf49c8cee119338ffa636cc17fc3378421d714efad)
FetchContent_MakeAvailable(gumbo)
file(GLOB GUMBO_SOURCES ${gumbo_SOURCE_DIR}/src/*.c)
add_library(gumbo STATIC ${GUMBO_SOURCES})
target_include_directories(gumbo PUBLIC ${gumbo_SOURCE_DIR}/src)
target_compile_options(gumbo PRIVATE -w -std=gnu99)
driver(doc-lexbor lanes/doc/lexbor.cpp lexbor_static)
driver(doc-gumbo lanes/doc/gumbo.cpp gumbo)
foreach(target doc-lexbor doc-gumbo)
  target_include_directories(${target} PRIVATE lanes/doc)
endforeach()
driver(paths-lexbor lanes/paths/lexbor.cpp lexbor_static)
driver(write-lexbor lanes/write/lexbor.cpp lexbor_static)
foreach(target paths-lexbor write-lexbor)
  target_include_directories(${target} PRIVATE lanes/doc)
endforeach()

# toml++ and toml11, the TOML lanes' C++ libraries.
FetchContent_Declare(tomlplusplus
  URL https://github.com/marzer/tomlplusplus/archive/refs/tags/v3.4.0.tar.gz
  URL_HASH SHA256=8517f65938a4faae9ccf8ebb36631a38c1cadfb5efa85d9a72e15b9e97d25155)
FetchContent_Declare(toml11
  URL https://github.com/ToruNiina/toml11/archive/refs/tags/v4.4.0.tar.gz
  URL_HASH SHA256=815bfe6792aa11a13a133b86e7f0f45edc5d71eb78f5fb6686c49c7f792b9049)
set(tomlplusplus_BUILD_EXAMPLES OFF CACHE BOOL "")
set(tomlplusplus_BUILD_TESTS OFF CACHE BOOL "")
set(TOML11_INSTALL OFF CACHE BOOL "")
FetchContent_MakeAvailable(tomlplusplus toml11)

driver(doc-tomlpp lanes/doc/tomlpp.cpp tomlplusplus::tomlplusplus)
driver(doc-toml11 lanes/doc/toml11.cpp toml11::toml11)
driver(paths-tomlpp lanes/paths/tomlpp.cpp tomlplusplus::tomlplusplus)
driver(write-tomlpp lanes/write/tomlpp.cpp tomlplusplus::tomlplusplus)
