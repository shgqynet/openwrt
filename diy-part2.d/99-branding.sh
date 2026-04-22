#!/bin/bash
# 99-branding.sh - 固件版本号、SSH Banner、LuCI 概览及 Argon 底栏定制

# 注入固件版本号，供 luci-app-autoupdate 与 GitHub Release Tag 进行比对
# Release Tag 格式 (openwrt-builder.yml)：YYYY.MM.DD-HHMM
BUILD_DATE="${BUILD_VERSION:-$(TZ=UTC-8 date +"%Y.%m.%d-%H%M")}"

sed -i '/^CONFIG_VERSION_NUMBER=/d' .config
sed -i '/^CONFIG_VERSION_CODE=/d' .config

echo "CONFIG_VERSION_NUMBER=\"${BUILD_DATE}\"" >> .config
sed -i "s/R[0-9]\+\.[0-9]\+\.[0-9]\+/${BUILD_DATE}/g" package/lean/default-settings/files/zzz-default-settings

# 写入 SSH 登录欢迎 Banner（含 ASCII Art + 作者/项目/构建时间）
mkdir -p package/base-files/files/etc
cat > package/base-files/files/etc/banner << EOF
  _______                     ________        __
 |       |.-----.-----.-----.|  |  |  |.----.|  |_
 |   -   ||  _  |  -__|     ||  |  |  ||   _||   _|
 |_______||   __|_____|__|__||________||__|  |____|
          |__| W I R E L E S S   F R E E D O M
 -----------------------------------------------------
  作者：夏昸
  项目：https://github.com/suifeng009/openwrt
  构建：${BUILD_DATE}
 -----------------------------------------------------
EOF

# 写入 LuCI 概览页厂商/项目信息（官方 CONFIG_VERSION_* 字段）
sed -i '/^CONFIG_VERSION_MANUFACTURER=/d' .config
sed -i '/^CONFIG_VERSION_BUG_URL=/d' .config
echo 'CONFIG_VERSION_MANUFACTURER="夏风拂尽千重网，昸日长明万卷云。"' >> .config
echo 'CONFIG_VERSION_BUG_URL="https://github.com/suifeng009/openwrt"' >> .config

# 在固件元信息文件追加自定义作者字段（供脚本/插件读取）
mkdir -p package/base-files/files/etc
# 若文件不存在则创建，避免追加到空路径
touch package/base-files/files/etc/openwrt_release
grep -q "DISTRIB_AUTHOR" package/base-files/files/etc/openwrt_release \
  || cat >> package/base-files/files/etc/openwrt_release << 'REOF'
DISTRIB_AUTHOR="夏昸"
DISTRIB_PROJECT="https://github.com/suifeng009/openwrt"
REOF

# 自定义 Argon 登录页底部 Footer（直接覆写主题源码，避免与 base-files 文件冲突）
# argon 主题由 feeds 提供，其源码路径为 feeds/luci/themes/luci-theme-argon
# 直接写入该路径，文件归属仍属于 argon 包，不会触发 check_data_file_clashes
ARGON_FOOTER="feeds/luci/themes/luci-theme-argon/luasrc/view/themes/argon/footer_login.htm"
if [ -f "$ARGON_FOOTER" ]; then
  cat > "$ARGON_FOOTER" << 'EOF'
<%
local ver = require "luci.version"
%>
<div class="login-footer">
        <span><a href="https://github.com/suifeng009/openwrt" target="_blank">夏风拂尽千重网，昸日长明万卷云。</a></span>
  <span> <%= ver.distversion %></span>
</div>
EOF
fi

# 修改主界面页脚为自定义超链接与诗句 (解决多链接问题)
# 1. 移除原有的 Powered by LuCI 和 ArgonTheme 链接区域
find feeds/luci/themes/luci-theme-argon/ -type f -name "footer*" | xargs -i sed -i 's/<a.*Powered by.*<\/a>//g' {}
find feeds/luci/themes/luci-theme-argon/ -type f -name "footer*" | xargs -i sed -i 's/<a.*ArgonTheme.*<\/a>//g' {}
find feeds/luci/themes/luci-theme-argon/ -type f -name "footer*" | xargs -i sed -i 's/<span class="footer-separator">|<\/span>//g' {}

# 2. 将发行版版本区域替换为你的专属诗句链接
# 适配 23.05 的 ucode 模板 (.ut) 和 传统模板 (.htm)
find feeds/luci/themes/luci-theme-argon/ -type f -name "footer*" | xargs -i sed -i 's/{{ version.distname }} {{ version.distversion }}-{{ version.distrevision }}/<a href="https:\/\/github.com\/suifeng009\/openwrt" target="_blank">夏风拂尽千重网，昸日长明万卷云。<\/a>/g' {}
find feeds/luci/themes/luci-theme-argon/ -type f -name "footer*" | xargs -i sed -i 's/<%=ver.distname%> <%=ver.distversion%> (.*)/<a href="https:\/\/github.com\/suifeng009\/openwrt" target="_blank">夏风拂尽千重网，昸日长明万卷云。<\/a>/g' {}
