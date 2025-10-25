#!/bin/bash

# =================================================================
# SoftEther VPN Server 自动安装脚本 (v5 - 最终修正版)
#
# 修正点：在 .install.sh 运行后，手动将文件移动到 /usr/local/vpnserver。
# =================================================================

# --- 脚本设置 ---
# 在出错时立即退出
set -e

# --- 变量定义 ---
GITHUB_REPO="SoftEtherVPN/SoftEtherVPN_Stable"
API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
ACCELERATOR_URL="https://ghfast.top/"
INSTALL_DIR="/usr/local/vpnserver"
TEMP_DIR=$(mktemp -d)

# --- 帮助函数 ---
log() {
    echo "--- [INFO] $1"
}

err() {
    echo "*** [ERROR] $1" >&2
    rm -rf "$TEMP_DIR"
    exit 1
}

# --- 脚本开始 ---

# 1. 检查是否为 root
if [ "$(id -u)" -ne 0 ]; then
   err "此脚本必须以 root 权限运行。"
fi

# 2. 安装依赖 (省略已安装的输出，以保持日志整洁)
log "正在安装依赖包 (build-essential/make, curl, wget, jq)..."
# 重新运行依赖安装，但静默输出，仅处理错误
if [ -f /usr/bin/apt ]; then
    apt update -y > /dev/null
    apt install -y build-essential curl wget jq > /dev/null
elif [ -f /usr/bin/yum ]; then
    yum install -y epel-release > /dev/null
    yum install -y make gcc curl wget jq > /dev/null
elif [ -f /usr/bin/dnf ]; then
    dnf install -y make gcc curl wget jq > /dev/null
else
    err "不支持的包管理器。"
fi
log "依赖包检查完成。"

# 3. 架构检测 (省略不变的代码块)
ARCH=$(uname -m)
SOFTETHER_ARCH=""
case "$ARCH" in
    x86_64) SOFTETHER_ARCH="linux-x64" ;;
    i686|i386) SOFTETHER_ARCH="linux-x86" ;;
    aarch64) SOFTETHER_ARCH="linux-arm64" ;;
    armv7l|arm) SOFTETHER_ARCH="linux-arm" ;;
    *) err "不支持的系统架构: $ARCH" ;;
esac
log "检测到系统架构: $ARCH (SoftEther 架构: $SOFTETHER_ARCH)"

# 4. 获取最新版本下载链接 (保留修正后的 jq 命令)
log "正在从 GitHub API 获取最新版本信息..."
DOWNLOAD_URL=$(curl -s "$API_URL" | jq -r --arg ARCH "$SOFTETHER_ARCH" \
    '.assets[] | select(.name | (contains($ARCH) and contains("vpnserver"))) | .browser_download_url')

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
    err "无法为架构 $SOFTETHER_ARCH 找到匹配的 'vpnserver' 下载链接。"
fi

# 5. 构建加速链接并下载 (省略不变的代码块)
FILENAME=$(basename "$DOWNLOAD_URL")
ACCELERATED_URL="${ACCELERATOR_URL}${DOWNLOAD_URL}"
log "最新版本文件: $FILENAME"
log "使用加速链接下载: $ACCELERATED_URL"
cd "$TEMP_DIR"
wget -q --show-progress -O "$FILENAME" "$ACCELERATED_URL"
if [ $? -ne 0 ]; then
    err "下载失败。请检查网络或加速器 $ACCELERATOR_URL 是否可用。"
fi

# 6. 解压 (省略不变的代码块)
log "正在解压 $FILENAME..."
tar -xzf "$FILENAME"
cd vpnserver

# 7. 运行安装脚本 (.install.sh)
log "正在运行安装脚本 (.install.sh) 并自动同意许可协议..."
if [ ! -f ./.install.sh ]; then
    err "未找到 .install.sh，请确认下载的文件内容。"
fi

# 自动同意许可协议 (连续回答 3 次 '1')
printf '1\n1\n1\n' | ./.install.sh
if [ $? -ne 0 ]; then
    err "安装准备失败。 (.install.sh 脚本执行出错)"
fi

# --- [!!] 修正点 [!!] ---
# 8. 移动和安装文件
log "安装准备完成。正在将文件移动到最终安装目录 $INSTALL_DIR..."
cd .. # 回到临时目录的根 (包含 vpnserver 文件夹)
rm -rf "$INSTALL_DIR" # 清理旧的安装目录 (如果有)
mv vpnserver "$INSTALL_DIR"
# --- [!!] 修正结束 [!!] ---

# 确认安装
if [ ! -f "$INSTALL_DIR/vpnserver" ]; then
    err "文件移动失败。最终安装目录中缺少 vpnserver 可执行文件。"
fi
log "文件已成功安装到 $INSTALL_DIR"

# 设置权限 
chmod 600 "$INSTALL_DIR"/*
chmod 700 "$INSTALL_DIR"/vpnserver
chmod 700 "$INSTALL_DIR"/vpncmd

# 9. 创建服务 (保留不变)
if [ -f /usr/bin/systemctl ]; then
    # --- Systemd ---
    log "正在创建 systemd 服务 (vpnserver.service)..."
    cat > /etc/systemd/system/vpnserver.service << EOF
[Unit]
Description=SoftEther VPN Server
After=network.target

[Service]
Type=forking
ExecStart=$INSTALL_DIR/vpnserver start
ExecStop=$INSTALL_DIR/vpnserver stop
User=root
Group=root
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    log "重新加载 systemd 并启动 vpnserver 服务..."
    systemctl daemon-reload
    systemctl start vpnserver
    systemctl enable vpnserver

    log "等待服务启动..."
    sleep 3
    systemctl status vpnserver --no-pager

else
    # --- Init.d ---
    log "未检测到 systemd, 正在创建 init.d 脚本 (/etc/init.d/vpnserver)..."
    cat > /etc/init.d/vpnserver << EOF
#!/bin/sh
# chkconfig: 2345 99 01
# description: SoftEther VPN Server
DAEMON=$INSTALL_DIR/vpnserver
LOCK=/var/lock/subsys/vpnserver

case "\$1" in
start)
    \$DAEMON start
    touch \$LOCK
    ;;
stop)
    \$DAEMON stop
    rm \$LOCK
    ;;
restart)
    \$DAEMON stop
    sleep 3
    \$DAEMON start
    ;;
*)
    echo "Usage: \$0 {start|stop|restart}"
    exit 1
esac
exit 0
EOF

    chmod 755 /etc/init.d/vpnserver
    
    if [ -f /sbin/chkconfig ]; then
        chkconfig --add vpnserver
        chkconfig vpnserver on
    elif [ -f /usr/sbin/update-rc.d ]; then
        update-rc.d vpnserver defaults
    fi
    
    /etc/init.d/vpnserver start
    log "vpnserver 服务已通过 init.d 启动。"
fi

# 10. 清理
log "清理临时文件..."
rm -rf "$TEMP_DIR"
cd ~

# 11. 完成提示
log "SoftEther VPN Server 安装完成! 🎉"
echo "===================================================="
echo " 重要：您必须立即设置一个管理员密码!"
echo ""
echo " 1. 运行: $INSTALL_DIR/vpncmd"
echo " 2. 选择 '1' (Management of VPN Server)"
echo " 3. 按 Enter (localhost:default)"
echo " 4. 再次按 Enter (Server Admin Mode)"
echo " 5. 运行: ServerPasswordSet"
echo " 6. 设置您的密码"
echo "===================================================="
