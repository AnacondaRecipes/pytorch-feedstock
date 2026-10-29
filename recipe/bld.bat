@echo On
setlocal enabledelayedexpansion

@REM Tells pytorch's setup.py we're in a conda build, preventing
@REM vendored library bundling into the wheel.
set PACKAGE_TYPE=conda

@REM Used by our patched FindCUDAToolkit.cmake to allow overriding
@REM CUDA paths instead of using CMAKE_CUDA_COMPILER_TOOLKIT_ROOT
set IN_PYTORCH_BUILD=1

set PYTORCH_BUILD_VERSION=%PKG_VERSION%
@REM Always pass 0 to avoid appending ".post" to version string.
set PYTORCH_BUILD_NUMBER=0

@REM ========================= PARALLELISM ======================================
@REM Each CUDA compilation job peaks at ~2-4GB RAM.
@REM 6 is safe on our 64GB runners.
set MAX_JOBS=6

@REM ========================= WIN-ARM64 ========================================
if "%target_platform%" == "win-arm64" (
    @REM Memory: the peak is the torch_cpu.dll link - MSVC link.exe over about
    @REM 13.7GB of objects, 12GB+ private. That OOMed the old 16GB PBP workers;
    @REM they are 32GB since 2026-09-24. OpenMP routing is in the openblas
    @REM block below, shared with win-64.
    @REM Parallelism: 2.14's scikit-build-core ignores MAX_JOBS and
    @REM CMAKE_BUILD_PARALLEL_LEVEL never reached ninja; ninja JOB POOLS via
    @REM CMAKE_ARGS are the knob that works. Ordinary TUs run in compile_pool;
    @REM patch 0026 moves torch_python, the generated binding TUs, into its own
    @REM pool. Pools are sized for the 32GB PBP worker, 8 vCPU: with 8 compiles +
    @REM 2 torch_python + 2 links the torch_cpu.dll link peaked at 31.7 of 32 GiB
    @REM and the py3.13 build was watchdog-killed twice - graph 1f996af7. 4/1/1
    @REM leaves headroom for the link at the cost of a slower compile.
    set "CMAKE_ARGS=!CMAKE_ARGS! -DCMAKE_JOB_POOLS=compile_pool=4;torch_python_pool=1;link_pool=1 -DCMAKE_JOB_POOL_COMPILE=compile_pool -DCMAKE_JOB_POOL_LINK=link_pool -DTORCH_PYTHON_JOB_POOL=torch_python_pool"
)

@REM ========================= BLAS SETUP =======================================
if "%blas_impl%" == "openblas" (
    set BLAS=OpenBLAS
    set OpenBLAS_HOME=%LIBRARY_PREFIX%
) else if "%blas_impl%" == "mkl" (
    set BLAS=MKL
    set INTEL_MKL_DIR=%LIBRARY_PREFIX%
) else (
    echo [ERROR] Unsupported BLAS implementation: %blas_impl%
    exit /b 1
)

@REM Win openblas OpenMP, both win-64 and win-arm64: route MSVC's LLVM OpenMP
@REM mode to conda llvm-openmp so torch_cpu.dll links the provided libomp.dll
@REM instead of libomp140.<arch>.dll or vcomp140.dll, which no conda package
@REM provides. Ref anaconda-issues 13513. win+mkl uses intel-openmp instead.
@REM Forward slashes: scikit-build-core splits CMAKE_ARGS shlex-style and
@REM eats backslashes.
if "%blas_impl%" == "openblas" (
    set "CMAKE_ARGS=!CMAKE_ARGS! -DOpenMP_C_FLAGS=/openmp:llvm -DOpenMP_CXX_FLAGS=/openmp:llvm -DOpenMP_C_LIB_NAMES=libomp -DOpenMP_CXX_LIB_NAMES=libomp -DOpenMP_libomp_LIBRARY=%LIBRARY_LIB:\=/%/libomp.lib"
)

@REM ========================= COMMON BUILD FLAGS ===============================
set "BUILD_CUSTOM_PROTOBUF=OFF"
set "USE_LITE_PROTO=ON"
set "USE_ITT=0"
set "USE_NUMA=0"
set "USE_OPENMP=ON"
set "USE_TENSORPIPE=0"
set "USE_KINETO=OFF"
set "INSTALL_TEST=0"
set "BUILD_TEST=0"

@REM Use system packages instead of vendored copies
set USE_SYSTEM_EIGEN_INSTALL=1
set USE_SYSTEM_PYBIND11=1
set USE_SYSTEM_SLEEF=1

@REM workaround to stop setup.py from checking submodule status
if EXIST .gitmodules del .gitmodules

