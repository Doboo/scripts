#!/bin/bash
# =================================================================
# SoftEther VPN Client 自动安装脚本（5.x 版本 · Debian 12 适配版）
#
# 功能：
#   1. 安装 SoftEther VPN Client 5.x（vpnclient）
#   2. 支持手动输入版本号（默认 5.2.5188）
#   3. 多镜像加速下载（本地 HTTP > 镜像列表 > 直连 GitHub）
#   4. 交互式配置虚拟网卡和 VPN 账户
#   5. 创建 systemd 服务并自动启动
#   6. 自动创建 tap 设备并通过 DHCP 获取 IP
#
# 版本差异（对比 4.x sfe-client.sh）：
#   - 仓库：SoftEtherVPN/SoftEtherVPN（非 _Stable 仓库）
#   - Tag 格式：5.2.5188（无 v 前缀）
#   - 文件名：softether-vpnclient-v5.2.5188-linux-x64-unsigned.tar.gz
#   - 架构标识：x64 / x86 / arm_eabi / arm64
#   - 5.x 安装方式改为 cmake 编译，不再使用 .install.sh
# =================================================================

set -euo pipefail

# ==================================================================
# >>>>>>>>>>>>>> 用户可配置区域 START <<<<<<<<<<<<<<
# ==================================================================

DEFAULT_VERSION="5.2.5188"

# GitHub 加速镜像列表（按优先级排序）
MIRROR_URLS=(
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    "https://mirror.ghproxy.com/"
)

# 本地/内网 HTTP 下载基础地址（留空则跳过）
# 示例：LOCAL_HTTP_BASE="http://192.168.1.100:8080/softether"
LOCAL_HTTP_BASE=""

# ==================================================================
# >>>>>>>>>>>>>> 用户可配置区域 END   <<<<<<<<<<<<<<
# ==================================================================

GITHUB_REPO="SoftEtherVPN/SoftEtherVPN"
INSTALL_DIR="/usr/local/vpnclient"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# ── 日志函数 ──────────────────────────────────────────────────────
log()  { echo "--- [INFO]  $*"; }
warn() { echo "!!! [WARN]  $*" >&2; }
err()  { echo "*** [ERROR] $*" >&2; exit 1; }

# ── 下载函数（成功返回 0，失败返回 1）────────────────────────────
try_download() {
    local url="$1"
    local output="$2"
    log "尝试下载: $url"
    if wget -q --show-progress --tries=2 --timeout=30 -O "$output" "$url" 2>/dev/null; then
        local size
        size=$(stat -c%s "$output" 2>/dev/null || echo 0)
        if [ "$size" -gt 1048576 ]; then
            return 0
        else
            warn "文件过小 (${size} bytes)，可能是错误页面，跳过。"
            rm -f "$output"
            return 1
        fi
    else
        rm -f "$output"
        return 1
    fi
}

# ===== 脚本开始 =====

# 1. Root 权限检查
if [ "$(id -u)" -ne 0 ]; then
    err "此脚本必须以 root 权限运行。请使用 sudo 或切换到 root 用户。"
fi

echo "===================================================="
echo "  SoftEther VPN Client 5.x 安装脚本（Debian 12）"
echo "===================================================="
echo ""

# 2. 交互式输入版本号
echo "请输入版本号（格式：5.2.5188 或 5.02.5185 等）："
echo "可在此查看所有版本: https://github.com/SoftEtherVPN/SoftEtherVPN/releases"
echo ""
read -r -p "  版本号 [默认: ${DEFAULT_VERSION}]: " INPUT_VERSION
VERSION="${INPUT_VERSION:-$DEFAULT_VERSION}"

# 验证版本号格式（必须是 5.x 版本）
if ! echo "$VERSION" | grep -qE '^5\.[0-9]+\.[0-9]+$'; then
    err "版本号格式不正确，应为 5.x.xxxx 格式（例如 5.2.5188）。"
fi

echo ""
log "将安装版本: ${VERSION}"
echo ""

# 3. 安装依赖
log "正在更新包列表并安装依赖..."
apt-get update -y -q
apt-get install -y -q \
    build-essential \
    cmake \
    libssl-dev \
    libreadline-dev \
    zlib1g-dev \
    curl \
    wget \
    jq \
    net-tools \
    iproute2 \
    ca-certificates
