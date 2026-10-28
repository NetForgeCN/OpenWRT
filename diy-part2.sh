#!/usr/bin/env bash

# ============================================================
# DIY2：第三方软件包、Rust LLVM 与内核配置
#
# 执行位置：
#   OpenWrt 源码根目录
#
# 处理内容：
#   1. 克隆非 feeds 管理的第三方软件包
#   2. 修改 Rust LLVM 下载参数
#   3. 替换官方 v2ray-geodata
#   4. 修改 x86 Linux 6.18 内核配置
#
# 所有 git clone 均使用完整克隆，不使用浅克隆。
# ============================================================

set -e

echo "=========================================="
echo "DIY2：第三方软件包与编译配置"
echo "当前目录：$(pwd)"
echo "=========================================="

# ============================================================
# 1. 克隆其他第三方软件包
# ============================================================

echo
echo ">>> 1. 克隆第三方软件包"

# 这些软件包不由 feeds 管理。
# v2ray-geodata 在后面单独处理。

git clone \
    https://github.com/gSpotx2f/luci-app-temp-status.git \
    package/luci-app-temp-status

git clone \
    https://github.com/jerrykuku/luci-theme-argon.git \
    package/luci-theme-argon

git clone \
    https://github.com/w9315273/luci-app-pulse.git \
    package/luci-app-pulse

echo "第三方软件包克隆完成"


# ============================================================
# 2. 修改 Rust LLVM 下载参数
# ============================================================

echo
echo ">>> 2. 修改 Rust LLVM 下载参数"

RUST_MAKEFILE="feeds/packages/lang/rust/Makefile"

if [ ! -f "$RUST_MAKEFILE" ]; then
    echo "❌ 错误：找不到 $RUST_MAKEFILE"
    exit 1
fi

if grep -qE -- '--set=llvm\.download-ci-llvm=(falst|false)' "$RUST_MAKEFILE"; then

    sed -i -E \
        's/--set=llvm\.download-ci-llvm=(falst|false)/--set=llvm.download-ci-llvm=true/g' \
        "$RUST_MAKEFILE"

    echo "✅ Rust LLVM 下载参数已修改为 true"

elif grep -qF -- '--set=llvm.download-ci-llvm=true' "$RUST_MAKEFILE"; then

    echo "✅ Rust LLVM 下载参数已经是 true"

else

    echo "❌ 错误：未找到预期的 Rust LLVM 下载参数"
    echo "检查文件：$RUST_MAKEFILE"
    exit 1

fi


# ============================================================
# 3. 替换官方 v2ray-geodata
# ============================================================

echo
echo ">>> 3. 替换官方 v2ray-geodata"

OFFICIAL_V2RAY="feeds/packages/net/v2ray-geodata"
THIRD_V2RAY="package/v2ray-geodata"

# 删除 feeds/packages 中官方版本

if [ -e "$OFFICIAL_V2RAY" ]; then
    rm -rf -- "$OFFICIAL_V2RAY"
    echo "✅ 已删除官方 v2ray-geodata"
else
    echo "ℹ️ 官方 v2ray-geodata 不存在"
fi

# 克隆第三方版本
# 不使用 --depth，获取完整 Git 历史。

git clone \
    https://github.com/NetForgeCN/Loyalsoldier.git \
    "$THIRD_V2RAY"

echo "✅ 第三方 v2ray-geodata 克隆完成"


# ============================================================
# 4. 修改 x86 Linux 6.18 内核配置
# ============================================================

echo
echo ">>> 4. 修改 x86 Linux 6.18 内核配置"

KERNEL_CONFIG="target/linux/x86/config-6.18"

if [ ! -f "$KERNEL_CONFIG" ]; then
    echo "❌ 错误：找不到 $KERNEL_CONFIG"
    exit 1
fi

# ------------------------------------------------------------
# 设置内核配置
#
# 参数：
#   $1 = 配置名称，不包含 CONFIG_
#   $2 = 最终配置行
#
# 功能：
#   1. 删除已有的同名 CONFIG
#   2. 删除 "# CONFIG_xxx is not set"
#   3. 添加新的配置
#   4. 避免重复配置
# ------------------------------------------------------------

set_kernel_config() {
    local key="$1"
    local value="$2"
    local tmp

    tmp="$(mktemp "${KERNEL_CONFIG}.XXXXXX")"

    awk -v key="$key" '
        $0 ~ "^CONFIG_" key "=" { next }
        $0 ~ "^# CONFIG_" key " is not set$" { next }
        { print }
    ' "$KERNEL_CONFIG" > "$tmp"

    printf '%s\n' "$value" >> "$tmp"

    chmod --reference="$KERNEL_CONFIG" "$tmp"
    mv -- "$tmp" "$KERNEL_CONFIG"
}

# 启用 NETKIT
set_kernel_config \
    "NETKIT" \
    "CONFIG_NETKIT=y"

# 禁用 X86_NATIVE_CPU
set_kernel_config \
    "X86_NATIVE_CPU" \
    "# CONFIG_X86_NATIVE_CPU is not set"

# 禁用 X86_SGX
set_kernel_config \
    "X86_SGX" \
    "# CONFIG_X86_SGX is not set"

echo "✅ 内核配置修改完成"


# ============================================================
# 5. 检查最终配置
# ============================================================

echo
echo ">>> 最终内核配置："

grep -nE \
    '^(CONFIG_NETKIT=y|# CONFIG_X86_NATIVE_CPU is not set|# CONFIG_X86_SGX is not set)$' \
    "$KERNEL_CONFIG"


# ============================================================
# 完成
# ============================================================

echo
echo "=========================================="
echo "✅ DIY2 所有任务完成"
echo "=========================================="