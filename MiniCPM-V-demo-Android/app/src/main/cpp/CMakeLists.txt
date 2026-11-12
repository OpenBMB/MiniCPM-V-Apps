cmake_minimum_required(VERSION 3.22.1)

project("minicpm_v_demo" VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED true)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED true)

set(CMAKE_C_FLAGS   "${CMAKE_C_FLAGS}"   CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS}" CACHE STRING "" FORCE)

if(DEFINED ANDROID_ABI)
    message(STATUS "Detected Android ABI: ${ANDROID_ABI}")
    if(ANDROID_ABI STREQUAL "arm64-v8a")
        set(GGML_SYSTEM_ARCH "ARM")
        set(GGML_CPU_KLEIDIAI ON)
        set(GGML_OPENMP ON)
    elseif(ANDROID_ABI STREQUAL "x86_64")
        set(GGML_SYSTEM_ARCH "x86")
        set(GGML_CPU_KLEIDIAI OFF)
        set(GGML_OPENMP OFF)
    elseif(ANDROID_ABI STREQUAL "x86")
        set(GGML_SYSTEM_ARCH "x86")
        set(GGML_CPU_KLEIDIAI OFF)
        set(GGML_OPENMP OFF)
    else()
        message(WARNING "Unsupported ABI: ${ANDROID_ABI}, defaulting to generic CPU")
        set(GGML_SYSTEM_ARCH "")
        set(GGML_CPU_KLEIDIAI OFF)
        set(GGML_OPENMP OFF)
    endif()
endif()

# llama.cpp-omni source lives at the repository root so it can be shared with the iOS demo.
# Allow override via -DLLAMA_SRC=... if you keep llama.cpp-omni elsewhere.
if(NOT DEFINED LLAMA_SRC)
    set(LLAMA_SRC ${CMAKE_CURRENT_LIST_DIR}/../../../../../llama.cpp-omni)
endif()
get_filename_component(LLAMA_SRC ${LLAMA_SRC} ABSOLUTE)
if(NOT EXISTS ${LLAMA_SRC}/CMakeLists.txt)
    message(FATAL_ERROR
        "llama.cpp-omni not found at ${LLAMA_SRC}. "
        "Run `git submodule update --init` from the repository root.")
endif()
message(STATUS "Using llama.cpp-omni source at: ${LLAMA_SRC}")