# 尝试安装 DHCP 客户端（dhcpcd5 优先，fallback isc-dhcp-client）
apt-get install -y -q dhcpcd5 2>/dev/null || \
apt-get install -y -q isc-dhcp-client 2>/dev/null || \
    warn "未能安装 DHCP 客户端，连接后需手动配置 IP。"
log "依赖安装完成。"
echo ""

# 4. 架构检测
#    5.x 文件名架构标识：x64 / x86 / arm64 / arm_eabi
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)          SOFTETHER_ARCH="x64"      ;;
    i686|i386)       SOFTETHER_ARCH="x86"      ;;
    aarch64|arm64)   SOFTETHER_ARCH="arm64"    ;;
    armv7l|armv6l)   SOFTETHER_ARCH="arm_eabi" ;;
    *) err "不支持的系统架构: $ARCH" ;;
esac
log "系统架构: $ARCH → SoftEther 5.x 包架构标识: $SOFTETHER_ARCH"

# 5. 确定文件名
#    5.x 文件名格式：softether-vpnclient-v{VERSION}-linux-{ARCH}-unsigned.tar.gz
FILENAME="softether-vpnclient-v${VERSION}-linux-${SOFTETHER_ARCH}-unsigned.tar.gz"
GITHUB_DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/${FILENAME}"
log "目标文件: $FILENAME"
echo ""

# 6. 下载文件（优先级：本地 HTTP > 镜像 > 直连 GitHub）
cd "$TEMP_DIR"
DOWNLOAD_SUCCESS=false

# 6a. 本地 HTTP（若已配置）
if [ -n "$LOCAL_HTTP_BASE" ]; then
    LOCAL_URL="${LOCAL_HTTP_BASE%/}/${FILENAME}"
    log "[本地 HTTP] 尝试从本地服务器下载..."
    if try_download "$LOCAL_URL" "$FILENAME"; then
        log "✓ 本地 HTTP 下载成功！"
        DOWNLOAD_SUCCESS=true
    else
        warn "本地 HTTP 下载失败，将尝试镜像源。"
    fi
fi

# 6b. 镜像列表
if [ "$DOWNLOAD_SUCCESS" = false ]; then
    for MIRROR in "${MIRROR_URLS[@]}"; do
        ACCELERATED_URL="${MIRROR}${GITHUB_DOWNLOAD_URL}"
        log "[镜像] 尝试: ${MIRROR}"
        if try_download "$ACCELERATED_URL" "$FILENAME"; then
            log "✓ 镜像下载成功！(${MIRROR})"
            DOWNLOAD_SUCCESS=true
            break
        else
            warn "镜像 ${MIRROR} 下载失败，尝试下一个..."
        fi
    done
fi

# 6c. 直连 GitHub（最终备选）
if [ "$DOWNLOAD_SUCCESS" = false ]; then
    log "[直连] 所有镜像均失败，尝试直连 GitHub..."
    if try_download "$GITHUB_DOWNLOAD_URL" "$FILENAME"; then
        log "✓ 直连 GitHub 下载成功！"
        DOWNLOAD_SUCCESS=true
    fi
fi

[ "$DOWNLOAD_SUCCESS" = false ] && err "所有下载源均失败，请检查网络或版本号是否正确。\n  手动验证地址: ${GITHUB_DOWNLOAD_URL}"

# 7. 解压
log "正在解压 $FILENAME..."
tar -xzf "$FILENAME"

# 7.1 确认解压目录名（通常为 vpnclient）
if [ -d "vpnclient" ]; then
    SRC_DIR="vpnclient"
elif [ -d "SoftEtherVPN-${VERSION}" ]; then
    SRC_DIR="SoftEtherVPN-${VERSION}"
else
    # 找出解压出来的第一个目录
    SRC_DIR=$(find . -maxdepth 1 -mindepth 1 -type d | head -1)
    [ -z "$SRC_DIR" ] && err "解压后未找到目录，请检查下载的文件是否完整。"
    SRC_DIR="${SRC_DIR#./}"
fi
log "解压目录: $SRC_DIR"
cd "$SRC_DIR"

# 8. 编译或直接使用预编译二进制
#    5.x releases 提供预编译二进制，tar 包内包含可执行文件，无需编译
#    但若下载的是源码包（无二进制），则需 cmake 编译
if [ -f "./vpnclient" ] && [ -x "./vpnclient" ]; then
    log "检测到预编译二进制，跳过编译步骤。"
