# Omega SREP - CMake build (alternative to the Makefile).
#
# Primary build path remains the Makefile (used by CI on Linux and by
# MinGW-w64 on Windows; release binaries are built from it). This
# CMakeLists exists for users who prefer cmake -- Ninja, IDE
# integration, easier per-platform tweaks. It is intentionally
# toolchain-agnostic: GCC, clang, MinGW-w64, llvm-mingw all work.
# MSVC compiles too (the source is MSVC-clean as of beta.4) but is
# not tested by the maintainer and not in CI.
#
#     cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
#     cmake --build build
#
# This file mirrors the Makefile rule (compile Common.cpp + srep.cpp;
# everything else is reached via #include from those two TUs) rather
# than re-modelling the source graph in CMake.
#
# Verified on:
#   - GCC 14 (Linux x86_64) -- equivalent to the Makefile build
#   - clang 19 (Linux x86_64) -- equivalent to the Makefile build
#
# See docs/windows-build.md for the supported Windows path
# (MinGW-w64 via scoop or MSYS2) and notes on alternative toolchains.

cmake_minimum_required(VERSION 3.20)
project(omega-srep CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release)
endif()

if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8 AND NOT CMAKE_SIZEOF_VOID_P EQUAL 4)
    message(FATAL_ERROR "Omega SREP requires a 32- or 64-bit toolchain.")
endif()

set(OSREP_SOURCES
    Compression/Common.cpp
    Compression/SREP/srep.cpp
)

set(OSREP_INCLUDES
    ${CMAKE_CURRENT_SOURCE_DIR}/Compression
    ${CMAKE_CURRENT_SOURCE_DIR}/Compression/_Encryption
    ${CMAKE_CURRENT_SOURCE_DIR}/Compression/_Encryption/headers
    ${CMAKE_CURRENT_SOURCE_DIR}/Compression/_Encryption/hashes
)

set(OSREP_DEFINES
    FREEARC_INTEL_BYTE_ORDER
    _FILE_OFFSET_BITS=64
)

if(WIN32)
    list(APPEND OSREP_DEFINES
        FREEARC_WIN
        UNICODE
        _UNICODE
    )
    set(OSREP_LIBS ole32 uuid shell32 advapi32)
else()
    list(APPEND OSREP_DEFINES FREEARC_UNIX)
    set(OSREP_LIBS pthread)
endif()

add_executable(osrep ${OSREP_SOURCES})
target_include_directories(osrep PRIVATE ${OSREP_INCLUDES})
target_compile_definitions(osrep PRIVATE ${OSREP_DEFINES})
target_link_libraries(osrep PRIVATE ${OSREP_LIBS})

if(MSVC)
    target_compile_options(osrep PRIVATE
        /utf-8
        /EHsc
        /Zc:__cplusplus
        /W3
        /wd4244 /wd4267 /wd4018 /wd4146
        /wd4996
    )
    target_compile_definitions(osrep PRIVATE
        _CRT_SECURE_NO_WARNINGS
        _CRT_NONSTDC_NO_DEPRECATE
        WIN32_LEAN_AND_MEAN
        NOMINMAX
    )
    if(CMAKE_BUILD_TYPE STREQUAL "Release")
        target_compile_options(osrep PRIVATE /O2 /Oi /GL)
        target_link_options(osrep PRIVATE /LTCG)
    endif()
else()
    target_compile_options(osrep PRIVATE
        -O3 -flto -mtune=generic -funroll-all-loops -msse2
        -Wno-write-strings -Wno-unused-result
    )
    # -flto must be repeated on the link step too: unlike the Makefile (which
    # compiles and links in one $(CXX) invocation), CMake's add_executable
    # runs them as separate steps, so the compile-time flag alone is not
    # sufficient here.
    target_link_options(osrep PRIVATE -flto)
    if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND NOT WIN32)
        target_link_options(osrep PRIVATE -static)
    endif()
endif()

message(STATUS "Omega SREP CMake build configured")
message(STATUS "  Toolchain: ${CMAKE_CXX_COMPILER_ID} (${CMAKE_CXX_COMPILER})")
message(STATUS "  Target:    ${CMAKE_SYSTEM_NAME} ${CMAKE_SYSTEM_PROCESSOR}")
message(STATUS "  Build:     ${CMAKE_BUILD_TYPE}")
