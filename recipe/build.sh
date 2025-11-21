#!/bin/bash

set -ex

echo "####################################################################"
echo "Building PyTorch using BLAS implementation: $blas_impl              "
echo "####################################################################"

# https://github.com/conda-forge/pytorch-cpu-feedstock/issues/243
# https://github.com/pytorch/pytorch/blob/v2.3.1/setup.py#L341
export PACKAGE_TYPE=conda

# remove pyproject.toml to avoid installing deps from pip
rm -rf pyproject.toml

# uncomment to debug cmake build
# export CMAKE_VERBOSE_MAKEFILE=1

export USE_NUMA=0
export USE_ITT=0

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
if [[ "$c_compiler" == "clang" ]]; then
    export CXXFLAGS="$CXXFLAGS -Wno-deprecated-declarations -Wno-unknown-warning-option -Wno-error=unused-command-line-argument -Wno-error=vla-cxx-extension"
    export CFLAGS="$CFLAGS -Wno-deprecated-declarations -Wno-unknown-warning-option -Wno-error=unused-command-line-argument -Wno-error=vla-cxx-extension"
else
    export CXXFLAGS="$CXXFLAGS -Wno-deprecated-declarations -Wno-error=maybe-uninitialized"
    export CFLAGS="$CFLAGS -Wno-deprecated-declarations -Wno-error=maybe-uninitialized"
fi

# This is not correctly found for linux-aarch64 since pytorch 2.0.0 for some reason
export _GLIBCXX_USE_CXX11_ABI=1

# KINETO seems to require CUPTI and will look quite hard for it.
# CUPTI seems to cause trouble when users install a version of
# cudatoolkit different than the one specified at compile time.
# https://github.com/conda-forge/pytorch-cpu-feedstock/issues/135
export USE_KINETO=OFF

if [[ "$target_platform" == "osx-64" ]]; then
  export CXXFLAGS="$CXXFLAGS -DTARGET_OS_OSX=1"
  export CFLAGS="$CFLAGS -DTARGET_OS_OSX=1"
fi

# Dynamic libraries need to be lazily loaded so that torch
# can be imported on system without a GPU
LDFLAGS="${LDFLAGS//-Wl,-z,now/-Wl,-z,lazy}"

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
export CMAKE_GENERATOR=Ninja
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

# Force extraction of build tools from package cache to avoid race conditions
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "Pre-extracting build dependencies to avoid race conditions..."
    which cmake > /dev/null 2>&1 || conda install --force-reinstall cmake -y
    which ninja > /dev/null 2>&1 || conda install --force-reinstall ninja-base -y
    
    # Verify cmake can actually run
    cmake --version || {
        echo "cmake cannot execute, reinstalling..."
        conda install --force-reinstall cmake -y
        cmake --version
    }
fi

# Uncomment to use ccache; development only
# ccache -M 25Gi && ccache -F 0
# export CMAKE_C_COMPILER_LAUNCHER=ccache
# export CMAKE_CXX_COMPILER_LAUNCHER=ccache
# export CMAKE_CUDA_COMPILER_LAUNCHER=ccache
# first removes the timestamp directory, second ignores directories entirely when considering cache hits.
# Neither verified; try both.
# export CCACHE_BASEDIR=${PREFIX}/../
# export CCACHE_NOHASHDIR=true

for ARG in $CMAKE_ARGS; do
  if [[ "$ARG" == "-DCMAKE_"* ]]; then
    cmake_arg=$(echo $ARG | cut -d= -f1)
    cmake_arg=$(echo $cmake_arg| cut -dD -f2-)
    cmake_val=$(echo $ARG | cut -d= -f2-)
    printf -v $cmake_arg "$cmake_val"
    export ${cmake_arg}
  fi
