project(cf_dummy LANGUAGES C CXX)
cmake_minimum_required(VERSION 3.12)
# Ask for the exact version: without TorchConfigVersion.cmake an unversioned
# find_package still succeeds, but downstream find_package(Torch <ver>) fails.
find_package(Torch ${TORCH_EXPECTED_VERSION} EXACT CONFIG REQUIRED)
find_package(ATen CONFIG REQUIRED)