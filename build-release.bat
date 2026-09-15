@echo off

if not exist "libs\odin-imgui\imgui_windows_x64.lib" (
    echo Error: imgui_windows_x64.lib not found. Run setup.bat first.
    exit /b 1
)

odin build src -out:build/OBS_Remake.exe -collection:libs=libs -vet -vet-shadowing -o:speed
