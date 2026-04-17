#!/bin/bash
# diy-part2.sh - 在 install feeds 之后执行
# 用途：修改默认配置，预置自定义设置 (通过包含 diy-part2.d 下的子脚本实现)

script_dir="$GITHUB_WORKSPACE/diy-part2.d"
if [ ! -d "$script_dir" ]; then
    script_dir="$(dirname "$0")/diy-part2.d"
fi

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