elif [ -f "CMakeLists.txt" ]; then
    log "未找到预编译二进制，使用 cmake 编译（可能耗时较长）..."
    mkdir -p build
    cd build
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TYPE=client \
        2>&1 | tail -5
    make -j"$(nproc)" 2>&1 | tail -10
    # 将编译产物复制到上层目录
    cp bin/vpnclient ../vpnclient 2>/dev/null || true
    cp bin/vpncmd    ../vpncmd    2>/dev/null || true
    cd ..
    log "编译完成。"
elif [ -f "./.install.sh" ]; then
    # 兼容部分非标准包格式，回退到 .install.sh
    log "使用 .install.sh 安装..."
    printf '1\n1\n1\n' | ./.install.sh || err ".install.sh 执行出错。"
else
    err "未找到可执行文件、CMakeLists.txt 或 .install.sh，无法继续安装。请确认版本号是否正确。"
fi

# 9. 移动到安装目录
log "正在将文件安装到 $INSTALL_DIR..."
cd "$TEMP_DIR"
rm -rf "$INSTALL_DIR"
mv "$SRC_DIR" "$INSTALL_DIR"

[ ! -f "$INSTALL_DIR/vpnclient" ] && err "文件移动失败，安装目录中缺少 vpnclient 可执行文件。"
log "文件已安装到 $INSTALL_DIR"

# 设置权限
chmod 750 "$INSTALL_DIR"
find "$INSTALL_DIR" -type f -name "*.sh" -exec chmod 750 {} \;
chmod 700 "$INSTALL_DIR/vpnclient" 2>/dev/null || true
chmod 700 "$INSTALL_DIR/vpncmd"    2>/dev/null || true
log "文件权限已设置完成。"
echo ""

# 10. 创建 systemd 服务
log "正在创建 systemd 服务 (vpnclient.service)..."
cat > /etc/systemd/system/vpnclient.service << 'EOF'
[Unit]
Description=SoftEther VPN Client (5.x)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/local/vpnclient/vpnclient start
ExecStop=/usr/local/vpnclient/vpnclient stop
ExecReload=/bin/kill -HUP $MAINPID
User=root
Group=root
Restart=on-failure
RestartSec=5
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vpnclient
systemctl start vpnclient
log "vpnclient 服务已启动并设置为开机自启。"
sleep 2

# 验证服务启动
if ! systemctl is-active --quiet vpnclient; then
    err "vpnclient 服务启动失败，请运行 journalctl -xeu vpnclient 查看日志。"
fi
echo ""

# 11. 交互式配置 VPN 账户
echo "===================================================="
echo "  配置 VPN 连接账户"
echo "===================================================="
echo ""
echo "接下来将引导您创建虚拟网卡并配置 VPN 账户。"
echo "如果暂时不配置，可按 Ctrl+C 退出，稍后手动运行:"
echo "  ${INSTALL_DIR}/vpncmd"
echo ""
read -r -p "是否现在配置 VPN 账户？(Y/n): " CONFIGURE_NOW
CONFIGURE_NOW="${CONFIGURE_NOW:-Y}"

if [[ ! "$CONFIGURE_NOW" =~ ^[Yy]$ ]]; then
    log "跳过账户配置。"
else
    echo ""
    read -r -p "  虚拟网卡名称      [默认: vpn0]: " NIC_NAME
    NIC_NAME="${NIC_NAME:-vpn0}"

    read -r -p "  VPN 账户名称      [默认: myvpn]: " ACCOUNT_NAME
    ACCOUNT_NAME="${ACCOUNT_NAME:-myvpn}"

    read -r -p "  VPN 服务器地址    (例: vpn.example.com): " SERVER_HOST
    if [ -z "${SERVER_HOST:-}" ]; then
        warn "服务器地址为空，跳过自动配置。请稍后手动配置。"
        CONFIGURE_NOW="n"
    fi
fi

