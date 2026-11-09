#!/usr/bin/env bash
#
# diy-part2.sh —— feeds update -a / install -a 之后的全部定制处理
#
# 来源：由本地一键构建脚本 compile.sh 拆分而来，对应其中的：
#   - remove_official_v2ray_geodata / install_airplay2_feed_pkgs（update_feeds 收尾）
#   - fix_rust_llvm / fix_golang_amd64
#   - replace_v2ray_geodata / install_extra_repos
#   - patch_kernel_config / clean_stale_artifacts
#
# 执行时机：GitHub Actions 工作流在 `./scripts/feeds update -a` 与
# `./scripts/feeds install -a` 之后、`make defconfig` 之前调用
# （工作目录：OpenWrt 源码根目录，.config 已由工作流拷贝到位）。
#
# 与原 compile.sh 的实现差异（最终结果一致）：
#   1. 官方 v2ray-geodata 的删除时机从「update -a 之后、install -a 之前」
#      移到本脚本（install -a 之后）：feeds install 产生的符号链接会被一并
#      清理，官方源与链接同样不存在，随后仍替换为第三方版本。
#   2. .config 的下载与 make defconfig（原 prepare_config）、make download
#      （原 download_sources）、编译（原 build）均由工作流负责，不在本脚本内。
#
# 特性：不锁定任何仓库版本/提交，始终跟随上游默认分支最新代码；
#       所有操作幂等，可重复执行（CI 每次全新环境，本地重复运行也安全）。
#
# 注意：新增/删除克隆仓库时，请同步更新
#       .github/workflows/AutoCheck.yml 里的监控清单。
#

set -Eeuo pipefail

# 统一 locale：既避免 sort/grep 的 locale 差异，也避免 bash 3.2 在 UTF-8 下
# 把全角标点的首字节误判成变量名的一部分（$VAR）+ 中文 会报 unbound variable
export LC_ALL=C LANG=C
unset -v GREP_OPTIONS || true

# ---------------------------------------------------------------------------
# 可配置项（全部可用环境变量覆盖）
# ---------------------------------------------------------------------------

RUST_MAKEFILE="${RUST_MAKEFILE:-feeds/packages/lang/rust/Makefile}"
GOLANG_VALUES="${GOLANG_VALUES:-feeds/packages/lang/golang/golang-values.mk}"
GO_AMD64_LEVEL="${GO_AMD64_LEVEL:-v3}"     # GOAMD64 微架构级别：v1/v2/v3/v4
TARGET_SUBDIR="${TARGET_SUBDIR:-x86}"
KERNEL_CONFIG="${KERNEL_CONFIG:-}"          # 留空则自动探测 target/linux/<TARGET>/config-<ver>
CLEAN_KERNEL="${CLEAN_KERNEL:-auto}"        # auto|1|0：内核配置变更后是否 make target/linux/clean
CLEAN_GOLANG="${CLEAN_GOLANG:-auto}"        # auto|1|0：GO_AMD64 变更后是否 make golang/clean
SKIP_UPDATE="${SKIP_UPDATE:-0}"             # 1 = 不更新第三方仓库（CI 全新克隆，无需设置）

# 内部状态标记（先给默认值，避免未绑定变量）
RUST_CHANGED=0
GOLANG_CHANGED=0
KERNEL_CHANGED=0

# 需要克隆/更新的普通第三方包（url dir）
EXTRA_REPOS=(
    "https://github.com/gSpotx2f/luci-app-temp-status.git|package/luci-app-temp-status"
    "https://github.com/jerrykuku/luci-theme-argon.git|package/luci-theme-argon"
    "https://github.com/w9315273/luci-app-pulse.git|package/luci-app-pulse"
    "https://github.com/NetForgeCN/luci-app-oxidns.git|package/luci-app-oxidns"
)

