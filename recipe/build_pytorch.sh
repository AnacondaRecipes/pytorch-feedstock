#!/bin/bash

set -ex

echo "####################################################################"
echo "Building PyTorch using BLAS implementation: $blas_impl              "
echo "####################################################################"

# clean up an existing cmake build directory
rm -rf build

# uncomment to debug cmake build
export CMAKE_VERBOSE_MAKEFILE=1


################ CONFIGURE CMAKE FOR CONDA ENVIRONMENT ###################
if [[ "$OSTYPE" != "darwin"* ]]; then
    export CMAKE_SYSROOT=$CONDA_BUILD_SYSROOT
else
    export CMAKE_OSX_SYSROOT=$CONDA_BUILD_SYSROOT
fi
# Required to make the right SDK found on Anaconda's CI system. Ideally should be fixed in the CI or conda-build
if [[ "${build_platform}" = "osx-arm64" ]]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
export CMAKE_LIBRARY_PATH=$PREFIX/lib:$PREFIX/include:$CMAKE_LIBRARY_PATH
export CMAKE_PREFIX_PATH=$PREFIX
export CMAKE_BUILD_TYPE=Release

# Apparently, the PATH that conda generates when stacking environments, does not
# have a logical order, potentially leading to CMake looking for (and finding)
# things in the wrong (e.g. parent) environment. In particular, we want to avoid
# finding the wrong Python interpreter.
# Additionally, we explicitly tell CMake where the correct Python interpreter is,
# because simply setting the PATH doesn't work completely.
export PATH=$PREFIX/bin:$PREFIX:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH
export Python3_ROOT_DIR=${PREFIX}
export Python3_EXECUTABLE="${PYTHON}"

export CMAKE_GENERATOR=Ninja

# Uncomment to use ccache; development only
# export CMAKE_C_COMPILER_LAUNCHER=ccache
# export CMAKE_CXX_COMPILER_LAUNCHER=ccache
# export CMAKE_CUDA_COMPILER_LAUNCHER=ccache
# export CCACHE_BASEDIR=${PREFIX}/../

#################### ADJUST COMPILER AND LINKER FLAGS #####################
# Pytorch's build system doesn't like us setting the c++ standard and will
# issue a warning. In particular, if it's set to anything other than c++14,
# we'll get compiler errors. Let's just remove it like we're told.
export CXXFLAGS="$(echo $CXXFLAGS | sed 's/-std=c++[0-9][0-9]//g')"
# The below three lines expose symbols that would otherwise be hidden or
# optimised away. They were here before, so removing them would potentially
# break users' programs
export CFLAGS="$(echo $CFLAGS | sed 's/-fvisibility-inlines-hidden//g')"
export CXXFLAGS="$(echo $CXXFLAGS | sed 's/-fvisibility-inlines-hidden//g')"
export LDFLAGS="$(echo $LDFLAGS | sed 's/-Wl,--as-needed//g')"
# The default conda LDFLAGs include -Wl,-dead_strip_dylibs, which removes all the
# MKL sequential, core, etc. libraries, resulting in a "Symbol not found: _mkl_blas_caxpy"
# error on osx-64.
export LDFLAGS="$(echo $LDFLAGS | sed 's/-Wl,-dead_strip_dylibs//g')"
export LDFLAGS_LD="$(echo $LDFLAGS_LD | sed 's/-dead_strip_dylibs//g')"

# Dynamic libraries need to be lazily loaded so that torch can be imported on
# systems without a GPU.
export LDFLAGS="${LDFLAGS//-Wl,-z,now/-Wl,-z,lazy}"

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
# Unvendoring onnx requires our package to provide ONNXConfig.cmake etc first
if [[ "${build_platform}" = "osx-arm64" ]]; then
    export USE_SYSTEM_SLEEF=1
fi
export BUILD_CUSTOM_PROTOBUF=OFF
export USE_SYSTEM_PYBIND11=1
export USE_SYSTEM_EIGEN_INSTALL=1
# If not set, libomp is embedded into the package on osx
export PACKAGE_TYPE="conda"

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
if [[ ${gpu_variant} == "metal" ]]; then

    ###### Mac - MPS backend ######
    export USE_MPS=1

