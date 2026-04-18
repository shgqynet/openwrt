#!/bin/bash
# 00-fix-cmake.sh - 拦截并强制升级 OpenWrt 内部 Host 工具链使用的 CMake 版本

echo "========================================================="
echo " [CMake Fix] Checking internal OpenWrt Host CMake version"
echo "========================================================="

CMAKE_MAKEFILE="tools/cmake/Makefile"

if [ -f "$CMAKE_MAKEFILE" ]; then
    # 提取 OpenWrt 工具链中的 CMake 版本
    PKG_VER=$(grep "^PKG_VERSION:=" "$CMAKE_MAKEFILE" | cut -d'=' -f2)
    
    echo "Current OpenWrt internal host-cmake version: $PKG_VER"
    
    # 简单的版本判断，如果是 3.30 或以下的 3.x 版本，则强制升级至 3.31.2
    if [[ "$PKG_VER" == 3.30.* ]] || [[ "$PKG_VER" == 3.2* ]]; then
        echo "--> Upgrading OpenWrt host-cmake version to 3.31.2 to satisfy rpcd-mod-luci requirements."
        
        # 替换版本号
        sed -i 's/^PKG_VERSION:=.*/PKG_VERSION:=3.31.2/g' "$CMAKE_MAKEFILE"
        
        # 必须跳过 Hash 校验，否则下载官方源码包时会因为 hash 不匹配而中断
        sed -i 's/^PKG_HASH:=.*/PKG_HASH:=skip/g' "$CMAKE_MAKEFILE"
        
        echo "--> Update successful."
    else
        echo "--> Host CMake version $PKG_VER satisfies requirements or is unknown, skipping override."
    fi
else
    echo "--> Warning: $CMAKE_MAKEFILE not found!"
    echo "--> Skipping internal CMake version bump."
fi

echo "========================================================="
