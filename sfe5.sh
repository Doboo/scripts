#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "此脚本必须以 root 权限运行。"
   exit 1
fi

ARCH=$(uname -m)
echo "正在开始 SoftEther VPN Server 5.x 自动化安装 (Debian, 架构: $ARCH)..."

# 1. 安装依赖（官方推荐，含 libsodium-dev 和 g++）
apt update
apt install -y cmake gcc g++ make pkgconf \
    libncurses5-dev libssl-dev libsodium-dev \
    libreadline-dev zlib1g-dev git

# 2. 克隆源码
cd /usr/local/src
rm -rf SoftEtherVPN
git clone https://github.com/SoftEtherVPN/SoftEtherVPN.git

# 3. 编译安装
cd SoftEtherVPN
git submodule init && git submodule update

# ARM64 等非 x86 架构跳过 cpu_features 检测
CMAKE_FLAGS="-DSKIP_CPU_FEATURES=ON" ./configure
make -C build
make -C build install

# 4. 创建 Systemd 服务
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

# 5. 启用并启动服务
systemctl daemon-reload
systemctl enable softether-vpnserver
systemctl start softether-vpnserver

# 6. 开启内核 IPv4 转发
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p

echo "-------------------------------------------------------"
echo "安装完成！"
echo "架构: $ARCH"
echo "状态: $(systemctl is-active softether-vpnserver)"
echo "管理工具: vpncmd"
echo "-------------------------------------------------------"
