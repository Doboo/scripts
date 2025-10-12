#!/bin/bash

# ==============================================================================
# 脚本说明:
#   本脚本用于在 Debian 12 系统上配置 VPN 网络与局域网的双向转发。
#   它会同时允许:
#   1. 来自局域网的流量通过VPN转发出去
#   2. 来自VPN的流量转发到局域网
#   实现VPN网络和局域网之间的双向通信。
# ==============================================================================

# --- 颜色定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- 1. 检查是否以 Root 身份运行 ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：本脚本需要以 root 权限运行。${NC}"
  echo -e "${YELLOW}请尝试使用 'sudo ./your_script_name.sh' 来执行。${NC}"
  exit 1
fi

# --- 2. 显示网络接口信息 ---
echo -e "${GREEN}=====================================================${NC}"
echo -e "${YELLOW}当前系统的网络接口信息如下：${NC}"
ip addr show
echo -e "${GREEN}=====================================================${NC}"
echo ""

# --- 3. 提示用户确认或修改网卡名称 ---
read -p "请输入您的「局域网物理网卡」名称 (默认: eth0): " -e -i "eth0" LAN_IF
read -p "请输入您的「VPN虚拟网卡」名称 (默认: tun0): " -e -i "tun0" VPN_IF

echo ""
echo -e "${GREEN}配置确认：${NC}"
echo -e "局域网物理网卡 (LAN Interface) 将被设置为: ${YELLOW}$LAN_IF${NC}"
echo -e "VPN虚拟网卡 (VPN Interface) 将被设置为: ${YELLOW}$VPN_IF${NC}"
read -p "确认无误吗？(y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}操作已取消。${NC}"
    exit 1
fi

# --- 4. 检查并永久开启 IPv4 转发 ---
echo -e "\n${YELLOW}[*] 正在检查并配置 IPv4 转发...${NC}"
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" -eq 1 ]; then
    echo -e "${GREEN}IPv4 转发已经开启。${NC}"
else
    echo -e "${YELLOW}IPv4 转发未开启，正在为您永久开启...${NC}"
    if grep -q "#net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    elif ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    sysctl -p
    echo -e "${GREEN}IPv4 转发已成功开启并设为永久。${NC}"
fi

# --- 5. 应用 Iptables 规则（双向转发核心配置） ---
echo -e "\n${YELLOW}[*] 正在应用 iptables 规则...${NC}"

# 清理旧规则，避免冲突
echo "  - 清理旧的 FORWARD 和 POSTROUTING 规则..."
iptables -F FORWARD
iptables -t nat -F POSTROUTING

# 规则解释：
# 1. 允许所有已建立的或相关的连接，确保双向通信的连接状态被正确维护
# 2. 允许从局域网到VPN的新连接
# 3. 允许从VPN到局域网的新连接
# 4. 对从VPN出口的流量进行NAT伪装，确保局域网设备能通过VPN正常访问外部网络

echo "  - 应用双向转发规则..."
# 允许已建立的和相关的连接
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# 允许局域网到VPN的流量
iptables -A FORWARD -i "${LAN_IF}" -o "${VPN_IF}" -j ACCEPT

# 允许VPN到局域网的流量
iptables -A FORWARD -i "${VPN_IF}" -o "${LAN_IF}" -j ACCEPT

echo "  - 应用 NAT 规则，确保局域网设备通过VPN访问外部网络..."
iptables -t nat -A POSTROUTING -o "${VPN_IF}" -j MASQUERADE

echo -e "${GREEN}Iptables 双向转发规则应用成功！${NC}"

# --- 6. 保存 Iptables 规则以实现持久化 ---
echo -e "\n${YELLOW}[*] 正在保存规则以确保重启后生效...${NC}"

if ! dpkg -s iptables-persistent &> /dev/null; then
    echo "  - 'iptables-persistent' 未安装，正在为您自动安装..."
    apt-get update
    apt-get install -y iptables-persistent
fi

echo "  - 正在保存当前的 IPv4 和 IPv6 规则..."
netfilter-persistent save

echo -e "\n${GREEN}=====================================================${NC}"
echo -e "${GREEN}恭喜！所有配置已完成并永久保存。${NC}"
echo -e "${GREEN}现在已实现 VPN 网络和局域网的双向转发：${NC}"
echo -e "${GREEN}1. 局域网设备可以访问 VPN 网络${NC}"
echo -e "${GREEN}2. VPN 网络中的设备可以访问局域网${NC}"
echo -e "${GREEN}=====================================================${NC}"

exit 0
