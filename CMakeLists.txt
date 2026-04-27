# Omega SREP - CMake build (F6.8).
#
# Primary build path remains the Makefile (used by CI on Linux and by
# MinGW-w64 on Windows). This CMakeLists is the supported way to
# build with native MSVC (cl.exe) and exists so users on Visual
# Studio / Visual Studio Build Tools have a one-liner that works:
#
#     cmake -B build
#     cmake --build build --config Release
#
# This file mirrors the Makefile rule (compile Common.cpp + srep.cpp;
# everything else is reached via #include from those two TUs) rather
# than re-modelling the source graph in CMake.
#
# Tested on:
#   - GCC 13 (Linux x86_64) -- equivalent to the Makefile build
#   - clang 19 (Linux x86_64) -- equivalent to the Makefile build
#   - cl.exe (MSVC 19.4x, VS 2022) -- see docs/msvc-build.md
#
# See docs/msvc-build.md for full Windows-specific instructions.

cmake_minimum_required(VERSION 3.20)
project(omega-srep CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release)
endif()

if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "Omega SREP requires a 64-bit toolchain.")
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
        -O3 -mtune=generic -funroll-loops -msse2
        -Wno-write-strings -Wno-unused-result
    )
    if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND NOT WIN32)
        target_link_options(osrep PRIVATE -static)
    endif()
endif()

message(STATUS "Omega SREP CMake build configured")
message(STATUS "  Toolchain: ${CMAKE_CXX_COMPILER_ID} (${CMAKE_CXX_COMPILER})")
message(STATUS "  Target:    ${CMAKE_SYSTEM_NAME} ${CMAKE_SYSTEM_PROCESSOR}")
message(STATUS "  Build:     ${CMAKE_BUILD_TYPE}")