V2RAY_GEODATA_REPO="https://github.com/NetForgeCN/Loyalsoldier.git"
V2RAY_GEODATA_DIR="package/v2ray-geodata"
V2RAY_GEODATA_FEED_SRC="feeds/packages/net/v2ray-geodata"

# 需要强制设定的内核选项（KEY|value）
KERNEL_OPTIONS=(
    "NETKIT|CONFIG_NETKIT=y"
    "X86_NATIVE_CPU|# CONFIG_X86_NATIVE_CPU is not set"
    "X86_SGX|# CONFIG_X86_SGX is not set"
)

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

log()  { printf '\n[diy2] %s\n' "$*"; }
warn() { printf '\n[diy2][警告] %s\n' "$*" >&2; }
die()  { printf '\n[diy2][错误] %s\n' "$*" >&2; exit 1; }

TMP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/diy-part2.XXXXXX")"
cleanup() { rm -rf -- "$TMP_WORK"; }

on_err() {
    local rc=$?
    printf '\n[diy2][错误] 脚本在第 %s 行执行失败，退出码：%s\n' "$1" "$rc" >&2
    printf '[diy2][错误] 失败命令：%s\n' "$2" >&2
    exit "$rc"
}

trap 'cleanup' EXIT
trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR

# 可移植的「原地修改」：不走 sed -i（BSD/GNU 行为不一致），且保留原 inode 与权限
sed_inplace() {
    local expr="$1" file="$2" tmp
    [[ -f "$file" ]] || { warn "sed_inplace: 文件不存在：$file"; return 1; }
    tmp="${TMP_WORK}/$(basename "$file").sed.$$"
    sed -E "$expr" "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    cat -- "$tmp" > "$file" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
}

# 消除 "detected dubious ownership" 导致的 git 操作失败
git_safe() {
    local dir="$1"
    git config --global --get-all safe.directory 2>/dev/null |
        grep -qxF "$dir" || git config --global --add safe.directory "$dir" 2>/dev/null || true
}

repo_is_dirty() {
    ! git -C "$1" diff --quiet --ignore-submodules -- 2>/dev/null ||
        ! git -C "$1" diff --cached --quiet --ignore-submodules -- 2>/dev/null
}

# 克隆或更新一个 Git 仓库（不锁定版本，跟随默认分支）
ensure_repo() {
    local url="$1" dir="$2" parent

    parent="$(dirname "$dir")"
    [[ -d "$parent" ]] || mkdir -p -- "$parent"

    if [[ ! -e "$dir" && ! -L "$dir" ]]; then
        log "首次克隆：$dir"
        git clone "$url" "$dir"
        return 0
    fi

    if [[ ! -d "$dir/.git" ]]; then
        die "目标已存在但不是 Git 仓库：$dir"
    fi

    git_safe "$(cd "$dir" && pwd -P)"

    if [[ "$SKIP_UPDATE" == "1" ]]; then
        log "跳过更新（SKIP_UPDATE=1）：$dir"
        return 0
    fi

    if repo_is_dirty "$dir"; then
        warn "$dir 存在未提交的本地修改，跳过更新以便保留你的改动"
        return 0
    fi

    if ! git -C "$dir" symbolic-ref -q HEAD >/dev/null; then
        warn "$dir 处于 detached HEAD 状态，跳过更新"
        return 0
    fi

    log "更新仓库：$dir"
    if ! git -C "$dir" pull --ff-only; then
        warn "$dir 无法快进更新（本地分支可能已分叉），继续使用当前代码；"
        warn "如需强制同步，请手动执行：git -C \"$dir\" reset --hard origin/\$(git -C \"$dir\" branch --show-current)"
    fi
}

