# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(transcript_whisper_native_library VERSION 0.0.1 LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

find_package(Threads REQUIRED)

# Vendored ggml/whisper.cpp sources (MIT licensed, copied verbatim from the
# upstream project). This library only needs the CPU backend: no CUDA,
# Metal, Vulkan, etc. sources exist in the vendored tree, so the globs below
# only ever pick up CPU code.
set(WHISPER_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/whisper_cpp")

file(GLOB GGML_SOURCES
  "${WHISPER_CPP_DIR}/ggml/src/*.c"
  "${WHISPER_CPP_DIR}/ggml/src/*.cpp"
  "${WHISPER_CPP_DIR}/ggml/src/ggml-cpu/*.c"
  "${WHISPER_CPP_DIR}/ggml/src/ggml-cpu/*.cpp"
  "${WHISPER_CPP_DIR}/ggml/src/ggml-cpu/arch/arm/*.c"
  "${WHISPER_CPP_DIR}/ggml/src/ggml-cpu/arch/arm/*.cpp"
  "${WHISPER_CPP_DIR}/ggml/src/ggml-cpu/arch/x86/*.c"
  "${WHISPER_CPP_DIR}/ggml/src/ggml-cpu/arch/x86/*.cpp"
  "${WHISPER_CPP_DIR}/ggml/src/ggml-cpu/amx/*.cpp"
)

add_library(transcript_whisper_ggml STATIC
  ${GGML_SOURCES}
  "${WHISPER_CPP_DIR}/src/whisper.cpp"
)

target_include_directories(transcript_whisper_ggml PUBLIC
  "${WHISPER_CPP_DIR}/include"
  "${WHISPER_CPP_DIR}/ggml/include"
  "${WHISPER_CPP_DIR}/ggml/src"
  "${WHISPER_CPP_DIR}/ggml/src/ggml-cpu"
)

target_compile_definitions(transcript_whisper_ggml PUBLIC GGML_USE_CPU)
target_compile_definitions(transcript_whisper_ggml PRIVATE
  _GNU_SOURCE
  GGML_VERSION="1.9.1"
  GGML_COMMIT="transcript_whisper_native-vendored"
  WHISPER_VERSION="1.9.1"
)
target_compile_options(transcript_whisper_ggml PRIVATE -O3)

option(TRANSCRIPT_WHISPER_AVX2 "Enable AVX2/FMA/F16C on x86_64 builds" ON)
if(TRANSCRIPT_WHISPER_AVX2 AND CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|amd64|AMD64")
  target_compile_options(transcript_whisper_ggml PRIVATE -mavx2 -mfma -mf16c)
endif()

if(ANDROID)
  # Support Android 15 16k page size.
  target_link_options(transcript_whisper_ggml PRIVATE "-Wl,-z,max-page-size=16384")
endif()

add_library(transcript_whisper_native SHARED
  "transcript_whisper_native.cpp"
)

set_target_properties(transcript_whisper_native PROPERTIES
  PUBLIC_HEADER transcript_whisper_native.h
  OUTPUT_NAME "transcript_whisper_native"
)

target_compile_definitions(transcript_whisper_native PUBLIC DART_SHARED_LIB)
target_link_libraries(transcript_whisper_native PRIVATE
  transcript_whisper_ggml
  Threads::Threads
  ${CMAKE_DL_LIBS}
)
if(NOT WIN32)
  target_link_libraries(transcript_whisper_native PRIVATE m)
endif()

if(ANDROID)
  target_link_options(transcript_whisper_native PRIVATE "-Wl,-z,max-page-size=16384")
endif()
