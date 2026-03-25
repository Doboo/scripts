#!/bin/bash
# =================================================================
# SoftEther VPN Client 自动安装脚本（Debian 12 适配版）
#
# 功能：
#   1. 安装 SoftEther VPN Client（vpnclient）
#   2. 支持手动输入版本号（默认 4.44，构建号 9807）
#   3. 多镜像加速下载（本地 HTTP > 镜像列表 > 直连 GitHub）
#   4. 交互式配置虚拟网卡和 VPN 账户
#   5. 创建 systemd 服务并自动启动
#   6. 自动创建 tap 设备并通过 DHCP 获取 IP
# =================================================================

set -euo pipefail

# ==================================================================
# >>>>>>>>>>>>>> 用户可配置区域 START <<<<<<<<<<<<<<
# ==================================================================

DEFAULT_VERSION="4.44"
DEFAULT_BUILD="9807"
DEFAULT_TAG="rtm"

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

GITHUB_REPO="SoftEtherVPN/SoftEtherVPN_Stable"
INSTALL_DIR="/usr/local/vpnclient"
TEMP_DIR=$(mktemp -d)

# ── 日志函数 ──────────────────────────────────────────────────────
log()  { echo "--- [INFO]  $*"; }
warn() { echo "!!! [WARN]  $*" >&2; }
err()  { echo "*** [ERROR] $*" >&2; rm -rf "$TEMP_DIR"; exit 1; }

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
echo "  SoftEther VPN Client 安装脚本（Debian 12）"
echo "===================================================="
echo ""

# 2. 交互式输入版本号
echo "请输入版本信息（直接按 Enter 使用默认值）："
echo ""
read -r -p "  版本号   [默认: ${DEFAULT_VERSION}]: " INPUT_VERSION
read -r -p "  构建号   [默认: ${DEFAULT_BUILD}]: " INPUT_BUILD
read -r -p "  标签     [默认: ${DEFAULT_TAG}]: " INPUT_TAG

VERSION="${INPUT_VERSION:-$DEFAULT_VERSION}"
BUILD="${INPUT_BUILD:-$DEFAULT_BUILD}"
TAG="${INPUT_TAG:-$DEFAULT_TAG}"
FULL_TAG="v${VERSION}-${BUILD}-${TAG}"

echo ""
log "将安装版本: ${FULL_TAG}"
echo ""

# 3. 安装依赖
log "正在更新包列表并安装依赖..."
apt-get update -y -q
apt-get install -y -q \
    build-essential \
    curl \
    wget \
    jq \
    net-tools \
    iproute2 \
    dhcpcd5 2>/dev/null || \
apt-get install -y -q \
    build-essential \
    curl \
    wget \
    jq \
    net-tools \
    iproute2 \
    isc-dhcp-client
log "依赖安装完成。"
echo ""

# 4. 架构检测
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)     SOFTETHER_ARCH="linux-x64"  ;;
    i686|i386)  SOFTETHER_ARCH="linux-x86"  ;;
    aarch64)    SOFTETHER_ARCH="linux-arm64" ;;
    armv7l|arm) SOFTETHER_ARCH="linux-arm"  ;;
    *) err "不支持的系统架构: $ARCH" ;;
esac
log "系统架构: $ARCH (SoftEther 包架构: $SOFTETHER_ARCH)"

# 5. 通过 GitHub API 获取精确文件名
log "正在从 GitHub API 获取 ${FULL_TAG} 的文件信息..."
RELEASE_API="https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${FULL_TAG}"

GITHUB_DOWNLOAD_URL=$(curl -sf --max-time 15 "$RELEASE_API" \
    | jq -r --arg ARCH "$SOFTETHER_ARCH" \
      '.assets[] | select(.name | (contains($ARCH) and contains("vpnclient"))) | .browser_download_url' \
    2>/dev/null || true)

if [ -z "$GITHUB_DOWNLOAD_URL" ] || [ "$GITHUB_DOWNLOAD_URL" = "null" ]; then
    warn "GitHub API 获取文件链接失败，尝试构造文件名..."
    KNOWN_DATES=("2025.04.16" "2025.01.01" "2024.09.24")
    GITHUB_DOWNLOAD_URL=""
    for DATE in "${KNOWN_DATES[@]}"; do
        BITS="64bit"
        [[ "$SOFTETHER_ARCH" == "linux-x86" || "$SOFTETHER_ARCH" == "linux-arm" ]] && BITS="32bit"
        CANDIDATE="softether-vpnclient-${FULL_TAG}-${DATE}-${SOFTETHER_ARCH}-${BITS}.tar.gz"
        CANDIDATE_URL="https://github.com/${GITHUB_REPO}/releases/download/${FULL_TAG}/${CANDIDATE}"
        if curl -sf --head --max-time 10 "$CANDIDATE_URL" > /dev/null 2>&1; then
            GITHUB_DOWNLOAD_URL="$CANDIDATE_URL"
            log "找到文件: $CANDIDATE"
            break
        fi
    done
    [ -z "$GITHUB_DOWNLOAD_URL" ] && err "无法确定下载文件名，请检查版本号或网络连接。"
