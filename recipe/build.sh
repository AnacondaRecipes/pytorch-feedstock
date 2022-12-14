#!/bin/bash

set -ex

echo "####################################################################"
echo "Building PyTorch using BLAS implementation: $blas_impl              "
echo "####################################################################"

rm -fr build/

# Apparently, the PATH that conda generates when stacking environments, does not
# have a logical order, potentially leading to CMake looking for (and finding)
# things in the wrong (e.g. parent) environment. In particular, we want to avoid
# finding the wrong Python interpreter.
export PATH=$PREFIX/bin:$PREFIX:$BUILD_PREFIX/bin:$BUILD_PREFIX:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

# uncomment to debug cmake build
export CMAKE_VERBOSE_MAKEFILE=1

# # The reason for these flags being removed has been lost in time. It would
# # be nice to investigate why they're here at some point.
# export CFLAGS="$(echo $CFLAGS | sed 's/-fvisibility-inlines-hidden//g')"
# export CXXFLAGS="$(echo $CXXFLAGS | sed 's/-fvisibility-inlines-hidden//g')"
# export LDFLAGS="$(echo $LDFLAGS | sed 's/-Wl,--as-needed//g')"
# The default conda LDFLAGs include -Wl,-dead_strip_dylibs, which conveniently decides to remove all the MKL sequential, core, etc. libraries, resulting in Symbol not found: _mkl_blas_caxpy error on osx-64.
export LDFLAGS="$(echo $LDFLAGS | sed 's/-Wl,-dead_strip_dylibs//g')"
export LDFLAGS_LD="$(echo $LDFLAGS_LD | sed 's/-dead_strip_dylibs//g')"
# export CXXFLAGS="$CXXFLAGS -Wno-deprecated-declarations"
# export CFLAGS="$CFLAGS -Wno-deprecated-declarations"

# Dynamic libraries need to be lazily loaded so that torch can be imported on
# systems without a GPU.
LDFLAGS="${LDFLAGS//-Wl,-z,now/-Wl,-z,lazy}"

# Taken from CF. This is a desperate attempt to export the CMake config to all
# submodules, and hope that it will be picked up.
# It would be great to have a look at these flags and set the ones that we need
# explicitly. Also to try and understand which CMake config these are coming from.
# TODO: try taking this out.
# for ARG in $CMAKE_ARGS; do
#   if [[ "$ARG" == "-DCMAKE_"* ]]; then
#     cmake_arg=$(echo $ARG | cut -d= -f1)
#     cmake_arg=$(echo $cmake_arg| cut -dD -f2-)
#     cmake_val=$(echo $ARG | cut -d= -f2-)
#     printf -v $cmake_arg "$cmake_val"
#     export ${cmake_arg}
#   fi
# done

# This must be unset, else PyTorch complains.
# Test - try removing - delete this if it's ok without
#unset CMAKE_INSTALL_PREFIX

export PYTORCH_BUILD_VERSION=$PKG_VERSION
export PYTORCH_BUILD_NUMBER=$PKG_BUILDNUM

#export TH_BINARY_BUILD=1
export USE_NINJA=1
export BUILD_TEST=0
#export INSTALL_TEST=0

# This is the default, but just in case it changes, one day.
export BUILD_DOCS=OFF

# The build needs a lot of memory, limit to 4 CPUs to take it easy on builders.
export MAX_JOBS=$((${CPU_COUNT} > 4 ? 4 : ${CPU_COUNT}))

case "$build_platform" in
    linux-ppc64le|linux-s390x)
        # Breakpad is missing a ppc64 and s390x port.
        export USE_BREAKPAD=OFF
    ;;
esac

export CMAKE_GENERATOR=Ninja
if [[ "$OSTYPE" != "darwin"* ]]; then
    export CMAKE_SYSROOT=$CONDA_BUILD_SYSROOT
fi
export CMAKE_LIBRARY_PATH=$PREFIX/lib:$PREFIX/include:$CMAKE_LIBRARY_PATH
export CMAKE_PREFIX_PATH=$PREFIX
export CMAKE_BUILD_TYPE=Release

# Re-export modified env vars so sub-processes see them
export CFLAGS CPPFLAGS CXXFLAGS LDFLAGS LDFLAGS_LD

# MacOS build is simple, and will not be done for CUDA.
if [[ "$OSTYPE" == "darwin"* ]]; then
    "$PYTHON" -m pip install . \
        --no-deps \
        --no-binary :all: \
        --no-clean \
        -vvv
    exit $?
fi

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

    # export CMAKE_TOOLCHAIN_FILE="${RECIPE_DIR}/cross-linux.cmake"
fi

"$PYTHON" -m pip install . \
    --no-deps \
    --no-binary :all: \
    --no-clean \
    -vvv
