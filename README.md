## Quick Start

```
git clone --recurse-submodules https://github.com/amingst/OBS_Remake.git
cd OBS_Remake
setup.bat
build.bat
```

## Prerequisites

The following tools must be installed and available on your PATH before running `setup.bat`.

### Git

Required for cloning and initializing submodules.

### Odin Lang

Install the Odin language and add to PATH.
https://odin-lang.org/docs/install/

### Premake5

Required for generating the imgui build files. Download and add to PATH.
https://premake.github.io/download

### Python 3.3+

Required by Dear Bindings to generate C bindings for imgui during setup.

### Visual Studio with C++ workload

`setup.bat` requires a Visual Studio installation (Community, Professional, or Build Tools) with the **Desktop development with C++** workload. This provides MSBuild and the MSVC compiler. Supported versions: VS 2017, 2019, 2022, and 2026. The script auto-detects the latest installed version via `vswhere`.

### D3D11 Debug Layer (optional)

The D3D11 debug layer requires the "Graphics Tools" optional Windows feature. Install via Settings > Apps > Optional features > Add a feature > Graphics Tools.

## Building

### `setup.bat`

Run once to initialize git submodules, generate imgui build files with premake5, and compile the imgui static library (`imgui_windows_x64.lib`) with MSBuild. The script is idempotent -- if the library already exists, it exits early.

What it does:
1. Validates prerequisites (git, premake5, python, MSBuild)
2. Initializes git submodules (`libs/odin-imgui`)
3. Runs premake5 to generate a Visual Studio solution for imgui (with win32, dx11, glfw, and opengl3 backends)
4. Builds the solution with MSBuild (Release, x64)
5. Verifies `libs/odin-imgui/imgui_windows_x64.lib` was produced

To force a clean rebuild of the imgui library:

```
setup.bat --force
```

### `build.bat`

Compiles the project with the Odin compiler:

```
odin build src -out:build/app.exe -collection:libs=libs -vet -vet-shadowing -debug
```

## Packages

### odin-imgui

https://github.com/Capati/odin-imgui
