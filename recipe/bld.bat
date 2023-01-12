@echo On

rmdir /s/q build

:: set TH_BINARY_BUILD=1
set PYTORCH_BUILD_VERSION=%PKG_VERSION%
set PYTORCH_BUILD_NUMBER=%PKG_BUILDNUM%

:: uncomment to debug cmake build
set CMAKE_VERBOSE_MAKEFILE=1

if "%pytorch_variant%" == "gpu" (
    set build_with_cuda=1
    set desired_cuda=%CUDA_VERSION:~0,-1%.%CUDA_VERSION:~-1,1%
) else (
    set build_with_cuda=
    set USE_CUDA=0
)

:: =============================== CUDA> ======================================
if "%build_with_cuda%" == "" goto cuda_flags_end

set CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v%desired_cuda%
set CUDA_BIN_PATH=%CUDA_PATH%\bin
set TORCH_CUDA_ARCH_LIST=3.5;5.0+PTX

if "%desired_cuda%" == "9.0" (
    set TORCH_CUDA_ARCH_LIST=%TORCH_CUDA_ARCH_LIST%;6.0;7.0
)
if "%desired_cuda%" == "9.2" (
    set TORCH_CUDA_ARCH_LIST=%TORCH_CUDA_ARCH_LIST%;6.0;6.1;7.0
)
if "%desired_cuda%" == "10.0" (
    set TORCH_CUDA_ARCH_LIST=%TORCH_CUDA_ARCH_LIST%;6.0;6.1;7.0;7.5
)

set TORCH_NVCC_FLAGS=-Xfatbin -compress-all

set MAGMA_HOME=%LIBRARY_PREFIX%
set "PATH=%CUDA_BIN_PATH%;%PATH%"
set CUDNN_INCLUDE_DIR=%LIBRARY_PREFIX%\include

:cuda_flags_end
:: =============================== CUDA< ======================================


set DISTUTILS_USE_SDK=1
set BUILD_TEST=0
set CPU_COUNT=2
set MAX_JOBS=%CPU_COUNT%
:: Use our Pybind11, Eigen
set USE_SYSTEM_PYBIND11=1
set USE_SYSTEM_EIGEN_INSTALL=1

set CMAKE_GENERATOR=Ninja
set CMAKE_INCLUDE_PATH=%LIBRARY_PREFIX%\include
set LIB=%LIBRARY_PREFIX%\lib;%LIB%
set CMAKE_PREFIX_PATH=%LIBRARY_PREFIX%
set CMAKE_BUILD_TYPE=Release
:: This is so that CMake finds the environment's Python, not another one
set Python_EXECUTABLE=%PYTHON%
set Python3_EXECUTABLE=%PYTHON%

:: This is the default, but just in case it changes, one day.
set BUILD_DOCS=OFF

%PYTHON% -m pip install . ^
    --no-deps ^
    --no-binary :all: ^
    --no-clean ^
    -vvv
if errorlevel 1 exit /b 1