elif [[ ${gpu_variant} == "cuda-11" ]]; then

    export USE_CUDA=1

    # Warning from pytorch v1.12.1: In the future we will require one to
    # explicitly pass TORCH_CUDA_ARCH_LIST to cmake instead of implicitly
    # setting it as an env variable.

    # This is valid for each cudatoolkit version but was applied here only
    # from cudatoolkit >= 11.8, as we won't rebuild older versions:
    #
    # +PTX should go to the oldest arch. There's a modest runtime performance
    # hit for (unlisted) newer arches on doing this, but that must be set
    # when wide compatibility is a concern.
    #
    # https://pytorch.org/docs/stable/cpp_extension.html (Compute capabilities)
    # https://github.com/pytorch/builder/blob/c85da84005b44041b75e1eb3221ea7dcbd1b28aa/conda/pytorch-nightly/build.sh#L53-L89
    if [[ ${cudatoolkit} == 9.0* ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5+PTX;5.0;6.0;7.0"
    elif [[ ${cudatoolkit} == 9.2* ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5+PTX;5.0;6.0;6.1;7.0"
    elif [[ ${cudatoolkit} == 10.* ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5+PTX;5.0;6.0;6.1;7.0;7.5"
    elif [[ ${cudatoolkit} == 11.0* ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5+PTX;5.0;6.0;6.1;7.0;7.5;8.0"
    elif [[ ${cudatoolkit} == 11.1 ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5+PTX;5.0;6.0;6.1;7.0;7.5;8.0;8.6"
    elif [[ ${cudatoolkit} == 11.2 ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5+PTX;5.0;6.0;6.1;7.0;7.5;8.0;8.6"
    elif [[ ${cudatoolkit} == 11.3 ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5+PTX;5.0;6.0;6.1;7.0;7.5;8.0;8.6"
    elif [[ ${cudatoolkit} == 11.8 ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5+PTX;5.0;6.0;6.1;7.0;7.5;8.0;8.6;9.0"
    else
        echo "No CUDA architecture list exists for cudatoolkit==${cudatoolkit}"
        echo "in build.sh. Use https://en.wikipedia.org/wiki/CUDA#GPUs_supported to make one."
        exit 1
    fi

    export TORCH_NVCC_FLAGS="-Xfatbin -compress-all"
    export NCCL_ROOT_DIR=/usr/local/cuda
    export USE_STATIC_NCCL=1
    export CUDACXX=/usr/local/cuda/bin/nvcc
    export CUDAHOSTCXX="${CXX}"                # If this isn't included, CUDA will use the system compiler to compile host
                                            # files, rather than the one in the conda environment, resulting in compiler errors
    export MAGMA_HOME="${PREFIX}"

    export USE_STATIC_CUDNN=0   # Use our cudnn package

elif [[ ${gpu_variant} == "cuda-12" ]]; then

    export USE_CUDA=1
    export TORCH_CUDA_ARCH_LIST="5.0+PTX;6.0;6.1;7.0;7.5;8.0;8.6;9.0"
    export TORCH_NVCC_FLAGS="-Xfatbin -compress-all"
    export MAGMA_HOME="${PREFIX}"
    export USE_STATIC_CUDNN=0   # Use our cudnn package
    export CUDA_INC_PATH="${PREFIX}/targets/x86_64-linux/include/"  # Point cmake to the header files

elif [[ ${gpu_variant} == "cpu" ]]; then

    if [[ "$OSTYPE" == "darwin"* ]]; then
        export USE_MPS=0
    else
        export USE_CUDA=0
    fi
else
    echo "Unsupported GPU variant: ${gpu_variant}"
    exit 1
fi

case "${blas_impl}" in
    mkl)
        export BLAS="MKL"
        export USE_MKLDNN=1
        ;;
    openblas)
        export BLAS="OpenBLAS"
        export USE_MKLDNN=0
        ;;
    *)
        echo "[ERROR] Unsupported BLAS implementation '${blas_impl}'" >&2
        exit 1
        ;;
esac



# Leave a spare core for other tasks. This may need to be reduced further
# if we get out of memory errors. (Each job uses a certain amount of memory.)
export MAX_JOBS=$((CPU_COUNT > 1 ? CPU_COUNT - 1 : 1))

# The Pytorch build system is invoked
# via their setup.py
"$PYTHON" -m pip install . --no-deps --no-build-isolation -v
