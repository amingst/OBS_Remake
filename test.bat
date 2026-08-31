@echo off
REM Runs every package that has tests. Odin's test runner takes one package at
REM a time, so each gets its own line -- add new ones as they appear.
REM
REM -collection:libs matches build.bat: a test package that transitively
REM imports odin-imgui won't resolve without it.

setlocal
set FLAGS=-collection:libs=libs -vet -vet-shadowing -debug
set FAILED=0

echo === audio ===
odin test src/audio %FLAGS%
if errorlevel 1 set FAILED=1

echo === rtmp ===
odin test src/rtmp %FLAGS% -define:ODIN_TEST_THREADS=1
if errorlevel 1 set FAILED=1

if %FAILED%==1 (
    echo.
    echo === TESTS FAILED ===
    exit /b 1
)

echo.
echo === all tests passed ===
exit /b 0
