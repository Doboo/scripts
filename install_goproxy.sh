#!/bin/bash
set -e

# 检查是否以root用户运行
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root用户运行此脚本" >&2
    exit 1
fi

# 检测CPU架构
detect_architecture() {
    local arch=$(uname -m)
    case $arch in
        x86_64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l) echo "arm" ;;
        i386|i686) echo "386" ;;
        *) echo "不支持的架构: $arch" >&2; exit 1 ;;
    esac
}

ARCH=$(detect_architecture)
echo "检测到CPU架构: $ARCH"

# 提示用户输入token
read -p "请输入goproxy的token: " TOKEN
if [ -z "$TOKEN" ]; then
    echo "token不能为空" >&2
    exit 1
fi

# 创建安装目录
INSTALL_DIR="/root/proxy"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# 获取最新版本号
echo "正在获取最新版本..."
LAST_VERSION=$(curl --silent "https://api.github.com/repos/snail007/goproxy/releases/latest" | grep -Po '"tag_name": *"\K.*?(?=")')
if [ -z "$LAST_VERSION" ]; then
    echo "无法获取最新版本号，使用默认版本v15.1"
    LAST_VERSION="v15.1"
fi

# 下载安装包
PACKAGE="proxy-linux-${ARCH}.tar.gz"
DOWNLOAD_URL="https://ghfast.top/https://github.com/snail007/goproxy/releases/download/${LAST_VERSION}/${PACKAGE}"
echo "正在下载 ${DOWNLOAD_URL}..."
wget -q --show-progress "$DOWNLOAD_URL" -O "$PACKAGE"

# 解压安装包
echo "正在解压安装包..."
tar zxvf "$PACKAGE" >/dev/null 2>&1
rm -f "$PACKAGE"

# 创建systemd服务文件
SERVICE_FILE="/etc/systemd/system/goproxy.service"
echo "正在创建systemd服务..."
cat > "$SERVICE_FILE" << EOF
[Unit]
Description=GoProxy Client Service
After=network.target

[Service]
Type=simple
WorkingDirectory=/root/proxy
ExecStart=/root/proxy/proxy client -P nps.175419.xyz:30001 -T tcp --k $TOKEN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 启动服务
echo "正在启动goproxy服务..."
systemctl daemon-reload
systemctl enable goproxy
systemctl start goproxy

# 检查服务状态
echo "检查服务状态..."
if systemctl is-active --quiet goproxy; then
    echo "goproxy服务已成功启动"
    echo "服务状态: 运行中"
    echo "可以使用以下命令管理服务:"
    echo "  启动: systemctl start goproxy"
    echo "  停止: systemctl stop goproxy"
    echo "  重启: systemctl restart goproxy"
    echo "  查看状态: systemctl status goproxy"
else
    echo "goproxy服务启动失败" >&2
    echo "请查看日志: journalctl -u goproxy" >&2
    exit 1
fi
