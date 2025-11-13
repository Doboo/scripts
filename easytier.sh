#!/bin/bash
# -------------------------------
# 检查 unzip 是否安装
# -------------------------------
if ! command -v unzip &>/dev/null; then
    echo "未检测到 unzip，正在安装..."
    if [ -f /etc/debian_version ]; then
         apt-get update -y && apt-get install -y unzip
    elif [ -f /etc/redhat-release ]; then
         yum install -y unzip
    elif [ -f /etc/alpine-release ]; then
        apk add unzip
    else
        echo "无法自动安装 unzip，请手动安装后重试。"
        exit 1
    fi
else
    echo "unzip 已安装"
fi

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
# 从远程HTTP地址获取EasyTier版本号
EASYTIER_VERSION=$(curl -fsSL http://etsh2.442230.xyz/etver)
if [ -z "$EASYTIER_VERSION" ]; then
    echo "错误: 无法从 http://etsh2.442230.xyz/etver 获取EasyTier版本号"
    exit 1
fi
echo "检测到 EasyTier 版本: $EASYTIER_VERSION"

# 下载并解压EasyTier文件
download_and_extract() {
    local arch_name=$1
    local download_url=""
    local extracted_dir_name="" # 用于存储解压后的子目录名

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
    # 注意：这里先解压到 /root/easytier/, 它会在此目录下创建二级目录
    unzip -o /tmp/easytier.zip -d /root/easytier/
    if [ $? -ne 0 ]; then
        echo "错误: 解压EasyTier文件失败."
        rm -f /tmp/easytier.zip
        exit 1
    fi

    # 移动二级目录中的文件到 /root/easytier/
    if [ -d "/root/easytier/${extracted_dir_name}" ]; then
        echo "正在将文件从 /root/easytier/${extracted_dir_name} 移动到 /root/easytier/..."
        mv /root/easytier/"${extracted_dir_name}"/* /root/easytier/
        if [ $? -ne 0 ]; then
            echo "警告: 移动文件失败，请手动检查 /root/easytier/ 目录。"
        fi
        # 删除现在为空的二级目录
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
    # 1. 新建文件夹路径为 /root/easytier
    if [ -d "/root/easytier" ]; then
        rm -rf /root/easytier
    fi
    mkdir -p /root/easytier

    # 2. 根据架构下载并解压文件
    download_and_extract "$ARCH"

    # 3. 设置主机名
    #hostnamectl set-hostname "$HOSTNAME"
    #--machine-id $HOSTNAME

    # 4. 创建systemd服务
    service_content="[Unit]
Description=EasyTier Service
After=network.target syslog.target
Wants=network.target
[Service]
Type=simple
ExecStart=/root/easytier/easytier-core -w $USERNAME  --hostname $HOSTNAME 
Restart=always
RestartSec=5
# 关键配置：将输出定向到HDMI对应的物理控制台（tty1为默认第一个物理终端）
StandardOutput=file:/dev/tty1
StandardError=file:/dev/tty1
LimitNOFILE=1048576
Environment=TOKIO_CONSOLE=1
[Install]
WantedBy=multi-user.target"

    echo "$service_content" > /etc/systemd/system/easytier.service
   # 5. 启动服务
    systemctl daemon-reload
    systemctl enable easytier
    systemctl restart easytier
   echo "EasyTier服务已安装并启动！"
   echo "显示运行日志中，请按ctrl+c 取消输出"  
  journalctl -f -u easytier.service
}

# 修改配置流程
modify_config() {
    # 1. 更新主机名
    #hostnamectl set-hostname "$HOSTNAME"
  #--machine-id $HOSTNAME
    # 2. 更新服务文件
    service_content="[Unit]
Description=EasyTier Service
After=network.target syslog.target
Wants=network.target
[Service]
Type=simple
ExecStart=/root/easytier/easytier-core -w $USERNAME --hostname $HOSTNAME 
Restart=always
RestartSec=5
# 关键配置：将输出定向到HDMI对应的物理控制台（tty1为默认第一个物理终端）
StandardOutput=file:/dev/tty1
StandardError=file:/dev/tty1
LimitNOFILE=1048576
Environment=TOKIO_CONSOLE=1
[Install]
WantedBy=multi-user.target"

    echo "$service_content" > /etc/systemd/system/easytier.service

    # 3. 重启服务
    systemctl daemon-reload
    systemctl restart easytier
    echo "EasyTier服务配置已更新并重启。查看日志:"
    journalctl -f -u easytier.service
}

# 卸载流程
uninstall_service() {
    # 1. 停止并禁用服务
    systemctl stop easytier 2>/dev/null
    systemctl disable easytier 2>/dev/null
    systemctl daemon-reload
    systemctl reset-failed

    # 2. 删除服务文件
    rm -f /etc/systemd/system/easytier.service

    # 3. 删除安装文件
    rm -rf /root/easytier
    rm -f /root/easytier.sh # Assuming the script itself is named easytier.sh
    echo "EasyTier服务已卸载，相关文件已删除"
}

# 更新流程
update_service() {
    # 1. 停止服务
    systemctl stop easytier 2>/dev/null

    # 2. 删除原来的程序文件
    rm -rf /root/easytier

    # 3. 新建文件夹路径为 /root/easytier
    mkdir -p /root/easytier

    # 4. 根据架构下载并解压新的程序文件
    download_and_extract "$ARCH"

    # 5. 重新启动服务
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
