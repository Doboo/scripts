#!/bin/bash

# ==============================================================================
# 脚本说明:
#   本脚本用于在 Debian 12 系统上配置一个 VPN 网关。
#   它会将来自物理网卡(LAN)的流量通过虚拟网卡(VPN)转发出去，
#   并使用 iptables 的 MASQUERADE (NAT) 功能，让局域网内的其他设备
#   可以共享这台机器的 VPN 连接。
#
# 功能:
#   1. 自动检查并请求 Root 权限。
#   2. 显示当前网络接口信息，帮助用户选择。
#   3. 交互式设置物理网卡和虚拟网卡的名称。
#   4. 自动检查并永久开启 IPv4 转发。
#   5. 应用经过优化的、更安全的 iptables 规则。
#   6. 自动安装 iptables-persistent 并永久保存规则。
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
# -p: 显示提示信息
# -e: 允许使用 readline 进行行编辑
# -i: 设置默认值
read -p "请输入您的「物理网卡」名称 (默认: eth0): " -e -i "eth0" WAN_IF
read -p "请输入您的「虚拟网卡」名称 (默认: tun0): " -e -i "tun0" tun_IF

echo ""
echo -e "${GREEN}配置确认：${NC}"
echo -e "物理网卡 (WAN/LAN Interface) 将被设置为: ${YELLOW}$WAN_IF${NC}"
echo -e "虚拟网卡 (VPN Interface) 将被设置为: ${YELLOW}$tun_IF${NC}"
read -p "确认无误吗？(y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}操作已取消。${NC}"
    exit 1
fi

# --- 4. 检查并永久开启 IPv4 转发 ---
echo -e "\n${YELLOW}[*] 正在检查并配置 IPv4 转发...${NC}"
# /proc/sys/net/ipv4/ip_forward 的值为 1 表示已开启
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" -eq 1 ]; then
    echo -e "${GREEN}IPv4 转发已经开启。${NC}"
else
    echo -e "${YELLOW}IPv4 转发未开启，正在为您永久开启...${NC}"
    # 在 sysctl.conf 中取消注释或添加该行
    if grep -q "#net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    elif ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    # 立即应用配置
    sysctl -p
    echo -e "${GREEN}IPv4 转发已成功开启并设为永久。${NC}"
fi

# --- 5. 应用 Iptables 规则 ---
echo -e "\n${YELLOW}[*] 正在应用 iptables 规则...${NC}"

# 清理旧的转发和NAT规则，避免冲突
echo "  - 清理旧的 FORWARD 和 POSTROUTING 规则..."
iptables -F FORWARD
iptables -t nat -F POSTROUTING

# 规则解释：
# 1. -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
#    允许所有已建立的或与现有连接相关的流量通过。这是保持连接（如网页浏览、下载）正常工作的关键。
#
# 2. -A FORWARD -i ${WAN_IF} -o ${tun_IF} -j ACCEPT
#    明确允许从物理网卡(LAN)进入的、目的地是虚拟网卡(VPN)的新连接。
#
# 3. -t nat -A POSTROUTING -o ${tun_IF} -j MASQUERADE
#    这是核心的NAT规则。当数据包从虚拟网卡(VPN)出去时，
#    将其源IP地址伪装成这台机器在VPN网络中的IP地址。
#    这样，返回的流量才能正确地路由回局域网内的原始设备。

echo "  - 应用新的转发规则..."
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i "${WAN_IF}" -o "${tun_IF}" -j ACCEPT

echo "  - 应用 NAT (MASQUERADE) 规则..."
iptables -t nat -A POSTROUTING -o "${tun_IF}" -j MASQUERADE

echo -e "${GREEN}Iptables 规则应用成功！${NC}"

# --- 6. 保存 Iptables 规则以实现持久化 ---
echo -e "\n${YELLOW}[*] 正在保存规则以确保重启后生效...${NC}"

# 检查 iptables-persistent 是否已安装
if ! dpkg -s iptables-persistent &> /dev/null; then
    echo "  - 'iptables-persistent' 未安装，正在为您自动安装..."
    apt-get update
    apt-get install -y iptables-persistent
fi

# 保存规则
echo "  - 正在保存当前的 IPv4 和 IPv6 规则..."
netfilter-persistent save

echo -e "\n${GREEN}=====================================================${NC}"
echo -e "${GREEN}恭喜！所有配置已完成并永久保存。${NC}"
echo -e "${GREEN}您的局域网设备现在应该可以通过这台机器共享 VPN 连接了。${NC}"
echo -e "${GREEN}=====================================================${NC}"

exit 0
