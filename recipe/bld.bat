@echo On

:: The PyTorch test suite includes some symlinks, which aren't resolved on Windows, leading to packaging errors.
:: ATTN! These change and have to be updated manually, often with each release. 
:: (no current symlinks being packaged. Leaving this information here as it took some months to find the issue. Look out
:: for a failure with error message: "conda_package_handling.exceptions.ArchiveCreationError: <somefile> Cannot stat
:: while writing file")

set TH_BINARY_BUILD=1
set PYTORCH_BUILD_VERSION=%PKG_VERSION%
set PYTORCH_BUILD_NUMBER=%PKG_BUILDNUM%

:: uncomment to debug cmake build
:: set CMAKE_VERBOSE_MAKEFILE=1

if "%pytorch_variant%" == "gpu" (
    set build_with_cuda=1
    set desired_cuda=%CUDA_VERSION:~0,-1%.%CUDA_VERSION:~-1,1%
) else (
    set build_with_cuda=
    set USE_CUDA=0
)

set "PIP_ACTION=install"

if "%PKG_NAME%" == "pytorch" (
  set BUILD_PYTHON_ONLY=1
  set BUILD_LIBTORCH_WHL=
  set BUILD_PYTHON=ON
  set CMAKE_ARGS=-DBUILD_PYTHON=ON
) else (
  :: For the main script we just build a wheel for so that the C++/CUDA
  :: parts are built. Then they are reused in each python version.
  :: Skip building functorch when building libtorch
  set BUILD_LIBTORCH_WHL=1
)

:: =============================== CUDA FLAGS> ======================================
if "%build_with_cuda%" == "" goto cuda_flags_end

set CUDA_PATH=C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v%desired_cuda%
set CUDA_BIN_PATH=%CUDA_PATH%\bin
set TORCH_CUDA_ARCH_LIST=3.5;5.0+PTX
if "%desired_cuda%" == "9.0" set TORCH_CUDA_ARCH_LIST=%TORCH_CUDA_ARCH_LIST%;6.0;7.0
if "%desired_cuda%" == "9.2" set TORCH_CUDA_ARCH_LIST=%TORCH_CUDA_ARCH_LIST%;6.0;6.1;7.0
if "%desired_cuda%" == "10.0" set TORCH_CUDA_ARCH_LIST=%TORCH_CUDA_ARCH_LIST%;6.0;6.1;7.0;7.5
set TORCH_NVCC_FLAGS=-Xfatbin -compress-all

:cuda_flags_end
:: =============================== CUDA FLAGS< ======================================

set USE_MKLDNN=1

:: Tensorpipe cannot be used on windows
set USE_TENSORPIPE=0
set DISTUTILS_USE_SDK=1
set BUILD_TEST=0
:: Don't increase MAX_JOBS to NUMBER_OF_PROCESSORS, as it will run out of heap
set CPU_COUNT=1
set MAX_JOBS=%CPU_COUNT%
:: Use our Pybind11, Eigen
set USE_SYSTEM_PYBIND11=1
set USE_SYSTEM_EIGEN_INSTALL=1

set CMAKE_INCLUDE_PATH=%LIBRARY_PREFIX%\include
set LIB=%LIBRARY_PREFIX%\lib;%LIB%

:: =============================== CUDA> ======================================
IF "%build_with_cuda%" == "" goto cuda_end

set MAGMA_HOME=%LIBRARY_PREFIX%

set "PATH=%CUDA_BIN_PATH%;%PATH%"

set CUDNN_INCLUDE_DIR=%LIBRARY_PREFIX%\include

:cuda_end
:: =============================== CUDA< ======================================

set CMAKE_GENERATOR=Ninja
set "CMAKE_GENERATOR_PLATFORM="
set "CMAKE_PREFIX_PATH=%LIBRARY_PREFIX%"
set CMAKE_BUILD_TYPE=Release
set CMAKE_INSTALL_RPATH=%LIBRARY_BIN%
:: This is so that CMake finds the environment's Python, not another one
set Python_EXECUTABLE=%PYTHON%
set Python3_EXECUTABLE=%PYTHON%

:: This is the default, but just in case it changes, one day.
set BUILD_DOCS=OFF

:: Force usage of MKL. If MKL can't be found, cmake will raise an error.
set BLAS=MKL

:: Tell Pytorch's embedded FindMKL where to find MKL.
set INTEL_MKL_DIR=%LIBRARY_PREFIX%

set "libuv_ROOT=%LIBRARY_PREFIX%"
set "USE_SYSTEM_SLEEF=OFF"
:: Note that BUILD_CUSTOM_PROTOBUF=OFF (which would use our protobuf) doesn't work properly as of last testing, and results in
:: duplicate symbols at link time.
:: set "BUILD_CUSTOM_PROTOBUF=OFF"
set C10_BUILD_SHARED_LIBS=1
set BUILD_SHARED_LIBS=1

:: Clear the build from any remaining artifacts.
cmake --build build --target clean

%PYTHON% -m pip install . --no-deps --no-build-isolation -vv
if errorlevel 1 exit /b 1