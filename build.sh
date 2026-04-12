#!/bin/bash
# =======================================================
# OpenWrt (Lean) 本地终极一键编译脚本 (全新环境专版)
# 适用环境: Ubuntu 22.04 LTS / 24.04 LTS 或 最新版 WSL2
# =======================================================

# 设置报错即退出
set -e

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$BASE_DIR"

echo "==========================================================="
echo "   🚀 欢迎使用 Lean's OpenWrt 本地一键编译脚本 (完美防呆版)"
echo "==========================================================="

# --- 问题排查 1：绝对不能用 root 用户编译 ---
if [ "$EUID" -eq 0 ]; then
  echo "❌ 严重错误：千万不能使用 root 用户运行此脚本或编译 OpenWrt！"
  echo "👉 请使用普通用户登录 (例如 ubuntu)，然后重新运行脚本：bash build_local.sh"
  exit 1
fi

# --- 问题排查 2：路径中包含空格会导致编译神秘报错 ---
if [[ "$BASE_DIR" == *" "* ]]; then
  echo "❌ 严重错误：当前路径中打死不能包含空格！"
  echo "当前路径: $BASE_DIR"
  echo "👉 请将所有文件移动到没有空格的路径下 (例如 /home/user/openwrt) 再次运行。"
  exit 1
fi

# --- 问题排查 3：磁盘空间检查 (可用空间至少要 30G) ---
echo -e "\n[准备] 当前磁盘情况检查，请确保剩余容量 > 30GB..."
FREE_SPACE_KB=$(df -k . | tail -n1 | awk '{print $4}')
FREE_SPACE_GB=$((FREE_SPACE_KB / 1024 / 1024))
if [ "$FREE_SPACE_GB" -lt 30 ]; then
  echo "❌ 严重错误：当前磁盘剩余空间仅剩约 ${FREE_SPACE_GB}GB，可能导致编译中途失败退出。"
  echo "👉 请清理磁盘，确保至少有 30GB 以上剩余空间后再次执行。"
  exit 1
else
  echo "✅ 磁盘空间充足 (${FREE_SPACE_GB}GB)。"
fi

# --- 安装编译必备依赖 (针对全新安装的系统) ---
echo -e "\n[准备] 正在为全新安装的系统配置编译依赖环境..."
echo "⚠️  注意：下面需要使用 sudo 提权下载依赖，可能会提示您输入当前登录用户的密码"
echo "开始安装系统编译依赖包..."

# Lean 源码官方推荐依赖 (适用于 Ubuntu 22.04)
sudo apt-get update -y
sudo apt-get install -y ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
bzip2 ccache cmake cpio curl device-tree-compiler fastjar flex gawk gettext gcc-multilib g++-multilib \
git gperf haveged help2man intltool libc6-dev-i386 libelf-dev libfuse-dev libglib2.0-dev libgmp3-dev \
libltdl-dev libmpc-dev libmpfr-dev libncurses5-dev libncursesw5-dev libpython3-dev libreadline-dev \
libssl-dev libtool lrzsz mkisofs msmtp ninja-build p7zip p7zip-full patch pkgconf python2.7 python3 \
python3-pyelftools python3-setuptools qemu-utils rsync scons squashfs-tools subversion swig texinfo \
uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev python3-pip

echo "✅ 系统组件包准备完毕！"

# ----------- 开始正式的编译流程 -----------

echo -e "\n[1/7] 获取最新版 Lean 源码 ..."
if [ ! -d "lede" ]; then
    # --depth 1 加速浅克隆，如果只为编译不为开发者是很合适的
    echo "源码目录不存在，正在从 Github 克隆 (加时可能较长，需保持网络通畅)..."
    git clone https://github.com/coolsnowwolf/lede.git lede
else
    echo "源码已存在。正在恢复最新状态..."
    cd lede
    git reset --hard HEAD
    git pull origin master
    cd ..
fi

cd lede

