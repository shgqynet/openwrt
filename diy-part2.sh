#!/bin/bash
# diy-part2.sh - 在 install feeds 之后执行
# 用途：修改默认配置，预置自定义设置 (通过包含 diy-part2.d 下的子脚本实现)

# 自动探测并定义仓库根目录 (REPO_SRC)
# 优先级：GITHUB_WORKSPACE (云端) > 脚本所在目录的父目录 (本地)
export REPO_SRC="$GITHUB_WORKSPACE"
if [ -z "$REPO_SRC" ]; then
    REPO_SRC="$(cd "$(dirname "$0")" && pwd)"
fi

script_dir="$REPO_SRC/diy-part2.d"

if [ -d "$script_dir" ]; then
    echo "========================================================="
    echo " Executing custom scripts from $script_dir"
    echo "========================================================="
    for script in $(ls "$script_dir"/*.sh | sort); do
        if [ -f "$script" ]; then
            echo "---------------------------------------------------------"
            echo "-> Executing: $(basename "$script")"
            echo "---------------------------------------------------------"
            source "$script"
        fi
    done
    echo "========================================================="
    echo " All custom scripts executed successfully."
    echo "========================================================="
else
    echo "Warning: Directory $script_dir not found. Skipping custom scripts execution."
fi