# ---------------------------------------------------------------------------
# airplay2 feed 专用包（原 compile.sh 的 install_airplay2_feed_pkgs）
#
# 官方 packages feed 中也有 nqptp，feeds install -a 会按 feeds.conf 顺序
# 优先安装官方版本；而 luci-app-airplay2 需要搭配本 feed 内的 nqptp，
# 因此必须先卸载官方 nqptp，再用 -p airplay2 强制从本 feed 安装。
# 注意顺序：本步骤必须放在 feeds install -a 之后，否则会被官方版本覆盖。
# 幂等性：nqptp 未安装时 uninstall 无效果，重复运行安全。
# ---------------------------------------------------------------------------

install_airplay2_feed_pkgs() {
    log "处理 airplay2 feed 专用包（nqptp / luci-app-airplay2）"

    ./scripts/feeds uninstall nqptp ||
        warn "卸载 nqptp 未成功（可能尚未安装过），继续安装 airplay2 feed 内版本"

    ./scripts/feeds install -p airplay2 airplay2 nqptp luci-app-airplay2 ||
        die "从 airplay2 feed 安装 airplay2 / nqptp / luci-app-airplay2 失败"

    log "airplay2 feed 相关包（airplay2 / nqptp / luci-app-airplay2）安装完成"
}

# ---------------------------------------------------------------------------
# v2ray-geodata 替换（原 compile.sh 的 remove_official_v2ray_geodata /
# replace_v2ray_geodata）
# ---------------------------------------------------------------------------

remove_official_v2ray_geodata() {
    if [[ -e "$V2RAY_GEODATA_FEED_SRC" || -L "$V2RAY_GEODATA_FEED_SRC" ]]; then
        rm -rf -- "$V2RAY_GEODATA_FEED_SRC"
        log "已删除官方 v2ray-geodata 源"
    fi

    # 关键：feeds install 会在 package/feeds/<feed>/ 下生成指向源的符号链接，
    # 只删源会留下悬空链接，后续扫描包时会报错，这里必须一并清理。
    local link
    while IFS= read -r link; do
        [[ -n "$link" ]] || continue
        rm -f -- "$link"
        log "已删除失效符号链接：$link"
    done < <(find package/feeds -maxdepth 2 -name 'v2ray-geodata' -type l -print 2>/dev/null || true)
}

replace_v2ray_geodata() {
    log "替换 v2ray-geodata"

    rm -rf -- "$V2RAY_GEODATA_DIR"
    git clone "$V2RAY_GEODATA_REPO" "$V2RAY_GEODATA_DIR"

    [[ -f "$V2RAY_GEODATA_DIR/Makefile" ]] ||
        die "第三方 v2ray-geodata 克隆结果异常：缺少 Makefile"

    log "第三方 v2ray-geodata 就位：$V2RAY_GEODATA_DIR"
}

# ---------------------------------------------------------------------------
# Rust LLVM 下载开关（原 compile.sh 的 fix_rust_llvm）
# ---------------------------------------------------------------------------

fix_rust_llvm() {
    log "检查 Rust LLVM 下载配置"

    [[ -f "$RUST_MAKEFILE" ]] || { warn "找不到 Rust Makefile：${RUST_MAKEFILE}，跳过"; return 0; }

    if grep -qF -- '--set=llvm.download-ci-llvm=true' "$RUST_MAKEFILE"; then
        log "Rust LLVM 下载参数已经是 true"
        return 0
    fi

    # 上游曾出现过 falst 拼写错误，这里一并兼容
    if grep -qE -- '--set=llvm\.download-ci-llvm=(falst|false)' "$RUST_MAKEFILE"; then
        sed_inplace \
            's/--set=llvm\.download-ci-llvm=(falst|false)/--set=llvm.download-ci-llvm=true/g' \
            "$RUST_MAKEFILE"
        log "已将 Rust LLVM 下载参数修改为 true"
        RUST_CHANGED=1
        return 0
    fi

    warn "没有找到预期的 Rust LLVM 参数，请检查：$RUST_MAKEFILE"
}

# ---------------------------------------------------------------------------
# Golang GO_AMD64 微架构级别（原 compile.sh 的 fix_golang_amd64）
# ---------------------------------------------------------------------------

