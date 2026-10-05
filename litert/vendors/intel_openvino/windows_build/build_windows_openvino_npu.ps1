<#
.SYNOPSIS
  Builds the LiteRT Intel OpenVINO NPU dispatch library, compiler plugin, and
  NPU-optimizer test binary on Windows via CMake, starting from a fresh clone.

.DESCRIPTION
  This script automates everything that was done by hand to get the OpenVINO
  NPU CMake build working on Windows:
    1. Applies 0001-windows-cmake-npu-support.patch (CMake/header fixes that
       are not yet upstream) unless it's already applied.
    2. Locates a Visual Studio / Build Tools install with the C++ workload
       (via vswhere) to get a working MSVC toolchain + vcvarsall.bat.
    3. Ensures Ninja is available (installs via pip if missing).
    4. Locates an OpenVINO Windows runtime with NPU plugin support. Checks,
       in order: -OpenVinoDir, $env:OPENVINO_NATIVE_DIR, the Bazel external
       cache (C:\bzl\external\intel_openvino), then falls back to downloading
       the exact nightly build this repo is pinned to (see
       third_party/intel_openvino/openvino.bzl) into .\third_party_downloads.
    5. Configures and builds with CMake + Ninja.
    6. Runs the NPU-optimizer test binary and reports pass/fail.

.PARAMETER RepoRoot
  Path to the repo root (the directory containing the top-level "litert" and
  "tflite" directories). Defaults to three levels up from this script.

.PARAMETER OpenVinoDir
  Path to an already-extracted OpenVINO Windows runtime (the directory that
  contains "runtime\cmake\OpenVINOConfig.cmake"). If omitted, the script will
  search known locations and download one if none is found.

.PARAMETER BuildDir
  CMake build directory. Defaults to <RepoRoot>\litert\cmake_build_win.

.PARAMETER SkipPatch
  Skip applying 0001-windows-cmake-npu-support.patch (use if it's already
  merged upstream).

.PARAMETER Reconfigure
  Force a full `cmake` configure even if <BuildDir>\CMakeCache.txt already
  exists. By default, if the build was already configured once, this script
  skips straight to `ninja` (which does its own fast incremental regen-check
  and no-ops if nothing relevant changed) instead of re-running the full
  ~10+ minute configure step unconditionally. Pass this after changing a
  CMake option (e.g. -DLITERT_ENABLE_GPU) that a plain rebuild won't pick up.

.EXAMPLE
  .\build_windows_openvino_npu.ps1

.EXAMPLE
  .\build_windows_openvino_npu.ps1 -OpenVinoDir "C:\openvino_2026.3"
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [string]$OpenVinoDir = "",
    [string]$BuildDir = "",
    [switch]$SkipPatch,
    [switch]$Reconfigure
)

$ErrorActionPreference = "Stop"

# NOTE: $PSScriptRoot is not populated yet while parameter default values are
# evaluated when a script has [CmdletBinding()] (a long-standing PowerShell
# 5.1 quirk, fixed in PowerShell 7+) - so $RepoRoot is resolved here instead
# of as a param default.
if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..")).Path
}

function Write-Step($msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}

function Fail($msg) {
    Write-Host "ERROR: $msg" -ForegroundColor Red
    exit 1
}

if (-not $BuildDir) {
    $BuildDir = Join-Path $RepoRoot "litert\cmake_build_win"
}

Write-Step "Repo root: $RepoRoot"
if (-not (Test-Path (Join-Path $RepoRoot "litert\CMakeLists.txt"))) {
    Fail "Could not find litert\CMakeLists.txt under $RepoRoot. Pass -RepoRoot explicitly."
}

# ---------------------------------------------------------------------------
# 1. Apply the CMake/header patch (skip if already applied).
# ---------------------------------------------------------------------------
if (-not $SkipPatch) {
    Write-Step "Checking OpenVINO Windows CMake patch"
    $patchFile = Join-Path $PSScriptRoot "0001-windows-cmake-npu-support.patch"
    if (-not (Test-Path $patchFile)) {
        Fail "Patch file not found: $patchFile"
    }
    Push-Location $RepoRoot
    try {
        & git apply --check $patchFile 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Applying patch..."
            & git apply $patchFile
            if ($LASTEXITCODE -ne 0) { Fail "git apply failed." }
        } else {
            # Could already be applied (reverse-check), or a real conflict.
            & git apply --reverse --check $patchFile 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Patch already applied, skipping."
            } else {
                Fail "Patch does not apply cleanly. Resolve manually or pass -SkipPatch if you've already merged these changes."
            }
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Step "Skipping patch application (-SkipPatch)"
}

# ---------------------------------------------------------------------------
# 2. Locate Visual Studio / Build Tools with the C++ workload.
# ---------------------------------------------------------------------------
Write-Step "Locating Visual Studio C++ toolchain"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Fail "vswhere.exe not found. Install Visual Studio or Build Tools with the 'Desktop development with C++' workload."
}
$vsInstallPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $vsInstallPath) {
    Fail "No Visual Studio / Build Tools install with the C++ workload found. Install it via the Visual Studio Installer (Workload: 'Desktop development with C++')."
}
$vcvarsall = Join-Path $vsInstallPath "VC\Auxiliary\Build\vcvarsall.bat"
if (-not (Test-Path $vcvarsall)) {
    Fail "vcvarsall.bat not found under $vsInstallPath"
}
Write-Host "Using: $vcvarsall"

