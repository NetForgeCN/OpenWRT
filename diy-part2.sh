#!/usr/bin/env bash

# ============================================================
# DIY2：第三方软件包、Rust LLVM 与内核配置
#
# 由 GitHub Actions 工作流调用。
#
# 处理内容：
# 1. 克隆非 feeds 管理的第三方软件包
# 2. 修改 Rust LLVM 下载参数
# 3. 替换官方 v2ray-geodata
# 4. 修改 x86 Linux 6.18 内核配置
#
# GitHub Actions 每次均按首次构建处理。
# 所有 git clone 均不使用浅克隆。
# ============================================================

set -e

cd "$GITHUB_WORKSPACE"

echo "=========================================="
echo "处理第三方软件包与编译配置"
echo "=========================================="

# ============================================================
# 1. 克隆其他第三方软件包
# ============================================================

echo "开始克隆第三方软件包"

# v2ray-geodata 单独处理，放在后面。
# 以下仓库均不属于 feeds 管理。

git clone \
    https://github.com/gSpotx2f/luci-app-temp-status.git \
    package/luci-app-temp-status

git clone \
    https://github.com/jerrykuku/luci-theme-argon.git \
    package/luci-theme-argon

git clone \
    https://github.com/w9315273/luci-app-pulse.git \
    package/luci-app-pulse

echo "普通第三方软件包克隆完成"

# ============================================================
# 2. 修改 Rust LLVM 下载参数
# ============================================================

echo "修改 Rust LLVM 下载参数"

RUST_MAKEFILE="feeds/packages/lang/rust/Makefile"

if [ ! -f "$RUST_MAKEFILE" ]; then
    echo "错误：找不到 $RUST_MAKEFILE"
    exit 1
fi

# 将 false 或误写的 falst 修改为 true。
# 如果已经是 true，则不重复修改。
if grep -qE -- '--set=llvm\.download-ci-llvm=(falst|false)' "$RUST_MAKEFILE"; then

    sed -i -E \
        's/--set=llvm\.download-ci-llvm=(falst|false)/--set=llvm.download-ci-llvm=true/g' \
        "$RUST_MAKEFILE"

    echo "Rust LLVM 下载参数已修改为 true"

elif grep -qF -- '--set=llvm.download-ci-llvm=true' "$RUST_MAKEFILE"; then

    echo "Rust LLVM 下载参数已经是 true"

else

    echo "错误：未找到预期的 Rust LLVM 下载参数"
    echo "请检查 $RUST_MAKEFILE"
    exit 1

fi

# ============================================================
# 3. 删除官方 v2ray-geodata，克隆第三方版本
# ============================================================

echo "替换官方 v2ray-geodata"

OFFICIAL_V2RAY="feeds/packages/net/v2ray-geodata"
THIRD_V2RAY="package/v2ray-geodata"

# 删除官方软件包定义。
# 这是明确要求的特殊处理，不适用于其他第三方软件包。

if [ -e "$OFFICIAL_V2RAY" ]; then
    rm -rf -- "$OFFICIAL_V2RAY"
    echo "已删除官方 v2ray-geodata"
else
    echo "官方 v2ray-geodata 不存在，跳过删除"
fi

# 克隆第三方版本。
# 不使用 --depth，获取完整 Git 历史。

git clone \
    https://github.com/NetForgeCN/Loyalsoldier.git \
    "$THIRD_V2RAY"

echo "第三方 v2ray-geodata 克隆完成"

# ============================================================
# 4. 修改 x86 Linux 6.18 内核配置
# ============================================================

echo "修改 x86 Linux 6.18 内核配置"

KERNEL_CONFIG="target/linux/x86/config-6.18"

if [ ! -f "$KERNEL_CONFIG" ]; then
    echo "错误：找不到 $KERNEL_CONFIG"
    exit 1
fi

# 设置单个内核配置项：
# - 删除原有的所有同名定义
# - 写入指定的新值
# - 避免重复配置
#
# 参数：
# $1：配置名称，不包含 CONFIG_ 前缀
# $2：目标配置行

set_kernel_config() {
    local key="$1"
    local value="$2"
    local file="$3"
    local tmp

    tmp="$(mktemp "${file}.XXXXXX")"

    awk -v key="$key" '
        $0 ~ "^CONFIG_" key "=" { next }
        $0 ~ "^# CONFIG_" key " is not set$" { next }
        { print }
    ' "$file" > "$tmp"

    printf '%s\n' "$value" >> "$tmp"

    chmod --reference="$file" "$tmp"
    mv -- "$tmp" "$file"
}

# 启用 NETKIT
set_kernel_config \
    "NETKIT" \
    "CONFIG_NETKIT=y" \
    "$KERNEL_CONFIG"

# 禁用 X86_NATIVE_CPU
set_kernel_config \
    "X86_NATIVE_CPU" \
    "# CONFIG_X86_NATIVE_CPU is not set" \
    "$KERNEL_CONFIG"

# 禁用 X86_SGX
set_kernel_config \
    "X86_SGX" \
    "# CONFIG_X86_SGX is not set" \
    "$KERNEL_CONFIG"

echo "内核配置修改完成"

# 显示最终配置，便于 Actions 日志检查。
grep -nE \
    '^(CONFIG_NETKIT=y|# CONFIG_X86_NATIVE_CPU is not set|# CONFIG_X86_SGX is not set)$' \
    "$KERNEL_CONFIG"

echo "=========================================="
echo "DIY2 所有任务完成"
echo "=========================================="