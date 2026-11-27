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
    "opennexttrace|https://github.com/haohaoget/luci-app-open_nexttrace.git"
    "airplay2|https://github.com/NetForgeCN/luci-app-airplay2.git;main"
    # honk feed 已改名为 luci-app-daeuniverse（honk + dae 双核心），feed 短名
    # 保持 honk，让 honk_toolchain.sh 的 feeds/honk/honk/Makefile 路径继续有效。
    # 独立的 luci-app-dae (kix) 已归档，其 dae 包与新 feed 同名会撞包，故移除。
    "honk|https://github.com/QiuSimons/luci-app-daeuniverse.git"
    "photondns|https://github.com/c2h2/luci-app-photondns.git"
    "nikki|https://github.com/nikkinikki-org/OpenWrt-nikki.git"
    # mosdns 的默认分支是 v5（不是 main/master），这里显式钉住
    "mosdns|https://github.com/sbwml/luci-app-mosdns.git;v5"
    # openappfilter 的默认分支是 master，这里显式钉住（一个 feed 内含
    # luci-app-oaf / appfilter / kmod-oaf 三个包，feeds install -a 会自动装齐）
    "openappfilter|https://github.com/destan19/OpenAppFilter.git;master"
    # atomdns: 自有的一体化包，仓库根没有 Makefile，包目录是 luci-app-atomdns/，
    # 走 src-git feed 由 feeds install -a 扫描到。feed 短名只能是 atomdns
    # （名称段不含减号）：scripts/feeds 用 \w+ 解析 feeds.conf 的名称段。
    "atomdns|https://github.com/NetForgeCN/luci-app-atomdns.git;main"
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

# ---------------------------------------------------------------------------
# 安全的配置文件写入：同目录临时文件 + mv 原子替换，保留原权限/所有者；
# 首次改动前把原件备份到 TMP_WORK，失败时可回滚。拒绝跟随符号链接，避免
# 通过被篡改的 feeds.conf 把内容写到源码树之外。
# ---------------------------------------------------------------------------

atomic_replace() {
    local src="$1" dest="$2" bak tmp
    [[ -f "$src" ]] || { warn "atomic_replace: 源文件不存在：$src"; return 1; }
    [[ -f "$dest" && ! -L "$dest" ]] || { warn "atomic_replace: 目标不是普通文件（或为符号链接）：$dest"; return 1; }
    mkdir -p -- "${TMP_WORK}/backups" || return 1
    bak="${TMP_WORK}/backups/$(printf '%s' "$dest" | tr '/' '_').bak"
    if [[ ! -e "$bak" ]]; then
        cp -p -- "$dest" "$bak" || return 1
    fi
    tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").tmp.XXXXXX")" || return 1
    cp -p -- "$dest" "$tmp" || { rm -f -- "$tmp"; return 1; }
    cat -- "$src" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
}

rollback_file() {
    local dest="$1"
    local bak="${TMP_WORK}/backups/$(printf '%s' "$dest" | tr '/' '_').bak"
    [[ -f "$bak" ]] || return 1
    cp -p -- "$bak" "$dest"
}

# 可移植的「原地修改」：不走 sed -i（BSD/GNU 行为不一致），且保留原权限
sed_inplace() {
    local expr="$1" file="$2" tmp
    [[ -f "$file" && ! -L "$file" ]] || { warn "sed_inplace: 文件不存在或为符号链接：$file"; return 1; }
    tmp="${TMP_WORK}/$(basename "$file").sed.$$"
    sed -E "$expr" "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    atomic_replace "$tmp" "$file" || {
        rm -f -- "$tmp"
        rollback_file "$file" || true
        return 1
    }
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
sed_inplace 's;git\.openwrt\.org/(feed|project);github.com/openwrt;' "$FEEDS_CONF" ||
    die "改写官方 feeds 源失败：$FEEDS_CONF（已回滚）"

# 删除旧的同类配置，保证重复运行不会产生重复条目
for item in "${FEEDS[@]}"; do
    name="${item%%|*}"
    sed_inplace "/^[[:space:]]*src-git[[:space:]]+${name}[[:space:]]/d" "$FEEDS_CONF"
done

# 去掉文件末尾多余空行，避免多次运行后空行堆积；随后一次性原子写入
# 完整内容（trim + 追加），避免 `>` 截断/半写入导致 feeds.conf 损坏。
new_conf="${TMP_WORK}/feeds.conf.new"
{
    awk '{ a[NR] = $0 }
         END {
             n = NR
             while (n > 0 && a[n] ~ /^[[:space:]]*$/) n--
             for (i = 1; i <= n; i++) print a[i]
         }' "$FEEDS_CONF"
    printf '\n'
    for item in "${FEEDS[@]}"; do
        name="${item%%|*}"
        url="${item#*|}"
        printf 'src-git %s %s\n' "$name" "$url"
    done
} > "$new_conf"
atomic_replace "$new_conf" "$FEEDS_CONF" ||
    die "写入 ${FEEDS_CONF} 失败（已回滚）"

log "第三方 feeds 配置完成，当前 ${FEEDS_CONF} 内容："
cat -- "$FEEDS_CONF"
