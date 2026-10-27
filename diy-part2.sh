#!/bin/bash

set -e

# ============================================================
# 基础配置
# ============================================================

echo "============================================================"
echo " OpenWrt DIY"
echo "============================================================"

# ------------------------------------------------------------
# Git 仓库处理函数
#
# 第一次执行：
#   目录不存在 -> clone
#
# 后续执行：
#   目录存在且是 Git 仓库 -> 更新到远程默认分支
# ------------------------------------------------------------

clone_or_update() {
    local REPO="$1"
    local DIR="$2"

    echo
    echo "------------------------------------------------------------"
    echo "处理：$DIR"
    echo "仓库：$REPO"
    echo "------------------------------------------------------------"

    if [ -d "$DIR/.git" ]; then

        echo "--> 已存在，更新仓库"

        cd "$DIR"

        git reset --hard HEAD
        git clean -fd

        git fetch --prune origin

        DEFAULT_BRANCH=$(git remote show origin 2>/dev/null \
            | sed -n '/HEAD branch/s/.*: //p')

        if [ -z "$DEFAULT_BRANCH" ]; then
            DEFAULT_BRANCH="master"
        fi

        echo "--> 远程默认分支：$DEFAULT_BRANCH"

        git reset --hard "origin/$DEFAULT_BRANCH"

        cd - >/dev/null

    elif [ -e "$DIR" ]; then

        echo "❌ $DIR 已存在，但不是 Git 仓库"
        echo "请检查目录内容后再执行。"
        exit 1

    else

        echo "--> 首次执行，正在 clone"

        git clone --depth=1 "$REPO" "$DIR"
    fi

    echo "--> $DIR 处理完成"
}


# ============================================================
# Rust 编译配置
# ============================================================

echo
echo "============================================================"
echo " 设置 Rust 编译选项 (download-ci-llvm=true)"
echo "============================================================"

if [ -f "feeds/packages/lang/rust/Makefile" ]; then
    sed -i 's/--set=llvm\.download-ci-llvm=false/--set=llvm.download-ci-llvm=true/' feeds/packages/lang/rust/Makefile
    echo "--> Rust Makefile 修改成功"
else
    echo "⚠️ 未找到 feeds/packages/lang/rust/Makefile，请确保已执行 feeds update"
fi


# ============================================================
# 第三方组件
# ============================================================

# ------------------------------------------------------------
# v2ray-geodata
# ------------------------------------------------------------

# 删除 OpenWrt packages feed 自带的旧版本
rm -rf feeds/packages/net/v2ray-geodata

clone_or_update \
    "https://github.com/NetForgeCN/Loyalsoldier.git" \
    "package/v2ray-geodata"


# ------------------------------------------------------------
# luci-app-temp-status
# ------------------------------------------------------------

clone_or_update \
    "https://github.com/gSpotx2f/luci-app-temp-status.git" \
    "package/luci-app-temp-status"


# ------------------------------------------------------------
# luci-app-dae
# ------------------------------------------------------------

clone_or_update \
    "https://github.com/QiuSimons/luci-app-dae.git" \
    "package/dae"


# ------------------------------------------------------------
# luci-theme-argon
# ------------------------------------------------------------

clone_or_update \
    "https://github.com/jerrykuku/luci-theme-argon.git" \
    "package/luci-theme-argon"


# ------------------------------------------------------------
# luci-app-homeproxy
# ------------------------------------------------------------

clone_or_update \
    "https://github.com/XiaoHaiSly/luci-app-homeproxy.git" \
    "package/luci-app-homeproxy"


# ------------------------------------------------------------
# luci-app-pulse
# ------------------------------------------------------------

clone_or_update \
    "https://github.com/w9315273/luci-app-pulse.git" \
    "package/luci-app-pulse"


# ------------------------------------------------------------
# luci-app-open_nexttrace (open-nexttrace)
# ------------------------------------------------------------

