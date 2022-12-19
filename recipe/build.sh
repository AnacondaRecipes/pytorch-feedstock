#!/bin/bash

set -ex

echo "####################################################################"
echo "Building PyTorch using BLAS implementation: $blas_impl              "
echo "####################################################################"

rm -fr build/

# uncomment to debug cmake build
export CMAKE_VERBOSE_MAKEFILE=1



################ CONFIGURE CMAKE FOR CONDA ENVIRONMENT ###################
if [[ "$OSTYPE" != "darwin"* ]]; then
    export CMAKE_SYSROOT=$CONDA_BUILD_SYSROOT
fi
export CMAKE_LIBRARY_PATH=$PREFIX/lib:$PREFIX/include:$CMAKE_LIBRARY_PATH
export CMAKE_PREFIX_PATH=$PREFIX
export CMAKE_BUILD_TYPE=Release

# Apparently, the PATH that conda generates when stacking environments, does not
# have a logical order, potentially leading to CMake looking for (and finding)
# things in the wrong (e.g. parent) environment. In particular, we want to avoid
# finding the wrong Python interpreter.
export PATH=$PREFIX/bin:$PREFIX:$BUILD_PREFIX/bin:$BUILD_PREFIX:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

export CMAKE_GENERATOR=Ninja


########################## ADJUST LINKER FLAGS ##########################
# The default conda LDFLAGs include -Wl,-dead_strip_dylibs, which removes all the
# MKL sequential, core, etc. libraries, resulting in a "Symbol not found: _mkl_blas_caxpy"
# error on osx-64.
export LDFLAGS="$(echo $LDFLAGS | sed 's/-Wl,-dead_strip_dylibs//g')"
export LDFLAGS_LD="$(echo $LDFLAGS_LD | sed 's/-dead_strip_dylibs//g')"

# Dynamic libraries need to be lazily loaded so that torch can be imported on
# systems without a GPU.
export LDFLAGS="${LDFLAGS//-Wl,-z,now/-Wl,-z,lazy}"

# Re-export modified env vars so sub-processes see them
# export CFLAGS CPPFLAGS CXXFLAGS LDFLAGS LDFLAGS_LD



##################### CONFIGURE PYTORCH BUILD OPTIONS ########################
# See header of Pytorch's setup.py for a description of the most important
# environment variables that its build system uses to configure the build.
export USE_NINJA=1        # For fast builds
export BUILD_TEST=0       # Don't compile unit test binaries
export USE_NUMA=0         # This is implicit anyway, but this line makes it explicit
export BUILD_DOCS=OFF     # This is the default, but just in case it changes one day

# Use our sleef (only available on osx-arm64), protobuf,
# Pybind, Eigen packages, rather than the ones submodule'd
# into the Pytorch source tree
if [[ "${build_platform}" = "osx-arm64" ]]; then
    export USE_SYSTEM_SLEEF=1
fi
export BUILD_CUSTOM_PROTOBUF=OFF
export USE_SYSTEM_PYBIND11=1
export USE_SYSTEM_EIGEN_INSTALL=1

# Breakpad is missing a ppc64 and s390x port
case "$build_platform" in
    linux-ppc64le|linux-s390x)
        export USE_BREAKPAD=OFF
    ;;
esac

# Produce macOS builds with torch.distributed support.
# This is enabled by default on Linux, but disabled by default on macOS,
# because it requires an non-bundled compile-time dependency (libuv
# through gloo). This dependency is made available through meta.yaml, so
# we can override the default and set USE_DISTRIBUTED=1.
if [[ "$OSTYPE" == "darwin"* ]]; then
    export USE_DISTRIBUTED=1
fi

# Use our build version and number for inserting into binaries
export PYTORCH_BUILD_VERSION=$PKG_VERSION
export PYTORCH_BUILD_NUMBER=$PKG_BUILDNUM


############################# CONFIGURE BACKEND #############################
# CUDA is used as the acceleration backend 
# for GPU builds; MKL or openBLAS is used as
# the backend for CPU builds.
if [[ ${pytorch_variant} = "gpu" ]]; then

    export USE_CUDA=1

    # Warning from pytorch v1.12.1: In the future we will require one to 
    # explicitly pass TORCH_CUDA_ARCH_LIST to cmake instead of implicitly
    # setting it as an env variable.
    #
    # Use PTX with the latest CUDA architecture
    if [[ ${cuda_compiler_version} == 9.0* ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5;5.0;6.0;7.0+PTX"
    elif [[ ${cuda_compiler_version} == 9.2* ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5;5.0;6.0;6.1;7.0+PTX"
    elif [[ ${cuda_compiler_version} == 10.* ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5;5.0;6.0;6.1;7.0;7.5+PTX"
    elif [[ ${cuda_compiler_version} == 11.0* ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5;5.0;6.0;6.1;7.0;7.5;8.0+PTX"
    elif [[ ${cuda_compiler_version} == 11.1 ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5;5.0;6.0;6.1;7.0;7.5;8.0;8.6+PTX"
    elif [[ ${cuda_compiler_version} == 11.2 ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5;5.0;6.0;6.1;7.0;7.5;8.0;8.6+PTX"
    elif [[ ${cuda_compiler_version} == 11.3 ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5;5.0;6.0;6.1;7.0;7.5;8.0;8.6+PTX"
    else
        echo "No CUDA architecture list exists for cuda_compiler_version==${cuda_compiler_version}"
        echo "in build.sh. Use https://en.wikipedia.org/wiki/CUDA#GPUs_supported to make one."
        exit 1
    fi

    export TORCH_NVCC_FLAGS="-Xfatbin -compress-all"
    export NCCL_ROOT_DIR=/usr/local/cuda
    export USE_STATIC_NCCL=1
    export CUDACXX=/usr/local/cuda/bin/nvcc
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

fi


# The build needs a lot of memory. Limit to 4 CPUs to take it easy on builders.
export MAX_JOBS=$((${CPU_COUNT} > 4 ? 4 : ${CPU_COUNT}))


# The Pytorch build system is invoked
# via their setup.py
"$PYTHON" -m pip install . \
    --no-deps \
    --no-binary :all: \
    --no-clean \
    -vvv
