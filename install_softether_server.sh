#!/bin/bash

# =================================================================
# SoftEther VPN Server 自动安装脚本 (v6 - 多源下载版)
#
# 新增功能：
#   1. 手动输入版本号（默认 4.44，构建号 9807，标签 rtm）
#   2. 支持多个镜像加速地址（依次尝试）
#   3. 支持单个本地 HTTP 下载地址（直接使用，跳过镜像）
# =================================================================

set -e

# ==================================================================
# >>>>>>>>>>>>>> 用户可配置区域 START <<<<<<<<<<<<<<
# ==================================================================

# 默认版本信息（当用户不输入时使用）
DEFAULT_VERSION="4.44"
DEFAULT_BUILD="9807"
DEFAULT_TAG="rtm"

# GitHub 加速镜像列表（按优先级排序，依次尝试）
# 格式：每行一个前缀 URL，拼接到原始 GitHub 下载链接前即可
MIRROR_URLS=(
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    "https://mirror.ghproxy.com/"
)

# 本地/内网 HTTP 下载服务器基础地址（留空则跳过）
# 如果设置了此项，将优先使用此地址，完全跳过 GitHub 和镜像
# 脚本会自动拼接文件名，格式为：${LOCAL_HTTP_BASE}/${FILENAME}
# 示例: LOCAL_HTTP_BASE="http://192.168.1.100:8080/softether"
LOCAL_HTTP_BASE=""

# ==================================================================
# >>>>>>>>>>>>>> 用户可配置区域 END   <<<<<<<<<<<<<<
# ==================================================================

GITHUB_REPO="SoftEtherVPN/SoftEtherVPN_Stable"
INSTALL_DIR="/usr/local/vpnserver"
TEMP_DIR=$(mktemp -d)

# --- 帮助函数 ---
log() {
    echo "--- [INFO] $1"
}

warn() {
    echo "!!! [WARN] $1" >&2
}

err() {
    echo "*** [ERROR] $1" >&2
    rm -rf "$TEMP_DIR"
    exit 1
}

# --- 尝试下载函数（成功返回 0，失败返回 1）---
try_download() {
    local url="$1"
    local output="$2"
    log "尝试下载: $url"
    if wget -q --show-progress --tries=2 --timeout=30 -O "$output" "$url" 2>/dev/null; then
        # 检查文件大小，避免下载到错误页面（小于 1MB 视为失败）
        local size
        size=$(stat -c%s "$output" 2>/dev/null || echo 0)
        if [ "$size" -gt 1048576 ]; then
            return 0
        else
            warn "下载文件过小 (${size} bytes)，可能是错误页面，跳过此源。"
            rm -f "$output"
            return 1
        fi
    else
        rm -f "$output"
        return 1
    fi
}

# ===== 脚本开始 =====

# 1. 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
   err "此脚本必须以 root 权限运行。"
fi

# 2. 交互式输入版本号
echo "===================================================="
echo " SoftEther VPN Server 安装脚本"
echo "===================================================="
echo ""
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
log "正在安装依赖包..."
if [ -f /usr/bin/apt ]; then
    apt update -y > /dev/null
    apt install -y build-essential curl wget jq > /dev/null
elif [ -f /usr/bin/yum ]; then
    yum install -y epel-release > /dev/null
    yum install -y make gcc curl wget jq > /dev/null
elif [ -f /usr/bin/dnf ]; then
    dnf install -y make gcc curl wget jq > /dev/null
else
    err "不支持的包管理器。"
fi
log "依赖包检查完成。"

# 4. 架构检测
ARCH=$(uname -m)
SOFTETHER_ARCH=""
case "$ARCH" in
    x86_64)        SOFTETHER_ARCH="linux-x64" ;;
    i686|i386)     SOFTETHER_ARCH="linux-x86" ;;
    aarch64)       SOFTETHER_ARCH="linux-arm64" ;;
    armv7l|arm)    SOFTETHER_ARCH="linux-arm" ;;
    *) err "不支持的系统架构: $ARCH" ;;
esac
log "检测到系统架构: $ARCH (SoftEther 架构: $SOFTETHER_ARCH)"

# 5. 通过 GitHub API 获取精确文件名（含日期字段）
log "正在从 GitHub API 获取 ${FULL_TAG} 版本的文件信息..."
RELEASE_API="https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${FULL_TAG}"

GITHUB_DOWNLOAD_URL=$(curl -sf --max-time 15 "$RELEASE_API" \
    | jq -r --arg ARCH "$SOFTETHER_ARCH" \
      '.assets[] | select(.name | (contains($ARCH) and contains("vpnserver"))) | .browser_download_url' \
    2>/dev/null || true)

