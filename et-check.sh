#!/bin/sh

# ============================================================
# EasyTier 保活 + 网络检测脚本（OpenWrt / procd）
#
# 流程：
#   1) 进程保活：easytier-core 未运行时拉起（init 脚本 → 命令快照）
#   2) WAN 对照：114.114.114.114 / 223.6.6.6，从 WAN 口探测，不通则判定外网中断，不做处理
#   3) 列表检测：逐个 ping IP_LIST_FILE 中的地址，全部可达才算正常
#   4) 列表刷新：有不可达地址时，用 easytier-cli 取节点虚拟 IP 前 5 个写回列表文件；
#      easytier-cli 也取不到地址时，才 kill 掉 easytier-core（由 procd respawn 重新拉起）
#
# 依赖：jq（解析 easytier-cli 的 JSON 输出）、ping、pidof
# 适用：OpenWrt，每 15 分钟由 crontab 执行一次
# ============================================================

PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH

PROCESS_NAME="easytier-core"
PROCESS_PATH="/overlay/easytier-core"
ET_CLI="/overlay/easytier-cli"
ET_INIT="/etc/init.d/easytier"

# 待检测地址列表（每行一个 IP，支持 # 注释）
IP_LIST_FILE="/overlay/et-ip-list.txt"
# 从节点列表刷新时最多取几个虚拟 IP
MAX_LIST_IP=5

LOG_FILE="/tmp/check_network.log"
MAX_LOG_LINES=200

# ---- 对照组：公网地址，用于判定 WAN 是否通畅 ----
WAN_TARGETS="
114.114.114.114
223.6.6.6
"

# 对照组的出接口，确保探测流量不走 VPN 隧道
WAN_IF="eth1"

# 进程不在时的启动命令（可选）。留空则回退到上次运行命令的快照
DEFAULT_START_CMD=""
START_CMD_FILE="/overlay/.et-check.cmd"

PING_COUNT=3
PING_TIMEOUT=5

# ---- 自动注册计划任务 ----
CRON_FILE="/etc/crontabs/root"
SCRIPT_PATH=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")
CRON_JOB="*/15 * * * * $SCRIPT_PATH"

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

# 对照探测：限定出接口，避免探测流量误走 VPN 隧道
ping_wan() {
    if [ -n "$WAN_IF" ]; then
        ping -c "$PING_COUNT" -W "$PING_TIMEOUT" -I "$WAN_IF" "$1" > /dev/null 2>&1
    else
        ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$1" > /dev/null 2>&1
    fi
    return $?
}

ping_target() {
    ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$1" > /dev/null 2>&1
    return $?
}

# 保存当前进程的启动命令，供进程掉线后原样拉起
save_cmd_snapshot() {
    local pid="$1"
    [ -n "$pid" ] || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1

    tr '\0' ' ' < "/proc/$pid/cmdline" > "${START_CMD_FILE}.tmp" 2>/dev/null || return 1
    if [ -s "${START_CMD_FILE}.tmp" ]; then
        mv "${START_CMD_FILE}.tmp" "$START_CMD_FILE"
    else
        rm -f "${START_CMD_FILE}.tmp"
        return 1
    fi
}

start_easytier() {
    # 方式一：OpenWrt init 脚本（procd 托管，会按 UCI 配置启动）
    if [ -x "$ET_INIT" ]; then
        log "尝试通过 $ET_INIT start 拉起"
        "$ET_INIT" start >> "$LOG_FILE" 2>&1
        sleep 8
        if [ -n "$(get_pid)" ]; then
            return 0
        fi
        log "init 脚本未能拉起进程，尝试其它方式"
    fi

    # 方式二：配置的启动命令，或上次运行命令的快照
    local cmd="$DEFAULT_START_CMD"
    if [ -z "$cmd" ] && [ -s "$START_CMD_FILE" ]; then
        cmd=$(cat "$START_CMD_FILE")
    fi
    if [ -z "$cmd" ] && [ -x "$PROCESS_PATH" ]; then
        log "未找到可用启动命令，无法安全拉起（缺少原始启动参数）"
        return 1
    fi
    if [ -z "$cmd" ]; then
        log "错误：$PROCESS_PATH 不可执行，且未配置任何启动命令，无法拉起"
        return 1
    fi

    log "执行命令拉起：$cmd"
    nohup sh -c "$cmd" >> "$LOG_FILE" 2>&1 &
    sleep 5

    [ -n "$(get_pid)" ] && return 0
    return 1
}

# 用 easytier-cli 取节点虚拟 IP（排除本机），写回列表文件
refresh_ip_list() {
    local tmp="${IP_LIST_FILE}.tmp"

    if [ ! -x "$ET_CLI" ]; then
        log "错误：未找到或不可执行 $ET_CLI，无法刷新地址列表"
        return 1
    fi

    # 排除本机节点（cost 为 Local）；若过滤后为空，则退化为不过滤
    "$ET_CLI" -o json peer list 2>/dev/null \
        | jq -r '.[] | select((.ipv4 != "") and (.cost != "Local")) | .ipv4' 2>/dev/null \
        | head -n "$MAX_LIST_IP" > "$tmp"

    if [ ! -s "$tmp" ]; then
        "$ET_CLI" -o json peer list 2>/dev/null \
            | jq -r '.[] | select(.ipv4 != "") | .ipv4' 2>/dev/null \
            | head -n "$MAX_LIST_IP" > "$tmp"
    fi

    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        log "easytier-cli 未返回任何虚拟 IP，刷新地址列表失败"
        return 1
    fi

    mv "$tmp" "$IP_LIST_FILE"
    log "地址列表已刷新为：$(tr '\n' ' ' < "$IP_LIST_FILE")"
    return 0
}

