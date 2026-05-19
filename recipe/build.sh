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

# Add this for GCC 14.3+ compatibility with XNNPACK
if [[ "$target_platform" == linux-aarch64 ]]; then
    export CFLAGS="$CFLAGS -Wno-error=incompatible-pointer-types"
fi

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
# Required to make the right SDK found on Anaconda's CI system. Ideally should be fixed in the CI or conda-build
if [[ "${build_platform}" = "osx-arm64" ]]; then
    export USE_NCCL=0
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

# ============================================================
# SIR-3273 DIAGNOSTIC [block 1/3]: state BEFORE sysroot reconstruction
# Captures what the compiler activation script handed us. Marek's
# 2026-05-19 comment showed MacOSX14.5.sdk IS installed; the question
# now is why downstream tooling picks 12.1 anyway.
# ============================================================
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "===================================================================="
    echo "SIR-3273 DIAGNOSTIC [1/3] — BEFORE sysroot reconstruction"
    echo "===================================================================="
    echo "[A] Installed SDKs on this worker (Marek showed 14.5 IS here):"
    ls -la /Library/Developer/CommandLineTools/SDKs/ 2>&1 || true
    echo
    echo "[B] MacOSX*.sdk symlink resolution:"
    for s in MacOSX.sdk MacOSX14.sdk MacOSX14.5.sdk MacOSX13.sdk MacOSX12.sdk MacOSX12.1.sdk; do
        ls -la "/Library/Developer/CommandLineTools/SDKs/${s}" 2>&1 || true
    done
    echo
    echo "[C] xcrun resolutions (what the toolchain auto-detects):"
    echo "    xcrun --show-sdk-path:                  $(xcrun --show-sdk-path 2>&1 || echo FAIL)"
    echo "    xcrun --show-sdk-version:               $(xcrun --show-sdk-version 2>&1 || echo FAIL)"
    echo "    xcrun --sdk macosx --show-sdk-path:     $(xcrun --sdk macosx --show-sdk-path 2>&1 || echo FAIL)"
    echo "    xcrun --sdk macosx14.5 --show-sdk-path: $(xcrun --sdk macosx14.5 --show-sdk-path 2>&1 || echo FAIL)"
    echo "    xcode-select -p:                        $(xcode-select -p 2>&1 || echo FAIL)"
    echo
    echo "[D] CBC / activation env vars (pre-reconstruction state):"
    echo "    CONDA_BUILD_SYSROOT:           ${CONDA_BUILD_SYSROOT:-<unset>}"
    echo "    MACOSX_SDK_VERSION:            ${MACOSX_SDK_VERSION:-<unset>}"
    echo "    MACOSX_DEPLOYMENT_TARGET:      ${MACOSX_DEPLOYMENT_TARGET:-<unset>}"
    echo "    SDKROOT:                       ${SDKROOT:-<unset>}"
    echo "    OSX_ARCH:                      ${OSX_ARCH:-<unset>}"
    echo "    target_platform:               ${target_platform:-<unset>}"
    echo "    build_platform:                ${build_platform:-<unset>}"
    echo "    gpu_variant:                   ${gpu_variant:-<unset>}"
    echo
    echo "[E] Compiler env vars (set by activation):"
    echo "    CC:                            ${CC:-<unset>}"
    echo "    CXX:                           ${CXX:-<unset>}"
    echo "    CFLAGS:                        ${CFLAGS:-<unset>}"
    echo "    CXXFLAGS:                      ${CXXFLAGS:-<unset>}"
    echo "    LDFLAGS:                       ${LDFLAGS:-<unset>}"
    echo "    CMAKE_ARGS:                    ${CMAKE_ARGS:-<unset>}"
    echo "    CMAKE_OSX_SYSROOT:             ${CMAKE_OSX_SYSROOT:-<unset>}"
    echo "    CMAKE_OSX_DEPLOYMENT_TARGET:   ${CMAKE_OSX_DEPLOYMENT_TARGET:-<unset>}"
    echo "    CMAKE_SYSROOT:                 ${CMAKE_SYSROOT:-<unset>}"
    echo
    echo "[F] clang resolution + version + default search paths:"
    which clang || echo "    clang not in PATH"
    clang --version 2>&1 | head -3 || true
    echo "    -- clang -v -E -x c /dev/null (default search paths) --"
    clang -v -E -x c /dev/null 2>&1 | head -40 || true
    echo "===================================================================="
fi

