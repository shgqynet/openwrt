#!/bin/bash
# 00-fix-cmake.sh - 动态探测并自动降级过高的 CMake 版本依赖要求

# 获取系统当前实际执行的 CMake 版本 (例如 3.30.5 截取为主次版本号 3.30)
if ! command -v cmake &> /dev/null; then
    echo "Warning: cmake command not found in PATH. Skipping CMake version dynamic fix."
    exit 0
fi

CURRENT_CMAKE_VERSION=$(cmake --version | head -n1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
if [ -z "$CURRENT_CMAKE_VERSION" ]; then
    echo "Warning: Could not parse cmake version. Skipping CMake fix."
    exit 0
fi

# 提取主次版本号 (例如 3.30.5 -> 3.30)
CURRENT_MAJOR_MINOR=$(echo "$CURRENT_CMAKE_VERSION" | cut -d. -f1,2)

echo "[CMake Fix] Current system CMake version is $CURRENT_CMAKE_VERSION."
echo "[CMake Fix] Setting compatibility cap to $CURRENT_MAJOR_MINOR"

# 查找所有 feeds 目录下的 CMakeLists.txt 并按需降级
find feeds -name "CMakeLists.txt" -type f 2>/dev/null | while read -r file; do
    # 查找如 cmake_minimum_required(VERSION 3.31) 中的版本号
    REQ_VER=$(grep -i 'cmake_minimum_required.*VERSION' "$file" | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    
    if [ -n "$REQ_VER" ]; then
        # 比较两个版本号。如果 REQ_VER > CURRENT_MAJOR_MINOR，说明代码库要求超过了系统能力
        # 使用 sort -V 来自然排序版本号
        HIGHEST=$(printf '%s\n' "$REQ_VER" "$CURRENT_MAJOR_MINOR" | sort -V | tail -n1)
        
        if [ "$HIGHEST" = "$REQ_VER" ] && [ "$REQ_VER" != "$CURRENT_MAJOR_MINOR" ]; then
            echo "[CMake Fix] -> Patching $file: Lowering required version from $REQ_VER to $CURRENT_MAJOR_MINOR"
            # 动态替换版本号
            sed -i "s/VERSION[[:space:]]*$REQ_VER/VERSION $CURRENT_MAJOR_MINOR/gi" "$file"
        fi
    fi
done

echo "[CMake Fix] Dynamic CMake adaptation completed."
