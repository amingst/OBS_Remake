@echo off
setlocal enabledelayedexpansion

:: ============================================================
:: setup.bat — One-command build setup for StreamSmith
:: Usage: setup.bat [--force | --rebuild]
:: ============================================================

set "FORCE=0"
if /i "%~1"=="--force"   set "FORCE=1"
if /i "%~1"=="--rebuild" set "FORCE=1"

:: ------------------------------------------------------------
:: Prerequisite checks
:: ------------------------------------------------------------

where git >nul 2>&1
if errorlevel 1 (
    echo Error: git is not on PATH.
    exit /b 1
)

where premake5 >nul 2>&1
if errorlevel 1 (
    echo Error: premake5 is not on PATH.
    echo Download from https://premake.github.io/download
    exit /b 1
)

where python >nul 2>&1
if errorlevel 1 (
    echo Error: python is not on PATH.
    exit /b 1
)

:: Check Python version >= 3.3
for /f "tokens=2 delims= " %%v in ('python --version 2^>^&1') do set "PYVER=%%v"
for /f "tokens=1,2 delims=." %%a in ("!PYVER!") do (
    if %%a LSS 3 (
        echo Error: Python 3.3+ required, found !PYVER!
        exit /b 1
    )
    if %%a EQU 3 if %%b LSS 3 (
        echo Error: Python 3.3+ required, found !PYVER!
        exit /b 1
    )
)
echo [OK] Python !PYVER!

:: Locate vswhere
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "!VSWHERE!" (
    echo Error: vswhere.exe not found at !VSWHERE!
    echo Install Visual Studio Build Tools.
    exit /b 1
)
echo [OK] vswhere found

:: Locate MSBuild via vswhere (use temp file to avoid for /f quoting issues)
set "VSWHERE_TMP=%TEMP%\vswhere_msbuild.tmp"
"!VSWHERE!" -latest -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" > "!VSWHERE_TMP!" 2>nul
for /f "usebackq delims=" %%p in ("!VSWHERE_TMP!") do (
    set "MSBUILD=%%p"
)
del "!VSWHERE_TMP!" >nul 2>nul
if not defined MSBUILD (
    echo Error: MSBuild not found. Install Visual Studio Build Tools with C++ workload.
    exit /b 1
)
echo [OK] MSBuild: !MSBUILD!

:: Detect VS major version for premake generator (use temp file)
set "VSWHERE_TMP=%TEMP%\vswhere_vsver.tmp"
"!VSWHERE!" -latest -property installationVersion > "!VSWHERE_TMP!" 2>nul
for /f "usebackq tokens=1 delims=." %%v in ("!VSWHERE_TMP!") do (
    set "VS_MAJOR=%%v"
)
del "!VSWHERE_TMP!" >nul 2>nul
if "!VS_MAJOR!"=="18" (
    set "VS_GEN=vs2026"
) else if "!VS_MAJOR!"=="17" (
    set "VS_GEN=vs2022"
) else if "!VS_MAJOR!"=="16" (
    set "VS_GEN=vs2019"
) else if "!VS_MAJOR!"=="15" (
    set "VS_GEN=vs2017"
) else (
    echo Error: Unsupported Visual Studio major version !VS_MAJOR!
    exit /b 1
)
echo [OK] Visual Studio generator: !VS_GEN!

:: ------------------------------------------------------------
:: Idempotency check
:: ------------------------------------------------------------

set "LIB_PATH=libs\odin-imgui\imgui_windows_x64.lib"

if "!FORCE!"=="0" (
    if exist "!LIB_PATH!" (
        echo Already built: !LIB_PATH! exists.
        echo Use --force or --rebuild to do a clean rebuild.
        exit /b 0
    )
)

:: ------------------------------------------------------------
:: Force cleanup
:: ------------------------------------------------------------

if "!FORCE!"=="1" (
    echo Cleaning previous build artifacts...
    if exist "libs\odin-imgui\build\" rmdir /s /q "libs\odin-imgui\build"
    if exist "!LIB_PATH!" del /q "!LIB_PATH!"
)

:: ------------------------------------------------------------
:: Build steps
:: ------------------------------------------------------------

echo.
echo === Initializing submodules ===
git submodule update --init --recursive
if errorlevel 1 (
    echo Error: git submodule update failed.
    exit /b 1
)

echo.
echo === Running premake5 ===
pushd libs\odin-imgui
premake5 --backends=win32,dx11,glfw,opengl3 !VS_GEN!
if errorlevel 1 (
    echo Error: premake5 failed.
    popd
    exit /b 1
)
popd

echo.
echo === Building with MSBuild ===
:: vs2026 generates .slnx instead of .sln
set "SLN_FILE=libs\odin-imgui\build\make\windows\ImGui.sln"
if not exist "!SLN_FILE!" set "SLN_FILE=libs\odin-imgui\build\make\windows\ImGui.slnx"
"!MSBUILD!" "!SLN_FILE!" /p:Configuration=Release /p:Platform=x64
if errorlevel 1 (
    echo Error: MSBuild failed.
    exit /b 1
)

:: ------------------------------------------------------------
:: Verify output
:: ------------------------------------------------------------

if not exist "!LIB_PATH!" (
    echo Error: Build completed but !LIB_PATH! was not produced.
    exit /b 1
)

echo.
echo ============================================================
echo Setup complete: !LIB_PATH! built successfully.
echo Run build.bat to compile the project.
echo ============================================================
exit /b 0
