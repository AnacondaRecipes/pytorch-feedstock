#!/bin/bash

set -ex

# clean up an existing cmake build directory
rm -rf build

# uncomment to debug cmake build
#export CMAKE_VERBOSE_MAKEFILE=1

# Worked previously, but with PyTorch >=1.6.0, use of the `-pie` linker flag
# triggers `std::__cxx11::basic_string`-related undefined reference errors.
#export LDFLAGS="-Wl,-pie -Wl,-headerpad_max_install_names -Wl,-rpath,$PREFIX/lib -L$PREFIX/lib"
#export LDFLAGS_LD="-Wl,-pie -Wl,-headerpad_max_install_names -Wl,-rpath,$PREFIX/lib -L$PREFIX/lib"

LDFLAGS="${LDFLAGS//-Wl,--as-needed/}"
LDFLAGS="${LDFLAGS//-Wl,-dead_strip_dylibs/}"
LDFLAGS_LD="${LDFLAGS_LD//-dead_strip_dylibs/}"

# Dynamic libraries need to be lazily loaded so that torch
# can be imported on system without a GPU
LDFLAGS="${LDFLAGS//-Wl,-z,now/-Wl,-z,lazy}"

export CMAKE_SYSROOT=$CONDA_BUILD_SYSROOT
export CMAKE_LIBRARY_PATH=$PREFIX/lib:$PREFIX/include:$CMAKE_LIBRARY_PATH
export CMAKE_PREFIX_PATH=$PREFIX
export TH_BINARY_BUILD=1
export PYTORCH_BUILD_VERSION=$PKG_VERSION
export PYTORCH_BUILD_NUMBER=$PKG_BUILDNUM

export USE_NINJA=OFF
export INSTALL_TEST=0

# MacOS build is simple, and will not be for CUDA
if [[ "$OSTYPE" == "darwin"* ]]; then
    export MACOSX_DEPLOYMENT_TARGET=10.10
    export CMAKE_OSX_SYSROOT=/opt/MacOSX10.10.sdk
    python -m pip install . --no-deps -vv
    exit 0
fi

# Squash certain warnings so build errors are easier to find
CXXFLAGS="$CXXFLAGS -Wno-deprecated-declarations"
CFLAGS="$CFLAGS -Wno-deprecated-declarations"
CXXFLAGS="${CXXFLAGS} -Wno-attributes"
CFLAGS="${CFLAGS} -Wno-attributes"

# Force use of modern libstdc++ ABI.  (Should be the upstream default with
# recent releases, but just to be sure...)
export GLIBCXX_USE_CXX11_ABI=1

# Possibly needed to avoid undefined reference errors with PyTorch >=1.6.0
#CFLAGS="${CFLAGS//-fvisibility-inlines-hidden/}"
#CXXFLAGS="${CXXFLAGS//-fvisibility-inlines-hidden/}"

# std=c++14 is required to compile some .cu files
CPPFLAGS="${CPPFLAGS//-std=c++17/-std=c++14}"
CXXFLAGS="${CXXFLAGS//-std=c++17/-std=c++14}"

if [[ ${pytorch_variant} = "gpu" ]]; then
    export USE_CUDA=1
    export TORCH_CUDA_ARCH_LIST="3.5;5.0+PTX"
    if [[ ${cudatoolkit} == 9.0* ]]; then
        export TORCH_CUDA_ARCH_LIST="$TORCH_CUDA_ARCH_LIST;6.0;7.0"
    elif [[ ${cudatoolkit} == 9.2* ]]; then
        export TORCH_CUDA_ARCH_LIST="$TORCH_CUDA_ARCH_LIST;6.0;6.1;7.0"
    elif [[ ${cudatoolkit} == 10.0* ]]; then
        export TORCH_CUDA_ARCH_LIST="$TORCH_CUDA_ARCH_LIST;6.0;6.1;7.0;7.5"
    elif [[ ${cudatoolkit} == 10.1* ]]; then
        export TORCH_CUDA_ARCH_LIST="$TORCH_CUDA_ARCH_LIST;6.0;6.1;7.0;7.5"
    fi
    export TORCH_NVCC_FLAGS="-Xfatbin -compress-all"
    export NCCL_ROOT_DIR=/usr/local/cuda
    export USE_STATIC_NCCL=1
    export CUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda
    export MAGMA_HOME="${PREFIX}"
else
    export USE_CUDA=0
    case "${blas_impl}" in
        mkl)
            export BLAS="MKL"
            export USE_MKL=1
            export USE_MKLDNN=1
            ;;
        openblas)
            export BLAS="OpenBLAS"
            export USE_MKL=0
            export USE_MKLDNN=0
            ;;
        *)
            echo "[ERROR] Unsupported BLAS implementation '${blas_impl}'" >&2
            exit 1
            ;;
    esac
    export CMAKE_TOOLCHAIN_FILE="${RECIPE_DIR}/cross-linux.cmake"
fi

export CMAKE_BUILD_TYPE=Release
export CMAKE_CXX_STANDARD=14

# Re-export modified env vars so sub-processes see them
export CFLAGS CXXFLAGS LDFLAGS LDFLAGS_LD

python  -m pip install . --no-deps -vvv
