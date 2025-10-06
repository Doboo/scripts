#!/bin/bash
# 脚本功能：检查easytier-core进程是否运行，从指定HTTP地址获取指令并执行，获取失败时执行备用指令

##############################################################################
# 配置参数
##############################################################################
TARGET_URL="http://etsh2.442230.xyz/wia3300-8"
BACKUP_CMD="/overlay/easytier-core -w guoke --hostname wia3300-8 &"
TIMEOUT=10
TEMP_CMD_FILE=$(mktemp)
PROCESS_NAME="easytier-core"
PROCESS_PATH="/overlay/easytier-core"

##############################################################################
# 检查进程是否运行（兼容 BusyBox 的 ps）
##############################################################################
echo "=== 检查$PROCESS_NAME进程是否运行 ==="

# 使用 pgrep 查找匹配的进程 ID
PIDS=$(pgrep -f "$PROCESS_NAME")

if [ -n "$PIDS" ]; then
    echo "发现正在运行的进程，正在检查其路径..."
    
    # 遍历所有找到的进程 ID
    for PID in $PIDS; do
        # 兼容 BusyBox，直接读取 /proc/[PID]/cmdline 获取完整命令行
        # 使用 tr '\0' ' ' 替换空字符为空格，使输出可读
        CMD_LINE=$(cat /proc/$PID/cmdline 2>/dev/null | tr '\0' ' ')
        
        # 检查是否成功读取命令行
        if [ -n "$CMD_LINE" ]; then
            echo "发现进程 ID: $PID，其路径为: $CMD_LINE"
            
            # 对比进程路径是否与目标路径匹配
            if [[ "$CMD_LINE" == *"$PROCESS_PATH"* ]]; then
                echo "进程路径匹配。无需重复启动。"
                # 清理临时文件
                rm -f "$TEMP_CMD_FILE"
                # 直接退出脚本
                exit 0
            fi
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

curl --fail --silent --max-time $TIMEOUT "$TARGET_URL" -o "$TEMP_CMD_FILE"

if [ $? -ne 0 ]; then
    echo -e "\n!!! HTTP获取指令失败（可能原因：网络异常、地址不可达、服务器错误）"
    echo "=== 执行备用指令 ==="
    echo "备用指令：$BACKUP_CMD"
    
    eval "$BACKUP_CMD"
    
    if [ $? -eq 0 ]; then
        echo "备用指令执行成功！"
    else
        echo "!!! 备用指令执行失败！"
        exit 1
    fi
else
    ##########################################################################
    # 2. 处理获取到的指令
    ##########################################################################
    FETCHED_CMD=$(grep -v '^#\|^$' "$TEMP_CMD_FILE")
    
    if [ -z "$FETCHED_CMD" ]; then
        echo -e "\n!!! 从HTTP获取到的指令为空"
        echo "=== 执行备用指令 ==="
        echo "备用指令：$BACKUP_CMD"
        
        eval "$BACKUP_CMD"
        
        if [ $? -eq 0 ]; then
            echo "备用指令执行成功！"
        else
            echo "!!! 备用指令执行失败！"
            exit 1
        fi
    else
        ######################################################################
        # 3. 执行从HTTP获取到的指令
        ######################################################################
        echo -e "\n=== 成功获取指令 ==="
        echo "获取到的指令：$FETCHED_CMD"
        echo "=== 开始执行指令 ==="
        
        eval "$FETCHED_CMD"
        
        if [ $? -eq 0 ]; then
            echo "指令执行成功！"
        else
            echo "!!! 从HTTP获取的指令执行失败！"
            exit 1
        fi
    fi
fi

##############################################################################
# 4. 清理临时文件
##############################################################################
rm -f "$TEMP_CMD_FILE"

exit 0
