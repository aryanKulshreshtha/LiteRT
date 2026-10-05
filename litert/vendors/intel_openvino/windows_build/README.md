<!-- Copyright 2026 Google LLC.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. -->

# Building the Intel OpenVINO NPU dispatch/compiler libraries on Windows (CMake)

This directory has everything needed to go from a **fresh clone** of this
repo to a working `LiteRtDispatch_OpenVINO.dll` +
`LiteRtCompilerPlugin_IntelOpenvino.dll` build on Windows, via CMake (not
Bazel).

Contents:
- `0001-windows-cmake-npu-support.patch` — CMake/header fixes required to get
  this building on MSVC (not yet upstream; see "What the patch does" below).
- `build_windows_openvino_npu.ps1` — automates everything below.

## Quick start

From a regular (non-admin) PowerShell, at the repo root:

```powershell
.\litert\vendors\intel_openvino\windows_build\build_windows_openvino_npu.ps1
```

That's it for the common case. First run takes 30-60+ minutes (mostly
fetching and building TFLite/Abseil/FlatBuffers via CMake FetchContent);
subsequent runs are incremental and fast. It will:

1. Apply `0001-windows-cmake-npu-support.patch` (no-ops if already applied).
2. Find a Visual Studio / Build Tools install with the C++ workload.
3. Install Ninja via pip if it's not already on `PATH`.
4. Find or download an OpenVINO Windows runtime with NPU plugin support.
5. Configure + build with CMake + Ninja.
6. Run the NPU-optimizer test and report pass/fail.

Useful parameters:

```powershell
# Point at an OpenVINO runtime you've already extracted somewhere.
.\build_windows_openvino_npu.ps1 -OpenVinoDir "C:\openvino_2026.3"

# The patch is already merged upstream — don't try to (re-)apply it.
.\build_windows_openvino_npu.ps1 -SkipPatch

# Build somewhere other than <repo>\litert\cmake_build_win.
.\build_windows_openvino_npu.ps1 -BuildDir "D:\builds\litert_win"
```

## Prerequisites (installed once, not by this script)

- **CMake** ≥ 3.20, on `PATH`.
- **Visual Studio 2022 (or later) Build Tools**, with the **"Desktop
  development with C++"** workload. The script uses `vswhere` to find any
  installed edition (Community/Professional/Enterprise/BuildTools) that has
  `Microsoft.VisualStudio.Component.VC.Tools.x86.x64`. If none is found,
  install it via the Visual Studio Installer.
  - Note: a plain "Visual Studio Community" install *without* the C++
    workload will **not** satisfy this — the script explicitly checks for
    the C++ tools component, not just any VS instance.
- **Python** (any recent 3.x), only needed if Ninja isn't already installed
  (`pip install ninja` is run automatically).

## What the patch does

These are genuine cross-platform CMake/MSVC portability fixes, not
OpenVINO-specific hacks — each addresses a real gap in the existing CMake
scripts when targeting Windows:

1. **`tflite/CMakeLists.txt`** — `TFLITE_ENABLE_MMAP` was left effectively
   forced ON for Windows (a stale comment claimed `mmap_allocation.cc` had
   been ported to `CreateFileMapping`/`MapViewOfFile`; it hadn't — it's still
   pure POSIX `sys/mman.h`/`unistd.h`). Now falls back to
   `mmap_allocation_disabled.cc` on Windows, matching what the option's own
   description already says ("unsupported on Windows").
2. **`litert/core/CMakeLists.txt`** — `dynamic_loading.cc` (needs `dlfcn.h`,
   POSIX-only) was never excluded on Windows; only `dynamic_loading_windows.cc`
   was excluded on non-Windows. Added the missing `else()` branch.
3. **`litert/CMakeLists.txt`** — added a global `NOMINMAX` define for MSVC.
   Without it, `<windows.h>`'s `min`/`max` macros corrupt FlatBuffers-generated
   accessors that happen to be named `min()`/`max()` (e.g. in TFLite's
   `schema_generated.h`), producing bizarre parse errors far from the real
   cause.
4. **`litert/vendors/c/litert_dispatch_api.h`** — `<windows.h>` (pulled in
   transitively, e.g. via `litert_shared_library_windows.h` for
   `LoadLibrary`) does `#define interface struct` for COM authoring, which
   collides with the ABI-stable `LiteRtDispatchApi::interface` field name.
   `#undef`'d locally in this header (safe: nothing in this codebase uses the
   COM `interface` macro).