# On macOS, the compiler activation overrides CONDA_BUILD_SYSROOT with the
# base CBC's SDK (e.g. 12.1), and CMAKE_ARGS also carries that stale value.
# Reconstruct the correct sysroot from MACOSX_SDK_VERSION, which is
# preserved from the recipe CBC's zip_keys and not touched by activation.
if [[ "$OSTYPE" != "darwin"* ]]; then
    export CMAKE_SYSROOT=$CONDA_BUILD_SYSROOT
else
    export CMAKE_OSX_SYSROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX${MACOSX_SDK_VERSION}.sdk"
    export CONDA_BUILD_SYSROOT="${CMAKE_OSX_SYSROOT}"
    # SIR-3273 fix: the previous two exports were sufficient before the
    # Taskcluster 95.x AMI rebuild because activation defaulted to the
    # right SDK. After the rebuild, MacOSX.sdk symlink points at 12.1
    # and activation pre-sets SDKROOT + CMAKE_ARGS to 12.1 too. clang
    # honors SDKROOT and CMake honors -DCMAKE_OSX_SYSROOT= embedded in
    # CMAKE_ARGS over our env overrides, so without these extra lines
    # the compile still uses MacOSX12.1.sdk (which lacks Metal 3.0).
    export SDKROOT="${CMAKE_OSX_SYSROOT}"
    CMAKE_ARGS="${CMAKE_ARGS//MacOSX12.1.sdk/MacOSX${MACOSX_SDK_VERSION}.sdk}"
    CMAKE_ARGS="${CMAKE_ARGS//-DCMAKE_OSX_DEPLOYMENT_TARGET=12.1/-DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET}}"
    export CMAKE_ARGS
fi

# ============================================================
# SIR-3273 DIAGNOSTIC [block 2/3]: state AFTER sysroot reconstruction
# Confirm the reconstruction set what we think it did, and inspect the
# Metal headers in BOTH the reconstructed sysroot AND the 14.5 SDK
# directly. If Metal headers in 14.5 SDK contain MTLLanguageVersion3_0
# but the actual compile still fails on it, downstream tooling is
# silently overriding our CMAKE_OSX_SYSROOT.
# ============================================================
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "===================================================================="
    echo "SIR-3273 DIAGNOSTIC [2/3] — AFTER sysroot reconstruction"
    echo "===================================================================="
    echo "[G] Env vars after reconstruction (lines 117-122):"
    echo "    CONDA_BUILD_SYSROOT:           ${CONDA_BUILD_SYSROOT:-<unset>}"
    echo "    CMAKE_OSX_SYSROOT:             ${CMAKE_OSX_SYSROOT:-<unset>}"
    echo "    MACOSX_SDK_VERSION (driving):  ${MACOSX_SDK_VERSION:-<unset>}"
    echo
    echo "[H] Does CONDA_BUILD_SYSROOT contain Metal headers with MTLLanguageVersion3_0?"
    METAL_HDR_DIR="${CONDA_BUILD_SYSROOT}/System/Library/Frameworks/Metal.framework/Headers"
    if [ -d "${METAL_HDR_DIR}" ]; then
        echo "    Metal.framework/Headers EXISTS at ${METAL_HDR_DIR}"
        echo "    Sample headers:"
        ls "${METAL_HDR_DIR}/" 2>&1 | head -8
        echo "    grep MTLLanguageVersion3_0:"
        grep -l "MTLLanguageVersion3_0" "${METAL_HDR_DIR}/"*.h 2>&1 | head -5 || echo "    NOT FOUND in CONDA_BUILD_SYSROOT"
    else
        echo "    Metal.framework/Headers MISSING at ${METAL_HDR_DIR}"
    fi
    echo
    echo "[I] Cross-check the 14.5 SDK directly (Marek says it's installed):"
    HDR_145="/Library/Developer/CommandLineTools/SDKs/MacOSX14.5.sdk/System/Library/Frameworks/Metal.framework/Headers"
    if [ -d "${HDR_145}" ]; then
        echo "    14.5 Metal headers exist."
        echo "    grep MTLLanguageVersion3_0 in 14.5 SDK Metal:"
        grep -l "MTLLanguageVersion3_0" "${HDR_145}/"*.h 2>&1 | head -5 || echo "    NOT FOUND in 14.5 SDK"
    else
        echo "    14.5 Metal headers MISSING — Marek's evidence may not apply."
    fi
    echo
    echo "[J] Same check on 12.1 SDK (the wrong one we keep falling back to):"
    HDR_121="/Library/Developer/CommandLineTools/SDKs/MacOSX12.1.sdk/System/Library/Frameworks/Metal.framework/Headers"
    if [ -d "${HDR_121}" ]; then
        echo "    grep MTLLanguageVersion3_0 in 12.1 SDK Metal:"
        grep -l "MTLLanguageVersion3_0" "${HDR_121}/"*.h 2>&1 | head -5 || echo "    NOT FOUND in 12.1 SDK (expected — 12.1 predates Metal 3.0)"
    fi
    echo
    echo "[K] What does clang now resolve as its default sysroot, with our overrides?"
    clang -v -E -x c /dev/null 2>&1 | grep -iE "(sysroot|sdk)" | head -10 || true
    echo "===================================================================="
