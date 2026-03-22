#!/bin/bash
set -e

# ============================================================
# 【配置区】将下载好的 SoftEtherVPN 源码 zip 上传到你的服务器
# 然后将 URL 填入下方变量，留空则自动从 GitHub 下载
# 示例: SOURCE_ZIP_URL="http://192.168.1.100:8080/SoftEtherVPN.zip"
# ============================================================
SOURCE_ZIP_URL="http://47.98.36.99:8888/chfs/shared/softether/SoftEtherVPN-master.zip"
# ============================================================

if [[ $EUID -ne 0 ]]; then
   echo "此脚本必须以 root 权限运行。"
   exit 1
fi

ARCH=$(uname -m)
echo "正在开始 SoftEther VPN Server 5.x 自动化安装 (Debian, 架构: $ARCH)..."

apt update
apt install -y cmake gcc g++ make pkgconf unzip wget \
    libncurses5-dev libssl-dev libsodium-dev \
    libreadline-dev zlib1g-dev git

cd /usr/local/src
rm -rf SoftEtherVPN

if [ -n "$SOURCE_ZIP_URL" ]; then
    # 从自定义服务器下载 zip
    echo "从自定义地址下载源码: $SOURCE_ZIP_URL"
    wget -O SoftEtherVPN.zip "$SOURCE_ZIP_URL"
    unzip -q SoftEtherVPN.zip
    # 兼容 zip 内顶层目录名不固定的情况（如 SoftEtherVPN-master）
    EXTRACTED_DIR=$(unzip -Z1 SoftEtherVPN.zip | head -1 | cut -d/ -f1)
    [ "$EXTRACTED_DIR" != "SoftEtherVPN" ] && mv "$EXTRACTED_DIR" SoftEtherVPN
    rm -f SoftEtherVPN.zip
else
    # 备用：从 GitHub 下载（自动重试 3 次）
    echo "SOURCE_ZIP_URL 未设置，尝试从 GitHub 克隆..."
    git config --global http.version HTTP/1.1
    for i in 1 2 3; do
        git clone --depth=1 https://github.com/SoftEtherVPN/SoftEtherVPN.git && break
        echo "Clone 失败，第 $i 次重试..."
        rm -rf SoftEtherVPN
        sleep 5
    done
    [ -d "SoftEtherVPN" ] || { echo "git clone 最终失败，请检查网络或设置 SOURCE_ZIP_URL。"; exit 1; }
fi

cd SoftEtherVPN

# 如果是 git 仓库则更新 submodule，zip 下载则直接初始化
if [ -d ".git" ]; then
    git submodule init && git submodule update
else
    # zip 包通常已包含 submodule 内容，若缺失则从网络补充
    git init
    git submodule update --init --recursive 2>/dev/null || true
fi

CMAKE_FLAGS="-DSKIP_CPU_FEATURES=ON" ./configure
make -C build
make -C build install

cat > /etc/systemd/system/softether-vpnserver.service <<EOF
[Unit]
Description=SoftEther VPN Server
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
WorkingDirectory=/usr/local/bin
ExecStart=/usr/local/bin/vpnserver start
ExecStop=/usr/local/bin/vpnserver stop
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable softether-vpnserver
systemctl start softether-vpnserver

sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p

echo "-------------------------------------------------------"
echo "安装完成！"
echo "架构: $ARCH"
echo "状态: $(systemctl is-active softether-vpnserver)"
echo "管理工具: vpncmd"
echo "-------------------------------------------------------"
