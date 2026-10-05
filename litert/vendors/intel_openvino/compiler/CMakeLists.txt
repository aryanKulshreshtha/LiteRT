# Copyright 2026 Google LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Intel OpenVINO Compiler Plugin Shared Library
cmake_minimum_required(VERSION 3.20)

message(STATUS "Building Intel OpenVINO compiler plugin for host")

add_library(intel_openvino_compiler_plugin SHARED
    decoder.cc
    graph_iterator.cc
    npu_optimizer.cc
    openvino_compile_context.cc
    openvino_compiler_plugin.cc
    openvino_soc_config.cc
)

target_link_libraries(intel_openvino_compiler_plugin
    PRIVATE
        litert_c_api
        litert_cc_api
        litert_cc_internal
        tensorflow-lite
        absl::status
        absl::statusor
        absl::strings
        absl::str_format
        flatbuffers::flatbuffers
        openvino::runtime
        openvino::frontend::tensorflow_lite
)

set_target_properties(intel_openvino_compiler_plugin PROPERTIES
    OUTPUT_NAME "LiteRtCompilerPlugin_IntelOpenvino"
)

target_compile_definitions(intel_openvino_compiler_plugin
    PRIVATE
        LITERT_COMPILE_LIBRARY
)

if(MSVC)
    target_compile_options(intel_openvino_compiler_plugin PRIVATE /wd4018)
elseif(UNIX)
    target_link_options(intel_openvino_compiler_plugin PRIVATE
        "-Wl,-soname=libLiteRtCompilerPlugin_IntelOpenvino.so"
    )
endif()

# NPU optimizer test (self-contained: only needs OpenVINO + litert logging, no
# litert/test infra). Other intel_openvino tests (decoder_test,
# graph_iterator_test, openvino_compiler_plugin_test) additionally depend on
# litert/test:common, litert/test:matchers, litert/test:test_models, which are
# not yet ported to this CMake build.
if(NOT TARGET GTest::gtest)
    include(FetchContent)
    FetchContent_Declare(
        googletest
        GIT_REPOSITORY https://github.com/google/googletest.git
        GIT_TAG v1.12.x
    )
    FetchContent_MakeAvailable(googletest)
endif()

add_executable(intel_openvino_npu_optimizer_test
    npu_optimizer.cc
    npu_optimizer_test.cc
)

target_link_libraries(intel_openvino_npu_optimizer_test
    PRIVATE
        litert_c_api
        openvino::runtime
        GTest::gtest
        GTest::gtest_main
)