done
unset CMAKE_INSTALL_PREFIX
#export TH_BINARY_BUILD=1
# Use our build version and number for inserting into binaries
export PYTORCH_BUILD_VERSION=$PKG_VERSION
# Always pass 0 to avoid appending ".post" to version string.
# https://github.com/conda-forge/pytorch-cpu-feedstock/issues/315
export PYTORCH_BUILD_NUMBER=0

export INSTALL_TEST=0
export BUILD_TEST=0

export USE_SYSTEM_SLEEF=1
# use our protobuf
export BUILD_CUSTOM_PROTOBUF=OFF
export USE_SYSTEM_PYBIND11=1
export USE_SYSTEM_EIGEN_INSTALL=1
# TODO:Unvendor onnx. Requires our package to provide ONNXConfig.cmake etc first
# Breakpad is missing a ppc64 and s390x port
case "$build_platform" in
    linux-ppc64le|linux-s390x)
        export USE_BREAKPAD=OFF
    ;;
esac

rm -rf $PREFIX/bin/protoc

if [[ "${target_platform}" != "${build_platform}" ]]; then
    # It helps cross compiled builds without emulation support to complete
    # Use BUILD PREFIX protoc instead of the one that is from the host platform
    sed -i.bak \
        "s,IMPORTED_LOCATION_RELEASE .*/bin/protoc,IMPORTED_LOCATION_RELEASE \"${BUILD_PREFIX}/bin/protoc," \
        ${PREFIX}/lib/cmake/protobuf/protobuf-targets-release.cmake
fi

# I don't know where this folder comes from, but it's interfering with the build in osx-64
rm -rf $PREFIX/git

if [[ "$CONDA_BUILD_CROSS_COMPILATION" == 1 ]]; then
    export COMPILER_WORKS_EXITCODE=0
    export COMPILER_WORKS_EXITCODE__TRYRUN_OUTPUT=""
fi

if [[ "${CI}" == "github_actions" ]]; then
    # h-vetinari/hmaarrfk -- May 2024
    # reduce parallelism to avoid getting OOM-killed on
    # cirun-openstack-gpu-2xlarge, which has 32GB RAM, 8 CPUs
    export MAX_JOBS=4
else
    # Leave a spare core for other tasks. This may need to be reduced further
    # if we get out of memory errors. (Each job uses a certain amount of memory.)
    export MAX_JOBS=$((CPU_COUNT > 1 ? CPU_COUNT - 1 : 1))
fi

if [[ "$blas_impl" == "openblas" ]]; then
    # Fake openblas
    export BLAS=OpenBLAS
    #sed -i.bak "s#FIND_LIBRARY.*#set(OpenBLAS_LIB ${PREFIX}/lib/liblapack${SHLIB_EXT} ${PREFIX}/lib/libcblas${SHLIB_EXT} ${PREFIX}/lib/libblas${SHLIB_EXT})#g" cmake/Modules/FindOpenBLAS.cmake
elif [[ "$blas_impl" == "mkl" ]]; then
    export BLAS=MKL
else
    echo "[ERROR] Unsupported BLAS implementation '${blas_impl}'" >&2
    exit 1
fi

if [[ "$PKG_NAME" == "pytorch" ]]; then
  PIP_ACTION=install
  # Trick Cmake into thinking python hasn't changed
  sed "s/3\.12/$PY_VER/g" build/CMakeCache.txt.orig > build/CMakeCache.txt
  sed -i.bak "s/3;12/${PY_VER%.*};${PY_VER#*.}/g" build/CMakeCache.txt
  sed -i.bak "s/cpython-312/cpython-${PY_VER%.*}${PY_VER#*.}/g" build/CMakeCache.txt
else
  # For the main script we just build a wheel for so that the C++/CUDA
  # parts are built. Then they are reused in each python version.
  PIP_ACTION=wheel
fi