fi

FILENAME=$(basename "$GITHUB_DOWNLOAD_URL")
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

[ "$DOWNLOAD_SUCCESS" = false ] && err "所有下载源均失败，请检查网络或版本号是否正确。"

# 7. 解压并编译安装
log "正在解压 $FILENAME..."
tar -xzf "$FILENAME"
cd vpnclient

log "正在运行安装脚本（自动同意许可协议）..."
if [ ! -f ./.install.sh ]; then
    err "未找到 .install.sh，请确认下载的文件内容是否正确。"
fi
printf '1\n1\n1\n' | ./.install.sh || err "安装准备失败（.install.sh 执行出错）。"

# 8. 移动到安装目录
log "正在将文件移动到 $INSTALL_DIR..."
cd ..
rm -rf "$INSTALL_DIR"
mv vpnclient "$INSTALL_DIR"

[ ! -f "$INSTALL_DIR/vpnclient" ] && err "文件移动失败，安装目录中缺少 vpnclient 可执行文件。"
log "文件已安装到 $INSTALL_DIR"

# 设置权限
chmod 600 "$INSTALL_DIR"/*
chmod 700 "$INSTALL_DIR/vpnclient"
chmod 700 "$INSTALL_DIR/vpncmd"
log "文件权限已设置完成。"
echo ""

# 9. 创建 systemd 服务
log "正在创建 systemd 服务 (vpnclient.service)..."
cat > /etc/systemd/system/vpnclient.service << EOF
[Unit]
Description=SoftEther VPN Client
After=network.target

[Service]
Type=forking
ExecStart=${INSTALL_DIR}/vpnclient start
ExecStop=${INSTALL_DIR}/vpnclient stop
ExecReload=/bin/kill -HUP \$MAINPID
User=root
Group=root
Restart=always
RestartSec=3

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

# 10. 交互式配置 VPN 账户
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
    # 收集 VPN 账户信息
    echo ""
    read -r -p "  虚拟网卡名称      [默认: vpn0]: " NIC_NAME
    NIC_NAME="${NIC_NAME:-vpn0}"

    read -r -p "  VPN 账户名称      [默认: myvpn]: " ACCOUNT_NAME
    ACCOUNT_NAME="${ACCOUNT_NAME:-myvpn}"

    read -r -p "  VPN 服务器地址    (例: vpn.example.com): " SERVER_HOST
    if [ -z "$SERVER_HOST" ]; then
        warn "服务器地址为空，跳过自动配置。请稍后手动配置。"
        CONFIGURE_NOW="n"
    fi
fi

if [[ "$CONFIGURE_NOW" =~ ^[Yy]$ ]] && [ -n "${SERVER_HOST:-}" ]; then
    read -r -p "  VPN 服务器端口    [默认: 443]: " SERVER_PORT
    SERVER_PORT="${SERVER_PORT:-443}"

    read -r -p "  Hub 名称          (VPN 服务器上的 HUB 名称): " HUB_NAME
    [ -z "$HUB_NAME" ] && HUB_NAME="VPN"

    read -r -p "  VPN 用户名: " VPN_USER
    [ -z "$VPN_USER" ] && err "用户名不能为空。"

    read -r -s -p "  VPN 密码: " VPN_PASS
    echo
    [ -z "$VPN_PASS" ] && err "密码不能为空。"

    echo ""
    log "正在通过 vpncmd 配置 VPN 账户..."

    # 通过 vpncmd 的非交互模式批量执行命令
    "${INSTALL_DIR}/vpncmd" localhost /CLIENT /CMD \
        NicCreate "$NIC_NAME" \
        AccountCreate "$ACCOUNT_NAME" /SERVER:"${SERVER_HOST}:${SERVER_PORT}" /HUB:"${HUB_NAME}" /USERNAME:"${VPN_USER}" /NICNAME:"$NIC_NAME" \
        AccountPasswordSet "$ACCOUNT_NAME" /PASSWORD:"${VPN_PASS}" /TYPE:standard \
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

    # 检查连接状态
    echo ""
    log "当前 VPN 账户连接状态："
    "${INSTALL_DIR}/vpncmd" localhost /CLIENT /CMD \
        AccountStatusGet "$ACCOUNT_NAME" 2>/dev/null \
        | grep -E "状态|Status|Session|Virtual|Connected|Disconnected" || true
fi

# 11. 清理临时文件
log "清理临时文件..."
rm -rf "$TEMP_DIR"
cd ~

# 12. 完成提示
echo ""
echo "===================================================="
echo "  ✅  SoftEther VPN Client ${FULL_TAG} 安装完成！"
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
echo "===================================================="