# ---------------------------------------------------------------------------
# 3. Ensure Ninja is available.
# ---------------------------------------------------------------------------
Write-Step "Checking for Ninja"
$ninja = Get-Command ninja -ErrorAction SilentlyContinue
if (-not $ninja) {
    Write-Host "Ninja not found on PATH; installing via pip..."
    & python -m pip install --quiet ninja
    if ($LASTEXITCODE -ne 0) { Fail "Failed to install ninja via pip. Install it manually and ensure it's on PATH." }
    # pip may install into either the interpreter's own Scripts dir or the
    # per-user Scripts dir (e.g. if it lacks permission to write the global
    # site-packages) - try both before giving up. Note: the per-user path is
    # NOT simply site.USER_BASE + "\Scripts" on Windows (that's missing the
    # version-specific "PythonXY" component) - use the "nt_user" sysconfig
    # scheme, which resolves it correctly.
    $baseScripts = & python -c "import sysconfig; print(sysconfig.get_path('scripts'))"
    $userScripts = & python -c "import sysconfig; print(sysconfig.get_path('scripts', scheme='nt_user'))"
    $env:PATH = "$baseScripts;$userScripts;$env:PATH"
    $ninja = Get-Command ninja -ErrorAction SilentlyContinue
    if (-not $ninja) {
        Fail "ninja still not found on PATH after pip install (checked '$baseScripts' and '$userScripts'). Install it manually and ensure it's on PATH."
    }
}
Write-Host "Using: $($ninja.Source)"

# ---------------------------------------------------------------------------
# 4. Locate or download an OpenVINO Windows runtime with NPU plugin support.
# ---------------------------------------------------------------------------
Write-Step "Locating OpenVINO Windows runtime"

# This is the exact nightly build this repo is pinned to (see
# third_party/intel_openvino/openvino.bzl) - kept in sync manually.
$OpenVinoPinnedUrl = "https://storage.openvinotoolkit.org/repositories/openvino/packages/nightly/2026.3.0-22242-561fc907ca4/openvino_toolkit_windows_2026.3.0.dev20260622_x86_64.zip"

function Test-OpenVinoDir($dir) {
    return (Test-Path (Join-Path $dir "runtime\cmake\OpenVINOConfig.cmake"))
}

if ($OpenVinoDir) {
    if (-not (Test-OpenVinoDir $OpenVinoDir)) {
        Fail "-OpenVinoDir '$OpenVinoDir' does not contain runtime\cmake\OpenVINOConfig.cmake"
    }
} elseif ($env:OPENVINO_NATIVE_DIR -and (Test-OpenVinoDir $env:OPENVINO_NATIVE_DIR)) {
    $OpenVinoDir = $env:OPENVINO_NATIVE_DIR
    Write-Host "Using OPENVINO_NATIVE_DIR: $OpenVinoDir"
} else {
    # Look for an existing Bazel-fetched copy first (common on machines that
    # also build this repo with Bazel).
    $bazelCache = Get-ChildItem -Path "C:\bzl\external\intel_openvino" -Directory -Filter "openvino_toolkit_windows_*" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($bazelCache -and (Test-OpenVinoDir $bazelCache.FullName)) {
        $OpenVinoDir = $bazelCache.FullName
        Write-Host "Found existing Bazel-fetched OpenVINO: $OpenVinoDir"
    } else {
        # Download and extract into the repo's third_party_downloads folder.
        $downloadRoot = Join-Path $RepoRoot "third_party_downloads\intel_openvino"
        New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null
        $zipPath = Join-Path $downloadRoot "openvino_windows.zip"
        $existing = Get-ChildItem -Path $downloadRoot -Directory -Filter "openvino_toolkit_windows_*" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($existing -and (Test-OpenVinoDir $existing.FullName)) {
            $OpenVinoDir = $existing.FullName
            Write-Host "Using previously downloaded OpenVINO: $OpenVinoDir"
        } else {
            Write-Host "Downloading OpenVINO from:`n  $OpenVinoPinnedUrl"
            Write-Host "(This is ~115 MB and may take a few minutes.)"
            Invoke-WebRequest -Uri $OpenVinoPinnedUrl -OutFile $zipPath
            Write-Host "Extracting..."
            Expand-Archive -Path $zipPath -DestinationPath $downloadRoot -Force
            Remove-Item $zipPath
            $extracted = Get-ChildItem -Path $downloadRoot -Directory -Filter "openvino_toolkit_windows_*" -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $extracted -or -not (Test-OpenVinoDir $extracted.FullName)) {
                Fail "Downloaded archive did not produce a valid OpenVINO runtime layout."
            }
            $OpenVinoDir = $extracted.FullName
        }
    }
}
Write-Host "OpenVINO runtime: $OpenVinoDir"
$OpenVinoCmakeDir = (Join-Path $OpenVinoDir "runtime\cmake") -replace '\\', '/'