@REM ========================= CUDA SETUP =======================================
if "%gpu_variant:~0,4%" == "cuda" (
    set USE_CUDA=1
    set "USE_MKLDNN=1"
    set USE_STATIC_CUDNN=0
    set USE_CUFILE=0
    @REM NCCL is not available on Windows
    set USE_NCCL=0
    set USE_STATIC_NCCL=0

    @REM CUDA Architecture List: matches upstream PyTorch 2.15 TORCH_CUDA_ARCH_LIST_TABLE
    @REM in .ci/wheel/windows/build_env_setup.py for 12.9 and 13.x.
    @REM  7.5 = Turing     (RTX 20xx, T4)
    @REM  8.0 = Ampere HPC (A100)
    @REM  8.6 = Ampere     (RTX 30xx)
    @REM  9.0 = Hopper     (H100, H200)
    @REM 10.0 = Blackwell  (GB200, B200)
    @REM 12.0 = Blackwell  (RTX 50xx, RTX PRO)
    @REM sm_70 (Volta/V100) dropped upstream in 2.11 for CUDA 12 and CUDA 13.
    @REM We deliberately keep trailing +PTX for forward-compat with future archs
    @REM (sm_13+). Upstream release wheels are SASS-only; only nightlies add +PTX.
    @REM We keep it so users on hardware newer than sm_12 still get JIT-runnable kernels.
    set "cuda_major=%cuda_compiler_version:~0,2%"
    if "!cuda_major!" == "12" (
        set "TORCH_CUDA_ARCH_LIST=7.5;8.0;8.6;9.0;10.0;12.0+PTX"
    ) else if "!cuda_major!" == "13" (
        set "TORCH_CUDA_ARCH_LIST=7.5;8.0;8.6;9.0;10.0;12.0+PTX"
        @REM win-arm64: win-64 list plus 12.1 - the NVIDIA N1X / GB10-class GPU
        @REM that ships in Windows-on-ARM machines gets its own SASS; 12.0 SASS
        @REM would also run on it, since the major version is the same.
        if "%target_platform%" == "win-arm64" set "TORCH_CUDA_ARCH_LIST=7.5;8.0;8.6;9.0;10.0;12.0;12.1+PTX"
    ) else (
        echo [ERROR] No CUDA architecture list exists for CUDA v%cuda_compiler_version%
        echo Use https://en.wikipedia.org/wiki/CUDA#GPUs_supported to make one.
        exit /b 1
    )
    @REM TORCH_NVCC_FLAGS: --threads 2 parallelizes nvcc within each translation unit.
    @REM Do NOT set BUILD_BUNDLE_PTXAS on Windows: pytorch's CMakeLists.txt:1467
    @REM does `file(COPY "${CUDAToolkit_BIN_DIR}/ptxas" ...)` with the literal
    @REM Linux name `ptxas` — on Windows the binary is `ptxas.exe`, so the
    @REM copy fails with "cannot find ... ptxas: File exists". Master (2.11)
    @REM never set it on win; we don't need PTXAS bundled on win either.
    set "TORCH_NVCC_FLAGS=-Xfatbin -compress-all --threads 2"

    @REM Suppress extremely noisy ptxas advisories that bloat logs
    set "CMAKE_CUDA_FLAGS=-w -Xptxas -w"
    @REM Disable cuSPARSELt: the conda package doesn't exist in defaults channels,
    @REM and it's only needed for semi-structured (2:4) sparsity ops which most users don't need.
    set USE_CUSPARSELT=0
    @REM Disable cuDSS: the conda package (libcudss-dev) doesn't exist in defaults channels,
    @REM and it's only needed for sparse direct solvers on CSR tensors which most users don't need.
    set USE_CUDSS=0

    set MAGMA_HOME=%LIBRARY_PREFIX%
    set "PATH=%CUDA_BIN_PATH%;%PATH%"
    set CUDNN_INCLUDE_DIR=%LIBRARY_PREFIX%\include
    set "CUDA_VERSION=%cuda_compiler_version%"

    @REM ==================== libcudacxx clusterlaunchcontrol patch ===============
    @REM cuda-cccl_win-64 12.9.27 ships a libcudacxx header with an asm-constraint
    @REM bug that fails to compile on Windows MSVC:
    @REM   clusterlaunchcontrol.h(78): error: asm operand type size(4) does not
    @REM   match type/size implied by constraint 'l'
    @REM Root cause: the header casts to `long2*` and feeds .x/.y into asm with
    @REM constraint 'l' (64-bit). On Linux x86_64 LP64 `long` is 64-bit (works);
    @REM on Windows MSVC LLP64 `long` is 32-bit (size mismatch). Fixed upstream
    @REM in CUDA 13.0+. For 12.9 we sed-replace long2 with longlong2 (64-bit on
    @REM both platforms) in the host- and build-env copies of the header.
    if "%cuda_compiler_version%"=="12.9" (
        powershell -NoProfile -Command "@('%BUILD_PREFIX%','%PREFIX%') | ForEach-Object { $p = Join-Path $_ 'Library\include\targets\x64\cuda\__ptx\instructions\generated\clusterlaunchcontrol.h'; if (Test-Path $p) { $orig = Get-Content $p -Raw; $patched = $orig -replace 'reinterpret_cast<long2\*>', 'reinterpret_cast<longlong2*>'; if ($patched -ne $orig) { Set-Content -Path $p -Value $patched -NoNewline; Write-Host \"libcudacxx patch applied: $p\" } } }"
    )
) else (
    set USE_CUDA=0
    set "USE_MKLDNN=1"
    @REM On Windows, env vars are case-insensitive and setup.py passes all
    @REM env vars starting with CUDA_*, CMAKE_* to cmake. Clear them.
    set "cuda_compiler_version="
    set "cuda_compiler="
    set "CUDA_VERSION="
)

