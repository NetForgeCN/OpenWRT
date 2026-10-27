#!/usr/bin/env bash

# ============================================================
# DIY1：配置第三方 feeds
#
# 由 GitHub Actions 工作流调用。
# 这里只配置 feeds 源，不执行 feeds update/install。
# ============================================================

set -e

cd "$GITHUB_WORKSPACE"

echo "=========================================="
echo "配置第三方 feeds"
echo "=========================================="

FEEDS_CONF="feeds.conf.default"

# 删除指定第三方 feeds 的旧条目，避免重复配置。
# 其他官方 feeds 保持不变。
sed -i -E \
    '/^[[:space:]]*src-git[[:space:]]+(ddnsgo|kixdns|diskman|dae|honk|homeproxy|opennexttrace)[[:space:]]/d' \
    "$FEEDS_CONF"

# 添加第三方 feeds
cat >> "$FEEDS_CONF" <<'EOF'

# ===== 第三方 LuCI 应用 =====
src-git ddnsgo https://github.com/sirpdboy/luci-app-ddns-go.git
src-git kixdns https://github.com/JohnsonRan/luci-app-kixdns.git
src-git diskman https://github.com/sbwml/luci-app-diskman.git
src-git dae https://github.com/QiuSimons/luci-app-dae.git
src-git honk https://github.com/QiuSimons/luci-app-honk.git
src-git homeproxy https://github.com/XiaoHaiSly/luci-app-homeproxy.git
src-git opennexttrace https://github.com/haohaoget/luci-app-open_nexttrace.git
EOF

echo "第三方 feeds 配置完成"
cat "$FEEDS_CONF"