# ---------------------------------------------------------------------------
# 5. Configure + build with CMake + Ninja inside a vcvars-initialized shell.
# ---------------------------------------------------------------------------
function Invoke-InVsEnv([string]$Command, [string]$LogPath) {
    $full = "call `"$vcvarsall`" x64 >nul && $Command"
    $errLog = "$LogPath.err"
    $proc = Start-Process -FilePath cmd.exe -ArgumentList "/c", $full `
        -NoNewWindow -PassThru -Wait `
        -RedirectStandardOutput $LogPath -RedirectStandardError $errLog
    return $proc.ExitCode
}

New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
$litertSrcDir = Join-Path $RepoRoot "litert"
$cmakeCache = Join-Path $BuildDir "CMakeCache.txt"

if ((Test-Path $cmakeCache) -and -not $Reconfigure) {
    Write-Step "Build already configured ($cmakeCache exists) - skipping cmake configure"
    Write-Host "(ninja will still do its own fast incremental regen-check below. Pass -Reconfigure to force a full reconfigure.)"
} else {
    Write-Step "Configuring CMake (this fetches TFLite/abseil/flatbuffers on first run - can take 15-30+ minutes)"
    # LITERT_FETCH_*_HEADERS=OFF and LITERT_ENABLE_SAMSUNG=OFF skip the other
    # vendor SDK downloads/builds (Qualcomm QAIRT is a multi-GB download,
    # Samsung builds its compiler plugin ON by default) - we only need
    # OpenVINO here.
    $configureCmd = "cmake -S `"$litertSrcDir`" -B `"$BuildDir`" -G Ninja " +
        "-DCMAKE_BUILD_TYPE=Release -DLITERT_BUILD_TESTS=ON -DLITERT_ENABLE_NPU=ON " +
        "-DLITERT_ENABLE_GPU=OFF -DOpenVINO_DIR=`"$OpenVinoCmakeDir`" " +
        "-DLITERT_FETCH_MEDIATEK_HEADERS=OFF -DLITERT_FETCH_QUALCOMM_HEADERS=OFF " +
        "-DLITERT_FETCH_SAMSUNG_HEADERS=OFF -DLITERT_ENABLE_SAMSUNG=OFF " +
        "-DLITERT_ENABLE_QUALCOMM=OFF -DQAIRT_HEADERS_DIR= -DLITECORE_HEADERS_DIR= " +
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    $configureLog = Join-Path $BuildDir "configure.log"
    $rc = Invoke-InVsEnv $configureCmd $configureLog
    if ($rc -ne 0) {
        Write-Host (Get-Content $configureLog -Tail 60)
        Fail "CMake configure failed (exit $rc). See $configureLog for details."
    }
    Write-Host "Configure OK."
}

Write-Step "Building dispatch_api_OpenVINO_so, intel_openvino_compiler_plugin, intel_openvino_npu_optimizer_test"
$cpuCount = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
$jobs = [Math]::Max(1, $cpuCount - 2)
$buildCmd = "cd /d `"$BuildDir`" && ninja dispatch_api_OpenVINO_so intel_openvino_compiler_plugin intel_openvino_npu_optimizer_test -j$jobs"
$buildLog = Join-Path $BuildDir "build.log"
$rc = Invoke-InVsEnv $buildCmd $buildLog
if ($rc -ne 0) {
    Write-Host (Get-Content $buildLog -Tail 80)
    Fail "Build failed (exit $rc). See $buildLog for details."
}
Write-Host "Build OK."

# ---------------------------------------------------------------------------
# 6. Run the NPU-optimizer test.
# ---------------------------------------------------------------------------
Write-Step "Running intel_openvino_npu_optimizer_test"
$testExe = Join-Path $BuildDir "vendors\intel_openvino\compiler\intel_openvino_npu_optimizer_test.exe"
if (-not (Test-Path $testExe)) {
    Fail "Test binary not found at $testExe"
}
$oldPath = $env:PATH
try {
    $env:PATH = "$OpenVinoDir\runtime\bin\intel64\Release;$env:PATH"
    & $testExe
    $testRc = $LASTEXITCODE
} finally {
    $env:PATH = $oldPath
}

Write-Step "Summary"
$dispatchDll = Join-Path $BuildDir "vendors\LiteRtDispatch_OpenVINO.dll"
$pluginDll = Join-Path $BuildDir "vendors\intel_openvino\compiler\LiteRtCompilerPlugin_IntelOpenvino.dll"
Write-Host "Dispatch library:       $dispatchDll" -ForegroundColor $(if (Test-Path $dispatchDll) { "Green" } else { "Red" })
Write-Host "Compiler plugin:        $pluginDll"
Write-Host "Test binary:            $testExe"
Write-Host "Test result:            $(if ($testRc -eq 0) { 'PASSED' } else { 'FAILED' })" -ForegroundColor $(if ($testRc -eq 0) { "Green" } else { "Red" })

if ($testRc -ne 0) { exit 1 }