5. **`litert/vendors/CMakeLists.txt`** — the generic `_litert_add_dispatch_so`
   source glob never picked up `openvino_shared_core.cc` /
   `openvino_tensor_buffer.cc` (unlike other vendors, which special-case their
   extra sources). Added an `OpenVINO`-specific source list, matching the
   existing pattern for MediaTek/Qualcomm/Samsung. Also added
   `add_subdirectory(intel_openvino/compiler)`.
6. **`litert/vendors/intel_openvino/compiler/CMakeLists.txt`** (new file) —
   this subdirectory had no CMake support at all (only Bazel). Builds
   `LiteRtCompilerPlugin_IntelOpenvino.dll` and a self-contained
   `intel_openvino_npu_optimizer_test` (the only one of the five
   `intel_openvino/compiler` tests that doesn't depend on the
   not-yet-CMake-ported `litert/test` helper libraries — see "Known gaps"
   below).

## Known gaps / not covered here

- `decoder_test`, `graph_iterator_test`, `openvino_compiler_plugin_test`
  (all in `litert/vendors/intel_openvino/compiler/`), and
  `dispatch_api_openvino_test` (in `litert/vendors/intel_openvino/dispatch/`)
  all depend on `litert/test:common`, `litert/test:matchers`,
  `litert/test:test_models`, and/or `litert/test:load_test_model`, none of
  which have a CMake port yet (Bazel-only). Porting that shared test
  infrastructure is a separate, larger task.
- No NPU hardware is required to build or to run `intel_openvino_npu_optimizer_test`
  (it only exercises OpenVINO graph-transform passes on the host). Actually
  compiling a model for the `NPU` device at runtime does require physical
  Intel NPU hardware (e.g. Meteor Lake / Core Ultra) — on a machine without
  it, `core.compile_model(model, "NPU")` fails with `Unsupported platform:
  'AUTO_DETECT'`, which is expected/correct behavior, not a build problem.
- The Intel Neural Compute Stick 2 (Myriad X VPU) is a **different, older**
  device family — Intel dropped Myriad/VPU plugin support after OpenVINO
  2022.3, and it is not present in the OpenVINO version this build targets.
  It cannot be exercised through this build at all, on any OS.

## Manual steps (if you'd rather not use the script)

```powershell
# 1. Apply the patch.
cd <repo-root>
git apply litert\vendors\intel_openvino\windows_build\0001-windows-cmake-npu-support.patch

# 2. Open a "Developer PowerShell for VS 2022" (or run vcvarsall.bat x64
#    yourself first), then:
pip install ninja   # if not already installed

# 3. Configure (point OpenVINO_DIR at wherever you extracted the runtime;
#    see third_party/intel_openvino/openvino.bzl for the pinned download URL).
cmake -S litert -B litert\cmake_build_win -G Ninja `
  -DCMAKE_BUILD_TYPE=Release -DLITERT_BUILD_TESTS=ON -DLITERT_ENABLE_NPU=ON `
  -DLITERT_ENABLE_GPU=OFF `
  -DOpenVINO_DIR="<path-to-openvino>\runtime\cmake" `
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5

# 4. Build.
cd litert\cmake_build_win
ninja dispatch_api_OpenVINO_so intel_openvino_compiler_plugin intel_openvino_npu_optimizer_test

# 5. Run the test (needs the OpenVINO runtime DLLs on PATH).
$env:PATH = "<path-to-openvino>\runtime\bin\intel64\Release;$env:PATH"
.\vendors\intel_openvino\compiler\intel_openvino_npu_optimizer_test.exe
```

## Output artifacts

After a successful build, under `<BuildDir>` (default
`litert\cmake_build_win`):

- `vendors\LiteRtDispatch_OpenVINO.dll` (+ `.lib` import lib) — the NPU
  dispatch library; exports `LiteRtDispatchGetApi`.
- `vendors\intel_openvino\compiler\LiteRtCompilerPlugin_IntelOpenvino.dll`
  (+ `.lib`) — the compiler plugin; exports `LiteRtCreateCompilerPlugin`,
  `LiteRtCompilerPluginCompile`, etc.
- `vendors\intel_openvino\compiler\intel_openvino_npu_optimizer_test.exe` —
  the test binary (needs the OpenVINO runtime DLLs on `PATH` to run).

Both DLLs dynamically link `openvino.dll` (and, for the compiler plugin,
`openvino_tensorflow_lite_frontend.dll`) rather than bundling OpenVINO's code,
which is why they're relatively small (a couple hundred KB) — that's expected,
not a sign anything is missing. Verify with `dumpbin /dependents` /
`dumpbin /exports` (from a VS Developer Command Prompt) if in doubt.
