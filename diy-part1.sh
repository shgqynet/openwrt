#!/bin/bash
#
# diy-part1.sh - 在 update feeds 之前执行
# 用途：修改 feeds.conf.default，添加第三方插件源
#

# 1. 添加 SSR-Plus (helloworld) 源
#    LEDE 的 feeds.conf.default 中没有预置此行，需要直接追加
echo 'src-git helloworld https://github.com/fw876/helloworld.git' >> feeds.conf.default

# 2. 添加 OpenClash 源
echo 'src-git openclash https://github.com/vernesong/OpenClash.git;dev' >> feeds.conf.default

# 3. 添加 Argon 主题源（确保获取最新版）
echo 'src-git argon https://github.com/jerrykuku/luci-theme-argon.git;master' >> feeds.conf.default

# 4. 添加 AdGuard Home 源
echo 'src-git adguardhome https://github.com/rufengsuixing/luci-app-adguardhome.git' >> feeds.conf.default
