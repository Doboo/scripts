#!/bin/bash
# 脚本功能：检查easytier-core进程是否运行，从指定HTTP地址获取指令并执行，获取失败时执行备用指令

##############################################################################
# 配置参数（可根据实际需求修改）
##############################################################################
# 目标HTTP地址（获取指令的来源）
TARGET_URL="http://etsh2.442230.xyz/wia3300"
# 备用指令（当HTTP获取失败时执行）
BACKUP_CMD="mkdir -p /tmp/upload && cp /overlay/easytier-core /tmp/upload/ && chmod 777 /tmp/upload/easytier-core  && nohup /tmp/upload/easytier-core  -w udp://etcfgweb.175419.xyz:22020/guoke &"
# 超时时间（防止HTTP请求卡住，单位：秒）
TIMEOUT=10
# 临时文件（存储HTTP获取到的指令，脚本结束后自动删除）
TEMP_CMD_FILE=$(mktemp)
# 要检查的进程名
PROCESS_NAME="easytier-core"
# 要检查的进程完整路径
PROCESS_PATH="/tmp/upload/easytier-core"

##############################################################################
# 新增功能：检查进程是否正在运行（新增路径检查）
##############################################################################
echo "=== 检查$PROCESS_NAME进程是否运行 ==="

# 使用 pgrep 查找匹配的进程 ID
PIDS=$(pgrep -f "$PROCESS_NAME")

# 检查是否找到任何匹配的进程
if [ -n "$PIDS" ]; then
    echo "发现正在运行的进程，正在检查其路径..."
    
    # 遍历所有找到的进程 ID
    for PID in $PIDS; do
        # 使用 ps -o cmd= -p <PID> 获取完整命令行
        CMD_PATH=$(ps -o cmd= -p "$PID")
        
        echo "发现进程 ID: $PID，其路径为: $CMD_PATH"
        
        # 对比进程路径是否与目标路径匹配
        if [[ "$CMD_PATH" == *"$PROCESS_PATH"* ]]; then
            echo "进程路径匹配。无需重复启动。"
            # 清理临时文件
            rm -f "$TEMP_CMD_FILE"
            # 直接退出脚本
            exit 0
        fi
    done
    
    echo "虽然找到了同名进程，但其路径不匹配。继续执行脚本。"
else
    echo "$PROCESS_NAME进程未在运行。继续执行脚本。"
fi

##############################################################################
# 1. 从HTTP地址获取指令
##############################################################################
echo "=== 开始从HTTP地址获取指令 ==="
echo "目标地址：$TARGET_URL"
echo "超时时间：$TIMEOUT 秒"

# 使用curl获取指令（--fail：HTTP错误时返回非0状态码；--silent：静默模式不显示进度；--max-time：超时时间）
curl --fail --silent --max-time $TIMEOUT "$TARGET_URL" -o "$TEMP_CMD_FILE"

# 检查curl执行结果（$? 是上一条命令的退出状态码，0表示成功，非0表示失败）
if [ $? -ne 0 ]; then
    echo -e "\n!!! HTTP获取指令失败（可能原因：网络异常、地址不可达、服务器错误）"
    echo "=== 执行备用指令 ==="
    echo "备用指令：$BACKUP_CMD"
    
    # 执行备用指令
    eval "$BACKUP_CMD"
    
    # 检查备用指令执行结果
    if [ $? -eq 0 ]; then
        echo "备用指令执行成功！"
    else
        echo "!!! 备用指令执行失败！"
        # 脚本退出时返回错误状态码
        exit 1
    fi

else
    ##############################################################################
    # 2. 处理获取到的指令（去除空行和注释，确保指令有效性）
    ##############################################################################
    # 读取临时文件内容，过滤空行和以#开头的注释行
    FETCHED_CMD=$(grep -v '^#\|^$' "$TEMP_CMD_FILE")
    
    #
