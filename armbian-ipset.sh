#!/bin/bash

# 检查是否为root用户
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root权限运行此脚本"
    exit 1
fi

# 获取当前的netplan配置文件
config_file=$(find /etc/netplan -name "*.yaml" | head -1)

# 如果没有找到配置文件，则创建一个新的
if [ -z "$config_file" ]; then
    config_file="/etc/netplan/01-netcfg.yaml"
    echo "network:" > "$config_file"
    echo "  version: 2" >> "$config_file"
    echo "  renderer: networkd" >> "$config_file"
fi

# 获取当前eth0的DHCP配置
current_ip=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
current_gateway=$(ip route | grep default | grep -oP 'via\s\K\d+(\.\d+){3}')

# 选择网络配置类型
echo "请选择网络配置类型:"
echo "1. 使用DHCP自动获取IP地址"
echo "2. 设置固定IP地址"
read -p "请输入选项 (1-2): " config_type

case $config_type in
    1)
        # 创建备份
        cp "$config_file" "${config_file}.bak"
        
        # 配置DHCP
        cat > "$config_file" << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
EOF
        
        echo "已配置eth0使用DHCP获取IP地址"
        ;;
    2)
        # 提示用户输入IP地址
        read -p "请输入IP地址（默认使用当前DHCP获取的地址: $current_ip）: " ip_address
        ip_address=${ip_address:-$current_ip}

        # 提示用户输入子网掩码
        read -p "请输入子网掩码（默认: 255.255.255.0）: " netmask
        netmask=${netmask:-255.255.255.0}

        # 计算CIDR表示法
        calculate_cidr() {
            local mask=$1
            local a=$(echo $mask | cut -d. -f1)
            local b=$(echo $mask | cut -d. -f2)
            local c=$(echo $mask | cut -d. -f3)
            local d=$(echo $mask | cut -d. -f4)
            local bits=$(printf "%08d" $(bc <<< "obase=2;$a"))$(printf "%08d" $(bc <<< "obase=2;$b"))$(printf "%08d" $(bc <<< "obase=2;$c"))$(printf "%08d" $(bc <<< "obase=2;$d"))
            echo $(echo $bits | grep -o 1 | wc -l)
        }

        cidr=$(calculate_cidr "$netmask")

        # 提示用户输入网关地址
        read -p "请输入网关地址（默认使用当前DHCP获取的网关: $current_gateway）: " gateway
        gateway=${gateway:-$current_gateway}

        # 提示用户输入DNS服务器
        read -p "请输入DNS服务器（多个服务器请用空格分隔，默认: 223.6.6.6 114.114.114.114）: " dns
        dns=${dns:-"223.6.6.6 114.114.114.114"}

        # 创建备份
        cp "$config_file" "${config_file}.bak"

        # 更新配置文件
        cat > "$config_file" << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: false
      addresses: [$ip_address/$cidr]
      gateway4: $gateway
      nameservers:
        addresses: [$(echo $dns | tr ' ' ',')]
EOF
        
        echo "已配置eth0使用固定IP地址"
        ;;
    *)
        echo "无效的选项，脚本退出"
        exit 1
        ;;
esac

echo "配置文件已更新：$config_file"
echo "新配置内容："
cat "$config_file"

# 应用配置
read -p "是否应用新的网络配置？(y/n): " apply
if [ "$apply" = "y" ] || [ "$apply" = "Y" ]; then
    echo "正在应用新的网络配置..."
    netplan try
    if [ $? -ne 0 ]; then
        echo "配置应用失败，恢复到之前的配置"
        cp "${config_file}.bak" "$config_file"
        netplan apply
    else
        echo "配置已成功应用"
    fi
else
    echo "配置未应用，原始配置已保留"
fi    
