#!/bin/bash
# 00-fix-cmake.sh - 修复 CMake 版本过低的编译错误
# 降低第三方包中的 CMake 依赖版本，以适配 Github Actions 环境

echo "Fixing CMake minimum version requirements..."
find ./feeds ./package -name "CMakeLists.txt" -exec sed -i 's/cmake_minimum_required(VERSION 3.31)/cmake_minimum_required(VERSION 3.30)/g' {} +
find ./feeds ./package -name "CMakeLists.txt" -exec sed -i 's/cmake_minimum_required(VERSION 3.31.0)/cmake_minimum_required(VERSION 3.30.0)/g' {} +
echo "CMake version requirements adjusted."
