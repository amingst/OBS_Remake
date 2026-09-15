@echo off

if not exist "libs\odin-imgui\imgui_windows_x64.lib" (
    echo Error: imgui_windows_x64.lib not found. Run setup.bat first.
    exit /b 1
)

if not exist "build" mkdir build

odin build src -out:build/app.exe -collection:libs=libs -vet -vet-shadowing -debug
