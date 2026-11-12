# Lets ggml-vulkan's find_package(SPIRV-Headers) succeed without a Vulkan SDK.
# The actual headers come from the NDK shaderc tree; the Android CMakeLists
# adds that include path before configuring llama.cpp-omni.
set(SPIRV-Headers_FOUND TRUE)
if(NOT TARGET SPIRV-Headers::SPIRV-Headers)
    add_library(SPIRV-Headers::SPIRV-Headers INTERFACE IMPORTED)
endif()
