#!/usr/bin/env bash
#
# diy-part1.sh —— 第三方 feeds 配置
#
# 来源：由本地一键构建脚本 compile.sh 的 configure_feeds 拆分而来。
# 执行时机：GitHub Actions 工作流在 `./scripts/feeds update -a / install -a`
# 之前调用（工作目录：OpenWrt 源码根目录），本脚本只负责修改 feeds.conf，
# 不执行 feeds update / install。
#
# 特性：
#   - 不锁定任何仓库版本/提交，始终跟随上游默认分支最新代码；
#   - 所有操作幂等，可重复执行：先删除旧的同名 feed 条目、去掉文件末尾
#     空行，再追加新条目，避免重复运行产生重复条目。
#
# 注意：新增/删除 feed 时，请同步更新
#       .github/workflows/AutoCheck.yml 里的监控清单。
#

set -Eeuo pipefail

# 统一 locale：既避免 sort/grep 的 locale 差异，也避免 bash 3.2 在 UTF-8 下
# 把全角标点的首字节误判成变量名的一部分（$VAR）+ 中文 会报 unbound variable
export LC_ALL=C LANG=C
unset -v GREP_OPTIONS || true

# ---------------------------------------------------------------------------
# 可配置项（环境变量可覆盖）
# ---------------------------------------------------------------------------

FEEDS_CONF="${FEEDS_CONF:-feeds.conf.default}"

# 需要写入的第三方 feeds（name url）
FEEDS=(
    "ddnsgo|https://github.com/sirpdboy/luci-app-ddns-go.git"
    "kixdns|https://github.com/JohnsonRan/luci-app-kixdns.git"
    "diskman|https://github.com/sbwml/luci-app-diskman.git"
    "dae|https://github.com/QiuSimons/luci-app-dae.git"
    "opennexttrace|https://github.com/haohaoget/luci-app-open_nexttrace.git"
    "airplay2|https://github.com/NetForgeCN/luci-app-airplay2.git;main"
    "honk|https://github.com/QiuSimons/luci-app-honk.git"
    "photondns|https://github.com/c2h2/luci-app-photondns.git"
)

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

log()  { printf '\n[diy1] %s\n' "$*"; }
warn() { printf '\n[diy1][警告] %s\n' "$*" >&2; }
die()  { printf '\n[diy1][错误] %s\n' "$*" >&2; exit 1; }

TMP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/diy-part1.XXXXXX")"
cleanup() { rm -rf -- "$TMP_WORK"; }
trap cleanup EXIT

# 可移植的「原地修改」：不走 sed -i（BSD/GNU 行为不一致），且保留原 inode 与权限
sed_inplace() {
    local expr="$1" file="$2" tmp
    [[ -f "$file" ]] || { warn "sed_inplace: 文件不存在：$file"; return 1; }
    tmp="${TMP_WORK}/$(basename "$file").sed.$$"
    sed -E "$expr" "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    cat -- "$tmp" > "$file" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
}

# ---------------------------------------------------------------------------
# 配置第三方 feeds（原 compile.sh 的 configure_feeds）
# ---------------------------------------------------------------------------

log "配置第三方 feeds"

[[ -f "$FEEDS_CONF" ]] || die "找不到 ${FEEDS_CONF}（当前目录：$(pwd)）"

# ---------------------------------------------------------------------------
# 官方 feed 源：git.openwrt.org -> GitHub 镜像
#
# 原因：git.openwrt.org 会对 GitHub Actions runner 的出口 IP 限流，且历史上
# 多次被爬虫打爆过载；此时 ./scripts/feeds update -a 拉 packages/luci 等
# 大仓库会长时间无输出挂起，表现为工作流「卡在 Update feeds」直到 6h 超时。
# packages/luci/routing/telephony 在 github.com/openwrt/* 均有实时镜像
# （HEAD 与上游一致），2025-07 OpenWrt 官方 buildbot 遇到同一问题时也是
# 直接把 feeds.conf.default 的源 sed 成 github.com。
# ---------------------------------------------------------------------------
log "官方 feeds 源切换到 GitHub 镜像（规避 git.openwrt.org 限流）"
sed_inplace 's;git\.openwrt\.org/(feed|project);github.com/openwrt;' "$FEEDS_CONF" || true

# 删除旧的同类配置，保证重复运行不会产生重复条目
for item in "${FEEDS[@]}"; do
    name="${item%%|*}"
    sed_inplace "/^[[:space:]]*src-git[[:space:]]+${name}[[:space:]]/d" "$FEEDS_CONF"
done

# 去掉文件末尾多余空行，避免多次运行后空行堆积
trimmed="${TMP_WORK}/feeds.conf.trimmed"
awk '{ a[NR] = $0 }
     END {
         n = NR
         while (n > 0 && a[n] ~ /^[[:space:]]*$/) n--
         for (i = 1; i <= n; i++) print a[i]
     }' "$FEEDS_CONF" > "$trimmed"
cat -- "$trimmed" > "$FEEDS_CONF"

# 追加第三方 feed 条目
{
    printf '\n'
    for item in "${FEEDS[@]}"; do
        name="${item%%|*}"
        url="${item#*|}"
        printf 'src-git %s %s\n' "$name" "$url"
    done
} >> "$FEEDS_CONF"

log "第三方 feeds 配置完成，当前 ${FEEDS_CONF} 内容："
cat -- "$FEEDS_CONF"
