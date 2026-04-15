#!/bin/bash
#
# diy-part1.sh - 在 update feeds 之前执行
# 用途：修改 feeds.conf.default，添加第三方插件源
#

# 0. 找回 SSR-Plus (解开 Lean 源码自带的 helloworld 注释)
sed -i 's/^#\(.*helloworld\)/\1/' feeds.conf.default

# 1. 添加 OpenClash 源 (作为主力科学上网插件)
echo 'src-git openclash https://github.com/vernesong/OpenClash.git;dev' >> feeds.conf.default

# 2. 添加 tty228 微信/全能推送 (目前最活跃的推送插件)
# 改为手动 git clone，防止被 make defconfig 静默删除
rm -rf package/luci-app-pushbot
rm -rf package/luci-app-wechatpush
git clone https://github.com/tty228/luci-app-wechatpush.git package/luci-app-wechatpush



