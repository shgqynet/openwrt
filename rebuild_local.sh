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
# 【魔法操作所在】：撤销本地 C 代码和配置文件的修改，但完美保留所有编译好的 .o 缓存文件！
git checkout .

echo -e "\n[2/5] 从 Lean 的官方仓库同步并拉取最新的一手源码..."
git pull origin master

echo -e "\n[3/5] 更新并安装所有的第三方插件源 (Feeds)..."
./scripts/feeds update -a
./scripts/feeds install -a

echo -e "\n[4/5] 重新注入你的私人定制配置 (diy-part2 及 .config)..."
if [ -f "$BASE_DIR/diy-part2.sh" ]; then
    bash "$BASE_DIR/diy-part2.sh"
fi

if [ -f "$BASE_DIR/.config" ]; then
    cp "$BASE_DIR/.config" .config
    # 清理掉可能失效的旧包依赖，生成新清单
    make defconfig
else
    echo "❌ 没有找到 $BASE_DIR/.config"
    exit 1
fi

echo -e "\n[5/5] 🚀开始光速级别的增量编译！"
# 如果有新的包，稍微下载一下 (耗时极短，因为99%都在本地了)
make download -j8 V=s

CORES=$(nproc)
echo "检测到 $CORES 个核心。增量编译通常只需 5~15 分钟，喝口水就好。"

set +e
# 直接 make，绝不执行 make clean（那会清理掉所有心血缓存重头再来）
make -j$CORES V=s
COMPILE_RES=$?
set -e

if [ $COMPILE_RES -eq 0 ]; then
    echo "==========================================================="
    echo " 🎉 二次/增量编译完美结束！ 🎉"
    echo " 你的全新版本固件在: $(pwd)/bin/targets/"
    echo "==========================================================="
else
    echo "⚠️ 增量编译由于代码结构改变发生了冲突错误，转入单线程排错..."
    make -j1 V=s
fi
