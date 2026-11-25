# OpenWRT

基于 OpenWrt 官方 `main` 分支的 x86-64 固件构建仓库。用 GitHub Actions 分步编排构建流程，定制逻辑拆成 `diy-part1.sh`（feeds 配置）与 `diy-part2.sh`（配置与包定制）两个脚本，产物发布为固件 Release。仓库根目录的 `.config` 由使用者自行维护，构建流程不会改写它。

<a id="build"></a>

## 编译固件

NetForgeCN 提供三套 OpenWrt x86-64 固件构建仓库，编译入口不同，产物都是固件 Release。三份 `.config` 由使用者自行维护，构建脚本不会改写它。

| 仓库 | 编译方式 | 编译入口 |
|---|---|---|
| [openwrt-suite](https://github.com/NetForgeCN/openwrt-suite#build) | 聚合 feed + 一键脚本 | `build/compile.sh`、`build.yml` |
| [OpenWRT](https://github.com/NetForgeCN/OpenWRT#build) | GitHub Actions 分步编排 | `OpenWRT.yml` + `diy-part1.sh` / `diy-part2.sh` |
| [OpenWrt-ScriptBuild](https://github.com/NetForgeCN/OpenWrt-ScriptBuild#build) | 单脚本全流程 | `compile.sh`、`build.yml` |

三个仓库的完整编译说明见各自 README 的「编译固件」章节（上表链接）。

### 本仓库：GitHub Actions 分步构建

`.github/workflows/OpenWRT.yml` 支持两种触发方式：

- 手动：仓库页 → Actions → **OpenWrt Firmware Build (x86 Master)** → Run workflow；
- 自动：`.github/workflows/AutoCheck.yml` 每天检查受监控的第三方组件上游提交，检测到更新后以 `repository_dispatch` 触发一次编译。

构建步骤依次为：克隆 OpenWrt 源码 → 恢复 dl / 工具链 / ccache 缓存 → 运行 `diy-part1.sh` 配置 feeds → `feeds update -a` / `feeds install -a` → 写入 `.config` 并运行 `diy-part2.sh` → `make defconfig` → 按需安装 honk 宿主机工具链 → `make download` → 编译 → 收集固件 → 上传 artifact → 保存缓存 → 发布 Release。构建使用 `ubuntu-26.04` runner，单次超时 360 分钟，同一 workflow 的构建排队执行不取消。

可复现性：`SOURCE_DATE_EPOCH` 取 OpenWrt 源码 HEAD 的提交时间（可在 workflow env 中覆盖）；配置与 feeds 文件均通过「同目录临时文件 + `mv`」原子替换，写入前备份、失败回滚。供应链：workflow 里的 Actions 全部钉到 commit SHA；honk 宿主机工具链资产（bpf-linker、zig）下载后强制校验 SHA256，zig 的校验值取自 ziglang.org 官方索引。

产物为 `firmware-x86-64` artifact 与固件 Release（保留最近 7 个）。清理脚本会自动跳过 `backup-*` 前缀的不可变备份 Release/Tag。失败时会额外上传构建日志 artifact 便于排查。

### 本地使用两个 diy 脚本

`diy-part1.sh` 与 `diy-part2.sh` 均在 **OpenWrt 源码树根目录**运行，按 workflow 的时机调用：

```bash
cd openwrt

# 1) feeds update -a 之前：配置第三方 feeds
bash /path/to/OpenWRT/diy-part1.sh
./scripts/feeds update -a
./scripts/feeds install -a

# 2) feeds install -a 之后、make defconfig 之前：写入 .config 与包定制
cp /path/to/OpenWRT/.config .config
bash /path/to/OpenWRT/diy-part2.sh
make defconfig

make download -j"$(nproc)"
make -j"$(nproc)"
```

`diy-part1.sh` 把官方 feed 源切到 GitHub 镜像，并追加登记在脚本 `FEEDS` 数组里的第三方 feeds；`diy-part2.sh` 处理 Rust / golang 版本、内核配置补丁、`v2ray-geodata` 替换、额外仓库克隆等。两个脚本都幂等，可重复执行，路径与开关类配置（`FEEDS_CONF`、`RUST_MAKEFILE`、`GOLANG_VALUES`、`GO_AMD64_LEVEL`、`TARGET_SUBDIR`、`KERNEL_CONFIG`、`CLEAN_KERNEL`、`CLEAN_GOLANG`、`SKIP_UPDATE` 等）都可用环境变量覆盖。

## 第三方组件与配置

- **第三方 feeds**：`diy-part1.sh` 内的 `FEEDS` 数组（ddnsgo、kixdns、diskman、dae、opennexttrace、airplay2、honk、photondns、nikki、mosdns、openappfilter、atomdns 等），默认分支与上游不同的仓库显式钉住分支。
- **额外克隆仓库**：`diy-part2.sh` 内的 `EXTRA_REPOS` 数组，用于根目录即包目录、不通过 feed 提供的包（hevsocks5、oxidns、lucky、argon 等）。
- **v2ray-geodata**：删除官方同名包源与链接后，克隆 `NetForgeCN/Loyalsoldier` 到 `package/v2ray-geodata`，数据取自自建规则仓库 `NetForgeCN/v2ray-rules-dat`。
- **上游监控**：`.github/workflows/AutoCheck.yml` 内的 `REPOS` 关联数组，基线记录在 `.github/upstream-state/previous.txt`；新增或删除第三方仓库时同步更新这两处。
- **.config**：仓库根目录，由使用者自行维护；`.github/workflows/Clean.yaml` 可手动清理历史 Release 与 workflow 记录。

## 许可证

本仓库以 **MIT** 授权，见 [LICENSE](LICENSE)。构建时拉取的第三方组件按各自的许可证分发。