fix_golang_amd64() {
    log "检查 Golang GO_AMD64 设置（目标值：${GO_AMD64_LEVEL}）"

    [[ -f "$GOLANG_VALUES" ]] || { warn "找不到 golang-values.mk：${GOLANG_VALUES}，跳过"; return 0; }

    # 1) 输出当前内容（带行号）
    local lines
    lines="$(grep -nE '^[[:space:]]*GO_AMD64[[:space:]]*[:?]?=' "$GOLANG_VALUES" || true)"

    if [[ -z "$lines" ]]; then
        warn "在 $GOLANG_VALUES 中未找到 GO_AMD64 赋值行，请手动确认文件内容"
        return 0
    fi

    log "当前 GO_AMD64 内容："
    printf '%s\n' "$lines" | sed 's/^/    /'

    # 2) 已经是目标值则跳过
    if grep -qE "^[[:space:]]*GO_AMD64[[:space:]]*[:?]?=[[:space:]]*${GO_AMD64_LEVEL}[[:space:]]*$" \
        "$GOLANG_VALUES"; then
        log "GO_AMD64 已经是 ${GO_AMD64_LEVEL}，无需修改"
        return 0
    fi

    # 3) 改为目标值：保留原有缩进，覆盖任意赋值符（:= / ?= / =）
    sed_inplace \
        "s/^([[:space:]]*GO_AMD64)[[:space:]]*[:?]?=.*\$/\1:=${GO_AMD64_LEVEL}/" \
        "$GOLANG_VALUES"

    # 4) 校验并输出结果
    local after
    after="$(grep -nE "^[[:space:]]*GO_AMD64[[:space:]]*:=[[:space:]]*${GO_AMD64_LEVEL}[[:space:]]*\$" \
        "$GOLANG_VALUES" || true)"

    [[ -n "$after" ]] || die "GO_AMD64 修改失败，请检查 $GOLANG_VALUES"

    log "修改成功，当前 GO_AMD64 内容："
    printf '%s\n' "$after" | sed 's/^/    /'
    log "GO_AMD64 已设置为 ${GO_AMD64_LEVEL}（文件：${GOLANG_VALUES}）"

    GOLANG_CHANGED=1
}

# ---------------------------------------------------------------------------
# 普通第三方 Git 仓库（原 compile.sh 的 install_extra_repos）
# ---------------------------------------------------------------------------

install_extra_repos() {
    log "处理普通第三方 Git 仓库"

    local item url dir
    for item in "${EXTRA_REPOS[@]}"; do
        url="${item%%|*}"
        dir="${item#*|}"
        ensure_repo "$url" "$dir"
    done

    log "第三方 Git 仓库处理完成"
}

# ---------------------------------------------------------------------------
# 内核配置（原 compile.sh 的 detect_kernel_config / set_kernel_config /
# patch_kernel_config）
# ---------------------------------------------------------------------------

