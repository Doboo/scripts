#!/bin/bash

# 检查是否以root用户运行
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root用户运行此脚本" >&2
    exit 1
fi

# 检查并安装unzip
if ! command -v unzip &> /dev/null; then
    echo "未找到unzip，正在安装..."
    if command -v apt &> /dev/null; then
        apt update && apt install -y unzip
    elif command -v yum &> /dev/null; then
        yum install -y unzip
    elif command -v dnf &> /dev/null; then
        dnf install -y unzip
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
    exit 1
}

# 重命名文件
echo "配置文件..."
mv /root/chfs-* /root/chfs
chmod +x /root/chfs

# 创建配置文件
cat > /root/chfs.ini << 'EOF'
#---------------------------------------
# 请注意：
#     1，如果不存在键或对应值为空，则不影响对应的配置
#     2，配置项的值，语法如同其对应的命令行参数
#---------------------------------------
# 监听端口
port=8888
# 共享根目录，通过字符'|'进行分割
# 注意：
#     1，带空格的目录须用引号包住，如 path="c:\a uply name\folder"
#     2，可配置多个path，分别对应不同的目录
path=/root/
# IP地址过滤
allow=
# 用户操作日志存放目录，默认为空
# 如果赋值为空，表示禁用日志
log=/root
# 网页标题
html.title=guoke
#阿里云测试中文会乱码
# 网页顶部的公告板。可以是文字，也可以是HTML标签，此时，需要适用一对``(反单引号，通过键盘左上角的ESC键下面的那个键输出)来包住所有HTML标签。几个例子：
#     1,html.notice=内部资料，请勿传播
#     2,html.notice=`<img src="https://mat1.gtimg.com/pingjs/ext2020/qqindex2018/dist/img/qq_logo_2x.png" width="100%"/>`
#     3,html.notice=`<div style="background:black;color:white"><p>目录说明：</p><ul>一期工程：一期工程资料目录</ul><ul>二期工程：二期工程资料目录</ul></div>`
html.notice=guoke
#阿里云测试中文会乱码
# 是否启用图片预览(网页中显示图片文件的缩略图)，true表示开启，false为关闭。默认关闭
image.preview=true
# 下载目录策略。disable:禁用; leaf:仅限叶子目录的下载; enable或其他值:不进行限制。
# 默认值为 enable
folder.download=enable

#-------------- 设置生效后启用HTTPS，注意监听端口设置为443-------------
# 指定certificate文件
ssl.cert=
# 指定private key文件
ssl.key=
# 设置会话的生命周期，单位：分钟，默认为30分钟
session.timeout=30
# 文件/目录删除模式：
#     1: 安全删除：移动到系统回收站 [不是所有操作系统都支持，建议使用前进行测试。默认模式]
#阿里云测试不可以。
#     2: 安全删除：移动到chfs的专属回收站: ~/.chfs_trashbin， 程序会删除存储超过1个月的文件
#     3: 真正删除
file.remove=2
#----------------- ------------------------
# 注意： 账户配置区域放置到配置文件的后面
#------------------------------------------
#----------------- 账户及控制规则 -------------------
#     [xxx] xxx即为账户名, 访客的用户名为guest
#     password 账户密码
#     rule.default 账户对所有的目录和文件的访问权限，但可以针对任意子目录进行重新设定访问权限，以覆盖默认的权限
#     rule.none 表示对哪些子目录设置为不可访问的权限，多个目录使用字符'|'分割，也可以分为多行。注意：该子目录本身也不可访问！
#     rule.r 表示对哪些子目录设置为读权限，多个目录使用字符'|'分割，也可以分为多行。注意： 该子目录本身不受影响，影响的只是它所包含的目录和文件！
#     rule.w 表示对哪些子目录设置为写权限，多个目录使用字符'|'分割，也可以分为多行。注意： 该子目录本身不受影响，影响的只是它所包含的目录和文件！
#     rule.d 表示对哪些子目录设置为最高访问权限，多个目录使用字符'|'分割，也可以分为多行。注意： 该子目录本身不受影响，影响的只是它所包含的目录和文件！
#
#   示例：
#        [foo]
#        password=bar
#        rule.default=r
#        rule.none=d:\公司制度|d:\财务票据
#        rule.r=d:\施工项目\2021年
#        rule.r=d:\施工项目\2022年
#        rule.d=d:\个人目录\foo
#
#    该账户名为foo，密码为bar，默认访问权限是读权限，但账户没有“d:\公司制度”和“d:\财务票据”的访问权限，且
#    对“d:\施工项目\2021年”和“d:\施工项目\2021年”只有读权限，对“d:\个人目录\foo”有最高访问权限。
#
#账户xxx,访客的用户名为guest
[guoke]
password=38196962@qq.com
rule.default=d
rule.none=
rule.r=
rule.w=
rule.d=
[guest]
password=
rule.default=r
rule.none=/root/fileshare/CloudDrive/
rule.r=
rule.w=
rule.d=
EOF

# 创建systemd服务
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
    echo "chfs安装并启动成功！"
    echo "您可以通过 http://服务器IP:8888 访问"
else
    echo "chfs启动失败，请检查日志获取更多信息" >&2
    exit 1
fi
    
