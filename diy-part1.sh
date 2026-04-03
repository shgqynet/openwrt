#!/bin/bash
#
# diy-part1.sh - 在 update feeds 之前执行
# 用途：修改 feeds.conf.default，添加第三方插件源
#

# 1. 添加 SSR-Plus (helloworld) 源
echo 'src-git helloworld https://github.com/fw876/helloworld.git' >> feeds.conf.default

# 2. 添加 OpenClash 源
echo 'src-git openclash https://github.com/vernesong/OpenClash.git;dev' >> feeds.conf.default

# 3. 添加 Passwall2 依赖包源（sing-box / xray 等协议依赖）
echo 'src-git passwall_packages https://github.com/xiaorouji/openwrt-passwall-packages.git;main' >> feeds.conf.default

# 4. 添加 Passwall2 主源
echo 'src-git passwall2 https://github.com/xiaorouji/openwrt-passwall2.git;main' >> feeds.conf.default

# 5. 添加 MosDNS 源（v5 分支，支持规则分流 + DNS-over-HTTPS）
echo 'src-git mosdns https://github.com/sbwml/luci-app-mosdns.git;v5' >> feeds.conf.default

# 6. 添加 Argon 主题源（确保获取最新版）
echo 'src-git argon https://github.com/jerrykuku/luci-theme-argon.git;master' >> feeds.conf.default
