#!/usr/bin/env bash

# ============================================================
# DIY1：配置第三方 feeds
#
# 由 GitHub Actions 工作流调用。
# 这里只配置 feeds 源，不执行 feeds update/install。
# ============================================================


echo "=========================================="
echo "配置第三方 feeds"
echo "=========================================="

echo 'src-git ddnsgo https://github.com/sirpdboy/luci-app-ddns-go.git' >>feeds.conf.default
echo 'src-git kixdns https://github.com/JohnsonRan/luci-app-kixdns.git' >>feeds.conf.default
echo 'src-git diskman https://github.com/sbwml/luci-app-diskman.git' >>feeds.conf.default
echo 'src-git dae https://github.com/QiuSimons/luci-app-dae.git' >>feeds.conf.default
echo 'src-git honk https://github.com/QiuSimons/luci-app-honk.git' >>feeds.conf.default
echo 'src-git homeproxy https://github.com/XiaoHaiSly/luci-app-homeproxy.git' >>feeds.conf.default
echo 'src-git opennexttrace https://github.com/haohaoget/luci-app-open_nexttrace.git' >>feeds.conf.default