# Vulkan is the GPU path. The armv8.6 ggml-cpu build sets GGML_CPU_ARM_ARCH
# and stays CPU-only.
if(ANDROID AND NOT GGML_CPU_ARM_ARCH)
    set(GGML_VULKAN ON CACHE BOOL "" FORCE)

    # ggml-vulkan compiles its shaders with a host (build-machine) tool, so the
    # NDK clang must not be used for it. The host compiler is whatever CMake
    # was invoked with.
    if(NOT CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
        message(FATAL_ERROR
            "The Vulkan shader host toolchain here assumes a macOS build host. "
            "Add the equivalent toolchain file for ${CMAKE_HOST_SYSTEM_NAME}.")
    endif()
    set(_HOST_TOOLCHAIN "${CMAKE_BINARY_DIR}/host-macos.cmake")
    file(WRITE "${_HOST_TOOLCHAIN}"
"set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_C_COMPILER /usr/bin/clang)
set(CMAKE_CXX_COMPILER /usr/bin/clang++)
set(CMAKE_MAKE_PROGRAM \"${CMAKE_MAKE_PROGRAM}\" CACHE FILEPATH \"\" FORCE)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE NEVER)
")
    set(GGML_VULKAN_SHADERS_GEN_TOOLCHAIN "${_HOST_TOOLCHAIN}" CACHE FILEPATH "" FORCE)
    set(Vulkan_GLSLC_EXECUTABLE "${ANDROID_NDK}/shader-tools/darwin-x86_64/glslc" CACHE FILEPATH "" FORCE)

    # Vulkan-Hpp is vendored because the NDK ships only the C headers
    # (vulkan_core.h and friends, no vulkan.hpp). Point -DVULKAN_HEADERS_DIR at
    # a checkout of KhronosGroup/Vulkan-Headers to use your own copy.
    set(VULKAN_HEADERS_DIR "${CMAKE_CURRENT_LIST_DIR}/third_party/Vulkan-Headers"
        CACHE PATH "Checkout of KhronosGroup/Vulkan-Headers")
    set(_VK_HPP "${VULKAN_HEADERS_DIR}/include")
    if(NOT EXISTS "${_VK_HPP}/vulkan/vulkan.hpp")
        message(FATAL_ERROR
            "Vulkan-Headers not found at ${_VK_HPP}. Clone "
            "https://github.com/KhronosGroup/Vulkan-Headers there, or pass "
            "-DVULKAN_HEADERS_DIR=<path>.")
    endif()
    set(Vulkan_INCLUDE_DIR "${_VK_HPP}" CACHE PATH "" FORCE)
    set(Vulkan_LIBRARY "${CMAKE_SYSROOT}/usr/lib/aarch64-linux-android/28/libvulkan.so" CACHE FILEPATH "" FORCE)
    set(_SPIRV_INC "${ANDROID_NDK}/sources/third_party/shaderc/third_party/spirv-tools/external/spirv-headers/include")
    include_directories(BEFORE SYSTEM "${_SPIRV_INC}")
    set(SPIRV-Headers_DIR "${CMAKE_CURRENT_LIST_DIR}/cmake/SPIRV-Headers" CACHE PATH "" FORCE)
    message(STATUS "Vulkan glslc: ${Vulkan_GLSLC_EXECUTABLE}")
    message(STATUS "Vulkan library: ${Vulkan_LIBRARY}")
endif()

add_subdirectory(${LLAMA_SRC} ${CMAKE_BINARY_DIR}/build-llama)

if(NOT DEFINED LLAMA_INSTALL_VERSION)
    set(LLAMA_INSTALL_VERSION "0.0.0")
endif()

add_library(${CMAKE_PROJECT_NAME} SHARED
        llama_jni.cpp
        omni_jni.cpp
        qnn_vit.cpp
        qnn_vit_jni.cpp)

target_compile_definitions(${CMAKE_PROJECT_NAME} PRIVATE
        GGML_SYSTEM_ARCH=${GGML_SYSTEM_ARCH}
        GGML_CPU_KLEIDIAI=$<BOOL:${GGML_CPU_KLEIDIAI}>
        GGML_OPENMP=$<BOOL:${GGML_OPENMP}>
)

target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE
        ${LLAMA_SRC}
        ${LLAMA_SRC}/common
        ${LLAMA_SRC}/include
        ${LLAMA_SRC}/ggml/include
        ${LLAMA_SRC}/ggml/src
        ${LLAMA_SRC}/tools/mtmd
        ${LLAMA_SRC}/tools/omni
        ${LLAMA_SRC}/tools/omni/voxcpm2
        # llama-common/peg-parser pulls in <nlohmann/json_fwd.hpp> via chat.h.
        # The vendored nlohmann headers live under llama.cpp-omni/vendor.
        ${LLAMA_SRC}/vendor
        # Qualcomm QNN headers, copied from the QAIRT 2.51.200 SDK. They are
        # marked "Confidential and Proprietary" and stay out of git (see
        # .gitignore), so this directory only exists on dev machines.
        # Both the parent and QNN/ are on the path: QnnSystemInterface.h pulls
        # in "System/QnnSystemCommon.h" relative to the QNN/ directory.
        ${CMAKE_CURRENT_LIST_DIR}/qnn-include
        ${CMAKE_CURRENT_LIST_DIR}/qnn-include/QNN)

target_link_libraries(${CMAKE_PROJECT_NAME}
        llama
        llama-common
        mtmd
        voxcpm2_runtime
        android
        log)