# MacOS build is simple, and will not be for CUDA
if [[ "$OSTYPE" == "darwin"* ]]; then
    # Produce macOS builds with torch.distributed support.
    # This is enabled by default on Linux, but disabled by default on macOS,
    # because it requires an non-bundled compile-time dependency (libuv
    # through gloo). This dependency is made available through meta.yaml, so
    # we can override the default and set USE_DISTRIBUTED=1.
    export USE_DISTRIBUTED=1

    if [[ "$target_platform" == "osx-arm64" ]]; then
        # MKLDNN did not support on Apple M1 at the time support Apple M1
        # was added. Revisit later
        export USE_MKLDNN=0
    fi

    if [[ ${gpu_variant} == "metal" ]]; then
        export USE_MPS=1
    else
        export USE_MPS=0
    fi

elif [[ ${gpu_variant} == "cuda"* ]]; then
    if [[ "$target_platform" == "linux-aarch64" ]]; then
        # https://github.com/pytorch/pytorch/pull/121975
        # https://github.com/conda-forge/pytorch-cpu-feedstock/issues/264
        export USE_PRIORITIZED_TEXT_FOR_LD=1
    fi
    # Even though cudnn is used for CUDA builds, it's good to enable
    # for MKLDNN for CUDA builds when CUDA builds are used on a machine
    # with no NVIDIA GPUs. However compilation fails with mkldnn and cuda enabled.
    export USE_MKLDNN=OFF
    export USE_CUDA=1
    # PyTorch Vendors an old version of FindCUDA
    # https://gitlab.kitware.com/cmake/cmake/-/blame/master/Modules/FindCUDA.cmake#L891
    # They are working on updating it pytorch/pytorch#76082
    # See: https://github.com/conda-forge/pytorch-cpu-feedstock/pull/224#discussion_r1522698939
    if [[ "${target_platform}" != "${build_platform}" ]]; then
        export CUDA_TOOLKIT_ROOT=${CUDA_HOME}
    fi
    # Warning from pytorch v1.12.1: In the future we will require one to
    # explicitly pass TORCH_CUDA_ARCH_LIST to cmake instead of implicitly
    # setting it as an env variable.
    #
    # +PTX should go to the oldest arch. There's a modest runtime performance
    # hit for (unlisted) newer arches on doing this, but that must be set
    # when wide compatibility is a concern.
    #
    # https://pytorch.org/docs/stable/cpp_extension.html (Compute capabilities)
    # https://github.com/pytorch/builder/blob/c85da84005b44041b75e1eb3221ea7dcbd1b28aa/conda/pytorch-nightly/build.sh#L53-L89
    if [[ ${cuda_compiler_version} == 9.0* ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5+PTX;5.0;6.0;7.0"
        export CUDA_TOOLKIT_ROOT_DIR=$CUDA_HOME
    elif [[ ${cuda_compiler_version} == 9.2* ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5+PTX;5.0;6.0;6.1;7.0"
        export CUDA_TOOLKIT_ROOT_DIR=$CUDA_HOME
    elif [[ ${cuda_compiler_version} == 10.* ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5+PTX;5.0;6.0;6.1;7.0;7.5"
        export CUDA_TOOLKIT_ROOT_DIR=$CUDA_HOME
    elif [[ ${cuda_compiler_version} == 11.0* ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5+PTX;5.0;6.0;6.1;7.0;7.5;8.0"
        export CUDA_TOOLKIT_ROOT_DIR=$CUDA_HOME
    elif [[ ${cuda_compiler_version} == 11.1 ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5+PTX;5.0;6.0;6.1;7.0;7.5;8.0;8.6"
        export CUDA_TOOLKIT_ROOT_DIR=$CUDA_HOME
    elif [[ ${cuda_compiler_version} == 11.2 ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5+PTX;5.0;6.0;6.1;7.0;7.5;8.0;8.6"
        export CUDA_TOOLKIT_ROOT_DIR=$CUDA_HOME
    elif [[ ${cuda_compiler_version} == 11.8 ]]; then
        export TORCH_CUDA_ARCH_LIST="3.5+PTX;5.0;6.0;6.1;7.0;7.5;8.0;8.6;8.9"
        export CUDA_TOOLKIT_ROOT_DIR=$CUDA_HOME
    elif [[ ${cuda_compiler_version} == 12.[0-6] ]]; then
        export TORCH_CUDA_ARCH_LIST="5.0;6.0;6.1;7.0;7.5;8.0;8.6;8.9;9.0+PTX"
        # $CUDA_HOME not set in CUDA 12.0. Using $PREFIX
        export CUDA_TOOLKIT_ROOT_DIR="${PREFIX}"
        if [[ "${target_platform}" != "${build_platform}" ]]; then
            export CUDA_TOOLKIT_ROOT=${PREFIX}
        fi
    else
        echo "No CUDA architecture list exists for CUDA v${cuda_compiler_version}"
        echo "in build.sh. Use https://en.wikipedia.org/wiki/CUDA#GPUs_supported to make one."
        exit 1
    fi
    export TORCH_NVCC_FLAGS="-Xfatbin -compress-all"
    export NCCL_ROOT_DIR=$PREFIX
    export NCCL_INCLUDE_DIR=$PREFIX/include
    export USE_SYSTEM_NCCL=1
    export USE_STATIC_NCCL=0
    export USE_STATIC_CUDNN=0
    export USE_SYSTEM_NVTX=1
    export MAGMA_HOME="${PREFIX}"
    export CUDA_INC_PATH="${PREFIX}/targets/x86_64-linux/include/"  # Point cmake to the header files
else
    # MKLDNN is an Apache-2.0 licensed library for DNNs and is used
    # for CPU builds. Not to be confused with MKL.
    export USE_MKLDNN=1
    export USE_CUDA=0
    export CMAKE_TOOLCHAIN_FILE="${RECIPE_DIR}/cross-linux.cmake"
fi

echo '${CXX}'=${CXX}
echo '${PREFIX}'=${PREFIX}
$PREFIX/bin/python -m pip $PIP_ACTION . --no-deps --no-build-isolation -vvv --no-clean \
    | sed "s,${CXX},\$\{CXX\},g" \
    | sed "s,${PREFIX},\$\{PREFIX\},g"

if [[ "$PKG_NAME" == "libtorch" ]]; then
  mkdir -p $SRC_DIR/dist
  pushd $SRC_DIR/dist
  
  # Wait for wheel file with timeout
  WHEEL_WAIT=0
  MAX_WHEEL_WAIT=30
  while [ $WHEEL_WAIT -lt $MAX_WHEEL_WAIT ]; do
      if ls ../torch-*.whl 1> /dev/null 2>&1; then
          echo "Wheel file found after ${WHEEL_WAIT}s"
          break
      fi
      sleep 1
      WHEEL_WAIT=$((WHEEL_WAIT + 1))
  done
  
  if ! ls ../torch-*.whl 1> /dev/null 2>&1; then
      echo "ERROR: No wheel file found after ${MAX_WHEEL_WAIT}s"
      exit 1
  fi
  
  wheel unpack ../torch-*.whl
  pushd torch-*
  mv torch/bin/* ${PREFIX}/bin
  mv torch/lib/* ${PREFIX}/lib
  # need to merge these now because we're using system pybind11
  rsync -a torch/share/* ${PREFIX}/share
  for f in ATen caffe2 tensorpipe torch c10; do
    mv torch/include/$f ${PREFIX}/include/$f
  done
  rm ${PREFIX}/lib/libtorch_python.*
  popd
  popd

  # Keep the original backed up to sed later
  cp build/CMakeCache.txt build/CMakeCache.txt.orig
else
  # Keep this in ${PREFIX}/lib so that the library can be found by
  # TorchConfig.cmake.
  # With upstream non-split build, `libtorch_python.so`
  # and TorchConfig.cmake are both in ${SP_DIR}/torch/lib and therefore
  # this is not needed.
  mv ${SP_DIR}/torch/lib/libtorch_python${SHLIB_EXT} ${PREFIX}/lib
fi