if [ -z "$GITHUB_DOWNLOAD_URL" ] || [ "$GITHUB_DOWNLOAD_URL" = "null" ]; then
    warn "无法通过 GitHub API 获取文件链接，将尝试构造文件名..."
    # API 失败时尝试已知日期格式（可按需扩展此列表）
    # 格式: softether-vpnserver-{FULL_TAG}-{DATE}-{ARCH}-64bit.tar.gz
    KNOWN_DATES=("2025.04.16" "2025.01.01" "2024.09.24")
    GITHUB_DOWNLOAD_URL=""
    for DATE in "${KNOWN_DATES[@]}"; do
        BITS="64bit"
        [[ "$SOFTETHER_ARCH" == "linux-x86" || "$SOFTETHER_ARCH" == "linux-arm" ]] && BITS="32bit"
        CANDIDATE="softether-vpnserver-${FULL_TAG}-${DATE}-${SOFTETHER_ARCH}-${BITS}.tar.gz"
        CANDIDATE_URL="https://github.com/${GITHUB_REPO}/releases/download/${FULL_TAG}/${CANDIDATE}"
        # 仅做 HEAD 请求验证是否存在
        if curl -sf --head --max-time 10 "$CANDIDATE_URL" > /dev/null 2>&1; then
            GITHUB_DOWNLOAD_URL="$CANDIDATE_URL"
            log "找到文件: $CANDIDATE"
            break
        fi
    done
    if [ -z "$GITHUB_DOWNLOAD_URL" ]; then
        err "无法确定下载文件名，请检查版本号或网络连接。"
    fi
fi

FILENAME=$(basename "$GITHUB_DOWNLOAD_URL")
log "目标文件: $FILENAME"

# 6. 下载文件（优先级：本地 HTTP > 镜像列表 > 直连 GitHub）
cd "$TEMP_DIR"
DOWNLOAD_SUCCESS=false

# 6a. 尝试本地 HTTP 下载（若已配置）
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

# 6b. 依次尝试镜像列表
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

if [ "$DOWNLOAD_SUCCESS" = false ]; then
    err "所有下载源均失败，请检查网络或版本号是否正确。"
fi

# 7. 解压
log "正在解压 $FILENAME..."
tar -xzf "$FILENAME"
cd vpnserver

# 8. 运行安装脚本
log "正在运行安装脚本 (.install.sh) 并自动同意许可协议..."
if [ ! -f ./.install.sh ]; then
    err "未找到 .install.sh，请确认下载的文件内容。"
fi

printf '1\n1\n1\n' | ./.install.sh
if [ $? -ne 0 ]; then
    err "安装准备失败。(.install.sh 脚本执行出错)"
fi

# 9. 移动文件到安装目录
log "正在将文件移动到最终安装目录 $INSTALL_DIR..."
cd ..
rm -rf "$INSTALL_DIR"
mv vpnserver "$INSTALL_DIR"

if [ ! -f "$INSTALL_DIR/vpnserver" ]; then
    err "文件移动失败。最终安装目录中缺少 vpnserver 可执行文件。"
fi
log "文件已成功安装到 $INSTALL_DIR"

# 设置权限
chmod 600 "$INSTALL_DIR"/*
chmod 700 "$INSTALL_DIR"/vpnserver
chmod 700 "$INSTALL_DIR"/vpncmd

# 10. 创建系统服务
if [ -f /usr/bin/systemctl ]; then
    log "正在创建 systemd 服务 (vpnserver.service)..."
    cat > /etc/systemd/system/vpnserver.service << EOF
[Unit]
Description=SoftEther VPN Server
After=network.target

[Service]
Type=forking
ExecStart=$INSTALL_DIR/vpnserver start
ExecStop=$INSTALL_DIR/vpnserver stop
User=root
Group=root
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    log "重新加载 systemd 并启动 vpnserver 服务..."
    systemctl daemon-reload
    systemctl start vpnserver
    systemctl enable vpnserver
    log "等待服务启动..."
    sleep 3
    systemctl status vpnserver --no-pager

else
    log "未检测到 systemd，正在创建 init.d 脚本..."
    cat > /etc/init.d/vpnserver << EOF
#!/bin/sh
# chkconfig: 2345 99 01
# description: SoftEther VPN Server
DAEMON=$INSTALL_DIR/vpnserver
LOCK=/var/lock/subsys/vpnserver

case "\$1" in
start)
    \$DAEMON start
    touch \$LOCK
    ;;
stop)
    \$DAEMON stop
    rm \$LOCK
    ;;
restart)
    \$DAEMON stop
    sleep 3
    \$DAEMON start
    ;;
*)
    echo "Usage: \$0 {start|stop|restart}"
    exit 1
esac
exit 0
EOF
    chmod 755 /etc/init.d/vpnserver
    if [ -f /sbin/chkconfig ]; then
        chkconfig --add vpnserver
        chkconfig vpnserver on
    elif [ -f /usr/sbin/update-rc.d ]; then
        update-rc.d vpnserver defaults
    fi
    /etc/init.d/vpnserver start
    log "vpnserver 服务已通过 init.d 启动。"
fi

# 11. 清理
log "清理临时文件..."
rm -rf "$TEMP_DIR"
cd ~

# 12. 完成提示
log "SoftEther VPN Server ${FULL_TAG} 安装完成! 🎉"
echo "===================================================="
echo " 重要：您必须立即设置一个管理员密码!"
echo ""
echo " 1. 运行: $INSTALL_DIR/vpncmd"
echo " 2. 选择 '1' (Management of VPN Server)"
echo " 3. 按 Enter (localhost:default)"
echo " 4. 再次按 Enter (Server Admin Mode)"
echo " 5. 运行: ServerPasswordSet"
echo " 6. 设置您的密码"
echo "===================================================="