@REM ========================= CMAKE CONFIGURATION ==============================
set DISTUTILS_USE_SDK=1
set CMAKE_INCLUDE_PATH=%LIBRARY_PREFIX%\include
set LIB=%LIBRARY_PREFIX%\lib;%LIB%

set CMAKE_GENERATOR=Ninja
set "CMAKE_GENERATOR_TOOLSET="
set "CMAKE_GENERATOR_PLATFORM="
set "CMAKE_PREFIX_PATH=%LIBRARY_PREFIX%"
set "CMAKE_INCLUDE_PATH=%LIBRARY_INC%"
set "CMAKE_LIBRARY_PATH=%LIBRARY_LIB%"
set "CMAKE_BUILD_TYPE=Release"
set Python_EXECUTABLE=%PYTHON%
set Python3_EXECUTABLE=%PYTHON%
set Python_ROOT_DIR=%PREFIX%

set "libuv_ROOT=%LIBRARY_PREFIX%"

@REM Increase MSVC precompiled header memory limit.
@REM PyTorch has very large translation units that can hit compiler OOM without this.
set "CFLAGS=/Zm800 %CFLAGS%"
set "CXXFLAGS=/Zm800 %CXXFLAGS%"

@REM The activation script for cuda-nvcc doesn't add CUDA_CFLAGS on Windows.
@REM https://github.com/conda-forge/cuda-nvcc-feedstock/issues/47
set "CUDA_CFLAGS=-I%PREFIX%/Library/include -I%BUILD_PREFIX%/Library/include"
set "CFLAGS=%CFLAGS% %CUDA_CFLAGS%"
set "CPPFLAGS=%CPPFLAGS% %CUDA_CFLAGS%"
set "CXXFLAGS=%CXXFLAGS% %CUDA_CFLAGS%"

@REM ========================= BUILD PHASE ======================================
if "%PKG_NAME%" == "pytorch" (
    set "PIP_ACTION=install"
    set "PIP_VERBOSITY=-v"
) else (
    @REM libtorch: build wheel, then extract non-Python parts
    set "PIP_ACTION=wheel"
    set "PIP_VERBOSITY=-v"
)

