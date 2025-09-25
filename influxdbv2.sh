#!/bin/bash

# --- 变量定义与默认值 ---

# 默认版本号
DEFAULT_VERSION="2.7.12"

# InfluxDB 运行程序最终放置目录
INSTALL_DIR="/root"

# InfluxDB 服务名称
SERVICE_NAME="influxdb"

# --- 提示用户输入版本号 ---

read -r -p "请输入要安装的 InfluxDB 版本号 (默认: $DEFAULT_VERSION): " INFLUXDB_VERSION
INFLUXDB_VERSION=${INFLUXDB_VERSION:-$DEFAULT_VERSION} # 如果用户未输入，则使用默认值

echo "将安装 InfluxDB v$INFLUXDB_VERSION 版本。"

# --- 检测 CPU 架构 ---

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        OS_ARCH="amd64"
        ;;
    aarch64)
        OS_ARCH="arm64"
        ;;
    *)
        echo "错误: 不支持的 CPU 架构: $ARCH" >&2
        echo "脚本仅支持 x86_64 (amd64) 和 aarch64 (arm64)。" >&2
        exit 1
        ;;
esac

echo "检测到 CPU 架构为: $ARCH, 对应下载架构为: $OS_ARCH"

# --- 构造下载 URL 和文件名 ---

FILENAME="influxdb2-${INFLUXDB_VERSION}_linux_${OS_ARCH}.tar.gz"
DOWNLOAD_URL="https://dl.influxdata.com/influxdb/releases/v${INFLUXDB_VERSION}/${FILENAME}"
TEMP_DIR="/tmp/influxdb_install_$$"
BINARY_NAME="influxd"

# --- 下载与解压 ---

echo "---"
echo "开始下载 InfluxDB v$INFLUXDB_VERSION..."
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR" || exit 1

# 检查 curl 是否安装
if ! command -v curl &> /dev/null; then
    echo "错误: curl 未安装。请先安装 curl。" >&2
    exit 1
fi

# 使用 curl 下载文件
if ! curl -L "$DOWNLOAD_URL" -o "$FILENAME"; then
    echo "错误: 下载文件失败。请检查版本号 ($INFLUXDB_VERSION) 和网络连接。" >&2
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "下载完成，开始解压..."

# 解压文件
if ! tar -xzf "$FILENAME"; then
    echo "错误: 解压文件失败。" >&2
    rm -rf "$TEMP_DIR"
    exit 1
fi

# 查找 influxd 二进制文件
UNPACK_DIR=$(find . -maxdepth 1 -type d -name "influxdb2-*" -print -quit)
if [ -z "$UNPACK_DIR" ]; then
    echo "错误: 找不到解压后的 InfluxDB 目录。" >&2
    rm -rf "$TEMP_DIR"
    exit 1
fi

INFLUXD_PATH="${UNPACK_DIR}/usr/bin/${BINARY_NAME}"

# 再次检查文件路径
if [ ! -f "$INFLUXD_PATH" ]; then
    echo "错误: 在预期的位置找不到 ${BINARY_NAME} 二进制文件: $INFLUXD_PATH" >&2
    INFLUXD_PATH=$(find "$UNPACK_DIR" -type f -name "${BINARY_NAME}" -print -quit)
    if [ -z "$INFLUXD_PATH" ]; then
        echo "错误: 在整个解压目录中也找不到 ${BINARY_NAME}。" >&2
        rm -rf "$TEMP_DIR"
        exit 1
    fi
fi

# 移动到目标安装目录
echo "将 $BINARY_NAME 移动到 $INSTALL_DIR/$BINARY_NAME..."
mkdir -p "$INSTALL_DIR"
mv "$INFLUXD_PATH" "$INSTALL_DIR/$BINARY_NAME"
chmod +x "$INSTALL_DIR/$BINARY_NAME"

# 清理临时文件
rm -rf "$TEMP_DIR"

echo "InfluxDB 二进制程序安装完成: $INSTALL_DIR/$BINARY_NAME"
echo "---"

# --- 提示用户输入数据存储目录 ---

DEFAULT_DATA_DIR="/data/influxdb_data"

read -r -p "请输入 InfluxDB 数据存储目录 (默认: $DEFAULT_DATA_DIR): " DATA_DIR
DATA_DIR=${DATA_DIR:-$DEFAULT_DATA_DIR}

# 确保数据目录存在
mkdir -p "$DATA_DIR/engine"
mkdir -p "$DATA_DIR/bolt"

echo "InfluxDB 数据将存储在: $DATA_DIR"
echo "---"

# --- 创建 systemd 服务 (精简版本) ---

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
EXEC_START="${INSTALL_DIR}/${BINARY_NAME} --engine-path ${DATA_DIR}/engine --bolt-path ${DATA_DIR}/influxd.bolt"

echo "创建 systemd 服务文件: $SERVICE_FILE"

# 注意：这里去除了 Documentation, StandardOutput/Error, TimeoutStartSec 等可能引起旧系统报错的配置
cat << EOF | sudo tee "$SERVICE_FILE" > /dev/null
[Unit]
Description=InfluxDB Service
After=network-online.target

[Service]
User=root 
Group=root
Type=simple
ExecStart=${EXEC_START}
Restart=always
LimitNOFILE=65536
WorkingDirectory=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF

# 重新加载 systemd 配置，启用并启动服务
echo "重新加载 systemd 配置..."
if ! systemctl daemon-reload; then
    echo "警告: systemctl daemon-reload 失败，请手动执行。"
fi

echo "设置 $SERVICE_NAME 服务开机自启动..."
if ! systemctl enable "$SERVICE_NAME"; then
    echo "警告: systemctl enable $SERVICE_NAME 失败，请手动执行。"
fi

echo "启动 $SERVICE_NAME 服务..."
if systemctl start "$SERVICE_NAME"; then
    echo "---"
    echo "🎉 InfluxDB 服务安装并启动成功!"
    echo "您可以通过 'systemctl status $SERVICE_NAME' 查看服务状态。"
    echo "首次启动后，请访问 http://<服务器IP>:8086 进行初始化配置。"
else
    echo "---"
    echo "❌ 警告: InfluxDB 服务启动失败。"
    echo "请执行 'systemctl status $SERVICE_NAME' 检查详细错误日志。"
    echo "如果仍有 'bad unit file setting' 错误，请检查您的 Linux 发行版。"
fi