# 返回：0=全部可达  1=存在不可达  2=列表为空或缺失
check_ip_list() {
    local total=0 failed=0 ip

    [ -s "$IP_LIST_FILE" ] || return 2

    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        case "$ip" in
            \#*) continue ;;
        esac

        total=$((total + 1))
        if ping_target "$ip"; then
            log "目标 $ip 可达 ✓"
        else
            log "目标 $ip 不可达 ✗"
            failed=$((failed + 1))
        fi
    done < "$IP_LIST_FILE"

    [ "$total" -eq 0 ] && return 2
    [ "$failed" -eq 0 ] && return 0
    return 1
}

kill_process() {
    local pid
    pid=$(get_pid)

    if [ -n "$pid" ]; then
        log "正在终止进程 $PROCESS_NAME (PID: $pid)，由 procd 自动重新拉起"
        kill -9 $pid 2>/dev/null
        sleep 1
        if [ -n "$(get_pid)" ]; then
            log "警告：进程 $PROCESS_NAME 未能成功终止"
        else
            log "进程 $PROCESS_NAME 已成功终止 ✓"
        fi
    else
        log "$PROCESS_NAME 进程未在运行，无需终止"
    fi
}

register_cron() {
    # 间隔变更时先清理本脚本的旧条目，避免两条任务并存重复执行
    if [ -f "$CRON_FILE" ]; then
        old_entry=$(grep -F "$SCRIPT_PATH" "$CRON_FILE" 2>/dev/null | grep -vF "$CRON_JOB")
        if [ -n "$old_entry" ]; then
            grep -vF "$SCRIPT_PATH" "$CRON_FILE" > "${CRON_FILE}.tmp"
            rc=$?
            # grep 退出码 0=有剩余行 1=无剩余行，二者都表示过滤成功；>=2 才是真出错，不能覆盖原文件
            if [ "$rc" -le 1 ]; then
                mv "${CRON_FILE}.tmp" "$CRON_FILE"
                log "已清理本脚本的旧计划任务条目：$old_entry"
            else
                rm -f "${CRON_FILE}.tmp"
                log "警告：清理旧计划任务条目失败，跳过（退出码 $rc）"
            fi
        fi
    fi

    if grep -qF "$CRON_JOB" "$CRON_FILE" 2>/dev/null; then
        log "计划任务已存在，跳过添加"
        return 0
    fi

    if echo "$CRON_JOB" >> "$CRON_FILE" 2>/dev/null; then
        /etc/init.d/cron restart > /dev/null 2>&1
        log "计划任务已添加（每 15 分钟）并重启 cron"
    else
        log "警告：写入 $CRON_FILE 失败，请手动添加：$CRON_JOB"
    fi
}

# ---- 主逻辑 ----

trim_log
log "===== 开始检测 ====="
register_cron

pid=$(get_pid)

# 1) 进程保活
if [ -z "$pid" ]; then
    log "$PROCESS_NAME 未在运行，尝试拉起"
    if start_easytier; then
        log "$PROCESS_NAME 已拉起 ✓ PID: $(get_pid)"
    else
        log "警告：$PROCESS_NAME 拉起失败 ✗，请检查启动配置"
    fi
    log "===== 检测完成（本次执行拉起，网络判定顺延到下个周期）====="
    exit 0
fi

log "$PROCESS_NAME 运行中，PID: $pid"
save_cmd_snapshot "$(echo $pid | awk '{print $1}')"

# 2) 对照组：先判定 WAN 是否通畅
wan_ok=1
for ip in $WAN_TARGETS; do
    [ -z "$ip" ] && continue

    if ping_wan "$ip"; then
        log "WAN 对照 $ip 可达 ✓"
        wan_ok=0
        break
    else
        log "WAN 对照 $ip 不可达 ✗"
    fi
done

if [ "$wan_ok" -ne 0 ]; then
    log "WAN 不可达，判定为外网中断，与 $PROCESS_NAME 无关，不做处理"
    log "===== 检测完成 ====="
    exit 0
fi

# 3) 检测地址列表
check_ip_list
list_rc=$?

case "$list_rc" in
    0)
        log "地址列表全部可达，网络正常"
        ;;
    1)
        log "地址列表中存在不可达地址，从节点列表刷新"
        if ! refresh_ip_list; then
            log "刷新失败，判定 $PROCESS_NAME 异常，执行故障处理..."
            kill_process
        fi
        ;;
    2)
        log "地址列表为空或缺失，初始化：$IP_LIST_FILE"
        if ! refresh_ip_list; then
            log "初始化失败，判定 $PROCESS_NAME 异常，执行故障处理..."
            kill_process
        fi
        ;;
esac

log "===== 检测完成 ====="
