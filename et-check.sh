#!/bin/sh

# ============================================================
# 网络检测脚本 - 所有IP均不通时，杀掉 easytier-core 进程
# 适用：OpenWrt，建议每 10 分钟通过 crontab 执行一次
# ============================================================

PROCESS_NAME="easytier-core"
PROCESS_PATH="/overlay/easytier-core"
LOG_FILE="/tmp/check_network.log"
MAX_LOG_LINES=200

# ---- 在这里配置你要检测的 IP 地址列表 ----
TARGETS="
1.1.1.1
2.2.2.2
3.3.3.3
"
# ------------------------------------------

PING_COUNT=3
PING_TIMEOUT=5

# ---- 自动注册计划任务 ----
CRON_FILE="/etc/crontabs/root"
CRON_JOB="*/10 * * * * /overlay/et-check.sh"

if ! grep -qF "$CRON_JOB" "$CRON_FILE" 2>/dev/null; then
    echo "$CRON_JOB" >> "$CRON_FILE"
    /etc/init.d/cron restart
    echo "计划任务已添加并重启 cron"
else
    echo "计划任务已存在，跳过添加"
fi

# ---- 工具函数 ----

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

trim_log() {
    if [ -f "$LOG_FILE" ]; then
        lines=$(wc -l < "$LOG_FILE")
        if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
            tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        fi
    fi
}

get_pid() {
    local pid
    pid=$(pidof "$PROCESS_NAME" 2>/dev/null)
    if [ -z "$pid" ]; then
        pid=$(ps | grep "$PROCESS_NAME" | grep -v grep | awk '{print $1}')
    fi
    echo "$pid"
}

check_ip() {
    ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$1" > /dev/null 2>&1
    return $?
}

kill_process() {
    local pid
    pid=$(get_pid)

    if [ -n "$pid" ]; then
        log "正在终止进程 $PROCESS_NAME (PID: $pid)"
        kill -9 $pid 2>/dev/null
        sleep 1
        if [ -n "$(get_pid)" ]; then
            log "警告：进程 $PROCESS_NAME 未能成功终止"
        else
            log "进程 $PROCESS_NAME 已成功终止 ✓"
        fi
    else
        log "所有目标 IP 均不可达，但 $PROCESS_NAME 进程未在运行，无需操作"
    fi
}

# ---- 主逻辑 ----

trim_log
log "===== 开始网络检测 ====="

all_failed=1

for ip in $TARGETS; do
    [ -z "$ip" ] && continue

    if check_ip "$ip"; then
        log "IP $ip 可达 ✓"
        all_failed=0
        break
    else
        log "IP $ip 不可达 ✗"
    fi
done

if [ "$all_failed" -eq 1 ]; then
    log "所有目标 IP 均不可达，执行故障处理..."
    kill_process
else
    log "网络正常，无需操作"
fi

log "===== 检测完成 ====="