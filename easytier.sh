#!/bin/bash

# 定义帮助信息
usage() {
    echo "用法: $0 [install|modify|uninstall|update] [username] [hostname]"
    echo "  install   - 全新安装EasyTier服务"
    echo "  modify    - 修改现有配置并重启服务"
    echo "  uninstall - 卸载EasyTier服务并删除文件"
    echo "  update    - 更新EasyTier服务程序文件"
    echo "示例:"
    echo "  $0 install username hostname"
    echo "  $0 modify username hostname"
    echo "  $0 uninstall"
    echo "  $0 update"
    exit 1
}

# 获取最新版本号
get_latest_version() {
    local latest_version
    latest_version=$(curl -s https://api.github.com/repos/EasyTier/EasyTier/releases/latest | grep -oP '"tag_name":\s*"\K(.*)(?=")')
    if [ -n "$latest_version" ]; then
        echo "$latest_version"
    else
        echo "$LOCAL_EASYTIER_VERSION" # 获取失败则返回本地版本
    fi
}

# 获取CPU架构
get_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64) echo "x86_64" ;;
        aarch64) echo "aarch64" ;;
        armv7l) echo "armv7" ;;
        *) echo "unknown" ;;
    esac
}

# 检查参数数量
if [ $# -lt 1 ]; then
    usage
fi

ACTION=$1
USERNAME=$2
HOSTNAME=$3
ARCH=$(get_arch)
LOCAL_EASYTIER_VERSION="v2.4.2" # 本地默认版本
EASYTIER_VERSION=$(get_latest_version)

if [ "$EASYTIER_VERSION" != "$LOCAL_EASYTIER_VERSION" ]; then
    echo "检测到新版本: $EASYTIER_VERSION (本地默认: $LOCAL_EASYTIER_VERSION)"
else
    echo "当前已是最新版本: $EASYTIER_VERSION"
fi

# 下载并解压EasyTier文件
download_and_extract() {
    local arch_name=$1
    local download_url=""
    local extracted_dir_name=""

    case $arch_name in
        x86_64)
            download_url="https://ghfast.top/https://github.com/EasyTier/EasyTier/releases/download/${EASYTIER_VERSION}/easytier-linux-x86_64-${EASYTIER_VERSION}.zip"
            extracted_dir_name="easytier-linux-x86_64"
            ;;
        aarch64)
            download_url="https://ghfast.top/https://github.com/EasyTier/EasyTier/releases/download/${EASYTIER_VERSION}/easytier-linux-aarch64-${EASYTIER_VERSION}.zip"
            extracted_dir_name="easytier-linux-aarch64"
            ;;
        armv7)
            download_url="https://ghfast.top/https://github.com/EasyTier/EasyTier/releases/download/${EASYTIER_VERSION}/easytier-linux-armv7-${EASYTIER_VERSION}.zip"
            extracted_dir_name="easytier-linux-armv7"
            ;;
        *)
            echo "错误: 不支持的CPU架构 $(uname -m)"
            exit 1
            ;;
    esac

    echo "正在下载 EasyTier (${arch_name}) 到 /tmp/easytier.zip..."
    wget -O /tmp/easytier.zip "$download_url"
    if [ $? -ne 0 ]; then
        echo "错误: 下载EasyTier失败."
        exit 1
    fi

    echo "正在解压文件到 /root/easytier/..."
    unzip -o /tmp/easytier.zip -d /root/easytier/
    if [ $? -ne 0 ]; then
        echo "错误: 解压EasyTier文件失败."
        rm -f /tmp/easytier.zip
        exit 1
    fi

    if [ -d "/root/easytier/${extracted_dir_name}" ]; then
        echo "正在将文件从 /root/easytier/${extracted_dir_name} 移动到 /root/easytier/..."
        mv /root/easytier/"${extracted_dir_name}"/* /root/easytier/
        if [ $? -ne 0 ]; then
            echo "警告: 移动文件失败，请手动检查 /root/easytier/ 目录。"
        fi
        rmdir /root/easytier/"${extracted_dir_name}" 2>/dev/null
    else
        echo "警告: 未找到预期的二级目录 /root/easytier/${extracted_dir_name}。请手动检查解压结果。"
    fi

    rm -f /tmp/easytier.zip
    chmod +x /root/easytier/easytier-core
    chmod +x /root/easytier/easytier-cli
    echo "EasyTier文件下载并解压完成."
}

# 安装流程
install_service() {
    if [ -d "/root/easytier" ]; then
        rm -rf /root/easytier
    fi
    mkdir -p /root/easytier
    download_and_extract "$ARCH"

    service_content="[Unit]
Description=EasyTier Service
After=network.target syslog.target
Wants=network.target
[Service]
Type=simple
ExecStart=/root/easytier/easytier-core -w $USERNAME  --hostname $HOSTNAME 
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target"

    echo "$service_content" > /etc/systemd/system/easytier.service
    systemctl daemon-reload
    systemctl enable easytier
    systemctl restart easytier
    echo "EasyTier服务已安装并启动。查看日志:"
    journalctl -f -u easytier.service
}

# 修改配置流程
modify_config() {
    service_content="[Unit]
Description=EasyTier Service
After=network.target syslog.target
Wants=network.target
[Service]
Type=simple
ExecStart=/root/easytier/easytier-core -w $USERNAME --hostname $HOSTNAME 
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target"

    echo "$service_content" > /etc/systemd/system/easytier.service
    systemctl daemon-reload
    systemctl restart easytier
    echo "EasyTier服务配置已更新并重启。查看日志:"
    journalctl -f -u easytier.service
}

# 卸载流程
uninstall_service() {
    systemctl stop easytier 2>/dev/null
    systemctl disable easytier 2>/dev/null
    systemctl daemon-reload
    systemctl reset-failed
    rm -f /etc/systemd/system/easytier.service
    rm -rf /root/easytier
    rm -f /root/easytier.sh
    echo "EasyTier服务已卸载，相关文件已删除"
}

# 更新流程
update_service() {
    systemctl stop easytier 2>/dev/null
    rm -rf /root/easytier
    mkdir -p /root/easytier
    download_and_extract "$ARCH"
    systemctl daemon-reload
    systemctl enable easytier
    systemctl restart easytier
    echo "EasyTier服务已更新并重启。查看日志:"
    journalctl -f -u easytier.service
}

# 根据参数执行不同操作
case $ACTION in
    install)
        if [ $# -ne 3 ]; then
            echo "错误: install操作需要用户名和主机名参数"
            usage
        fi
        install_service
        ;;
    modify)
        if [ $# -ne 3 ]; then
            echo "错误: modify操作需要用户名和主机名参数"
            usage
        fi
        modify_config
        ;;
    uninstall)
        uninstall_service
        ;;
    update)
        update_service
        ;;
    *)
        echo "错误: 未知操作 '$ACTION'"
        usage
        ;;
esac