echo -e "\n[2/7] 执行环境准备 ( diy-part1.sh ) ..."
if [ -f "$BASE_DIR/diy-part1.sh" ]; then
    echo "✅ 挂载 diy-part1.sh 添加第三方插件源..."
    # 授予执行权限并运行
    chmod +x "$BASE_DIR/diy-part1.sh"
    bash "$BASE_DIR/diy-part1.sh"
else
    echo "未找到 diy-part1.sh，跳过这一步。"
fi

echo -e "\n[3/7] 更新并安装所有 Feeds 软件包 ..."
./scripts/feeds update -a
./scripts/feeds install -a

echo -e "\n[4/7] 执行自定义修改 ( diy-part2.sh ) ..."
if [ -f "$BASE_DIR/diy-part2.sh" ]; then
    echo "✅ 挂载 diy-part2.sh 修改 IP 及克隆独立主题等..."
    chmod +x "$BASE_DIR/diy-part2.sh"
    bash "$BASE_DIR/diy-part2.sh"
else
    echo "未找到 diy-part2.sh，跳过这一步。"
fi

echo -e "\n[5/7] 应用核心配方并校对依赖 (.config) ..."
if [ -f "$BASE_DIR/.config" ]; then
    echo "✅ 找到 .config 文件，正在应用..."
    cp "$BASE_DIR/.config" .config
    # 扩展生成完整的默认配置清单
    make defconfig
    # make defconfig 会覆盖版本号，必须在之后重新注入
    BUILD_DATE="$(date +"%Y.%m.%d-%H%M")"
    sed -i '/^CONFIG_VERSION_NUMBER=/d' .config
    echo "CONFIG_VERSION_NUMBER=\"${BUILD_DATE}\"" >> .config
    echo "✅ 固件版本号已注入: ${BUILD_DATE}"
else
    echo "❌ 严重错误: 当前环境没有 .config，无法编译！"
    exit 1
fi

echo -e "\n[6/7] 猛烈下载构建所需的依赖库文件 (这一步非常吃网络)..."
# 使用 while 循环配合 make download 增加容错率。网络报错时我们尝试再次执行两次。
set +e # 临时关闭报错退出
for i in 1 2 3; do
    echo "尝试执行代码包下载，第 $i 次运行..."
    make download -j8 V=s
    if [ $? -eq 0 ]; then
        echo "✅ 下载步骤结束。"
        break
    else
        echo "⚠️  下载过程中遇到网络阻断或超时报错！准备重试..."
        if [ $i -eq 3 ]; then
            echo "❌ 严重错误：下载组件包连续失败 3 次。请务必检查你的终端网络是否可以正常访问 Github 和海外资源（如配置 export ALL_PROXY=xxx）！"
            exit 1
        fi
        sleep 3
    fi
done
set -e

echo -e "\n[7/7] 💥 鸣枪开战: 开始固件漫长编译！ 💥"
CORES=$(nproc)
MAKE_CORES=$((CORES + 1))
# 推荐首次编译只用一个核心(V=s 打印详细日志)可以防止多线程死锁。但现代机器一般多线编译容错已提高，我们这里做双重保险：多核全速跑，如果挂了切单核排错。
echo "检测到系统分配了 $CORES 个 CPU 核心！"
echo "☕ 开始执行全速编译（约 1-3 小时），请勿关闭终端窗口！"

# 关闭因为编译报错导致的直接退出，自己捕获
set +e
make -j$MAKE_CORES V=s
COMPILE_RES=$?
set -e

if [ $COMPILE_RES -eq 0 ]; then
    echo "==========================================================="
    echo " 🎉 编译流程大成功！ 🎉"
    echo " 你的最终软路由固件存放在: "
    echo " $(pwd)/bin/targets/"
    echo "==========================================================="
else
    echo "==========================================================="
    echo " ⚠️ 多线程编译意外报错中断！准备使用单线程再试一次并输出诊断信息..."
    make -j1 V=s
    echo "❌ 如果单线程这里停下了，请截图这里的英文报错信息，那就是导致编译失败的源头！"
    echo "==========================================================="
fi
