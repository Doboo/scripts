#!/bin/bash

# 检查是否为root用户（放在最前面，避免用户填写配置后才发现无权限）
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root权限运行此脚本" >&2
    exit 1
fi

#====================================================
# 1. 交互式输入配置
#====================================================

# 提示用户输入监听端口
read -r -p "请输入 chfs 监听端口 (默认为 8888): " CHFS_PORT
CHFS_PORT=${CHFS_PORT:-8888}

# 验证端口有效性
if ! [[ "$CHFS_PORT" =~ ^[0-9]+$ ]] || [ "$CHFS_PORT" -lt 1 ] || [ "$CHFS_PORT" -gt 65535 ]; then
    echo "错误：无效的端口号: $CHFS_PORT" >&2
    exit 1
fi

# 提示用户设置管理员用户名
read -r -p "请设置管理员用户名 (默认为 guoke): " CHFS_USER
CHFS_USER=${CHFS_USER:-guoke}

# 提示用户设置管理员密码（输入时隐藏，二次确认）
while true; do
    read -r -s -p "请设置管理员密码: " CHFS_PASS
    echo
    if [[ -z "$CHFS_PASS" ]]; then
        echo "密码不能为空，请重新输入。"
        continue
    fi
    read -r -s -p "请再次输入密码确认: " CHFS_PASS2
    echo
    if [[ "$CHFS_PASS" != "$CHFS_PASS2" ]]; then
        echo "两次输入的密码不一致，请重新输入。"
    else
        break
    fi
done

# 提示用户设置共享目录
CHFS_PATHS=""
echo
echo "--- 设置文件共享目录 (输入一个空行结束输入) ---"
while true; do
    read -r -p "请输入一个共享目录的绝对路径: " DIR_PATH
    if [[ -z "$DIR_PATH" ]]; then
        break
    fi

    # 检查目录是否存在
    if [ ! -d "$DIR_PATH" ]; then
        read -r -p "目录 '$DIR_PATH' 不存在，是否创建? (y/N): " CREATE_DIR
        if [[ "$CREATE_DIR" =~ ^[Yy]$ ]]; then
            mkdir -p "$DIR_PATH" || {
                echo "错误：无法创建目录 '$DIR_PATH'，请检查权限。" >&2
                continue
            }
            echo "目录 '$DIR_PATH' 已创建。"
        else
            echo "跳过此目录。"
            continue
        fi
    fi

    CHFS_PATHS+="path=$DIR_PATH"$'\n'
done

# 如果用户没有输入任何共享目录，则设置一个默认值
if [[ -z "$CHFS_PATHS" ]]; then
    DEFAULT_PATH="/root/fileshare"
    echo "未设置共享目录，将使用默认目录: $DEFAULT_PATH"
    mkdir -p "$DEFAULT_PATH"
    CHFS_PATHS="path=$DEFAULT_PATH"$'\n'
fi
echo "------------------------------------------------"


#====================================================
# 2. 安装流程
#====================================================

# 检查并安装 unzip
if ! command -v unzip &> /dev/null; then
    echo "未找到unzip，正在安装..."
    if command -v apt &> /dev/null; then
        apt update -qq && apt install -y -q unzip
    elif command -v yum &> /dev/null; then
        yum install -y -q unzip
    elif command -v dnf &> /dev/null; then
        dnf install -y -q unzip
    else
        echo "无法自动安装unzip，请手动安装后重试" >&2
        exit 1
    fi
fi

# 检测系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        echo "检测到x86_64架构"
        DOWNLOAD_URL="http://iscute.cn/tar/chfs/3.1/chfs-linux-amd64-3.1.zip"
        ;;
    aarch64)
        echo "检测到arm64架构"
        DOWNLOAD_URL="http://iscute.cn/tar/chfs/3.1/chfs-linux-arm64-3.1.zip"
        ;;
    *)
        echo "不支持的系统架构: $ARCH" >&2
        exit 1
        ;;
esac

# 下载安装包
echo "正在下载chfs安装包..."
wget -q -O /tmp/chfs.zip "$DOWNLOAD_URL" || {
    echo "下载失败，请检查网络连接或URL是否正确" >&2
    exit 1
}

# 解压到/root目录
echo "正在解压安装包..."
unzip -q -o /tmp/chfs.zip -d /root/ || {
    echo "解压失败" >&2
    rm -f /tmp/chfs.zip
    exit 1
}
rm -f /tmp/chfs.zip

# 重命名文件
echo "配置文件..."
mv /root/chfs-* /root/chfs 2>/dev/null || true
chmod +x /root/chfs

# 创建配置文件
echo "生成 /root/chfs.ini 配置文件..."
cat > /root/chfs.ini << EOF
#---------------------------------------
# chfs 配置文件 (根据脚本交互输入生成)
#---------------------------------------
# 监听端口
port=$CHFS_PORT
# 共享根目录，可配置多个path，每行一个
$CHFS_PATHS
# IP地址过滤
allow=
# 用户操作日志存放目录
log=/root
# 网页标题
html.title=chfs File Share
# 是否启用图片预览
image.preview=true
# 下载目录策略
folder.download=enable
# 文件/目录删除模式：2: 移动到chfs专属回收站
file.remove=2

#----------------- 账户及控制规则 -------------------
# 管理员账户
[$CHFS_USER]
password=$CHFS_PASS
rule.default=d
rule.none=
rule.r=
rule.w=
rule.d=
# 访客账户
[guest]
password=
rule.default=r
rule.none=
rule.r=
rule.w=
rule.d=
EOF

# 保护配置文件权限（含密码，不允许其他用户读取）
chmod 600 /root/chfs.ini

# 创建 systemd 服务
echo "创建systemd服务..."
cat > /etc/systemd/system/chfs.service << 'EOF'
[Unit]
Description=Chfs File Server
After=network.target

[Service]
Type=simple
ExecStart=/root/chfs -file /root/chfs.ini
Restart=always
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

# 启动服务并设置开机自启
echo "启动chfs服务..."
systemctl daemon-reload
systemctl start chfs
systemctl enable chfs

# 检查服务状态
if systemctl is-active --quiet chfs; then
    IP_ADDR=$(hostname -I | awk '{print $1}')
    echo "================================================"
    echo " ✅ chfs 安装并启动成功！"
    echo " 您可以通过以下地址访问文件共享服务:"
    echo " http://${IP_ADDR:-<服务器IP>}:$CHFS_PORT"
    echo ""
    echo " 管理员账户: ${CHFS_USER}"
    echo " 配置文件路径: /root/chfs.ini"
    echo "================================================"
    echo " 如需修改配置，请编辑: nano /root/chfs.ini"
    echo " 修改后请重启服务: systemctl restart chfs"
    echo "================================================"
else
    echo " ❌ chfs 启动失败，请检查日志获取更多信息:" >&2
    echo "    journalctl -xeu chfs.service" >&2
    exit 1
fi