if [[ "${CONFIGURE_NOW:-n}" =~ ^[Yy]$ ]] && [ -n "${SERVER_HOST:-}" ]; then
    read -r -p "  VPN 服务器端口    [默认: 443]: " SERVER_PORT
    SERVER_PORT="${SERVER_PORT:-443}"

    read -r -p "  Hub 名称          (VPN 服务器上的 HUB 名称) [默认: VPN]: " HUB_NAME
    HUB_NAME="${HUB_NAME:-VPN}"

    read -r -p "  VPN 用户名: " VPN_USER
    [ -z "${VPN_USER:-}" ] && err "用户名不能为空。"

    read -r -s -p "  VPN 密码: " VPN_PASS
    echo
    [ -z "${VPN_PASS:-}" ] && err "密码不能为空。"

    echo ""
    log "正在通过 vpncmd 配置 VPN 账户..."

    "${INSTALL_DIR}/vpncmd" localhost /CLIENT /CMD \
        NicCreate "$NIC_NAME" \
        AccountCreate "$ACCOUNT_NAME" \
            /SERVER:"${SERVER_HOST}:${SERVER_PORT}" \
            /HUB:"${HUB_NAME}" \
            /USERNAME:"${VPN_USER}" \
            /NICNAME:"$NIC_NAME" \
        AccountPasswordSet "$ACCOUNT_NAME" \
            /PASSWORD:"${VPN_PASS}" \
            /TYPE:standard \
        AccountConnect "$ACCOUNT_NAME" \
        || warn "vpncmd 配置过程中出现错误，请手动检查账户状态。"

    echo ""
    log "等待 VPN 连接建立（约 5 秒）..."
    sleep 5

    # 尝试通过 DHCP 获取 IP
    TAP_DEVICE="vpn_${NIC_NAME}"
    log "尝试在 ${TAP_DEVICE} 上通过 DHCP 获取 IP 地址..."
    if ip link show "$TAP_DEVICE" > /dev/null 2>&1; then
        ip link set "$TAP_DEVICE" up
        if command -v dhclient > /dev/null 2>&1; then
            dhclient "$TAP_DEVICE" 2>/dev/null || warn "dhclient 执行失败，请手动配置 IP。"
        elif command -v dhcpcd > /dev/null 2>&1; then
            dhcpcd "$TAP_DEVICE" 2>/dev/null || warn "dhcpcd 执行失败，请手动配置 IP。"
        else
            warn "未找到 DHCP 客户端工具（dhclient/dhcpcd），请手动配置 IP。"
        fi
        log "当前网络接口状态："
        ip addr show "$TAP_DEVICE" 2>/dev/null || true
    else
        warn "虚拟网卡 ${TAP_DEVICE} 未找到，VPN 连接可能尚未完全建立。"
        warn "请稍后运行: ip link show 查看网卡状态"
    fi

    echo ""
    log "当前 VPN 账户连接状态："
    "${INSTALL_DIR}/vpncmd" localhost /CLIENT /CMD \
        AccountStatusGet "$ACCOUNT_NAME" 2>/dev/null \
        | grep -E "状态|Status|Session|Virtual|Connected|Disconnected" || true
fi

# 12. 完成提示
echo ""
echo "===================================================="
echo "  ✅  SoftEther VPN Client v${VERSION} 安装完成！"
echo "===================================================="
echo ""
echo "  安装目录:     ${INSTALL_DIR}"
echo "  服务状态:     systemctl status vpnclient"
echo "  服务日志:     journalctl -u vpnclient -f"
echo ""
echo "  常用 vpncmd 命令（手动管理）："
echo "  ┌─────────────────────────────────────────────────┐"
echo "  │  进入管理工具:                                   │"
echo "  │    ${INSTALL_DIR}/vpncmd localhost /CLIENT       │"
echo "  │                                                 │"
echo "  │  常用子命令:                                     │"
echo "  │    NicCreate <名称>         # 创建虚拟网卡       │"
echo "  │    AccountCreate <名称> ... # 创建 VPN 账户      │"
echo "  │    AccountConnect <名称>    # 连接 VPN           │"
echo "  │    AccountDisconnect <名称> # 断开 VPN           │"
echo "  │    AccountList              # 查看所有账户       │"
echo "  │    AccountStatusGet <名称>  # 查看连接状态       │"
echo "  └─────────────────────────────────────────────────┘"
echo ""
echo "  DHCP 获取 IP（连接后）："
echo "    dhclient vpn_<虚拟网卡名>"
echo ""
echo "  参考链接:"
echo "    https://github.com/SoftEtherVPN/SoftEtherVPN/releases"
echo "===================================================="