@REM Use pip instead of raw setup.py for a cleaner build flow.
@REM --no-clean preserves build dir so CMake can do incremental work.
@REM --no-build-isolation uses our conda environment packages.
@REM (2.14's scikit-build-core backend rejects the legacy --global-option config-setting.)
@REM win-arm64 megabuild: the libtorch output compiles the tree once against
@REM megabuild_python; each pytorch output reuses build\ after win_megabuild.py
@REM refreshes the Python entries in CMakeCache.txt (build.sh does this with sed).
set "MEGABUILD_WIN="
if /i "%megabuild%" == "true" if "%target_platform%" == "win-arm64" set "MEGABUILD_WIN=1"
echo megabuild=%megabuild% MEGABUILD_WIN=%MEGABUILD_WIN% PKG_NAME=%PKG_NAME%
set "PIP_EXTRA="
if defined MEGABUILD_WIN if "%PKG_NAME%" == "pytorch" (
    "%PYTHON%" "%RECIPE_DIR%\win_megabuild.py" prepare
    if errorlevel 1 exit 1
    set "PIP_EXTRA=-Cbuild.verbose=true "-Cbuild.tool-args=-d;explain""
)

"%PYTHON%" -m pip %PIP_ACTION% . --no-build-isolation --no-deps %PIP_VERBOSITY% --no-clean %PIP_EXTRA%
if %ERRORLEVEL% neq 0 exit 1

if defined MEGABUILD_WIN if "%PKG_NAME%" == "libtorch" (
    "%PYTHON%" "%RECIPE_DIR%\win_megabuild.py" save
    if errorlevel 1 exit 1
)
if defined MEGABUILD_WIN if "%PKG_NAME%" == "pytorch" (
    "%PYTHON%" "%RECIPE_DIR%\win_megabuild.py" report
    if errorlevel 1 exit 1
)

@REM %SP_DIR% still renders Lib\site-packages, but Python 3.15 on Windows installs to
@REM lib\python\site-packages (the nt_conda scheme), so ask the host Python.
set "PY_PLATLIB="
for /f "usebackq delims=" %%i in (`call "%PYTHON%" -c "import sysconfig; print(sysconfig.get_path('platlib'))"`) do set "PY_PLATLIB=%%i"
if not defined PY_PLATLIB exit 1
set "SP_DIR=%PY_PLATLIB%"

@REM ========================= PACKAGE SPLIT ====================================
@REM Use `if errorlevel N` (evaluated when the line runs), not %ERRORLEVEL%, which
@REM inside a parenthesized block is expanded once when the block is parsed.
@REM robocopy exit codes 0-7 are success (1 = files copied); 8 and above are failures.
if "%PKG_NAME%" == "libtorch" (
    if not exist "%SRC_DIR%\dist" mkdir "%SRC_DIR%\dist"
    pushd "%SRC_DIR%\dist"
    if errorlevel 1 exit 1
    for /f "delims=" %%f in ('dir /b /S ..\torch-*.whl') do (
        wheel unpack "%%f"
        if errorlevel 1 exit 1
    )

    pushd torch-*
    if errorlevel 1 exit 1

    @REM Move non-Python binaries into conda Library locations
    robocopy /NP /NFL /NDL /NJH /E torch\bin "%LIBRARY_BIN%" torch*.dll c10.dll shm.dll asmjit.dll fbgemm.dll dnnl.dll
    if errorlevel 8 exit 1
    robocopy /NP /NFL /NDL /NJH /E torch\lib "%LIBRARY_LIB%" torch*.lib c10.lib shm.lib asmjit.lib fbgemm.lib dnnl.lib
    if errorlevel 8 exit 1
    if "%gpu_variant:~0,4%" == "cuda" (
        robocopy /NP /NFL /NDL /NJH /E torch\bin "%LIBRARY_BIN%" c10_cuda.dll caffe2_nvrtc.dll
        if errorlevel 8 exit 1
        robocopy /NP /NFL /NDL /NJH /E torch\lib "%LIBRARY_LIB%" c10_cuda.lib caffe2_nvrtc.lib
        if errorlevel 8 exit 1
    )
    robocopy /NP /NFL /NDL /NJH /E torch\share "%LIBRARY_PREFIX%\share"
    if errorlevel 8 exit 1
    for %%f in (ATen caffe2 torch c10) do (
        robocopy /NP /NFL /NDL /NJH /E torch\include\%%f "%LIBRARY_INC%\%%f"
        if errorlevel 8 exit 1
    )

    @REM Remove Python-specific binary; that belongs in the pytorch package
    del "%LIBRARY_BIN%\torch_python.*" "%LIBRARY_LIB%\torch_python.*"
    if exist "%LIBRARY_BIN%\torch_python.dll" exit 1

    popd
    popd
) else if "%PKG_NAME%" == "pytorch" (
    if not exist "%SP_DIR%\torch\bin\torch_python.dll" exit 1
    @REM Move libtorch_python into LIBRARY and clean vendored copies
    robocopy /NP /NFL /NDL /NJH /E "%SP_DIR%\torch\bin" "%LIBRARY_BIN%" torch_python.dll
    if errorlevel 8 exit 1
    robocopy /NP /NFL /NDL /NJH /E "%SP_DIR%\torch\lib" "%LIBRARY_LIB%" torch_python.lib
    if errorlevel 8 exit 1
    for %%f in (bin\torch_python.dll lib\torch_python.lib) do (
        if not exist "%LIBRARY_PREFIX%\%%f" exit 1
    )
    rmdir /s /q "%SP_DIR%\torch\lib"
    rmdir /s /q "%SP_DIR%\torch\bin"
    rmdir /s /q "%SP_DIR%\torch\share"
    for %%f in (ATen caffe2 torch c10) do (
        rmdir /s /q "%SP_DIR%\torch\include\%%f"
    )
    for %%d in (lib bin share include\ATen include\caffe2 include\torch include\c10) do (
        if exist "%SP_DIR%\torch\%%d" exit 1
    )

    @REM Copy Python-specific libs back for torch's internal import machinery.
    @REM Copy, not move: cpp_extension links against TORCH_LIB_PATH, which
    @REM patch 0015 points at Library\lib, so torch_python.lib must stay there
    @REM too (test_autograd test_multi_grad_all_hooks failed LNK1181 without it).
    mkdir "%SP_DIR%\torch\lib"
    robocopy /NP /NFL /NDL /NJH /E "%LIBRARY_LIB%" "%SP_DIR%\torch\lib" torch_python.lib
    if errorlevel 8 exit 1
)

exit /b 0