fi
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
elif [[ "$target_platform" == "linux-aarch64" && ${gpu_variant} == "cuda"* ]]; then
    # CUDA template instantiation (flash attention / cutlass) is extremely
    # memory-hungry. Cap parallelism to avoid OOM.
    export MAX_JOBS=4
elif [[ "$target_platform" == "linux-64" && ${gpu_variant} == "cuda"* ]]; then
    # cicc OOMs on fbgemm_genai CUTLASS templates on runners. Rather
    # than globally throttle, we serialize only fbgemm_genai via a Ninja job
    # pool (patch 0024 + CMAKE_JOB_POOLS below) and leave MAX_JOBS high.
    # MAX_JOBS=CPU_COUNT-1 verified safe on g4dn.4xlarge (16 vCPU / 64GB) in 2.10.0.
    export MAX_JOBS=$((CPU_COUNT > 1 ? CPU_COUNT - 1 : 1))
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
    export USE_MKLDNN=1
    export USE_CUDA=1
    # PyTorch Vendors an old version of FindCUDA
    # https://gitlab.kitware.com/cmake/cmake/-/blame/master/Modules/FindCUDA.cmake#L891
    # They are working on updating it pytorch/pytorch#76082
    # See: https://github.com/conda-forge/pytorch-cpu-feedstock/pull/224#discussion_r1522698939
    if [[ "${target_platform}" != "${build_platform}" ]]; then
        export CUDA_TOOLKIT_ROOT=${CUDA_HOME}
    fi
    # CUDA arch lists aligned with upstream PyTorch v2.12.0 .ci/manywheel/build_cuda.sh,
    # with one deliberate divergence: keep trailing +PTX for forward-compat with future
    # archs (sm_13+). Upstream 2.11 shipped +PTX; upstream 2.12 dropped it (line 112's
    # comment still says "+ PTX for forward compatibility" but the code no longer adds it).
    # We preserve +PTX so users on hardware newer than sm_12 still get JIT-runnable kernels.
    # 2.12 supports CUDA 12.6/12.8/12.9/13.0/13.2; we ship 12.9 and 13.0
    # (pkgs/main has cuda-nvcc 13.0 but not 13.2 yet — see CBC).
    if [[ "$target_platform" == "linux-aarch64" && ${cuda_compiler_version} == 13.* ]]; then
        # aarch64 CUDA 13: upstream filters out <8.0, 7.5, 8.6 (x86_64-only SKUs)
        # and adds sm_11.0 (Jetson Thor) only on aarch64.
        # Keeps 8.0 (A100), 9.0 (Grace Hopper), 10.0+12.0 (Blackwell), 11.0 (Thor).
        export TORCH_CUDA_ARCH_LIST="8.0;9.0;10.0;11.0;12.0+PTX"
    elif [[ ${cuda_compiler_version} == 12.* ]]; then
        # CUDA 12: sm_50-sm_61 deprecated in 12.8; sm_70 dropped upstream in 2.11.
        export TORCH_CUDA_ARCH_LIST="7.5;8.0;8.6;9.0;10.0;12.0+PTX"
    elif [[ ${cuda_compiler_version} == 13.* ]]; then
        # CUDA 13: sm_70 dropped; same arch list as 12.x for x86_64.
        export TORCH_CUDA_ARCH_LIST="7.5;8.0;8.6;9.0;10.0;12.0+PTX"
    else
        echo "No CUDA architecture list exists for CUDA v${cuda_compiler_version}"
        echo "in build.sh. Use https://en.wikipedia.org/wiki/CUDA#GPUs_supported to make one."
        exit 1
    fi
    export CUDA_TOOLKIT_ROOT_DIR="${PREFIX}"
    if [[ "${target_platform}" != "${build_platform}" ]]; then
        export CUDA_TOOLKIT_ROOT=${PREFIX}
    fi
    # --threads 1: stop nvcc from fanning out per-arch cicc processes in one
    # invocation (each fork multiplies peak RSS). -Xptxas ...=false skips the
    # expensive ptxas passes (~0-3% perf on hot kernels, no correctness impact).
    export TORCH_NVCC_FLAGS="-Xfatbin -compress-all --threads 1 -Xptxas=--allow-expensive-optimizations=false"
    # Cap glibc per-thread malloc arenas so long-running cicc/gcc processes
    # don't hold hundreds of MB of fragmented heap. No codegen impact.
    export MALLOC_ARENA_MAX=2
    # Cap fbgemm_genai (CUTLASS) parallelism via a dedicated Ninja job pool
    # (patch 0024). cutlass_heavy=4 lets 4 heavy CUTLASS TUs compile at once;
    # observed RSS per cicc on g4dn.4xlarge T4 is ~4 GB, so 4× = ~16 GB peak,
    # well under the 64 GB host budget. Was 1 originally (serialized) — that
    # left 56 GB of RAM idle while MSLK FP4 GEMM kernels dominated wall time.
    # Measured speedup on the MSLK FP4 tail (cutlass_heavy=1 → 4): ~3.4×.
    # We tried =8 (PBP graph 2220751f): 13.0 dropped from 293→282 min (-3.8%),
    # 12.9 went from 342→358 min (+4.7%) — net within noise floor. The MSLK
    # tail saturates somewhere between 4 and 8 parallel TUs, so going higher
    # adds memory pressure without real wall-time gains. Sticking with 4.
    # Set as env vars so PyTorch setup.py auto-forwards them as -D
    # (CMAKE_ARGS itself is not read by setup.py).
    export CMAKE_JOB_POOLS="cutlass_heavy=4;compile=${MAX_JOBS};link=2"
    export USE_FBGEMM_GENAI_JOB_POOL=cutlass_heavy
    export NCCL_ROOT_DIR=$PREFIX
    export NCCL_INCLUDE_DIR=$PREFIX/include
    export USE_SYSTEM_NCCL=1
    export USE_STATIC_NCCL=0
    export USE_STATIC_CUDNN=0
    export USE_CUFILE=0
    # Disable cuSPARSELt: the conda package doesn't exist in defaults channels,
    # and it's only needed for semi-structured (2:4) sparsity ops which most users don't need.
    export USE_CUSPARSELT=0
    # Disable cuDSS: the conda package (libcudss-dev) doesn't exist in defaults channels,
    # and it's only needed for sparse direct solvers on CSR tensors which most users don't need.
    export USE_CUDSS=0
    export USE_SYSTEM_NVTX=1
    export MAGMA_HOME="${PREFIX}"
    # NVIDIA's conda CUDA packages use sbsa-linux (Server Base System Architecture)
    # for aarch64, not aarch64-linux. uname -m returns "aarch64" which doesn't match.
    case "$(uname -m)" in
        aarch64) _cuda_arch="sbsa-linux" ;;
        *)       _cuda_arch="$(uname -m)-linux" ;;
    esac
    export CUDA_INC_PATH="${PREFIX}/targets/${_cuda_arch}/include/"
    # pytorch 2.12 + CMake 4.x: cmake/public/cuda.cmake creates an INTERFACE
    # target caffe2::cuda → CUDA::cuda_driver, validated eagerly at generate.
    # The driver stub from cuda-driver-dev lives under targets/<arch>/lib/stubs/
    # which FindCUDAToolkit doesn't search by default. Point cmake at it.
    export CMAKE_LIBRARY_PATH="${BUILD_PREFIX}/targets/${_cuda_arch}/lib/stubs:${PREFIX}/targets/${_cuda_arch}/lib/stubs:${CMAKE_LIBRARY_PATH}"
    export CUDA_cuda_driver_LIBRARY="${BUILD_PREFIX}/targets/${_cuda_arch}/lib/stubs/libcuda.so"
    # pytorch 2.12 still calls find_package(CUB) when CUDA<13 (Dependencies.cmake:1167).
    # FindCUB.cmake's HINTS=${CUDAToolkit_INCLUDE_DIRS} doesn't resolve to conda's
    # targets/<arch>-linux/include path, so it fails to find cub/cub.cuh even though
    # cuda-cccl_linux-64 shipped it there. Inject the path as an extra HINTS entry.
    # No-op for CUDA 13+, which doesn't call find_package(CUB).
    if [[ ${cuda_compiler_version} == 12.* ]] && [[ -f cmake/Modules/FindCUB.cmake ]]; then
        sed -i.bak \
            's|HINTS "${CUDAToolkit_INCLUDE_DIRS}"|HINTS "${CUDAToolkit_INCLUDE_DIRS}" "'"${PREFIX}/targets/${_cuda_arch}/include"'"|' \
            cmake/Modules/FindCUB.cmake
    fi
