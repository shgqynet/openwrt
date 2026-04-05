#!/bin/bash
#
# diy-part1.sh - 在 update feeds 之前执行
# 用途：修改 feeds.conf.default，添加第三方插件源
#

# 1. 添加 OpenClash 源 (作为主力科学上网插件)
echo 'src-git openclash https://github.com/vernesong/OpenClash.git;dev' >> feeds.conf.default

# 2. 添加 全能推送 (PushBot/微信推送)
echo 'src-git pushbot https://github.com/zzsj0928/luci-app-pushbot' >> feeds.conf.default

# 注：luci-theme-argon 和 luci-app-adguardhome 已内置于 LEDE 官方 feeds，无需单独添加
