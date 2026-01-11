#!/usr/bin/env bash
set -e

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 运行本脚本（或 sudo bash xxx.sh）。"
    exit 1
fi

# GitHub 镜像前缀
MIRROR="https://docker.mk/"

# 获取最新版本
API_URL="${MIRROR}https://api.github.com/repos/snail007/proxy_admin_free/releases/latest"
echo "获取最新版本..."
TAG=$(curl -s "$API_URL" | grep -Po '"tag_name": *"\K.*?(?=")')
if [ -z "$TAG" ]; then
    echo "无法获取最新版本，退出。"
    exit 1
fi
echo "最新版本: $TAG"

# 检测架构并映射文件名
ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
    x86_64|amd64)
        FILE_NAME="proxy-admin_linux-amd64.tar.gz"
        ;;
    aarch64|arm64)
        FILE_NAME="proxy-admin_arm64.tar.gz"
        ;;
    *)
        echo "不支持的架构: $ARCH_RAW (仅支持 amd64/arm64)"
        exit 1
        ;;
esac
echo "检测到架构: $ARCH_RAW -> $FILE_NAME"

# 下载 URL
DOWNLOAD_URL="${MIRROR}https://github.com/snail007/proxy_admin_free/releases/download/${TAG}/${FILE_NAME}"

# 下载与解压
TMP_DIR=/tmp/proxy_admin_install
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
cd "$TMP_DIR"

echo "下载 $FILE_NAME ..."
curl -L "$DOWNLOAD_URL" -o "$FILE_NAME"

echo "解压 ..."
tar -zxf "$FILE_NAME"

# 进入解压目录并执行安装
if [ ! -f "./proxy-admin" ]; then
    echo "未找到 proxy-admin，请检查压缩包。"
    ls -la
    exit 1
fi

chmod +x ./proxy-admin
echo "执行 ./proxy-admin install ..."
./proxy-admin install

echo "启动并启用 proxyadmin.service ..."
systemctl daemon-reload
systemctl enable proxyadmin.service
systemctl start proxyadmin.service

echo "安装完成！"
echo "状态:"
systemctl status proxyadmin.service --no-pager -l
echo ""
echo "默认访问: http://127.0.0.1:32080 (root/123)"