else
    # MKLDNN is an Apache-2.0 licensed library for DNNs and is used
    # for CPU builds. Not to be confused with MKL.
    export USE_MKLDNN=1
    export USE_CUDA=0
    export CMAKE_TOOLCHAIN_FILE="${RECIPE_DIR}/cross-linux.cmake"
fi

echo '${CXX}'=${CXX}
echo '${PREFIX}'=${PREFIX}

# ============================================================
# SIR-3273 DIAGNOSTIC [block 3/3]: final env right before build
# Last chance to capture what's actually in env when setup.py /
# pip starts. Anything overridden between blocks [2/3] and here is
# from pytorch's own setup.py / CMake configure, not our recipe.
# ============================================================
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "===================================================================="
    echo "SIR-3273 DIAGNOSTIC [3/3] — FINAL env just before pip $PIP_ACTION"
    echo "===================================================================="
    echo "[L] Sysroot / SDK env at point of build invocation:"
    echo "    CONDA_BUILD_SYSROOT:           ${CONDA_BUILD_SYSROOT:-<unset>}"
    echo "    CMAKE_OSX_SYSROOT:             ${CMAKE_OSX_SYSROOT:-<unset>}"
    echo "    CMAKE_OSX_DEPLOYMENT_TARGET:   ${CMAKE_OSX_DEPLOYMENT_TARGET:-<unset>}"
    echo "    SDKROOT:                       ${SDKROOT:-<unset>}"
    echo "    MACOSX_DEPLOYMENT_TARGET:      ${MACOSX_DEPLOYMENT_TARGET:-<unset>}"
    echo "    MACOSX_SDK_VERSION:            ${MACOSX_SDK_VERSION:-<unset>}"
    echo
    echo "[M] Compiler invocation reality check:"
    echo "    CC:                            ${CC:-<unset>}"
    echo "    CXX:                           ${CXX:-<unset>}"
    echo "    CFLAGS:                        ${CFLAGS:-<unset>}"
    echo "    CXXFLAGS:                      ${CXXFLAGS:-<unset>}"
    echo "    LDFLAGS:                       ${LDFLAGS:-<unset>}"
    echo "    CMAKE_ARGS (may be stale):     ${CMAKE_ARGS:-<unset>}"
    echo
    echo "[N] What does the active clang resolve right now?"
    ${CXX:-clang++} -v -E -x c++ /dev/null 2>&1 | grep -iE "(sysroot|sdk|Apple|target|Target)" | head -15 || true
    echo
    echo "[O] Compile-test: does \${CXX} with current flags see MTLLanguageVersion3_0?"
    cat > /tmp/sir3273_metal_probe.mm <<'EOF'
#include <Metal/Metal.h>
int main() { return (int)MTLLanguageVersion3_0; }
EOF
    echo "    Trying compile probe with CXX + CXXFLAGS + LDFLAGS:"
    ${CXX:-clang++} ${CXXFLAGS} ${LDFLAGS} -ObjC++ -fobjc-arc \
        -framework Metal -framework Foundation \
        /tmp/sir3273_metal_probe.mm -o /tmp/sir3273_metal_probe \
        -v 2>&1 | grep -iE "(sysroot|sdk|MTLLanguageVersion3_0|error:)" | head -20 || true
    rm -f /tmp/sir3273_metal_probe.mm /tmp/sir3273_metal_probe
    echo "===================================================================="
fi

$PREFIX/bin/python -m pip $PIP_ACTION . --no-deps --no-build-isolation -vvv --no-clean \
    | sed "s,${CXX},\$\{CXX\},g" \
    | sed "s,${PREFIX},\$\{PREFIX\},g"

if [[ "$PKG_NAME" == "libtorch" ]]; then
  mkdir -p $SRC_DIR/dist
  pushd $SRC_DIR/dist
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
