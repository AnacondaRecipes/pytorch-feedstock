@echo On
setlocal enabledelayedexpansion

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

:: TODO(baszalmstra): Figure out if we need these flags
SET "USE_NUMA=0"
SET "USE_ITT=0"
:: KINETO seems to require CUPTI and will look quite hard for it.
:: CUPTI seems to cause trouble when users install a version of
:: cudatoolkit different than the one specified at compile time.
:: https://github.com/conda-forge/pytorch-cpu-feedstock/issues/135
set "USE_KINETO=OFF"

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
set INSTALL_TEST=0
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
set "CMAKE_GENERATOR_TOOLSET="
set "CMAKE_GENERATOR_PLATFORM="
set "CMAKE_PREFIX_PATH=%LIBRARY_PREFIX%"
set "CMAKE_INCLUDE_PATH=%LIBRARY_INC%"
set "CMAKE_LIBRARY_PATH=%LIBRARY_LIB%"
set "CMAKE_BUILD_TYPE=Release"
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
set "USE_SYSTEM_SLEEF=ON"

:: Use our protobuf
set "BUILD_CUSTOM_PROTOBUF=OFF"
set "USE_LITE_PROTO=ON"

:: Here we split the build into two parts.
:: 
:: Both the packages libtorch and pytorch use this same build script.
:: - The output of the libtorch package should just contain the binaries that are 
::   not related to Python.
:: - The output of the pytorch package contains everything except for the 
::   non-python specific binaries.
::
:: This ensures that a user can quickly switch between python versions without the
:: need to redownload all the large CUDA binaries.

if "%PKG_NAME%" == "libtorch" (
  :: For the main script we just build a wheel for so that the C++/CUDA
  :: parts are built. Then they are reused in each python version.
  set BUILD_LIBTORCH_WHL=1
  set BUILD_PYTHON_ONLY=0

  %PYTHON% setup.py bdist_wheel
  %PYTHON% -m pip install --find-links=dist torch_no_python --no-build-isolation --no-deps

  :: building libtorch generates an empty __init__.py file. We don't want to package that, it should come from pytorch.
  rm %SP_DIR%\torch\__init__.py
) else (
  set BUILD_LIBTORCH_WHL=0
  :: In theory we want BUILD_PYTHON_ONLY=1 but that ends up causing lots of linking problems.
  :: set BUILD_PYTHON_ONLY=1

  :: NOTE: Passing --cmake is necessary here since the torch frontend has it's
  :: own cmake files that it needs to generate
  %PYTHON% setup.py bdist_wheel --cmake
  %PYTHON% -m pip install --find-links=dist torch --no-build-isolation --no-deps
)

if errorlevel 1 exit /b 1

