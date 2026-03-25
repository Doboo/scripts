#!/bin/bash
set -euo pipefail

# --- 变量定义与默认值 ---
DEFAULT_VERSION="2.7.12"
INSTALL_DIR="/root"
SERVICE_NAME="influxdb"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# --- Root 权限检查（移到最前面）---
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：此脚本需要 root 权限运行。" >&2
    exit 1
fi

# --- 检查依赖工具 ---
if ! command -v curl &> /dev/null; then
    echo "错误: curl 未安装。请先安装 curl。" >&2
    exit 1
fi

# --- 提示用户输入版本号 ---
read -r -p "请输入要安装的 InfluxDB 版本号 (默认: $DEFAULT_VERSION): " INFLUXDB_VERSION
INFLUXDB_VERSION=${INFLUXDB_VERSION:-$DEFAULT_VERSION}

# 验证版本号格式
if ! [[ "$INFLUXDB_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "错误：版本号格式无效（需为 x.y.z 格式，如 2.7.12）。" >&2
    exit 1
fi

echo "将安装 InfluxDB v$INFLUXDB_VERSION 版本。"

# --- 检测 CPU 架构 ---
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  OS_ARCH="amd64" ;;
    aarch64) OS_ARCH="arm64" ;;
    *)
        echo "错误: 不支持的 CPU 架构: $ARCH（仅支持 x86_64 和 aarch64）。" >&2
        exit 1
        ;;
esac
echo "检测到 CPU 架构为: $ARCH，对应下载架构为: $OS_ARCH"

# --- 构造下载 URL 和文件名 ---
FILENAME="influxdb2-${INFLUXDB_VERSION}_linux_${OS_ARCH}.tar.gz"
DOWNLOAD_URL="https://dl.influxdata.com/influxdb/releases/v${INFLUXDB_VERSION}/${FILENAME}"
TEMP_DIR=$(mktemp -d /tmp/influxdb_install_XXXXXX)

# 确保临时目录在退出时被清理
trap 'rm -rf "$TEMP_DIR"' EXIT

# --- 下载与解压 ---
echo "---"
echo "开始下载 InfluxDB v$INFLUXDB_VERSION..."
cd "$TEMP_DIR"

if ! curl -L --fail --progress-bar "$DOWNLOAD_URL" -o "$FILENAME"; then
    echo "错误: 下载文件失败。请检查版本号 ($INFLUXDB_VERSION) 和网络连接。" >&2
    exit 1
fi

echo "下载完成，开始解压..."
if ! tar -xzf "$FILENAME"; then
    echo "错误: 解压文件失败。" >&2
    exit 1
fi

# 查找解压后的目录
UNPACK_DIR=$(find . -maxdepth 1 -type d -name "influxdb2-*" -print -quit)
if [ -z "$UNPACK_DIR" ]; then
    echo "错误: 找不到解压后的 InfluxDB 目录。" >&2
    exit 1
fi

INFLUXD_PATH="${UNPACK_DIR}/usr/bin/influxd"
# 若标准路径不存在则全局查找
if [ ! -f "$INFLUXD_PATH" ]; then
    echo "标准路径 $INFLUXD_PATH 不存在，正在全局搜索..."
    INFLUXD_PATH=$(find "$UNPACK_DIR" -type f -name "influxd" -print -quit)
    if [ -z "$INFLUXD_PATH" ]; then
        echo "错误: 在整个解压目录中也找不到 influxd。" >&2
        exit 1
    fi
fi

# 移动到目标安装目录
echo "将 influxd 移动到 $INSTALL_DIR/influxd..."
mkdir -p "$INSTALL_DIR"
mv "$INFLUXD_PATH" "$INSTALL_DIR/influxd"
chmod +x "$INSTALL_DIR/influxd"

echo "InfluxDB 二进制程序安装完成: $INSTALL_DIR/influxd"
echo "---"

# --- 提示用户输入数据存储目录 ---
DEFAULT_DATA_DIR="/data/influxdb_data"
read -r -p "请输入 InfluxDB 数据存储目录 (默认: $DEFAULT_DATA_DIR): " DATA_DIR
DATA_DIR=${DATA_DIR:-$DEFAULT_DATA_DIR}

mkdir -p "$DATA_DIR/engine"
mkdir -p "$DATA_DIR/bolt"
echo "InfluxDB 数据将存储在: $DATA_DIR"
echo "---"

# --- 创建 systemd 服务 ---
EXEC_START="${INSTALL_DIR}/influxd --engine-path ${DATA_DIR}/engine --bolt-path ${DATA_DIR}/bolt/influxd.bolt"

echo "创建 systemd 服务文件: $SERVICE_FILE"
cat > "$SERVICE_FILE" << EOF
[Unit]
Description=InfluxDB Service
After=network-online.target
Wants=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=${EXEC_START}
Restart=always
LimitNOFILE=65536
WorkingDirectory=${INSTALL_DIR}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 重新加载 systemd 配置，启用并启动服务
echo "重新加载 systemd 配置..."
systemctl daemon-reload

echo "设置 $SERVICE_NAME 服务开机自启动..."
systemctl enable "$SERVICE_NAME"

echo "启动 $SERVICE_NAME 服务..."
if systemctl start "$SERVICE_NAME"; then
    echo "---"
    echo "🎉 InfluxDB 服务安装并启动成功!"
    echo "可通过 'systemctl status $SERVICE_NAME' 查看服务状态。"
    echo "首次启动后，请访问 http://<服务器IP>:8086 进行初始化配置。"
else
    echo "---"
    echo "❌ 警告: InfluxDB 服务启动失败。"
    echo "请执行 'journalctl -xeu $SERVICE_NAME' 检查详细错误日志。"
    exit 1
fi