detect_kernel_config() {
    local dir="target/linux/${TARGET_SUBDIR}" best="" f ver best_ver=0

    [[ -d "$dir" ]] || die "找不到内核配置目录：$dir"

    for f in "$dir"/config-*; do
        [[ -f "$f" ]] || continue
        ver="${f##*config-}"
        [[ "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
        if [[ "$ver" =~ ^([0-9]+)(\.([0-9]+))? ]]; then
            local major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[3]:-0}"
            local score=$((major * 1000 + minor))
            if ((score >= best_ver)); then
                best_ver=$score
                best="$f"
            fi
        fi
    done

    [[ -n "$best" ]] || die "在 $dir 下未找到任何 config-<版本> 文件"
    printf '%s\n' "$best"
}

set_kernel_config() {
    local key="$1" value="$2" file="$3" tmp count

    count="$(grep -cE "^(CONFIG_${key}=|# CONFIG_${key} is not set$)" "$file" || true)"

    if [[ "$count" == "1" ]] && grep -qxF -- "$value" "$file"; then
        log "内核配置 ${key} 已是目标值，跳过"
        return 1
    fi

    tmp="${TMP_WORK}/$(basename "$file").new"
    awk -v key="$key" '
        $0 ~ "^CONFIG_" key "="                 { next }
        $0 ~ "^# CONFIG_" key " is not set$"    { next }
        { print }
    ' "$file" > "$tmp"

    printf '%s\n' "$value" >> "$tmp"
    cat -- "$tmp" > "$file"     # 保留原 inode / 权限 / 所有者
    rm -f -- "$tmp"

    log "已写入：${value}"
    return 0
}

patch_kernel_config() {
    log "处理 ${TARGET_SUBDIR} 内核配置"

    [[ -n "$KERNEL_CONFIG" ]] || KERNEL_CONFIG="$(detect_kernel_config)"
    [[ -f "$KERNEL_CONFIG" ]] || die "找不到内核配置文件：$KERNEL_CONFIG"
    log "内核配置文件：$KERNEL_CONFIG"

    local item key value changed=0
    for item in "${KERNEL_OPTIONS[@]}"; do
        key="${item%%|*}"
        value="${item#*|}"
        if set_kernel_config "$key" "$value" "$KERNEL_CONFIG"; then
            changed=1
        fi
    done

    # 校验（不因 grep 无匹配而中断脚本）
    log "内核配置校验结果："
    grep -nE '^(CONFIG_NETKIT=y|# CONFIG_X86_NATIVE_CPU is not set|# CONFIG_X86_SGX is not set)$' \
        "$KERNEL_CONFIG" || warn "未能在 $KERNEL_CONFIG 中校验到全部目标配置"

    KERNEL_CHANGED=$changed
}

# ---------------------------------------------------------------------------
# 清理过期构建产物（原 compile.sh 的 clean_stale_artifacts）
# ---------------------------------------------------------------------------

clean_stale_artifacts() {
    local do_clean="$CLEAN_KERNEL"

    if [[ "$do_clean" == "auto" ]]; then
        if [[ "$KERNEL_CHANGED" == "1" ]]; then do_clean=1; else do_clean=0; fi
    fi

    if [[ "$do_clean" == "1" && "$KERNEL_CHANGED" == "1" ]]; then
        log "内核配置已变更，清理内核构建目录以确保配置生效"
        make target/linux/clean || warn "make target/linux/clean 失败，可忽略（首次构建时无缓存可清）"
    fi

    if [[ "$RUST_CHANGED" == "1" ]] && compgen -G 'build_dir/*/rust*' >/dev/null; then
        log "Rust 构建参数已变更，清理 Rust 构建缓存"
        make package/feeds/packages/rust/clean 2>/dev/null ||
            warn "Rust 缓存清理失败，如编译异常请手动执行 make package/feeds/packages/rust/clean"
    fi

    if [[ "$GOLANG_CHANGED" == "1" && "$CLEAN_GOLANG" != "0" ]] &&
        compgen -G 'build_dir/*/golang*' >/dev/null; then
        log "GO_AMD64 已变更，清理 Golang 构建缓存"
        if ! make package/feeds/packages/golang/clean 2>/dev/null; then
            warn "Golang 缓存清理失败；已编译过的 Go 包（dae / ddns-go 等）需重新编译才会生效"
            warn "必要时请手动执行：make package/feeds/packages/golang/clean"
        fi
    fi
}

# ---------------------------------------------------------------------------
# 入口：执行顺序与原 compile.sh 保持一致
# ---------------------------------------------------------------------------

log "开始 diy-part2 处理（工作目录：$(pwd)）"

remove_official_v2ray_geodata
install_airplay2_feed_pkgs
fix_rust_llvm
fix_golang_amd64
replace_v2ray_geodata
install_extra_repos
patch_kernel_config
clean_stale_artifacts

log "diy-part2 所有任务完成"
