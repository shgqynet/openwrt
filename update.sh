#!/bin/bash
# =======================================================
# OpenWrt (Lean) 本地【二次增量编译】脚本
# 适用场景：源码更新、仅仅修改了 .config 增加或删除了某插件
# 特色：保留编译缓存，几分钟即可压制出新固件！
# =======================================================

set -e
BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "==========================================================="
echo "   ⚡ 欢迎使用 Lean's OpenWrt 本地增量编译/升级脚本 ⚡"
echo "==========================================================="

if [ ! -d "$BASE_DIR/lede" ]; then
    echo "❌ 错误：没找到 lede 目录！请确定你之前已经用过全新编译脚本。"
    exit 1
fi

cd "$BASE_DIR/lede"

echo -e "\n[1/5] 正在清理上一次 diy-part 造成的本地文件改动以防止代码冲突..."
# 撤销被 git 追踪的文件改动（如 IP、主机名等修改），保留编译好的 .o 缓存
git checkout .
# 关键修复①：排除我们手动 clone 的三个第三方插件目录，防止它们被误删后触发重新编译！
git clean -df \
    -e package/luci-app-pushbot \
    -e package/luci-app-aliddns \
    -e package/luci-app-argon-config
# 关键修复②：不再暴力删除 feeds/，保留已有 feeds 缓存，避免全量重新索引所有包

echo -e "\n[2/5] 从 Lean 的官方仓库同步并强制对齐最新代码..."
git fetch --all
git reset --hard origin/master

echo -e "\n[2.5/5] 执行环境准备 ( diy-part1.sh ) ..."
if [ -f "$BASE_DIR/diy-part1.sh" ]; then
    echo "✅ 挂载 diy-part1.sh 添加第三方插件源..."
    bash "$BASE_DIR/diy-part1.sh"
else
    echo "未找到 diy-part1.sh，跳过这一步。"
fi

echo -e "\n[3/5] 更新并安装所有的第三方插件源 (Feeds)..."
# 增加 Feeds 更新重试机制
set +e
for i in 1 2 3; do
    echo "正在更新 Feeds，第 $i 次尝试..."
    ./scripts/feeds update -a
    if [ $? -eq 0 ]; then
        echo "✅ Feeds 更新成功。"
        break
    else
        echo "⚠️  Feeds 更新失败，准备重试..."
        if [ $i -eq 3 ]; then
            echo "❌ 严重错误：Feeds 更新连续失败 3 次。请检查网络！"
            exit 1
        fi
        sleep 2
    fi
done
set -e
./scripts/feeds install -a

echo -e "\n[4/5] 重新注入你的私人定制配置 (diy-part2 及 .config)..."
if [ -f "$BASE_DIR/diy-part2.sh" ]; then
    bash "$BASE_DIR/diy-part2.sh"
fi

if [ -f "$BASE_DIR/.config" ]; then
    cp "$BASE_DIR/.config" .config
    # 关键修复③：注入 ccache 编译缓存选项，必须在 make defconfig 之前追加
    echo "CONFIG_CCACHE=y" >> .config
    # 扩展生成完整依赖清单
    make defconfig
else
    echo "❌ 没有找到 $BASE_DIR/.config"
    exit 1
fi

echo -e "\n[5/5] 🚀开始光速级别的增量编译！"
# 如果有新的包，稍微下载一下 (耗时极短，因为99%都在本地了)
set +e
for i in 1 2 3; do
    echo "尝试执行代码包下载，第 $i 次运行..."
    make download -j8 V=s
    if [ $? -eq 0 ]; then
        echo "✅ 下载步骤结束。"
        break
    else
        echo "⚠️  下载过程中遇到网络阻断或超时报错！准备重试..."
        if [ $i -eq 3 ]; then
            echo "❌ 严重错误：下载连续失败 3 次。请检查终端网络！"
            exit 1
        fi
        sleep 3
    fi
done
set -e

CORES=$(nproc)
MAKE_CORES=$((CORES + 1))
echo "检测到 $CORES 个核心。增量编译通常只需 5~15 分钟，喝口水就好。"

set +e
# 直接 make，绝不执行 make clean（那会清理掉所有心血缓存重头再来）
make -j$MAKE_CORES V=s
COMPILE_RES=$?
set -e

if [ $COMPILE_RES -eq 0 ]; then
    echo "==========================================================="
    echo " 🎉 二次/增量编译完美结束！ 🎉"
    echo " 你的全新版本固件在: $(pwd)/bin/targets/"
    echo "==========================================================="
else
    echo "==========================================================="
    echo " ⚠️ 增量编译由于代码结构改变发生错误，转入单线程排错..."
    make -j1 V=s
    echo "❌ 如果单线程在这里停下，请截图上方的英文报错信息，那就是源头！"
    echo "==========================================================="
fi