clone_or_update \
    "https://github.com/haohaoget/luci-app-open_nexttrace.git" \
    "package/open-nexttrace"


# ------------------------------------------------------------
# 如果以后需要 Honk，可以直接取消注释
# ------------------------------------------------------------

# clone_or_update \
#     "https://github.com/QiuSimons/luci-app-honk.git" \
#     "package/honk"


# ============================================================
# OpenWrt x86 内核配置
# ============================================================

echo
echo "============================================================"
echo " 设置 x86 Linux 6.18 内核配置"
echo "============================================================"

KERNEL_CONFIG="target/linux/x86/config-6.18"

if [ ! -f "$KERNEL_CONFIG" ]; then
    echo "❌ 找不到：$KERNEL_CONFIG"
    exit 1
fi

# ------------------------------------------------------------
# 幂等添加内核配置
#
# 不再使用 cat >>，避免 GitHub Actions 或重复执行时
# 产生重复配置。
# ------------------------------------------------------------

add_kernel_config() {

    local CONFIG="$1"

    if grep -qxF "$CONFIG" "$KERNEL_CONFIG"; then
        echo "已存在：$CONFIG"
    else
        echo "$CONFIG" >> "$KERNEL_CONFIG"
        echo "已添加：$CONFIG"
    fi
}

add_kernel_config "CONFIG_NETKIT=y"
add_kernel_config "# CONFIG_X86_NATIVE_CPU is not set"
add_kernel_config "# CONFIG_X86_SGX is not set"


# ============================================================
# DAE AMD64 v3 / AVX2
# ============================================================

echo
echo "============================================================"
echo " 设置 DAE 为 AMD64 v3 / AVX2 编译"
echo "============================================================"

DAE_DIR="package/dae"
DAE_MAKEFILE="$DAE_DIR/dae/Makefile"

if [ ! -f "$DAE_MAKEFILE" ]; then
    echo "❌ 未找到 DAE Makefile：$DAE_MAKEFILE"
    exit 1
fi

echo "--> DAE Makefile：$DAE_MAKEFILE"


# ------------------------------------------------------------
# 删除旧的 GO_AMD64 定义
# ------------------------------------------------------------

sed -i '/^[[:space:]]*GO_AMD64[[:space:]]*:?=/d' "$DAE_MAKEFILE"


# ------------------------------------------------------------
# 在 GO_PKG_BUILD_VARS 前加入 GO_AMD64:=v3
# ------------------------------------------------------------

if grep -q '^GO_PKG_BUILD_VARS+=' "$DAE_MAKEFILE"; then

    sed -i \
        '/^GO_PKG_BUILD_VARS+=/i GO_AMD64:=v3' \
        "$DAE_MAKEFILE"

else

    echo "❌ 未找到 GO_PKG_BUILD_VARS+="
    echo "无法自动设置 GO_AMD64=v3"
    exit 1

fi


# ============================================================
# 最终检查
# ============================================================

echo
echo "============================================================"
echo " DIY 配置完成"
echo "============================================================"

echo
echo "[内核配置]"
grep -n -E \
    'CONFIG_NETKIT|CONFIG_X86_NATIVE_CPU|CONFIG_X86_SGX' \
    "$KERNEL_CONFIG" || true

echo
echo "[DAE AMD64]"
grep -n -E \
    '^GO_AMD64[[:space:]]*:?=' \
    "$DAE_MAKEFILE" || true

echo
echo "[第三方组件]"

for DIR in \
    "package/v2ray-geodata" \
    "package/luci-app-temp-status" \
    "package/dae" \
    "package/luci-theme-argon" \
    "package/luci-app-homeproxy" \
    "package/luci-app-pulse" \
    "package/open-nexttrace"
do
    if [ -d "$DIR" ]; then
        echo "✓ $DIR"
    else
        echo "❌ $DIR"
    fi
done

echo
echo "============================================================"
echo " DIY 脚本执行完成"
echo "============================================================"
