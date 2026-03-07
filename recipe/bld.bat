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
if not "%cuda_compiler_version%" == "None" (
    set USE_CUDA=1
    set "USE_MKLDNN=1"
    set USE_STATIC_CUDNN=0
    set USE_CUFILE=0
    @REM NCCL is not available on Windows
    set USE_NCCL=0
    set USE_STATIC_NCCL=0

    @REM CUDA Architecture List
    @REM  7.5 = Turing     (RTX 20xx, T4)
    @REM  8.0 = Ampere HPC (A100)
    @REM  8.6 = Ampere     (RTX 30xx)
    @REM  8.9 = Ada        (RTX 40xx, L4, L40)
    @REM  9.0 = Hopper     (H100, H200)
    @REM 10.0 = Blackwell  (B100, B200, RTX 50xx)
    @REM +PTX = forward compat via JIT for future archs
    set "TORCH_CUDA_ARCH_LIST=7.5;8.0;8.6;8.9;9.0;10.0+PTX"
    set "TORCH_NVCC_FLAGS=-Xfatbin -compress-all"

    @REM Suppress extremely noisy ptxas advisories that bloat logs
    set "CMAKE_CUDA_FLAGS=-w -Xptxas -w"

    set MAGMA_HOME=%LIBRARY_PREFIX%
    set "PATH=%CUDA_BIN_PATH%;%PATH%"
    set CUDNN_INCLUDE_DIR=%LIBRARY_PREFIX%\include
    set "CUDA_VERSION=%cuda_compiler_version%"
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
@REM --config-settings=--global-option=-q reduces setup.py noise.
%PYTHON% -m pip %PIP_ACTION% . --no-build-isolation --no-deps %PIP_VERBOSITY% --no-clean --config-settings=--global-option=-q
if %ERRORLEVEL% neq 0 exit 1

@REM ========================= PACKAGE SPLIT ====================================
if "%PKG_NAME%" == "libtorch" (
    if not exist "%SRC_DIR%\dist" mkdir %SRC_DIR%\dist
    pushd %SRC_DIR%\dist
    for /f %%f in ('dir /b /S ..\torch-*.whl') do (
        wheel unpack %%f
        if %ERRORLEVEL% neq 0 exit 1
    )

    pushd torch-*
    if %ERRORLEVEL% neq 0 exit 1

    @REM Move non-Python binaries into conda Library locations
    robocopy /NP /NFL /NDL /NJH /E torch\bin\ %LIBRARY_BIN%\ torch*.dll c10.dll shm.dll asmjit.dll fbgemm.dll dnnl.dll
    robocopy /NP /NFL /NDL /NJH /E torch\lib\ %LIBRARY_LIB%\ torch*.lib c10.lib shm.lib asmjit.lib fbgemm.lib dnnl.lib
    if not "%cuda_compiler_version%" == "None" (
        robocopy /NP /NFL /NDL /NJH /E torch\bin\ %LIBRARY_BIN%\ c10_cuda.dll caffe2_nvrtc.dll
        robocopy /NP /NFL /NDL /NJH /E torch\lib\ %LIBRARY_LIB%\ c10_cuda.lib caffe2_nvrtc.lib
    )
    robocopy /NP /NFL /NDL /NJH /E torch\share\ %LIBRARY_PREFIX%\share
    for %%f in (ATen caffe2 torch c10) do (
        robocopy /NP /NFL /NDL /NJH /E torch\include\%%f %LIBRARY_INC%\%%f\
    )

    @REM Remove Python-specific binary; that belongs in the pytorch package
    del %LIBRARY_BIN%\torch_python.* %LIBRARY_LIB%\torch_python.*
    if %ERRORLEVEL% neq 0 exit 1

    popd
    popd
) else if "%PKG_NAME%" == "pytorch" (
    @REM Move libtorch_python into LIBRARY and clean vendored copies
    robocopy /NP /NFL /NDL /NJH /E %SP_DIR%\torch\bin\ %LIBRARY_BIN%\ torch_python.dll
    robocopy /NP /NFL /NDL /NJH /E %SP_DIR%\torch\lib\ %LIBRARY_LIB%\ torch_python.lib
    robocopy /NP /NFL /NDL /NJH /E %SP_DIR%\torch\lib\ %LIBRARY_LIB%\ _C.lib
    rmdir /s /q %SP_DIR%\torch\lib
    rmdir /s /q %SP_DIR%\torch\bin
    rmdir /s /q %SP_DIR%\torch\share
    for %%f in (ATen caffe2 torch c10) do (
        rmdir /s /q %SP_DIR%\torch\include\%%f
    )

    @REM Copy Python-specific libs back for torch's internal import machinery
    mkdir %SP_DIR%\torch\lib
    robocopy /NP /NFL /NDL /NJH /E /MOV %LIBRARY_LIB%\ %SP_DIR%\torch\lib\ torch_python.lib _C.lib
)

@REM Robocopy exit codes: 0=nothing copied, 1=files copied, 2=extras found,
@REM 4=mismatched. Codes <=7 are success. Only >=8 indicates failure.
if %ERRORLEVEL% leq 7 set ERRORLEVEL=0
if %ERRORLEVEL% neq 0 exit 1
exit /b 0