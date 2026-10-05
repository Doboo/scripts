#!/bin/bash
# ================================================================
# EasyTier 一键管理脚本（全交互式）
# 直接运行后通过菜单完成所有操作
# ================================================================
set -euo pipefail

# ----------------------------------------------------------------
# 常量定义
# ----------------------------------------------------------------
readonly INSTALL_DIR="/root/easytier"
readonly SERVICE_FILE="/etc/systemd/system/easytier.service"
readonly SERVICE_NAME="easytier"
readonly CONFIG_FILE="/etc/easytier/easytier.yaml"
readonly DEFAULT_CONSOLE_HOST="udp://cfgs.175419.xyz:22020"
readonly LOCAL_MIRROR="http://202.189.23.82:1880/chfs/shared/easytier"

# Web 控制台相关常量
readonly WEB_EMBED_BINARY="${INSTALL_DIR}/easytier-web-embed"
readonly WEB_SERVICE_FILE="/etc/systemd/system/easytier-web.service"
readonly WEB_SERVICE_NAME="easytier-web"
readonly WEB_DB_DIR="/etc/easytier"
readonly DEFAULT_WEB_HTTP_PORT="11211"
readonly DEFAULT_CONSOLE_PORT="22020"
readonly DEFAULT_CONSOLE_PROTO="udp"

# 服务运行模式
# console       : 配置服务器模式（命令行参数，使用 -w/--config-server）
# console_file  : 本地配置文件模式（使用 -c）
# relay         : 不连接配置服务器，以服务端/中继模式运行
readonly MODE_CONSOLE="console"
readonly MODE_CONSOLE_FILE="console_file"
readonly MODE_RELAY="relay"

# systemd 服务的日志级别
# info: 默认。能看到连接/路由/打洞过程，便于排障
#   磁盘风险可控：journald 默认 SystemMaxUse=磁盘10%（上限 4G），超限自动删最旧归档，
#   不会撑爆磁盘。仅在网络持续抖动时日志量会显著上升，可用 journalctl --disk-usage 观察。
# warn: 日志量最小，适合常年无人值守的节点，但排障时看不到连接过程
# 临时调整用 systemctl edit easytier 覆盖 Environment=RUST_LOG=
readonly RUST_LOG_LEVEL="info"

# 内存护栏上限：MemoryMax 取物理内存 1/4，并限制在 128M~1024M 之间
readonly MEM_LIMIT_MIN_MB=128
readonly MEM_LIMIT_MAX_MB=1024
readonly MEM_LIMIT_RATIO=4      # 物理内存除以该值得到 MemoryMax
readonly MEM_HIGH_PERCENT=60    # MemoryHigh = MemoryMax 的百分之多少

readonly PROXY_LIST=(
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    "https://ghproxylist.com/"
    "https://mirror.ghproxy.com/"
)

# ----------------------------------------------------------------
# 彩色输出
# ----------------------------------------------------------------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

info()    { echo -e "${GREEN}[INFO]${RESET}  $*" >&2; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
title()   { echo -e "\n${BOLD}${BLUE}>>> $* ${RESET}" >&2; }
success() { echo -e "${BOLD}${GREEN}$*${RESET}" >&2; }

# ----------------------------------------------------------------
# 临时文件
# ----------------------------------------------------------------
TMP_ZIP=$(mktemp /tmp/easytier_XXXXXX.zip)

# ----------------------------------------------------------------
# 清理与信号处理
# ----------------------------------------------------------------
cleanup() {
    rm -f "$TMP_ZIP"
}
trap cleanup EXIT
trap 'echo; error "脚本被中断"; exit 130' INT TERM

# ----------------------------------------------------------------
# Root 权限检查
# ----------------------------------------------------------------
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "此脚本需要 root 权限运行，请使用 sudo 或切换到 root 用户。"
        exit 1
    fi
}

# ----------------------------------------------------------------
# 安装依赖
# ----------------------------------------------------------------
install_deps() {
    local missing=()
    for cmd in unzip wget curl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [ ${#missing[@]} -eq 0 ] && return 0

    info "检测到缺少依赖: ${missing[*]}，正在安装..."
    if [ -f /etc/debian_version ]; then
        apt-get update -y -qq && apt-get install -y -qq "${missing[@]}" || true
    elif [ -f /etc/redhat-release ]; then
        yum install -y -q "${missing[@]}" || true
    elif [ -f /etc/alpine-release ]; then
        apk add --quiet "${missing[@]}" || true
    else
        error "无法自动安装依赖，请手动安装: ${missing[*]}"
    fi
    info "依赖安装完成。"
}

# ----------------------------------------------------------------
# 获取 CPU 架构
# ----------------------------------------------------------------
get_arch() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64"  ;;
        aarch64) echo "aarch64" ;;
        armv7l)  echo "armv7"   ;;
        riscv64) echo "riscv64" ;;
        *)
            error "不支持的CPU架构: $(uname -m)"
            exit 1
            ;;
    esac
}

# ----------------------------------------------------------------
# 读取当前服务配置（从 service 文件解析）
# ----------------------------------------------------------------
read_current_config() {
    if [ ! -f "$SERVICE_FILE" ]; then
        echo ""
        return
    fi
    # 匹配 -w "协议://地址/用户名" 中的 协议://地址:端口 部分
    grep -oP '(?<=-w ")[^/]+://[^/]+(?=/)' "$SERVICE_FILE" 2>/dev/null || echo ""
}

read_current_username() {
    if [ ! -f "$SERVICE_FILE" ]; then
        echo ""
        return
    fi
    # 匹配 -w "协议://地址/用户名" 中的用户名部分
    grep -oP '(?<=-w ")[^/]+/([^"]+)' "$SERVICE_FILE" 2>/dev/null | sed 's/^[^/]*\///' | head -1 || echo ""
}

read_current_hostname() {
    if [ ! -f "$SERVICE_FILE" ]; then
        echo ""
        return
    fi
    grep -oP '(?<=--hostname ")[^"]+' "$SERVICE_FILE" 2>/dev/null || echo ""
}

# ----------------------------------------------------------------
# 检测当前运行模式
# ----------------------------------------------------------------
read_current_mode() {
    if [ ! -f "$SERVICE_FILE" ]; then
        echo ""
        return
    fi
    if grep -q "relay-network-whitelist" "$SERVICE_FILE" 2>/dev/null; then
        echo "$MODE_RELAY"
    elif grep -q "\-c.*easytier\.yaml" "$SERVICE_FILE" 2>/dev/null; then
        echo "$MODE_CONSOLE_FILE"
    elif grep -q "\-w\s" "$SERVICE_FILE" 2>/dev/null; then
        # Web控制台模式：使用 -w 参数
        echo "$MODE_CONSOLE"
    else
        echo "$MODE_CONSOLE"
    fi
}

# ----------------------------------------------------------------
# 读取配置文件中各字段（辅助函数）
# ----------------------------------------------------------------
_read_yaml_val() {
    local key="$1"
    local file="${2:-}"
    [ -z "$file" ] && file="$CONFIG_FILE"
    [ ! -f "$file" ] && return
    grep -E "^${key}\s*=" "$file" 2>/dev/null | sed "s/^${key}\s*=\s*//" | tr -d '"' | tr -d "'" | xargs
}

# 读取 config 模式 hostname
read_current_conf_hostname() {
    _read_yaml_val "hostname" | head -1 || true
}

# 读取网络名称
read_current_network_name() {
    _read_yaml_val "network_name" | head -1 || true
}

# 读取网络密钥
read_current_network_secret() {
    _read_yaml_val "network_secret" | head -1 || true
}

# 读取本机虚拟 IP
read_current_conf_ipv4() {
    _read_yaml_val "ipv4" | head -1 || true
}

# 读取是否 dhcp
read_current_conf_dhcp() {
    _read_yaml_val "dhcp" | head -1 || true
}

# 读取 peer URI
read_current_conf_peer_uri() {
    grep -E '^\[\[peer\]\]' "$CONFIG_FILE" -A 1 2>/dev/null | grep "^uri\s*=" | sed 's/^uri\s*=\s*//' | tr -d '"' | tr -d "'" | xargs | awk '{print $1}' || true
}

# 读取子网代理 CIDR
read_current_conf_proxy_cidr() {
    grep -E '^\[\[proxy_network\]\]' "$CONFIG_FILE" -A 1 2>/dev/null | grep "^cidr\s*=" | sed 's/^cidr\s*=\s*//' | tr -d '"' | tr -d "'" | xargs | awk '{print $1}' || true
}

# 读取加密开关
read_current_conf_encryption() {
    _read_yaml_val "enable_encryption" | head -1 || true
}

# ----------------------------------------------------------------
# 读取服务端模式 hostname
# ----------------------------------------------------------------
read_current_relay_hostname() {
    if [ ! -f "$SERVICE_FILE" ]; then
        echo ""
        return
    fi
    grep -oP '(?<=--hostname ")[^"]+' "$SERVICE_FILE" 2>/dev/null || echo ""
}

# ----------------------------------------------------------------
# 读取服务端模式侦听端口（协议: tcp/udp/ws/wss）
# ----------------------------------------------------------------
read_current_relay_port() {
    local proto="$1"
    if [ ! -f "$SERVICE_FILE" ]; then
        echo ""
        return
    fi
    # 匹配 --listeners "tcp://0.0.0.0:11010" 这样的格式
    grep -oP "(?<=${proto}://0\\.0\\.0\\.0:)[0-9]+" "$SERVICE_FILE" 2>/dev/null | head -1 || echo ""
}

# ----------------------------------------------------------------
# 读取当前中继网络白名单
# ----------------------------------------------------------------
read_current_relay_whitelist() {
    if [ ! -f "$SERVICE_FILE" ]; then
        echo ""
        return
    fi
    grep -oP '(?<=--relay-network-whitelist ")[^"]+' "$SERVICE_FILE" 2>/dev/null | head -1 || echo ""
}

# ----------------------------------------------------------------
# 显示当前状态信息
# ----------------------------------------------------------------
show_current_info() {
    echo -e "\n${BOLD}${CYAN}──────────── 当前状态 ────────────${RESET}"
    if systemctl is-active "$SERVICE_NAME" &>/dev/null; then
        echo -e "  服务状态: ${GREEN}${BOLD}运行中 ✓${RESET}"
    elif [ -f "$SERVICE_FILE" ]; then
        echo -e "  服务状态: ${RED}${BOLD}已停止 ✗${RESET}"
    else
        echo -e "  服务状态: ${YELLOW}未安装${RESET}"
    fi

    if [ -f "$SERVICE_FILE" ]; then
        local cur_mode
        cur_mode=$(read_current_mode)
        if [ "$cur_mode" = "$MODE_RELAY" ]; then
            echo -e "  运行模式: ${CYAN}服务端/中继模式${RESET}"
            local relay_host relay_tcp relay_udp relay_ws relay_wss
            relay_host=$(read_current_relay_hostname)
            relay_tcp=$(read_current_relay_port "tcp")
            relay_udp=$(read_current_relay_port "udp")
            relay_ws=$(read_current_relay_port "ws")
            relay_wss=$(read_current_relay_port "wss")
            [ -n "$relay_host" ] && echo -e "  主机名:   ${CYAN}${relay_host}${RESET}"
            [ -n "$relay_tcp"  ] && echo -e "  TCP 端口: ${CYAN}${relay_tcp}${RESET}"
            [ -n "$relay_udp"  ] && echo -e "  UDP 端口: ${CYAN}${relay_udp}${RESET}"
            [ -n "$relay_ws"   ] && echo -e "  WS  端口: ${CYAN}${relay_ws}${RESET}"
            [ -n "$relay_wss"  ] && echo -e "  WSS 端口: ${CYAN}${relay_wss}${RESET}"
        elif [ "$cur_mode" = "$MODE_CONSOLE_FILE" ]; then
            local cf_host cf_netname cf_netsec cf_ip cf_peer
            cf_host=$(read_current_conf_hostname)
            cf_netname=$(read_current_network_name)
            cf_netsec=$(read_current_network_secret)
            cf_ip=$(read_current_conf_ipv4)
            cf_peer=$(read_current_conf_peer_uri)
            echo -e "  运行模式: ${CYAN}客户端模式（配置文件）${RESET}"
            echo -e "  配置文件: ${CYAN}${CONFIG_FILE}${RESET}"
            [ -n "$cf_host"    ] && echo -e "  主机名:   ${CYAN}${cf_host}${RESET}"
            [ -n "$cf_netname" ] && echo -e "  网络名称: ${CYAN}${cf_netname}${RESET}"
            [ -n "$cf_netsec"  ] && echo -e "  网络密钥: ${CYAN}${cf_netsec}${RESET}"
            [ -n "$cf_ip"      ] && echo -e "  虚拟 IP:  ${CYAN}${cf_ip}${RESET}"
            [ -n "$cf_peer"    ] && echo -e "  节点地址: ${CYAN}${cf_peer}${RESET}"
        else
            local cur_console cur_user cur_host
            cur_console=$(read_current_config)
            cur_user=$(read_current_username)
            cur_host=$(read_current_hostname)
            echo -e "  运行模式: ${CYAN}Web控制台模式${RESET}"
            [ -n "$cur_console" ] && echo -e "  控制台:   ${CYAN}${cur_console}${RESET}"
            [ -n "$cur_user"    ] && echo -e "  用户名:   ${CYAN}${cur_user}${RESET}"
            [ -n "$cur_host"    ] && echo -e "  机器名:   ${CYAN}${cur_host}${RESET}"
        fi
    fi

    if [ -f "${INSTALL_DIR}/easytier-core" ]; then
        local ver
        ver=$("${INSTALL_DIR}/easytier-core" --version 2>/dev/null | head -1 || echo "未知")
        echo -e "  程序版本: ${CYAN}${ver}${RESET}"
    fi

    echo -e "${BOLD}${CYAN}──────────────────────────────────${RESET}"

    # ── Web 控制台状态 ──
    if systemctl is-active "$WEB_SERVICE_NAME" &>/dev/null; then
        echo -e "${BOLD}────────── Web 控制台状态 ──────────${RESET}"
        echo -e "  服务状态: ${GREEN}${BOLD}运行中 ✓${RESET}"
        read_web_console_info
        echo -e "${BOLD}${CYAN}──────────────────────────────────${RESET}"
    elif [ -f "$WEB_SERVICE_FILE" ]; then
        echo -e "${BOLD}────────── Web 控制台状态 ──────────${RESET}"
        echo -e "  服务状态: ${RED}${BOLD}已停止 ✗${RESET}"
        read_web_console_info
        echo -e "${BOLD}${CYAN}──────────────────────────────────${RESET}"
    fi

    echo
}

# ----------------------------------------------------------------
# 从 easytier-web systemd 服务文件读取配置参数
# ----------------------------------------------------------------
read_web_console_info() {
    if [ ! -f "$WEB_SERVICE_FILE" ]; then
        return 0
    fi
    local exec_line
    exec_line=$(grep "^ExecStart=" "$WEB_SERVICE_FILE" 2>/dev/null || true)
    [ -z "$exec_line" ] && return 0

    # 提取各参数（grep 无匹配时返回1，用 || true 防止 set -e 退出）
    local http_port console_port console_proto api_host
    http_port=$(echo "$exec_line" | grep -oE '\-l[[:space:]]+([0-9]+)'  2>/dev/null | awk '{print $2}' | head -1 || true)
    console_port=$(echo "$exec_line" | grep -oE '\-c[[:space:]]+([0-9]+)' 2>/dev/null | awk '{print $2}' | head -1 || true)
    console_proto=$(echo "$exec_line" | grep -oE '\-p[[:space:]]+(tcp|udp|ws)[^[:space:]]*' 2>/dev/null | awk '{print $2}' | head -1 || true)
    api_host=$(echo "$exec_line" | sed -n 's/.*--api-host[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1 || true)

    [ -n "$http_port"    ] && echo "  HTTP 端口:  ${CYAN}${http_port}${RESET}"
    [ -n "$console_port" ] && echo -e "  后端端口:  ${CYAN}${console_port} (${console_proto})${RESET}"
    [ -n "$api_host"     ] && echo -e "  API 地址:  ${CYAN}${api_host}${RESET}"
    echo -e "  数据库:    ${CYAN}${WEB_DB_DIR}/et.db${RESET}"
    return 0
}

# ================================================================
# 主菜单
# ================================================================
main_menu() {
    while true; do
    clear || true
        echo -e "${BOLD}${BLUE}"
        echo "  ╔══════════════════════════════════════╗"
        echo "  ║       EasyTier 一键管理脚本          ║"
        echo "  ╚══════════════════════════════════════╝"
        echo -e "${RESET}"

        show_current_info

        echo -e "${BOLD}请选择操作:${RESET}"
        echo -e "  ${BOLD}${GREEN}1)${RESET} 全新安装 - 客户端模式"
        echo -e "  ${BOLD}${GREEN}2)${RESET} 全新安装 - 服务端模式（独立中继，不连控制台）"
        echo -e "  ${BOLD}${YELLOW}3)${RESET} 修改配置"
        echo -e "  ${BOLD}${CYAN}4)${RESET} 更新程序（保留配置）"
        echo -e "  ${BOLD}5)${RESET} 卸载 EasyTier"
        echo -e "  ${BOLD}6)${RESET} 查看运行日志"
        echo -e "  ${BOLD}7)${RESET} 重启服务"
        echo -e "  ${BOLD}8)${RESET} 查看组网信息（peer 列表）"
        echo -e "  ${BOLD}9)${RESET} 安装 Web 控制台"
        echo -e "  ${BOLD}10)${RESET} 断网监控（定时检测虚拟网，全部不通自动重启）"
        echo -e "  ${BOLD}11)${RESET} 增加 machine-id（为已安装服务追加随机 UUID 标识）"
        echo -e "  ${BOLD}12)${RESET} 旁路网关（iptables 转发，LAN↔虚拟网互通）"
        echo -e "  ${BOLD}0)${RESET} 退出"
        echo
        printf "请输入选项 [0-12]: "
        read -r choice </dev/tty

        case "$choice" in
            1) do_install "$MODE_CONSOLE" ;;
            2) do_install "$MODE_RELAY"   ;;
            3) do_modify   ;;
            4) do_update   ;;
            5) do_uninstall;;
            6) do_show_log ;;
            7) do_restart  ;;
            8) do_show_peer ;;
            9) do_install_web_console ;;
            10) do_watchdog ;;
            11) do_machine_id ;;
            12) etgw_menu      ;;
            0)
                echo -e "\n${GREEN}再见！${RESET}"
                exit 0
                ;;
            *)
                warn "无效选项 '${choice}'，请输入 0~12。"
                sleep 1
                ;;
        esac

        echo
        printf "${YELLOW}按 Enter 键返回主菜单...${RESET}"
        read -r </dev/tty
    done
}

# ----------------------------------------------------------------
# 交互：输入用户名
# ----------------------------------------------------------------
prompt_username() {
    local cur default
    cur=$(read_current_username)
    default="${cur:-}"

    while true; do
        if [ -n "$default" ]; then
            printf "请输入用户名 (当前: ${CYAN}%s${RESET}，直接回车保留): " "$default" >&2
        else
            printf "请输入用户名 (例: myuser): " >&2
        fi
        read -r val </dev/tty
        val="${val:-$default}"
        if [ -z "$val" ]; then
            warn "用户名不能为空，请重新输入。"
            continue
        fi
        if [[ "$val" =~ [[:space:]/\\] ]]; then
            warn "用户名不能包含空格或斜杠，请重新输入。"
            continue
        fi
        echo "$val"
        return
    done
}

# ----------------------------------------------------------------
# 交互：输入机器名
# ----------------------------------------------------------------
prompt_hostname() {
    local cur default
    cur=$(read_current_hostname)
    # 若无当前值，用系统 hostname 作建议值
    default="${cur:-$(hostname -s 2>/dev/null || echo "")}"

    while true; do
        if [ -n "$default" ]; then
            printf "请输入机器名/节点名 (当前: ${CYAN}%s${RESET}，直接回车保留): " "$default" >&2
        else
            printf "请输入机器名/节点名 (例: my-router): " >&2
        fi
        read -r val </dev/tty
        val="${val:-$default}"
        if [ -z "$val" ]; then
            warn "机器名不能为空，请重新输入。"
            continue
        fi
        if [[ "$val" =~ [[:space:]/\\] ]]; then
            warn "机器名不能包含空格或斜杠，请重新输入。"
            continue
        fi
        echo "$val"
        return
    done
}

# ----------------------------------------------------------------
# 交互：输入控制台地址（三选一 + 手动输入）
# ----------------------------------------------------------------
prompt_console() {
    local cur_console
    cur_console=$(read_current_config)

    # 预定义选项
    local -a OPTIONS
    OPTIONS[1]="udp://cfgs.175419.xyz:22020"
    OPTIONS[2]="wss://etcfgs.38196962.xyz:0"
    OPTIONS[3]=""

    # 判断当前配置匹配哪个选项
    local selected=""
    for i in 1 2 3; do
        if [ -n "$cur_console" ] && [ "$cur_console" = "${OPTIONS[$i]}" ]; then
            selected="$i"
            break
        fi
    done
    selected="${selected:-1}"  # 默认选1

    while true; do
        echo -e "\n${BOLD}── 选择控制台地址 ──${RESET}" >&2
        echo -e "  ${CYAN}1${RESET}) udp://cfgs.175419.xyz:22020" >&2
        echo -e "  ${CYAN}2${RESET}) wss://etcfgs.38196962.xyz:0" >&2
        echo -e "  ${CYAN}3${RESET}) 手动填写" >&2
        [ -n "$cur_console" ] && echo -e "\n  当前配置: ${CYAN}${cur_console}${RESET}" >&2
        printf "请选择 (1/2/3，直接回车默认 ${CYAN}%s${RESET}): " "$selected" >&2
        read -r choice </dev/tty
        choice="${choice:-$selected}"

        case "$choice" in
            1)
                info "已选择: ${OPTIONS[1]}"
                echo "${OPTIONS[1]}"
                return
                ;;
            2)
                info "已选择: ${OPTIONS[2]}"
                echo "${OPTIONS[2]}"
                return
                ;;
            3)
                break
                ;;
            *)
                warn "无效选择，请输入 1、2 或 3。"
                continue
                ;;
        esac
    done

    # 手动输入模式
    local manual=""
    while true; do
        [ -n "$cur_console" ] && printf "请输入控制台地址 (当前: ${CYAN}%s${RESET}，直接回车保留): " "$cur_console" >&2 \
                               || printf "请输入控制台地址 (例: ${CYAN}udp://1.2.3.4:22022${RESET}): " >&2
        read -r manual </dev/tty
        manual="${manual:-$cur_console}"
        if [ -z "$manual" ]; then
            warn "地址不能为空，请重新输入。"
            continue
        fi
        if [[ "$manual" =~ [[:space:]] ]]; then
            warn "地址不能包含空格，请重新输入。"
            continue
        fi
        break
    done

    info "控制台地址: ${manual}"
    echo "$manual"
}

# ----------------------------------------------------------------
# 交互：配置文件模式 - 引导输入各项参数
# ----------------------------------------------------------------

# 网络名称
prompt_network_name() {
    local cur default
    cur=$(read_current_network_name)
    default="${cur:-}"

    while true; do
        if [ -n "$default" ]; then
            printf "请输入网络名称 (当前: ${CYAN}%s${RESET}，直接回车保留): " "$default" >&2
        else
            printf "请输入网络名称 (network_name): " >&2
        fi
        read -r val </dev/tty
        val="${val:-$default}"
        if [ -z "$val" ]; then
            warn "网络名称不能为空，请重新输入。"
            continue
        fi
        if [[ "$val" =~ [[:space:]] ]]; then
            warn "网络名称不能包含空格，请重新输入。"
            continue
        fi
        echo "$val"
        return
    done
}

# 网络密钥/密码
prompt_network_secret() {
    local cur default
    cur=$(read_current_network_secret)
    default="${cur:-}"

    while true; do
        if [ -n "$default" ]; then
            printf "请输入网络密钥/密码 (当前: ${CYAN}%s${RESET}，直接回车保留): " "$default" >&2
        else
            printf "请输入网络密钥/密码 (network_secret): " >&2
        fi
        read -r val </dev/tty
        val="${val:-$default}"
        if [ -z "$val" ]; then
            warn "网络密钥不能为空，请重新输入。"
            continue
        fi
        echo "$val"
        return
    done
}

# 虚拟 IP（与 DHCP 二选一）
prompt_ipv4() {
    local cur default
    cur=$(read_current_conf_ipv4)
    local cur_dhcp
    cur_dhcp=$(read_current_conf_dhcp)
    default="$cur"

    info "请选择 IP 地址分配方式："
    printf "  ${BOLD}1)${RESET} 使用 DHCP 自动分配（推荐）\n" >&2
    printf "  ${BOLD}2)${RESET} 手动指定固定 IP\n" >&2
    local choice
    while true; do
        printf "请输入选项 [1/2]（默认: 1）: " >&2
        read -r choice </dev/tty
        choice="${choice:-1}"
        case "$choice" in
            1) echo "dhcp"; return ;;
            2) break ;;
            *) warn "无效选项，请输入 1 或 2。" ;;
        esac
    done

    while true; do
        printf "请输入虚拟网络 IPv4 地址 (例如: ${CYAN}10.0.0.50${RESET}): " >&2
        read -r val </dev/tty
        val="${val:-$default}"
        if [ -z "$val" ]; then
            warn "IP 地址不能为空。"
            continue
        fi
        # 简单校验格式
        if ! [[ "$val" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            warn "IP 格式无效，请重新输入（如 10.0.0.50）。"
            continue
        fi
        echo "$val"
        return
    done
}

# 节点服务器地址（peer URI，支持多个）
# 返回格式: peer1|peer2|peer3 (用 | 分隔)
prompt_peer_uri() {
    local cur
    cur=$(read_current_conf_peer_uri)

    # 预填的默认节点1
    local default_node1="tcp://et.sbgov.cn:11010"

    echo -e "\n${BOLD}── 配置节点服务器地址 (peer URI) ──${RESET}" >&2
    echo "  支持添加多个节点服务器地址" >&2
    echo "  输入完成后直接回车确认" >&2

    local peers=()
    local idx=1

    # 读取已有的 peer（配置文件中已存在的）
    if [ -n "$cur" ]; then
        IFS='|' read -ra existing <<< "$cur"
        for p in "${existing[@]}"; do
            [ -n "$p" ] && peers+=("$p")
        done
        echo -e "\n  ${CYAN}已加载现有节点配置${RESET}" >&2
    else
        # 首次配置：预填节点1，节点2要求手动输入
        peers=("$default_node1")
        echo -e "\n  ${CYAN}节点1已预填：${default_node1}${RESET}" >&2
    fi

    while true; do
        local cur_val="${peers[$((idx-1))]:-}"
        if [ "$idx" -le "${#peers[@]}" ]; then
            # 已有节点：允许修改
            printf "  节点 %d (当前: ${CYAN}%s${RESET})\n" "$idx" "$cur_val" >&2
            printf "  输入新地址或直接回车保留: " >&2
            read -r val </dev/tty
            [ -n "$val" ] && peers[$((idx-1))]="$val"
        elif [ "$idx" -eq 2 ]; then
            # 节点2：可选，空则结束节点输入
            printf "  节点 %d (输入第二个节点地址，或直接回车完成填写)\n" "$idx" >&2
            printf "  输入地址: " >&2
            read -r val </dev/tty
            [ -z "$val" ] && break
            peers+=("$val")
        else
            # 更多节点：可选添加
            printf "  节点 %d (新添加，输入地址如: ${CYAN}udp://1.2.3.4:11010${RESET})\n" "$idx" >&2
            printf "  或直接回车完成输入: " >&2
            read -r val </dev/tty
            [ -z "$val" ] && break
            peers+=("$val")
        fi
        idx=$((idx+1))
    done

    # 返回用 | 分隔的字符串
    local result
    printf -v result '%s|' "${peers[@]}"
    result="${result%|}"  # 去掉末尾的 |
    echo "$result"
}

# 子网代理（支持多个 CIDR，用 | 分隔）
prompt_proxy_network() {
    local cur
    cur=$(read_current_conf_proxy_cidr)

    echo -e "\n${BOLD}── 配置子网代理地址 (proxy_network) ──${RESET}" >&2
    echo "  可添加多个子网段，输入完成后直接回车结束" >&2

    local proxies=()

    # 加载已有的子网代理配置
    if [ -n "$cur" ] && [[ "$cur" == *"|"* ]]; then
        IFS='|' read -ra existing <<< "$cur"
        for p in "${existing[@]}"; do
            [ -n "$p" ] && proxies+=("$p")
        done
        echo -e "\n  ${CYAN}已加载现有子网代理配置${RESET}" >&2
    elif [ -n "$cur" ]; then
        # 单个已有值
        proxies+=("$cur")
        echo -e "\n  ${CYAN}已加载现有子网代理配置${RESET}" >&2
    fi

    local idx=1
    if [ ${#proxies[@]} -eq 0 ]; then
        idx=1
    else
        idx=${#proxies[@]}
    fi

    while true; do
        local cur_val="${proxies[$((idx-1))]:-}"
        if [ "$idx" -le "${#proxies[@]}" ]; then
            # 已有值：允许修改
            printf "  子网 %d (当前: ${CYAN}%s${RESET})\n" "$idx" "$cur_val" >&2
            printf "  输入新地址或直接回车保留: " >&2
            read -r val </dev/tty
            [ -n "$val" ] && proxies[$((idx-1))]="$val"
        else
            # 新添加：空则结束
            printf "  子网 %d (输入新的 CIDR 地址如: ${CYAN}10.0.0.0/16${RESET})\n" "$idx" >&2
            printf "  或直接回车完成输入: " >&2
            read -r val </dev/tty
            [ -z "$val" ] && break
            if ! [[ "$val" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                warn "CIDR 格式无效，请输入类似 192.168.1.0/24 的格式。"
                continue
            fi
            proxies+=("$val")
        fi
        idx=$((idx+1))
    done

    # 返回用 | 分隔的字符串
    if [ ${#proxies[@]} -eq 0 ]; then
        echo ""
    else
        local result
        printf -v result '%s|' "${proxies[@]}"
        result="${result%|}"
        echo "$result"
    fi
}

# 是否启用加密
prompt_encryption() {
    local cur
    cur=$(read_current_conf_encryption)
    local choice

    while true; do
        if [ "$cur" = "false" ]; then
            printf "是否启用加密 (enable_encryption)？[${YELLOW}y/N${RESET}]（当前: 关闭）: " >&2
        elif [ "$cur" = "true" ]; then
            printf "是否启用加密 (enable_encryption)？[${GREEN}Y/n${RESET}]（当前: 开启）: " >&2
        else
            printf "是否启用加密 (enable_encryption)？[${GREEN}Y/n${RESET}]（默认: 关闭）: " >&2
        fi
        read -r choice </dev/tty
        choice="${choice:-N}"
        case "$choice" in
            Y|y) echo "true";  return ;;
            N|n|"") echo "false"; return ;;
            *) warn "无效选项，请输入 Y 或 N。" ;;
        esac
    done
}

# ----------------------------------------------------------------
# 交互：Web 控制台 - HTTP 端口
# ----------------------------------------------------------------
prompt_web_http_port() {
    local default="${DEFAULT_WEB_HTTP_PORT:-11211}"
    while true; do
        printf "请输入 Web 控制台 HTTP 端口 [默认: ${CYAN}%s${RESET}]: " "$default" >&2
        read -r val </dev/tty
        val="${val:-$default}"
        if ! [[ "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ] || [ "$val" -gt 65535 ]; then
            warn "端口无效，请输入 1~65535 之间的整数。"
            continue
        fi
        echo "$val"
        return
    done
}

# ----------------------------------------------------------------
# 交互：Web 控制台 - 控制台通讯端口
# ----------------------------------------------------------------
prompt_web_console_port() {
    local default="${DEFAULT_CONSOLE_PORT:-22020}"
    while true; do
        printf "请输入控制台后端通讯端口（客户端连接此端口）[默认: ${CYAN}%s${RESET}]: " "$default" >&2
        read -r val </dev/tty
        val="${val:-$default}"
        if ! [[ "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ] || [ "$val" -gt 65535 ]; then
            warn "端口无效，请输入 1~65535 之间的整数。"
            continue
        fi
        echo "$val"
        return
    done
}

# ----------------------------------------------------------------
# 交互：Web 控制台 - 通讯协议
# ----------------------------------------------------------------
prompt_web_console_proto() {
    local default="${DEFAULT_CONSOLE_PROTO:-udp}"
    local choice
    while true; do
        printf "请选择控制台通讯协议:\n" >&2
        printf "  ${BOLD}1)${RESET} UDP（推荐，穿透性好）\n" >&2
        printf "  ${BOLD}2)${RESET} TCP\n" >&2
        printf "  ${BOLD}3)${RESET} WebSocket\n" >&2
        printf "请输入选项 [1/2/3]（默认: %s）: " "$default" >&2
        read -r choice </dev/tty

        case "${choice:-$default}" in
            1|udp|"") echo "udp"; return ;;
            2|tcp)   echo "tcp"; return ;;
            3|ws)    echo "ws";  return ;;
            *) warn "无效选项，请输入 1、2 或 3。" ;;
        esac
    done
}

# ----------------------------------------------------------------
# 交互：Web 控制台 - 公网 IP 地址（自动检测 + 手动确认/修改）
# ----------------------------------------------------------------
prompt_web_public_ip() {
    # 尝试自动获取公网 IP
    local detected_ip=""
    local methods=(
        "curl -s --max-time 5 ifconfig.me"
        "curl -s --max-time 5 ip.sb"
        "curl -s --max-time 5 ipinfo.io/ip"
        "wget -qO- --timeout=5 ifconfig.me"
    )

    for cmd in "${methods[@]}"; do
        detected_ip=$(eval "$cmd" 2>/dev/null | tr -d '[:space:]')
        if [[ "$detected_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        fi
        detected_ip=""
    done

    if [ -n "$detected_ip" ]; then
        echo -e "\n  检测到本机公网 IP: ${GREEN}${BOLD}${detected_ip}${RESET}" >&2
        printf "是否使用此地址？[${GREEN}Y/n${RESET}]（或直接输入新地址）: " >&2
        read -r ans </dev/tty
        ans="${ans:-Y}"
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            echo "$detected_ip"
            return
        fi
        # 用户输入了非 Y 的内容，当作手动 IP 继续处理
        if [ -n "$ans" ] && ! [[ "$ans" =~ ^[Nn]$ ]] && [[ "$ans" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            # 用户可能直接输入了IP
            echo "$ans"
            return
        fi
    else
        warn "未能自动检测到公网 IP，请手动输入。"
    fi

    # 手动输入
    while true; do
        printf "请输入服务器公网 IP 地址: " >&2
        read -r val </dev/tty
        if [ -z "$val" ]; then
            warn "公网 IP 不能为空。"
            continue
        fi
        if ! [[ "$val" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            warn "IP 格式无效，请重新输入。"
            continue
        fi
        echo "$val"
        return
    done
}


# ----------------------------------------------------------------
# 交互：配置文件模式 - 可选侦听端口（tcp/udp/ws/wss）
# 返回格式: "tcp:端口|udp:端口|ws:端口" （用 | 分隔）
# 某个协议直接回车=不设置；输入端口=开启侦听并自动启用转发
# ----------------------------------------------------------------
prompt_config_listen_ports() {
    local result=""

    echo -e "\n${BOLD}── 配置侦听端口（可选） ──${RESET}" >&2
    info "如需让其他节点通过此设备连接（中继转发），可配置侦听端口。"
    info "直接回车=不设置该协议；输入端口号=开启侦听并自动启用数据包转发。"
    echo -e "  参考默认: tcp/udp=${CYAN}11010${RESET}, ws=${CYAN}11011${RESET}, wss=${CYAN}11012${RESET}\n" >&2

    local val

    # TCP
    while true; do
        printf "  TCP  侦听端口 (直接回车=不设置): " >&2
        read -r val </dev/tty
        if [ -z "$val" ]; then break; fi
        if ! [[ "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ] || [ "$val" -gt 65535 ]; then
            warn "端口无效，请输入 1~65535 之间的整数。"
            continue
        fi
        result="${result:+$result|}tcp:$val"
        break
    done

    # UDP
    while true; do
        printf "  UDP  侦听端口 (直接回车=不设置): " >&2
        read -r val </dev/tty
        if [ -z "$val" ]; then break; fi
        if ! [[ "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ] || [ "$val" -gt 65535 ]; then
            warn "端口无效，请输入 1~65535 之间的整数。"
            continue
        fi
        result="${result:+$result|}udp:$val"
        break
    done

    # WS
    while true; do
        printf "  WS   侦听端口 (直接回车=不设置): " >&2
        read -r val </dev/tty
        if [ -z "$val" ]; then break; fi
        if ! [[ "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ] || [ "$val" -gt 65535 ]; then
            warn "端口无效，请输入 1~65535 之间的整数。"
            continue
        fi
        result="${result:+$result|}ws:$val"
        break
    done

    # WSS
    while true; do
        printf "  WSS  侦听端口 (直接回车=不设置): " >&2
        read -r val </dev/tty
        if [ -z "$val" ]; then break; fi
        if ! [[ "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ] || [ "$val" -gt 65535 ]; then
            warn "端口无效，请输入 1~65535 之间的整数。"
            continue
        fi
        result="${result:+$result|}wss:$val"
        break
    done

    if [ -z "$result" ]; then
        info "未配置任何侦听端口。"
    else
        info "已配置侦听: ${result}"
    fi
    echo "$result"
}

# ----------------------------------------------------------------
# 生成配置文件 /etc/easytier/easytier.yaml
# ----------------------------------------------------------------
write_config_file() {
    local hostname="$1"
    local network_name="$2"
    local network_secret="$3"
    local ipv4_mode="$4"   # "dhcp" 或具体 IP
    local peer_uri="$5"
    local proxy_cidr="$6"
    local encryption="$7"
    local listen_ports="${8:-}"  # 可选，格式: "tcp:11010|udp:11010|ws:11011"

    # 判断是否需要开启转发（只要配置了任意侦听端口就启用）
    local enable_relay="false"
    if [ -n "$listen_ports" ]; then
        enable_relay="true"
    fi

    mkdir -p "$(dirname "$CONFIG_FILE")"

    # 构建 listeners 数组内容
    local listeners_content="[]"
    if [ -n "$listen_ports" ]; then
        listeners_content="["
        IFS='|' read -ra LP <<< "$listen_ports"
        local first_lp=true
        for lp_entry in "${LP[@]}"; do
            [ -z "$lp_entry" ] && continue
            local proto="${lp_entry%%:*}"
            local port="${lp_entry##*:}"
            if $first_lp; then
                listeners_content+="\"${proto}://0.0.0.0:${port}\""
                first_lp=false
            else
                listeners_content+=", \"${proto}://0.0.0.0:${port}\""
            fi
        done
        listeners_content+="]"
    fi

    # 写入配置（TOML 格式）
    cat > "$CONFIG_FILE" <<EOF
# EasyTier 配置文件，由 easytier.sh 自动生成
# 如需手动修改，建议先备份

hostname = "${hostname}"
ipv4 = "${ipv4_mode}"
dhcp = $([ "$ipv4_mode" = "dhcp" ] && echo "true" || echo "false")
listeners = ${listeners_content}
relay_network_whitelist = "*"
relay_all_peer_rpc = ${enable_relay}

[network_identity]
network_name = "${network_name}"
network_secret = "${network_secret}"
EOF

    # peer URI（可选，支持多个）
    if [ -n "$peer_uri" ]; then
        IFS='|' read -ra PEERS <<< "$peer_uri"
        local first_peer=true
        for p in "${PEERS[@]}"; do
            [ -z "$p" ] && continue
            if $first_peer; then
                cat >> "$CONFIG_FILE" <<EOF

[[peer]]
uri = "${p}"
EOF
                first_peer=false
            else
                cat >> "$CONFIG_FILE" <<EOF

[[peer]]
uri = "${p}"
EOF
            fi
        done
    fi

    # 子网代理（可选，支持多个）
    if [ -n "$proxy_cidr" ]; then
        if [[ "$proxy_cidr" == *"|"* ]]; then
            # 多个子网代理（用 | 分隔）
            IFS='|' read -ra PROXIES <<< "$proxy_cidr"
            local first_proxy=true
            for p in "${PROXIES[@]}"; do
                [ -z "$p" ] && continue
                cat >> "$CONFIG_FILE" <<EOF

[[proxy_network]]
cidr = "${p}"
EOF
            done
        else
            # 单个子网代理
            cat >> "$CONFIG_FILE" <<EOF

[[proxy_network]]
cidr = "${proxy_cidr}"
EOF
        fi
    fi

    cat >> "$CONFIG_FILE" <<EOF

[flags]
enable_encryption = ${encryption}
default_protocol = "udp"
latency_first = true           # 延迟优先模式（默认开启）
use_physical_nic_only = true   # 仅使用物理网卡（默认开启）
multi_thread = true            # 启用多线程（默认开启）
EOF

    info "配置文件已写入: ${CONFIG_FILE}"
}

# ----------------------------------------------------------------
# 切换到 Web控制台模式（do_modify 辅助函数）
# ----------------------------------------------------------------
_do_switch_to_console_mode() {
    local username node_hostname console_addr
    username=$(prompt_username)
    node_hostname=$(prompt_hostname)
    console_addr=$(prompt_console)

    echo -e "\n${BOLD}${CYAN}──────── 修改确认 ────────${RESET}"
    echo -e "  新模式:   ${CYAN}Web控制台模式${RESET}"
    echo -e "  用户名:   ${CYAN}${username}${RESET}"
    echo -e "  机器名:   ${CYAN}${node_hostname}${RESET}"
    echo -e "  控制台:   ${CYAN}${console_addr}${RESET}"
    echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
    printf "${YELLOW}确认切换并重启服务？（配置文件将保留，不再使用）[Y/n]: ${RESET}" >&2
    read -r ans </dev/tty
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消。"; return 0; }

    # 不删除配置文件，保留以备后续切换回来使用
    apply_service "$MODE_CONSOLE" "$username" "$node_hostname" "$console_addr"
    show_status
}

# ----------------------------------------------------------------
# 切换到配置文件模式（do_modify 辅助函数）
# ----------------------------------------------------------------
_do_switch_to_config_mode() {
    info "直接回车可保留当前值。"

    local cfg_hostname cfg_netname cfg_netsec cfg_ip_mode cfg_peer cfg_proxy cfg_enc cfg_listen

    echo -e "\n${BOLD}── hostname ──${RESET}" >&2
    cfg_hostname=$(prompt_hostname)
    cfg_netname=$(prompt_network_name)
    cfg_netsec=$(prompt_network_secret)
    cfg_ip_mode=$(prompt_ipv4)
    cfg_peer=$(prompt_peer_uri)
    cfg_proxy=$(prompt_proxy_network)
    cfg_enc=$(prompt_encryption)
    cfg_listen=$(prompt_config_listen_ports)

    echo -e "\n${BOLD}${CYAN}──────── 修改确认 ────────${RESET}"
    echo -e "  新模式:   ${CYAN}客户端模式（配置文件）${RESET}"
    echo -e "  主机名:   ${CYAN}${cfg_hostname}${RESET}"
    echo -e "  网络名称: ${CYAN}${cfg_netname}${RESET}"
    echo -e "  网络密钥: ${CYAN}${cfg_netsec}${RESET}"
    echo -e "  IP 方式:  ${CYAN}${cfg_ip_mode}${RESET}"
    [ -n "$cfg_peer"   ] && echo -e "  节点地址: ${CYAN}${cfg_peer}${RESET}"
    [ -n "$cfg_proxy" ] && echo -e "  子网代理: ${CYAN}${cfg_proxy}${RESET}"
    [ -n "$cfg_listen"] && echo -e "  侦听端口: ${CYAN}${cfg_listen}${RESET}"
    echo -e "  启用加密: ${CYAN}${cfg_enc}${RESET}"
    echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
    printf "${YELLOW}确认切换并重启服务？[Y/n]: ${RESET}" >&2
    read -r ans </dev/tty
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消。"; return 0; }

    write_config_file "$cfg_hostname" "$cfg_netname" "$cfg_netsec" "$cfg_ip_mode" "$cfg_peer" "$cfg_proxy" "$cfg_enc" "$cfg_listen"
    apply_service "$MODE_CONSOLE_FILE"
    show_status
}

# ----------------------------------------------------------------
# 切换到服务端/中继模式（do_modify 辅助函数）
# ----------------------------------------------------------------
_do_switch_to_relay_mode() {
    info "直接回车可保留当前值。"

    echo -e "\n${BOLD}── 配置服务端信息 ──${RESET}" >&2
    local relay_hostname
    relay_hostname=$(prompt_relay_hostname)

    echo -e "\n${BOLD}── 配置侦听端口 ──${RESET}" >&2
    local ports_str tcp_port udp_port ws_port wss_port
    ports_str=$(prompt_listen_ports)
    read -r tcp_port udp_port ws_port wss_port <<< "$ports_str"

    local whitelist
    whitelist=$(prompt_relay_whitelist)

    echo -e "\n${BOLD}${CYAN}──────── 切换确认 ────────${RESET}"
    echo -e "  新模式:   ${CYAN}服务端/中继模式${RESET}"
    echo -e "  主机名:   ${CYAN}${relay_hostname}${RESET}"
    echo -e "  TCP 端口: ${CYAN}${tcp_port}${RESET}"
    echo -e "  UDP 端口: ${CYAN}${udp_port}${RESET}"
    echo -e "  WS  端口: ${CYAN}${ws_port}${RESET}"
    echo -e "  WSS 端口: ${CYAN}${wss_port}${RESET}"
    echo -e "  白名单:   ${CYAN}${whitelist}${RESET}"
    echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
    printf "${YELLOW}确认切换并重启服务？（配置文件将保留，不再使用）[Y/n]: ${RESET}" >&2
    read -r ans </dev/tty
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消。"; return 0; }

    # 不删除配置文件，保留以备后续切换回来使用
    apply_service "$MODE_RELAY" "$relay_hostname" "$tcp_port" "$udp_port" "$ws_port" "$wss_port" "$whitelist"
    show_status
}

# ----------------------------------------------------------------
# 交互：服务端模式 - 输入 hostname
# ----------------------------------------------------------------
prompt_relay_hostname() {
    local cur_val default
    cur_val=$(read_current_relay_hostname)
    # 默认值优先用已有配置，其次用系统机器名
    default="${cur_val:-$(hostname -s 2>/dev/null || echo "")}"

    while true; do
        if [ -n "$default" ]; then
            printf "请输入节点主机名 (默认: ${CYAN}%s${RESET}，直接回车使用默认值): " "$default" >&2
        else
            printf "请输入节点主机名 (例: relay-server-01): " >&2
        fi
        read -r val </dev/tty
        val="${val:-$default}"
        if [ -z "$val" ]; then
            warn "主机名不能为空，请重新输入。"
            continue
        fi
        if [[ "$val" =~ [[:space:]/\\] ]]; then
            warn "主机名不能包含空格或斜杠，请重新输入。"
            continue
        fi
        echo "$val"
        return
    done
}

# ----------------------------------------------------------------
# 交互：服务端模式 - 配置侦听端口
# ----------------------------------------------------------------
# 各协议侦听端口默认值
# tcp/udp: 11010（建议保持相同），ws: 11011，wss: 11012
readonly DEFAULT_TCP_PORT="11010"
readonly DEFAULT_UDP_PORT="11010"
readonly DEFAULT_WS_PORT="11011"
readonly DEFAULT_WSS_PORT="11012"

prompt_listen_ports() {
    local cur_tcp cur_udp cur_ws cur_wss
    cur_tcp=$(read_current_relay_port "tcp")
    cur_udp=$(read_current_relay_port "udp")
    cur_ws=$(read_current_relay_port "ws")
    cur_wss=$(read_current_relay_port "wss")

    local tcp_port udp_port ws_port wss_port

    info "以下为各协议侦听端口，直接回车使用括号内的默认/当前值。"
    echo -e "  (默认: tcp/udp=${DEFAULT_TCP_PORT}，建议相同；ws=${DEFAULT_WS_PORT}；wss=${DEFAULT_WSS_PORT})\n" >&2

    # TCP
    local tcp_def="${cur_tcp:-$DEFAULT_TCP_PORT}"
    while true; do
        printf "  TCP  侦听端口 [默认: ${CYAN}%s${RESET}]: " "$tcp_def" >&2
        read -r tcp_port </dev/tty
        tcp_port="${tcp_port:-$tcp_def}"
        if ! [[ "$tcp_port" =~ ^[0-9]+$ ]] || [ "$tcp_port" -lt 1 ] || [ "$tcp_port" -gt 65535 ]; then
            warn "端口无效，请输入 1~65535 之间的整数。"
            continue
        fi
        break
    done

    # UDP
    local udp_def="${cur_udp:-$DEFAULT_UDP_PORT}"
    while true; do
        printf "  UDP  侦听端口 [默认: ${CYAN}%s${RESET}]: " "$udp_def" >&2
        read -r udp_port </dev/tty
        udp_port="${udp_port:-$udp_def}"
        if ! [[ "$udp_port" =~ ^[0-9]+$ ]] || [ "$udp_port" -lt 1 ] || [ "$udp_port" -gt 65535 ]; then
            warn "端口无效，请输入 1~65535 之间的整数。"
            continue
        fi
        break
    done

    # WS
    local ws_def="${cur_ws:-$DEFAULT_WS_PORT}"
    while true; do
        printf "  WS   侦听端口 [默认: ${CYAN}%s${RESET}]: " "$ws_def" >&2
        read -r ws_port </dev/tty
        ws_port="${ws_port:-$ws_def}"
        if ! [[ "$ws_port" =~ ^[0-9]+$ ]] || [ "$ws_port" -lt 1 ] || [ "$ws_port" -gt 65535 ]; then
            warn "端口无效，请输入 1~65535 之间的整数。"
            continue
        fi
        break
    done

    # WSS
    local wss_def="${cur_wss:-$DEFAULT_WSS_PORT}"
    while true; do
        printf "  WSS  侦听端口 [默认: ${CYAN}%s${RESET}]: " "$wss_def" >&2
        read -r wss_port </dev/tty
        wss_port="${wss_port:-$wss_def}"
        if ! [[ "$wss_port" =~ ^[0-9]+$ ]] || [ "$wss_port" -lt 1 ] || [ "$wss_port" -gt 65535 ]; then
            warn "端口无效，请输入 1~65535 之间的整数。"
            continue
        fi
        break
    done

    # 以空格分隔输出四个端口，由调用方拆分
    echo "${tcp_port} ${udp_port} ${ws_port} ${wss_port}"
}

# ----------------------------------------------------------------
# 交互：服务端模式 - 配置中继网络白名单
# 白名单决定哪些网络可以经由本节点中继转发
# ----------------------------------------------------------------
prompt_relay_whitelist() {
    local cur_val default val ans
    cur_val=$(read_current_relay_whitelist)
    default="${cur_val:-}"

    echo -e "\n${BOLD}── 配置中继网络白名单 ──${RESET}" >&2
    echo -e "  ${YELLOW}白名单决定哪些网络可经由本节点中继转发。${RESET}" >&2
    echo -e "  ${YELLOW}填具体网络名（多个用空格分隔）；填 * 表示允许任意网络，${RESET}" >&2
    echo -e "  ${YELLOW}但公网带宽将被任意第三方使用，请谨慎。${RESET}\n" >&2

    while true; do
        if [ -n "$default" ]; then
            printf "允许中继的网络名 [当前: ${CYAN}%s${RESET}，直接回车保留]: " "$default" >&2
        else
            printf "允许中继的网络名: " >&2
        fi
        read -r val </dev/tty
        val="${val:-$default}"

        if [ -z "$val" ]; then
            warn "白名单不能为空。请输入网络名，或输入 * 允许所有网络。"
            continue
        fi

        if [ "$val" = "*" ]; then
            echo "" >&2
            warn "已选择允许任意网络中继！"
            echo -e "  ${YELLOW}任何人都可使用本节点的公网带宽与流量，且可能被用于非法用途。${RESET}" >&2
            printf "  ${YELLOW}确认继续？[y/N]: ${RESET}" >&2
            read -r ans </dev/tty
            if [[ ! "$ans" =~ ^[Yy]$ ]]; then
                echo "" >&2
                continue
            fi
        fi

        echo "$val"
        return 0
    done
}

# ----------------------------------------------------------------
# 交互：选择版本
# ----------------------------------------------------------------
prompt_version() {
    local choice ver

    while true; do
        printf "\n请选择要安装的 EasyTier 版本:\n" >&2
        printf "  ${BOLD}1)${RESET} v2.6.4（最新版，默认）\n" >&2
        printf "  ${BOLD}2)${RESET} v2.4.5（稳定版）\n" >&2
        printf "  ${BOLD}3)${RESET} 手动输入版本号\n" >&2
        printf "请输入选项 [1/2/3]（默认: 1）: " >&2
        read -r choice </dev/tty
        choice="${choice:-1}"

        case "$choice" in
            1) ver="v2.6.4"; break ;;
            2) ver="v2.4.5"; break ;;
            3)
                while true; do
                    printf "请输入版本号（不带 v，例如 2.5.1）: " >&2
                    read -r ver </dev/tty
                    if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        ver="v${ver}"
                        break
                    else
                        warn "版本号格式无效（需为 X.Y.Z，如 2.5.1），请重新输入。"
                    fi
                done
                break
                ;;
            *) warn "无效选项 '${choice}'，请输入 1、2 或 3。" ;;
        esac
    done

    info "已选择版本: ${ver}"
    echo "$ver"
}

# ----------------------------------------------------------------
# 交互：选择下载方式
# ----------------------------------------------------------------
prompt_download_method() {
    local choice

    while true; do
        printf "\n请选择下载方式:\n" >&2
        printf "  ${BOLD}1)${RESET} 本地镜像服务器（默认，推荐，速度快）\n" >&2
        printf "     地址: ${BLUE}${LOCAL_MIRROR}${RESET}\n" >&2
        printf "  ${BOLD}2)${RESET} GitHub 代理下载（ghfast.top / gh-proxy.com / ghproxylist.com / mirror.ghproxy.com）\n" >&2
        printf "  ${BOLD}3)${RESET} 直接从 GitHub 下载（需能直连 github.com）\n" >&2
        printf "请输入选项 [1/2/3]（默认: 1）: " >&2
        read -r choice </dev/tty
        choice="${choice:-1}"

        case "$choice" in
            1) echo "local";  return 0 ;;
            2) echo "proxy";  return 0 ;;
            3) echo "direct"; return 0 ;;
            *) warn "无效选项 '${choice}'，请输入 1、2 或 3。" ;;
        esac
    done
}

# ----------------------------------------------------------------
# 下载：本地镜像
# ----------------------------------------------------------------
download_from_local() {
    local rel_path="$1"
    local output="$2"
    local url="${LOCAL_MIRROR}/${rel_path}"

    info "从本地镜像下载: ${url}"
    if wget -q --timeout=15 -O "$output" "$url" 2>/dev/null; then
        info "本地镜像下载成功。"
        return 0
    fi
    error "本地镜像下载失败，请检查网络或服务器状态。"
    return 1
}

# ----------------------------------------------------------------
# 下载：GitHub 代理
# ----------------------------------------------------------------
download_from_proxy() {
    local github_url="$1"
    local output="$2"

    for proxy in "${PROXY_LIST[@]}"; do
        info "尝试代理: ${proxy}"
        if wget -q --timeout=15 -O "$output" "${proxy}${github_url}" 2>/dev/null; then
            info "代理下载成功: ${proxy}"
            return 0
        fi
        warn "代理 ${proxy} 失败，尝试下一个..."
    done

    error "所有代理均失败，请检查网络或改用本地镜像下载。"
    return 1
}

# ----------------------------------------------------------------
# 下载：直连 GitHub
# ----------------------------------------------------------------
download_from_github_direct() {
    local github_url="$1"
    local output="$2"

    info "直接从 GitHub 下载: ${github_url}"
    if wget -q --timeout=15 -O "$output" "$github_url" 2>/dev/null; then
        info "GitHub 直接下载成功。"
        return 0
    fi
    error "GitHub 直接下载失败，请确认网络可直连 github.com，或改用其他下载方式。"
    return 1
}

# ----------------------------------------------------------------
# 下载并解压 EasyTier
# ----------------------------------------------------------------
download_and_extract() {
    local arch="$1"
    local version="$2"
    local download_method="$3"
    local base_name="easytier-linux-${arch}"
    local zip_name="${base_name}-${version}.zip"
    local rel_path="${version}/${zip_name}"
    local github_url="https://github.com/EasyTier/EasyTier/releases/download/${rel_path}"

    title "下载 EasyTier ${version} (${arch})"

    if [ "$download_method" = "local" ]; then
        download_from_local "$rel_path" "$TMP_ZIP"
    elif [ "$download_method" = "proxy" ]; then
        download_from_proxy "$github_url" "$TMP_ZIP"
    else
        download_from_github_direct "$github_url" "$TMP_ZIP"
    fi

    title "解压文件"
    mkdir -p "$INSTALL_DIR"
    unzip -o "$TMP_ZIP" -d "$INSTALL_DIR/" >&2

    local sub_dir="${INSTALL_DIR}/${base_name}"
    if [ -d "$sub_dir" ]; then
        local file_count
        file_count=$(find "$sub_dir" -maxdepth 1 -mindepth 1 | wc -l)
        if [ "$file_count" -gt 0 ]; then
            find "$sub_dir" -maxdepth 1 -mindepth 1 -exec mv -t "$INSTALL_DIR/" {} +
        fi
        rmdir "$sub_dir" 2>/dev/null || true
    else
        warn "未找到预期子目录 ${sub_dir}，请手动检查 ${INSTALL_DIR}"
    fi

    for bin in easytier-core easytier-cli; do
        if [ ! -f "${INSTALL_DIR}/${bin}" ]; then
            error "解压后未找到 ${bin}，安装包可能损坏。"
            return 1
        fi
    done
    chmod +x "${INSTALL_DIR}/easytier-core" "${INSTALL_DIR}/easytier-cli"
    info "EasyTier 文件准备完成。"
}

# ----------------------------------------------------------------
# 下载 easytier-web-embed（从与 easytier-core 相同的 zip 包中提取）
# ----------------------------------------------------------------
download_web_embed() {
    local version="$1"
    local download_method="$2"
    local arch
    arch=$(get_arch)

    local base_name="easytier-linux-${arch}"
    local zip_name="${base_name}-${version}.zip"
    local rel_path="${version}/${zip_name}"
    local github_url="https://github.com/EasyTier/EasyTier/releases/download/${rel_path}"
    local web_embed_in_zip="${base_name}/easytier-web-embed"

    title "下载 EasyTier Web 控制台 (${arch})"

    if [ "$download_method" = "local" ]; then
        download_from_local "$rel_path" "$TMP_ZIP"
    elif [ "$download_method" = "proxy" ]; then
        download_from_proxy "$github_url" "$TMP_ZIP"
    else
        download_from_github_direct "$github_url" "$TMP_ZIP"
    fi

    # 从 zip 中只提取 web-embed 二进制文件
    title "提取 Web 控制台程序"
    if unzip -o "$TMP_ZIP" "$web_embed_in_zip" -d "$INSTALL_DIR/" >&2; then
        mv "${INSTALL_DIR}/${web_embed_in_zip}" "$WEB_EMBED_BINARY"
        chmod +x "$WEB_EMBED_BINARY"
        info "Web 控制台程序已安装: ${WEB_EMBED_BINARY}"
    else
        error "无法从 zip 包中提取 easytier-web-embed，请确认该版本包含 Web 控制台组件。"
        return 1
    fi
}

# ----------------------------------------------------------------
# 生成内存护栏配置段（MemoryHigh / MemoryMax）
# MemoryHigh 为软限（超限仅节流与回收，不杀进程），MemoryMax 为硬限（超限 OOM）
# 仅在 cgroup v2 且启用 memory 控制器时输出，避免旧系统/容器因不支持而启动失败
# ----------------------------------------------------------------
memory_limit_block() {
    [ -f /sys/fs/cgroup/cgroup.controllers ] || return 0
    grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null || return 0

    local mem_mb max_mb high_mb
    mem_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    [ "$mem_mb" -gt 0 ] || return 0

    max_mb=$(( mem_mb / MEM_LIMIT_RATIO ))
    [ "$max_mb" -lt "$MEM_LIMIT_MIN_MB" ] && max_mb="$MEM_LIMIT_MIN_MB"
    [ "$max_mb" -gt "$MEM_LIMIT_MAX_MB" ] && max_mb="$MEM_LIMIT_MAX_MB"
    high_mb=$(( max_mb * MEM_HIGH_PERCENT / 100 ))

    printf 'MemoryHigh=%sM\nMemoryMax=%sM\n' "$high_mb" "$max_mb"
}

# ----------------------------------------------------------------
# 生成 systemd 服务内容
# ----------------------------------------------------------------
generate_service() {
    local mode="$1"

    if [ "$mode" = "$MODE_RELAY" ]; then
        local relay_hostname="$2"
        local tcp_port="$3"
        local udp_port="$4"
        local ws_port="$5"
        local wss_port="$6"
        local whitelist="$7"
        cat <<EOF
[Unit]
Description=EasyTier Relay Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/easytier-core \
  --hostname "${relay_hostname}" \
  --listeners "tcp://0.0.0.0:${tcp_port}" "udp://0.0.0.0:${udp_port}" "ws://0.0.0.0:${ws_port}" "wss://0.0.0.0:${wss_port}" \
  --relay-network-whitelist "${whitelist}" \
  --relay-all-peer-rpc
Restart=on-failure
RestartSec=10
TimeoutStopSec=20
Environment=RUST_LOG=${RUST_LOG_LEVEL}
LogLevelMax=info
LimitNOFILE=65535
$(memory_limit_block)
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF
    elif [ "$mode" = "$MODE_CONSOLE_FILE" ]; then
        # 配置文件模式，仅指定 -c 参数
        cat <<EOF
[Unit]
Description=EasyTier Service (Config File Mode)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/easytier-core -c "${CONFIG_FILE}"
Restart=on-failure
RestartSec=10
TimeoutStopSec=20
Environment=RUST_LOG=${RUST_LOG_LEVEL}
LogLevelMax=info
LimitNOFILE=65535
$(memory_limit_block)
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF
    else
        # 配置服务器模式 (CLI 参数，使用 -w/--config-server)
        local username="$2"
        local node_hostname="$3"
        local console_addr="$4"
        cat <<EOF
[Unit]
Description=EasyTier Service (Config Server Mode)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/easytier-core -w "${console_addr}/${username}" --hostname "${node_hostname}"
Restart=on-failure
RestartSec=10
TimeoutStopSec=20
Environment=RUST_LOG=${RUST_LOG_LEVEL}
LogLevelMax=info
LimitNOFILE=65535
$(memory_limit_block)
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF
    fi
}

# ----------------------------------------------------------------
# 写入服务文件并重载
# ----------------------------------------------------------------
apply_service() {
    local mode="$1"
    shift
    # relay 模式：无后续参数；console 模式：username node_hostname console_addr
    generate_service "$mode" "$@" > "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" 2>&1 | while IFS= read -r line; do
        info "$line"
    done
    systemctl restart "$SERVICE_NAME" 2>/dev/null
}

# ----------------------------------------------------------------
# 生成 Web 控制台 systemd 服务内容
# ----------------------------------------------------------------
generate_web_service() {
    local http_port="$1"
    local console_port="$2"
    local console_proto="$3"
    local public_ip="$4"

    cat <<EOF
[Unit]
Description=EasyTier Web Console Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${WEB_EMBED_BINARY} \
  -d "${WEB_DB_DIR}/et.db" \
  -l ${http_port} \
  -c ${console_port} \
  -p ${console_proto} \
  --api-host "http://${public_ip}:${http_port}"
Restart=on-failure
RestartSec=10
TimeoutStopSec=20
Environment=RUST_LOG=${RUST_LOG_LEVEL}
LogLevelMax=info
LimitNOFILE=65535
$(memory_limit_block)
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${WEB_SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF
}

# ----------------------------------------------------------------
# 写入 Web 服务文件并启动
# ----------------------------------------------------------------
apply_web_service() {
    local http_port="$1"
    local console_port="$2"
    local console_proto="$3"
    local public_ip="$4"

    generate_web_service "$http_port" "$console_port" "$console_proto" "$public_ip" > "$WEB_SERVICE_FILE"
    mkdir -p "$WEB_DB_DIR"
    systemctl daemon-reload
    systemctl enable "$WEB_SERVICE_NAME" 2>&1 | while IFS= read -r line; do
        info "$line"
    done
    systemctl restart "$WEB_SERVICE_NAME" 2>/dev/null
}

# ----------------------------------------------------------------
# 显示最近日志并判断启动状态
# ----------------------------------------------------------------
show_status() {
    local wait_sec=3
    info "等待服务启动（${wait_sec}s）..."
    sleep "$wait_sec"

    echo -e "\n${BOLD}────────── 最近 15 条日志 ──────────${RESET}" >&2
    local boot_logs
    boot_logs=$(journalctl -u "${SERVICE_NAME}.service" -n 15 --no-pager 2>/dev/null || true)
    if [ -n "$boot_logs" ]; then
        echo "$boot_logs" >&2
    else
        echo -e "  ${YELLOW}（无日志输出）${RESET}" >&2
        if [ "${RUST_LOG_LEVEL}" = "warn" ]; then
            echo -e "  ${YELLOW}日志级别为 warn，无警告/错误时不产生日志，属正常。${RESET}" >&2
        else
            echo -e "  ${YELLOW}日志级别为 ${RUST_LOG_LEVEL}，正常启动应有输出，此处为空请确认服务是否真正运行。${RESET}" >&2
        fi
    fi
    echo -e "${BOLD}────────────────────────────────────${RESET}\n" >&2

    local svc_active
    svc_active=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)

    if [ "$svc_active" != "active" ]; then
        echo -e "${RED}${BOLD}✗ 操作失败${RESET}" >&2
        error "服务状态异常（systemctl 报告: ${svc_active}），请检查上方日志。"
        info  "可运行以下命令查看完整日志:"
        echo  "    journalctl -xe -u ${SERVICE_NAME}.service" >&2
        if [ "${RUST_LOG_LEVEL}" = "warn" ] && [ -z "$boot_logs" ]; then
            warn "日志为空，可能是 ${RUST_LOG_LEVEL} 级别过滤掉了启动细节。排障建议:"
            echo  "    systemctl edit ${SERVICE_NAME}    # 加入 [Service] 与 Environment=RUST_LOG=info" >&2
            echo  "    systemctl restart ${SERVICE_NAME} 后重新查看日志，定位后改回 ${RUST_LOG_LEVEL}" >&2
        fi
        return 1
    fi

    local logs logs_lower
    logs=$(journalctl -u "${SERVICE_NAME}.service" -n 15 --no-pager 2>/dev/null || true)
    logs_lower=$(echo "$logs" | tr '[:upper:]' '[:lower:]')

    local warn_patterns=("refused" "timeout" "unable to" "no such file" "permission denied" "address already in use")
    for pat in "${warn_patterns[@]}"; do
        if echo "$logs_lower" | grep -q "$pat"; then
            warn "日志中检测到异常关键字 \"${pat}\"，服务虽在运行但请确认连接状态。"
            info "可运行以下命令查看完整日志:"
            echo "    journalctl -xe -u ${SERVICE_NAME}.service" >&2
            return 0
        fi
    done

    echo -e "${GREEN}${BOLD}✓ 操作成功，服务运行正常！${RESET}" >&2

    # 显示当前配置信息
    local cur_mode cur_console cur_user cur_hostname
    cur_mode=$(read_current_mode)
    cur_console=$(read_current_config)
    cur_user=$(read_current_username)
    cur_hostname=$(read_current_hostname)

    if [ -n "$cur_mode" ]; then
        echo -e "\n${BOLD}────────── 当前配置信息 ──────────${RESET}" >&2
        if [ "$cur_mode" = "$MODE_RELAY" ]; then
            echo -e "  ${CYAN}服务端/中继模式${RESET}" >&2
            [ -n "$cur_hostname" ] && echo -e "  主机名:   ${CYAN}${cur_hostname}${RESET}" >&2
        elif [ "$cur_mode" = "$MODE_CONSOLE_FILE" ]; then
            echo -e "  模式:     ${CYAN}客户端模式（配置文件）${RESET}" >&2
            [ -n "$cur_hostname" ] && echo -e "  主机名:   ${CYAN}${cur_hostname}${RESET}" >&2
        else
            echo -e "  模式:     ${CYAN}Web控制台模式${RESET}" >&2
            [ -n "$cur_console" ] && echo -e "  控制台:   ${CYAN}${cur_console}${RESET}" >&2
            [ -n "$cur_user" ] && echo -e "  用户名:   ${CYAN}${cur_user}${RESET}" >&2
            [ -n "$cur_hostname" ] && echo -e "  主机名:   ${CYAN}${cur_hostname}${RESET}" >&2
        fi
        echo -e "${BOLD}────────────────────────────────────${RESET}\n" >&2
    fi

    success "EasyTier 已成功连接并启动。"
    info "如需持续监控日志，运行:"
    echo "    journalctl -f -u ${SERVICE_NAME}.service" >&2
    if [ "${RUST_LOG_LEVEL}" = "warn" ]; then
        echo -e "  ${YELLOW}注：日志级别为 warn，运行正常时几乎没有输出。${RESET}" >&2
        echo -e "  ${YELLOW}    排查连接问题时可临时调高：systemctl edit ${SERVICE_NAME}${RESET}" >&2
        echo -e "  ${YELLOW}    加入 [Service] 与 Environment=RUST_LOG=info，改回后删掉即可${RESET}" >&2
    else
        echo -e "  ${YELLOW}注：日志级别为 ${RUST_LOG_LEVEL}，日志量受 journald 配额保护（默认磁盘 10%，上限 4G），不会撑爆磁盘。${RESET}" >&2
        echo -e "  ${YELLOW}    查看本服务占用：journalctl -u ${SERVICE_NAME} --disk-usage${RESET}" >&2
    fi

    # 如果 easytier-web 服务也在运行，显示其信息
    if systemctl is-active "$WEB_SERVICE_NAME" &>/dev/null; then
        echo -e "\n${BOLD}${CYAN}──────────────────────────────────${RESET}" >&2
        echo -e "${BOLD}────────── Web 控制台状态 ──────────${RESET}" >&2
        echo -e "  服务状态: ${GREEN}${BOLD}运行中 ✓${RESET}" >&2
        read_web_console_info >&2
        echo -e "${BOLD}${CYAN}──────────────────────────────────${RESET}\n" >&2
    fi
}

# ----------------------------------------------------------------
# 交互式日志查看（Ctrl+C 返回主菜单）
# ----------------------------------------------------------------
watch_logs() {
    echo -e "\n${BOLD}────────── 实时日志监控 ──────────${RESET}" >&2
    if [ "${RUST_LOG_LEVEL}" = "warn" ]; then
        echo -e "  ${YELLOW}日志级别为 warn，无警告/错误时不会刷新内容，并非卡住。${RESET}" >&2
        echo -e "  ${YELLOW}想看连接详情请先用 systemctl edit ${SERVICE_NAME} 调高到 info${RESET}" >&2
    fi
    echo -e "  ${GREEN}按 ${BOLD}Ctrl+C${RESET}${GREEN} 返回主菜单${RESET}" >&2
    echo -e "${BOLD}────────────────────────────────────${RESET}\n" >&2

    # 使用 trap 捕获 Ctrl+C
    trap 'echo -e "\n${YELLOW}已退出日志监控，返回主菜单...${RESET}" >&2; trap - INT; return 0' INT

    # 实时查看日志
    journalctl -f -u "${SERVICE_NAME}.service" --no-pager
}

# ================================================================
# 操作：全新安装
# ----------------------------------------------------------------
# 已有程序文件时，提示用户选择下一步操作
# 检测目录：INSTALL_DIR 下的 easytier-core 和 easytier-web-embed
# 返回值：
#   use       → 使用已有文件，跳过下载
#   download  → 重新下载
#   cancel     → 取消安装
# ----------------------------------------------------------------
prompt_existing_binary_choice() {
    echo -e "
${YELLOW}⚠  检测到安装目录 ${CYAN}${INSTALL_DIR}${YELLOW} 中已有程序文件。${RESET}"
    echo -e "${YELLOW}   全新安装将会覆盖现有程序。${RESET}
"
    echo -e "${BOLD}请选择：${RESET}"
    echo -e "  ${CYAN}1)${RESET} 使用已有程序文件（跳过下载，推荐）"
    echo -e "  ${CYAN}2)${RESET} 重新下载并覆盖"
    echo -e "  ${CYAN}3)${RESET} 取消安装
"
    printf "${YELLOW}请输入选项 [1/2/3]（默认: 1）: ${RESET}" >&2
    local ans
    read -r ans </dev/tty
    case "${ans:-1}" in
        1) echo "use" ;;
        2) echo "download" ;;
        *) echo "cancel" ;;
    esac
}

# ================================================================
do_install() {
    local mode="${1:-}"

    # 中继/服务端模式
    if [ "$mode" = "$MODE_RELAY" ]; then
        title "EasyTier 服务端/中继模式安装"

        local choice="download"
        if [ -f "${INSTALL_DIR}/easytier-core" ]; then
            choice=$(prompt_existing_binary_choice)
            [[ "$choice" = "cancel" ]] && { info "已取消安装。"; return 0; }
        fi

        local version dm_label
        if [[ "$choice" = "download" ]]; then
            echo -e "\n${BOLD}── 第 1 步：选择版本 ──${RESET}" >&2
            version=$(prompt_version)

            echo -e "\n${BOLD}── 第 2 步：选择下载方式 ──${RESET}" >&2
            local download_method
            download_method=$(prompt_download_method)
            case "$download_method" in
                local)  dm_label="本地镜像" ;;
                proxy)  dm_label="GitHub 代理" ;;
                direct) dm_label="GitHub 直连" ;;
            esac
        else
            # use existing：读取已有文件的版本信息展示
            version=$("${INSTALL_DIR}/easytier-core" --version 2>/dev/null | head -1 || echo "未知")
            dm_label="（使用已有程序）"
        fi

        echo -e "\n${BOLD}── 第 3 步：配置服务端信息 ──${RESET}" >&2
        info "主机名将显示在 EasyTier 网络拓扑中，默认使用本机系统名。"
        local relay_hostname
        relay_hostname=$(prompt_relay_hostname)

        echo -e "\n${BOLD}── 第 4 步：配置侦听端口 ──${RESET}" >&2
        info "服务端需要对外开放以下端口，建议在防火墙/安全组中放行对应端口。"
        local ports_str tcp_port udp_port ws_port wss_port
        ports_str=$(prompt_listen_ports)
        read -r tcp_port udp_port ws_port wss_port <<< "$ports_str"

        echo -e "\n${BOLD}── 第 5 步：配置中继白名单 ──${RESET}" >&2
        local whitelist
        whitelist=$(prompt_relay_whitelist)

        echo -e "\n${BOLD}${CYAN}──────── 安装确认 ────────${RESET}"
        echo -e "  模式:     ${CYAN}服务端/中继模式${RESET}（不连接控制台）"
        echo -e "  版本:     ${CYAN}${version}${RESET}"
        echo -e "  下载方式: ${CYAN}${dm_label}${RESET}"
        echo -e "  主机名:   ${CYAN}${relay_hostname}${RESET}"
        echo -e "  TCP 端口: ${CYAN}${tcp_port}${RESET}"
        echo -e "  UDP 端口: ${CYAN}${udp_port}${RESET}"
        echo -e "  WS  端口: ${CYAN}${ws_port}${RESET}"
        echo -e "  WSS 端口: ${CYAN}${wss_port}${RESET}"
        echo -e "  白名单:   ${CYAN}${whitelist}${RESET}"
        echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
        printf "${YELLOW}确认安装？[Y/n]: ${RESET}" >&2
        read -r ans </dev/tty
        ans="${ans:-Y}"
        [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消安装。"; return 0; }

        info "模式: 服务端/中继 | 版本: $version | 架构: $ARCH | 下载方式: ${dm_label}"
        if [[ "$choice" = "download" ]]; then
            [ -d "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR"
            download_and_extract "$ARCH" "$version" "$download_method"
        fi
        apply_service "$MODE_RELAY" "$relay_hostname" "$tcp_port" "$udp_port" "$ws_port" "$wss_port" "$whitelist"
        show_status
        return
    fi

    # 客户端模式（连接控制台）
    title "EasyTier 客户端模式安装"

    local choice="download"
    if [ -f "${INSTALL_DIR}/easytier-core" ]; then
        choice=$(prompt_existing_binary_choice)
        [[ "$choice" = "cancel" ]] && { info "已取消安装。"; return 0; }
    fi

    echo -e "\n${BOLD}── 第 1 步：选择安装方式 ──${RESET}" >&2
    local install_method
    while true; do
        printf "请选择客户端安装方式:\n" >&2
        printf "  ${BOLD}1)${RESET} Web控制台模式（输入用户名、机器名、控制台地址）\n" >&2
        printf "  ${BOLD}2)${RESET} 配置文件模式（输入网络名称、密钥、节点地址等，写入 YAML）\n" >&2
        printf "请输入选项 [1/2]（默认: 1）: " >&2
        read -r install_method </dev/tty
        install_method="${install_method:-1}"
        case "$install_method" in
            1|2) break ;;
            *) warn "无效选项，请输入 1 或 2。" ;;
        esac
    done

    echo -e "\n${BOLD}── 第 2 步：选择版本 ──${RESET}" >&2
    local version dm_label
    if [[ "$choice" = "download" ]]; then
        version=$(prompt_version)

        echo -e "\n${BOLD}── 第 3 步：选择下载方式 ──${RESET}" >&2
        local download_method
        download_method=$(prompt_download_method)
        case "$download_method" in
            local)  dm_label="本地镜像" ;;
            proxy)  dm_label="GitHub 代理" ;;
            direct) dm_label="GitHub 直连" ;;
        esac
    else
        version=$("${INSTALL_DIR}/easytier-core" --version 2>/dev/null | head -1 || echo "未知")
        dm_label="（使用已有程序）"
    fi

    # ── 方式 2：配置文件模式 ──
    if [ "$install_method" = "2" ]; then
        echo -e "\n${BOLD}── 第 4 步：配置网络信息 ──${RESET}" >&2

        info "hostname：用于在网络中标识此节点，默认使用本机系统名。"
        local cfg_hostname
        cfg_hostname=$(prompt_hostname)

        local cfg_netname
        cfg_netname=$(prompt_network_name)

        local cfg_netsec
        cfg_netsec=$(prompt_network_secret)

        local cfg_ip_mode
        cfg_ip_mode=$(prompt_ipv4)

        echo -e "\n${BOLD}── 第 5 步：配置节点服务器地址 ──${RESET}" >&2
        info "peer URI：节点服务器的网络地址，留空则从控制台自动获取。"
        local cfg_peer
        cfg_peer=$(prompt_peer_uri)

        echo -e "\n${BOLD}── 第 6 步：配置子网代理（可选） ──${RESET}" >&2
        local cfg_proxy
        cfg_proxy=$(prompt_proxy_network)
        [ -n "$cfg_proxy" ] && info "将代理本地网段: ${cfg_proxy}"

        echo -e "\n${BOLD}── 第 7 步：加密设置 ──${RESET}" >&2
        local cfg_enc
        cfg_enc=$(prompt_encryption)

        echo -e "\n${BOLD}── 第 8 步：配置侦听端口（可选） ──${RESET}" >&2
        local cfg_listen
        cfg_listen=$(prompt_config_listen_ports)

        echo -e "\n${BOLD}${CYAN}──────── 安装确认 ────────${RESET}"
        echo -e "  模式:     ${CYAN}客户端模式（配置文件）${RESET}"
        echo -e "  版本:     ${CYAN}${version}${RESET}"
        echo -e "  下载方式: ${CYAN}${dm_label}${RESET}"
        echo -e "  主机名:   ${CYAN}${cfg_hostname}${RESET}"
        echo -e "  网络名称: ${CYAN}${cfg_netname}${RESET}"
        echo -e "  网络密钥: ${CYAN}${cfg_netsec}${RESET}"
        echo -e "  IP 方式:  ${CYAN}${cfg_ip_mode}${RESET}"
        [ -n "$cfg_peer"   ] && echo -e "  节点地址: ${CYAN}${cfg_peer}${RESET}"
        [ -n "$cfg_proxy"  ] && echo -e "  子网代理: ${CYAN}${cfg_proxy}${RESET}"
        [ -n "$cfg_listen" ] && echo -e "  侦听端口: ${CYAN}${cfg_listen}${RESET}"
        echo -e "  启用加密: ${CYAN}${cfg_enc}${RESET}"
        echo -e "  配置文件: ${CYAN}${CONFIG_FILE}${RESET}"
        echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
        printf "${YELLOW}确认安装？[Y/n]: ${RESET}" >&2
        read -r ans </dev/tty
        ans="${ans:-Y}"
        [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消安装。"; return 0; }

        info "版本: $version | 架构: $ARCH | 下载方式: ${dm_label}"
        if [[ "$choice" = "download" ]]; then
            [ -d "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR"
            download_and_extract "$ARCH" "$version" "$download_method"
        fi
        write_config_file "$cfg_hostname" "$cfg_netname" "$cfg_netsec" "$cfg_ip_mode" "$cfg_peer" "$cfg_proxy" "$cfg_enc" "$cfg_listen"
        apply_service "$MODE_CONSOLE_FILE"
        show_status
        return
    fi

    # ── 方式 1：Web控制台模式 ──
    echo -e "\n${BOLD}── 第 4 步：配置节点信息 ──${RESET}" >&2
    info "节点信息用于在 EasyTier 控制台中识别你的设备。"
    local username
    username=$(prompt_username)

    local node_hostname
    node_hostname=$(prompt_hostname)

    echo -e "\n${BOLD}── 第 5 步：配置控制台地址 ──${RESET}" >&2
    info "控制台是 EasyTier 的服务器地址，用于节点发现和组网。"
    local console_addr
    console_addr=$(prompt_console)

    echo -e "\n${BOLD}${CYAN}──────── 安装确认 ────────${RESET}"
    echo -e "  模式:     ${CYAN}Web控制台模式${RESET}"
    echo -e "  版本:     ${CYAN}${version}${RESET}"
    echo -e "  下载方式: ${CYAN}${dm_label}${RESET}"
    echo -e "  用户名:   ${CYAN}${username}${RESET}"
    echo -e "  机器名:   ${CYAN}${node_hostname}${RESET}"
    echo -e "  控制台:   ${CYAN}${console_addr}${RESET}"
    echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
    printf "${YELLOW}确认安装？[Y/n]: ${RESET}" >&2
    read -r ans </dev/tty
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消安装。"; return 0; }

    info "版本: $version | 架构: $ARCH | 下载方式: ${dm_label}"
    if [[ "$choice" = "download" ]]; then
        [ -d "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR"
        download_and_extract "$ARCH" "$version" "$download_method"
    fi
    apply_service "$MODE_CONSOLE" "$username" "$node_hostname" "$console_addr"
    show_status
}

# ================================================================
# 操作：安装 Web 控制台
# ================================================================
do_install_web_console() {
    title "安装 EasyTier Web 控制台"

    # 检查二进制文件是否已存在，存在则让用户选择
    local choice="download"
    if [ -f "$WEB_EMBED_BINARY" ]; then
        echo -e "\n${YELLOW}⚠  检测到已有 Web 控制台程序：${CYAN}${WEB_EMBED_BINARY}${YELLOW}${RESET}"
        echo -e "${YELLOW}   全新安装将会覆盖现有程序。${RESET}\n"
        echo -e "${BOLD}请选择：${RESET}"
        echo -e "  ${CYAN}1)${RESET} 使用已有程序（跳过下载，推荐）"
        echo -e "  ${CYAN}2)${RESET} 重新下载并覆盖"
        echo -e "  ${CYAN}3)${RESET} 取消安装\n"
        printf "${YELLOW}请输入选项 [1/2/3]（默认: 1）: ${RESET}" >&2
        local ans
        read -r ans </dev/tty
        case "${ans:-1}" in
            1) choice="use" ;;
            2) choice="download" ;;
            *) info "已取消安装。"; return 0 ;;
        esac
    fi

    # 若需要下载，让用户选择下载方式和版本
    local version dm_label
    if [[ "$choice" = "download" ]]; then
        echo -e "\n${BOLD}── 选择下载方式 ──${RESET}" >&2
        local download_method
        download_method=$(prompt_download_method)
        case "$download_method" in
            local)  dm_label="本地镜像" ;;
            proxy)  dm_label="GitHub 代理" ;;
            direct) dm_label="GitHub 直连" ;;
        esac

        version=$(prompt_version)

        echo -e "\n${BOLD}── 下载并安装 Web 控制台 ──${RESET}" >&2
        info "下载方式: ${dm_label}"
        if ! download_web_embed "$version" "$download_method"; then
            error "Web 控制台下载失败，请检查网络后重试。"
            return 1
        fi
    else
        # use existing：读取已有文件的版本信息
        version=$("$WEB_EMBED_BINARY" --version 2>/dev/null | head -1 || echo "未知")
        dm_label="（使用已有程序）"
        info "将使用已有程序，跳过下载。"
    fi

    # 配置 HTTP 端口
    echo -e "\n${BOLD}── 配置 HTTP 端口 ──${RESET}" >&2
    info "Web 控制台前端访问端口（浏览器打开的端口）。"
    local http_port
    http_port=$(prompt_web_http_port)

    # 配置控制台后端通讯端口
    echo -e "\n${BOLD}── 配置控制台后端通讯端口 ──${RESET}" >&2
    info "控制台后端节点发现/心跳通讯端口（注意：该端口必须与 easytier-core 客户端或服务端所用的 UDP/TCP 端口一致，否则无法通讯）。"
    local console_port
    console_port=$(prompt_web_console_port)

    # 配置控制台通讯协议
    echo -e "\n${BOLD}── 配置控制台通讯协议 ──${RESET}" >&2
    info "控制台后端通讯使用的协议类型。"
    local console_proto
    console_proto=$(prompt_web_console_proto)

    # 自动获取或确认公网 IP
    echo -e "\n${BOLD}── 配置公网 IP ──${RESET}" >&2
    local public_ip
    public_ip=$(prompt_web_public_ip)

    # 安装确认
    echo -e "\n${BOLD}${CYAN}──────── 安装确认 ────────${RESET}"
    echo -e "  程序路径:  ${CYAN}${WEB_EMBED_BINARY}${RESET}"
    echo -e "  数据库目录: ${CYAN}${WEB_DB_DIR}/${RESET}"
    echo -e "  HTTP 端口: ${CYAN}${http_port}${RESET}"
    echo -e "  后端端口:  ${CYAN}${console_port}${RESET}"
    echo -e "  通讯协议:  ${CYAN}${console_proto}${RESET}"
    echo -e "  公网 IP:   ${CYAN}${public_ip}${RESET}"
    echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
    printf "${YELLOW}确认安装？[Y/n]: ${RESET}" >&2
    read -r ans </dev/tty
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消安装。"; return 0; }

    # 生成服务文件并启动
    info "正在配置 systemd 服务..."
    apply_web_service "$http_port" "$console_port" "$console_proto" "$public_ip"

    # 检查服务是否启动成功
    sleep 2
    if systemctl is-active --quiet "$WEB_SERVICE_NAME"; then
        success "Web 控制台已启动！\n"
    else
        error "Web 控制台启动失败，请检查日志：journalctl -u ${WEB_SERVICE_NAME} -n 20"
        return 1
    fi

    echo -e "${BOLD}──────────────────────────────────────────${RESET}"
    echo -e "${BOLD}  🎉 EasyTier Web 控制台安装完成！${RESET}"
    echo -e "${BOLD}──────────────────────────────────────────${RESET}\n"
    echo -e "  ${GREEN}Web 访问地址:  http://${public_ip}:${http_port}${RESET}"
    echo -e "  ${GREEN}后端通讯地址:  ${console_proto}://${public_ip}:${console_port}${RESET}"
    echo -e "  ${GREEN}数据库路径:   ${WEB_DB_DIR}/et.db${RESET}\n"
    echo -e "  ${YELLOW}⚠  重要提醒：请定期备份数据库文件！${RESET}"
    echo -e "  ${YELLOW}   备份路径: ${WEB_DB_DIR}/  （包含 et.db 等文件）${RESET}\n"
    echo -e "  ${CYAN}常用命令：${RESET}"
    echo -e "    查看状态:  systemctl status ${WEB_SERVICE_NAME}"
    echo -e "    查看日志:  journalctl -u ${WEB_SERVICE_NAME} -f"
    echo -e "    停止服务:  systemctl stop ${WEB_SERVICE_NAME}"
    echo -e "    重启服务:  systemctl restart ${WEB_SERVICE_NAME}\n"
    echo -e "${BOLD}──────────────────────────────────────────${RESET}"
}

# ================================================================
# 操作：修改配置
# ================================================================
do_modify() {
    title "修改 EasyTier 配置"

    if [ ! -f "$SERVICE_FILE" ]; then
        error "未找到服务文件，请先执行【全新安装】。"
        return 1
    fi
    if [ ! -f "${INSTALL_DIR}/easytier-core" ]; then
        error "未找到 easytier-core，程序文件可能已损坏，请先执行【更新程序】或【全新安装】。"
        return 1
    fi

    local cur_mode
    cur_mode=$(read_current_mode)

    if [ "$cur_mode" = "$MODE_RELAY" ]; then
        # 当前为服务端模式：可修改 hostname/端口，也可切换到客户端模式
        echo -e "${BOLD}当前为服务端/中继模式，可执行以下操作：${RESET}" >&2
        echo -e "  ${BOLD}${GREEN}1)${RESET} 修改主机名 / 侦听端口（保持服务端模式）"
        echo -e "  ${BOLD}${YELLOW}2)${RESET} 切换为客户端模式"
        echo -e "  ${BOLD}0)${RESET} 取消，返回主菜单"
        printf "请输入选项 [0/1/2]: " >&2
        read -r relay_choice </dev/tty

        case "$relay_choice" in
            1)
                echo -e "\n${BOLD}── 修改主机名 ──${RESET}" >&2
                info "直接回车可保留当前值。"
                local relay_hostname
                relay_hostname=$(prompt_relay_hostname)

                echo -e "\n${BOLD}── 修改侦听端口 ──${RESET}" >&2
                local ports_str tcp_port udp_port ws_port wss_port
                ports_str=$(prompt_listen_ports)
                read -r tcp_port udp_port ws_port wss_port <<< "$ports_str"

                echo -e "\n${BOLD}── 修改中继白名单 ──${RESET}" >&2
                local whitelist
                whitelist=$(prompt_relay_whitelist)

                echo -e "\n${BOLD}${CYAN}──────── 修改确认 ────────${RESET}"
                echo -e "  主机名:   ${CYAN}${relay_hostname}${RESET}"
                echo -e "  TCP 端口: ${CYAN}${tcp_port}${RESET}"
                echo -e "  UDP 端口: ${CYAN}${udp_port}${RESET}"
                echo -e "  WS  端口: ${CYAN}${ws_port}${RESET}"
                echo -e "  WSS 端口: ${CYAN}${wss_port}${RESET}"
                echo -e "  白名单:   ${CYAN}${whitelist}${RESET}"
                echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
                printf "${YELLOW}确认修改并重启服务？[Y/n]: ${RESET}" >&2
                read -r ans </dev/tty
                ans="${ans:-Y}"
                [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消修改。"; return 0; }

                apply_service "$MODE_RELAY" "$relay_hostname" "$tcp_port" "$udp_port" "$ws_port" "$wss_port" "$whitelist"
                show_status
                return
                ;;
            2)
                # 切换到客户端模式
                echo -e "\n${BOLD}── 选择切换后的客户端安装方式 ──${RESET}" >&2
                local switch_method
                while true; do
                    printf "请选择客户端安装方式:\n" >&2
                    printf "  ${BOLD}1)${RESET} Web控制台模式\n" >&2
                    printf "  ${BOLD}2)${RESET} 配置文件模式\n" >&2
                    printf "请输入选项 [1/2]（默认: 2）: " >&2
                    read -r switch_method </dev/tty
                    switch_method="${switch_method:-2}"
                    case "$switch_method" in
                        1|2) break ;;
                        *) warn "无效选项，请输入 1 或 2。" ;;
                    esac
                done

                if [ "$switch_method" = "2" ]; then
                    _do_switch_to_config_mode
                else
                    _do_switch_to_console_mode
                fi
                return
                ;;
            *)
                info "已取消。"
                return 0
                ;;
        esac
    fi

    # 配置文件模式
    if [ "$cur_mode" = "$MODE_CONSOLE_FILE" ]; then
        echo -e "${BOLD}当前为客户端模式（配置文件），可执行以下操作：${RESET}" >&2
        echo -e "  ${BOLD}${GREEN}1)${RESET} 修改组网信息（主机名 / 网络名称 / 网络密钥）"
        echo -e "  ${BOLD}${YELLOW}2)${RESET} 修改全部配置"
        echo -e "  ${BOLD}${CYAN}3)${RESET} 切换为Web控制台模式"
        echo -e "  ${BOLD}${RED}4)${RESET} 切换为服务器/中继模式"
        echo -e "  ${BOLD}0)${RESET} 取消，返回主菜单"
        printf "请输入选项 [0-4]: " >&2
        read -r cf_choice </dev/tty

        case "$cf_choice" in
            1)
                # 仅修改组网相关参数
                info "直接回车可保留当前值。"
                echo -e "\n${BOLD}── 修改主机名 ──${RESET}" >&2
                local cfg_hostname; cfg_hostname=$(prompt_hostname)
                echo -e "\n${BOLD}── 修改网络名称 ──${RESET}" >&2
                local cfg_netname; cfg_netname=$(prompt_network_name)
                echo -e "\n${BOLD}── 修改网络密钥 ──${RESET}" >&2
                local cfg_netsec; cfg_netsec=$(prompt_network_secret)

                echo -e "\n${BOLD}${CYAN}──────── 修改确认 ────────${RESET}"
                echo -e "  主机名:   ${CYAN}${cfg_hostname}${RESET}"
                echo -e "  网络名称: ${CYAN}${cfg_netname}${RESET}"
                echo -e "  网络密钥: ${CYAN}${cfg_netsec}${RESET}"
                echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
                printf "${YELLOW}确认修改并重启服务？[Y/n]: ${RESET}" >&2
                read -r ans </dev/tty
                ans="${ans:-Y}"
                [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消修改。"; return 0; }

                # 仅更新组网相关字段，保留其他配置不变（包括侦听端口）
                local cur_cfg_netname cur_cfg_netsec cur_cfg_ip cur_cfg_peer cur_cfg_proxy_cidr cur_cfg_enc cur_cfg_listen
                cur_cfg_netname=$(read_current_network_name)
                cur_cfg_netsec=$(read_current_network_secret)
                cur_cfg_ip=$(read_current_conf_ipv4)
                cur_cfg_peer=$(read_current_conf_peer_uri)
                cur_cfg_proxy_cidr=$(read_current_conf_proxy_cidr)
                cur_cfg_enc=$(read_current_conf_encryption)
                cur_cfg_listen=$(_read_yaml_val "listeners" | grep -oP '://[^"]+' | sed 's|//0.0.0.0:||' | while read -r p; do echo "$p"; done | tr '\n' '|' | sed 's/|$//') || true

                write_config_file "$cfg_hostname" "$cfg_netname" "$cfg_netsec" \
                    "${cur_cfg_ip:-automatic}" "${cur_cfg_peer:-}" "${cur_cfg_proxy_cidr:-false}" "$cur_cfg_enc" "${cur_cfg_listen:-}"
                apply_service "$MODE_CONSOLE_FILE"
                show_status
                return
                ;;
            2)
                info "直接回车可保留当前值。"
                echo -e "\n${BOLD}── 修改 hostname ──${RESET}" >&2
                local cfg_hostname; cfg_hostname=$(prompt_hostname)
                echo -e "\n${BOLD}── 修改网络名称 ──${RESET}" >&2
                local cfg_netname; cfg_netname=$(prompt_network_name)
                echo -e "\n${BOLD}── 修改网络密钥 ──${RESET}" >&2
                local cfg_netsec; cfg_netsec=$(prompt_network_secret)
                echo -e "\n${BOLD}── 修改 IP 分配方式 ──${RESET}" >&2
                local cfg_ip_mode; cfg_ip_mode=$(prompt_ipv4)
                echo -e "\n${BOLD}── 修改节点服务器地址 ──${RESET}" >&2
                local cfg_peer; cfg_peer=$(prompt_peer_uri)
                echo -e "\n${BOLD}── 修改子网代理 ──${RESET}" >&2
                local cfg_proxy; cfg_proxy=$(prompt_proxy_network)
                echo -e "\n${BOLD}── 修改加密设置 ──${RESET}" >&2
                local cfg_enc; cfg_enc=$(prompt_encryption)
                echo -e "\n${BOLD}── 修改侦听端口 ──${RESET}" >&2
                local cfg_listen; cfg_listen=$(prompt_config_listen_ports)

                echo -e "\n${BOLD}${CYAN}──────── 修改确认 ────────${RESET}"
                echo -e "  主机名:   ${CYAN}${cfg_hostname}${RESET}"
                echo -e "  网络名称: ${CYAN}${cfg_netname}${RESET}"
                echo -e "  网络密钥: ${CYAN}${cfg_netsec}${RESET}"
                echo -e "  IP 方式:  ${CYAN}${cfg_ip_mode}${RESET}"
                [ -n "$cfg_peer"   ] && echo -e "  节点地址: ${CYAN}${cfg_peer}${RESET}"
                [ -n "$cfg_proxy"  ] && echo -e "  子网代理: ${CYAN}${cfg_proxy}${RESET}"
                [ -n "$cfg_listen"] && echo -e "  侦听端口: ${CYAN}${cfg_listen}${RESET}"
                echo -e "  启用加密: ${CYAN}${cfg_enc}${RESET}"
                echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
                printf "${YELLOW}确认修改并重启服务？[Y/n]: ${RESET}" >&2
                read -r ans </dev/tty
                ans="${ans:-Y}"
                [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消修改。"; return 0; }

                write_config_file "$cfg_hostname" "$cfg_netname" "$cfg_netsec" "$cfg_ip_mode" "$cfg_peer" "$cfg_proxy" "$cfg_enc" "$cfg_listen"
                apply_service "$MODE_CONSOLE_FILE"
                show_status
                return
                ;;
            3)
                echo -e "\n${BOLD}── 切换为 Web控制台模式 ──${RESET}" >&2
                _do_switch_to_console_mode
                return
                ;;
            4)
                echo -e "\n${BOLD}── 切换为服务器/中继模式 ──${RESET}" >&2
                _do_switch_to_relay_mode
                return
                ;;
            *)
                info "已取消。"
                return 0
                ;;
        esac
    fi

    # Web控制台模式
    echo -e "${BOLD}当前为Web控制台模式，可执行以下操作：${RESET}" >&2
    echo -e "  ${BOLD}${GREEN}1)${RESET} 修改控制台信息（用户名 / 机器名 / 控制台地址）"
    echo -e "  ${BOLD}${YELLOW}2)${RESET} 切换为配置文件模式"
    echo -e "  ${BOLD}${RED}3)${RESET} 切换为服务器/中继模式"
    echo -e "  ${BOLD}0)${RESET} 取消，返回主菜单"
    printf "请输入选项 [0-3]: " >&2
    read -r console_choice </dev/tty

    case "$console_choice" in
        1)
            info "当前为Web控制台模式，直接回车可保留现有值："

            echo -e "\n${BOLD}── 节点信息 ──${RESET}" >&2
            local username
            username=$(prompt_username)

            local node_hostname
            node_hostname=$(prompt_hostname)

            echo -e "\n${BOLD}── 控制台地址 ──${RESET}" >&2
            local console_addr
            console_addr=$(prompt_console)

            # 确认信息
            echo -e "\n${BOLD}${CYAN}──────── 修改确认 ────────${RESET}"
            echo -e "  用户名:   ${CYAN}${username}${RESET}"
            echo -e "  机器名:   ${CYAN}${node_hostname}${RESET}"
            echo -e "  控制台:   ${CYAN}${console_addr}${RESET}"
            echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
            printf "${YELLOW}确认修改并重启服务？[Y/n]: ${RESET}" >&2
            read -r ans </dev/tty
            ans="${ans:-Y}"
            [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消修改。"; return 0; }

            apply_service "$MODE_CONSOLE" "$username" "$node_hostname" "$console_addr"
            show_status
            return
            ;;
        2)
            echo -e "\n${BOLD}── 切换为配置文件模式 ──${RESET}" >&2
            _do_switch_to_config_mode
            return
            ;;
        3)
            echo -e "\n${BOLD}── 切换为服务器/中继模式 ──${RESET}" >&2
            _do_switch_to_relay_mode
            return
            ;;
        *)
            info "已取消。"
            return 0
            ;;
    esac
}

# ================================================================
# 操作：更新程序
# ================================================================
do_update() {
    title "更新 EasyTier 程序"

    if [ ! -d "$INSTALL_DIR" ]; then
        error "未检测到已安装的 EasyTier，请先执行【全新安装】。"
        return 1
    fi

    local cur_mode
    cur_mode=$(read_current_mode)
    if [ "$cur_mode" = "$MODE_RELAY" ]; then
        info "当前为服务端/中继模式，配置保持不变。"
    elif [ "$cur_mode" = "$MODE_CONSOLE_FILE" ]; then
        info "当前为配置文件模式，${CONFIG_FILE} 保持不变。"
    fi

    echo -e "\n${BOLD}── 第 1 步：选择目标版本 ──${RESET}" >&2
    local version
    version=$(prompt_version)

    echo -e "\n${BOLD}── 第 2 步：选择下载方式 ──${RESET}" >&2
    local download_method dm_label
    download_method=$(prompt_download_method)
    case "$download_method" in
        local)  dm_label="本地镜像" ;;
        proxy)  dm_label="GitHub 代理" ;;
        direct) dm_label="GitHub 直连" ;;
    esac

    echo -e "\n${BOLD}${CYAN}──────── 更新确认 ────────${RESET}"
    echo -e "  目标版本: ${CYAN}${version}${RESET}"
    echo -e "  下载方式: ${CYAN}${dm_label}${RESET}"
    echo -e "  (配置文件和服务设置保持不变)${RESET}"
    echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
    printf "${YELLOW}确认更新？[Y/n]: ${RESET}" >&2
    read -r ans </dev/tty
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消更新。"; return 0; }

    info "目标版本: $version | 架构: $ARCH | 下载方式: ${dm_label}"

    local backup_dir
    backup_dir=$(mktemp -d /tmp/easytier_backup_XXXXXX)
    trap 'rm -rf "$backup_dir"' RETURN

    for bin in easytier-core easytier-cli; do
        [ -f "${INSTALL_DIR}/${bin}" ] && cp "${INSTALL_DIR}/${bin}" "${backup_dir}/"
    done

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true

    if ! download_and_extract "$ARCH" "$version" "$download_method"; then
        warn "下载失败，正在回滚到备份版本..."
        for bin in easytier-core easytier-cli; do
            [ -f "${backup_dir}/${bin}" ] && cp "${backup_dir}/${bin}" "${INSTALL_DIR}/"
        done
        systemctl start "$SERVICE_NAME" 2>/dev/null || true
        error "更新失败，已回滚到旧版本，服务已恢复。"
        return 1
    fi

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" 2>&1 | while IFS= read -r line; do
        info "$line"
    done
    systemctl restart "$SERVICE_NAME"
    show_status
}

# ================================================================
# 操作：卸载
# ================================================================
do_uninstall() {
    title "卸载 EasyTier"

    if [ ! -f "$SERVICE_FILE" ] && [ ! -d "$INSTALL_DIR" ]; then
        warn "未检测到 EasyTier 的安装文件，可能已经卸载。"
        return 0
    fi

    echo -e "${RED}${BOLD}警告：此操作将删除所有 EasyTier 程序文件和服务，不可恢复！${RESET}" >&2
    printf "${YELLOW}请输入 \"yes\" 确认卸载（其他输入取消）: ${RESET}" >&2
    read -r ans </dev/tty
    [ "$ans" = "yes" ] || { info "已取消卸载。"; return 0; }

    systemctl stop    "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    rm -f "$SERVICE_FILE"
    rm -f "$CONFIG_FILE"
    rm -rf "$INSTALL_DIR"

    success "✓ EasyTier 已完全卸载。"
}

# ================================================================
# 操作：查看日志
# ================================================================
do_show_log() {
    title "EasyTier 运行日志"

    if ! systemctl is-active "$SERVICE_NAME" &>/dev/null && ! systemctl is-failed "$SERVICE_NAME" &>/dev/null; then
        warn "服务尚未安装或从未启动。"
        return 0
    fi

    echo -e "\n${BOLD}请选择日志查看方式:${RESET}"
    echo -e "  ${BOLD}1)${RESET} 查看最近 50 条日志"
    echo -e "  ${BOLD}2)${RESET} 实时追踪日志（${BOLD}Ctrl+C${RESET} 退出）"
    echo -e "  ${BOLD}3)${RESET} 查看今日全部日志"
    printf "请输入选项 [1/2/3]（默认: 1）: "
    read -r choice </dev/tty
    choice="${choice:-1}"

    case "$choice" in
        1)
            journalctl -u "${SERVICE_NAME}.service" -n 50 --no-pager 2>/dev/null || true
            ;;
        2)
            watch_logs
            ;;
        3)
            journalctl -u "${SERVICE_NAME}.service" --since today --no-pager 2>/dev/null || true
            ;;
        *)
            warn "无效选项，显示最近 50 条日志。"
            journalctl -u "${SERVICE_NAME}.service" -n 50 --no-pager 2>/dev/null || true
            ;;
    esac
}

# ================================================================
# 操作：重启服务
# ================================================================
do_restart() {
    title "重启 EasyTier 服务"

    if ! systemctl is-active "$SERVICE_NAME" &>/dev/null && ! systemctl is-failed "$SERVICE_NAME" &>/dev/null; then
        warn "服务尚未安装，请先执行【全新安装】。"
        return 0
    fi

    printf "${YELLOW}确认重启服务？[Y/n]: ${RESET}" >&2
    read -r ans </dev/tty
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消。"; return 0; }

    info "重新加载 systemd 配置..."
    systemctl daemon-reload

    info "正在重启服务..."
    if ! systemctl restart "$SERVICE_NAME"; then
        error "服务重启失败，请检查日志。"
        info "查看日志：journalctl -xe -u ${SERVICE_NAME}.service"
        return 1
    fi

    show_status
}

# ================================================================
# 操作：查看组网信息（peer 列表）
# ================================================================
do_show_peer() {
    title "查看 EasyTier 组网信息"

    if [ ! -f "${INSTALL_DIR}/easytier-cli" ]; then
        error "未找到 easytier-cli 工具，无法查询组网信息。"
        info "请先执行【全新安装】或【更新程序】安装完整工具包。"
        return 1
    fi

    if ! systemctl is-active "$SERVICE_NAME" &>/dev/null; then
        warn "EasyTier 服务当前未运行，尝试查询可能失败..."
    fi

    echo -e "\n${BOLD}────────── 组网 Peer 列表 ──────────${RESET}" >&2
    echo -e "  正在执行: ${INSTALL_DIR}/easytier-cli peer\n" >&2
    "${INSTALL_DIR}/easytier-cli" peer 2>&1 || true
    echo -e "${BOLD}────────────────────────────────────${RESET}\n" >&2
}

# ================================================================
# 操作：增加 machine-id（为已安装服务的 ExecStart 追加随机 UUID）
# ================================================================
# 生成随机 UUID（优先内核熵源，回退 uuidgen / openssl）
gen_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif command -v openssl &>/dev/null; then
        openssl rand -hex 16 | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
    else
        error "无法生成 UUID：无 /proc/sys/kernel/random/uuid、uuidgen、openssl。"
        return 1
    fi
}

do_machine_id() {
    title "增加 machine-id"

    if [ ! -f "$SERVICE_FILE" ]; then
        error "服务文件不存在，请先执行【全新安装】。"
        info "（路径: ${SERVICE_FILE}）"
        return 1
    fi

    if ! grep -q '^ExecStart=' "$SERVICE_FILE"; then
        error "服务文件中未找到 ExecStart 行，文件可能被手动改动过。"
        return 1
    fi

    # 当前 ExecStart 与已有 machine-id
    local cur_exec cur_mid
    cur_exec=$(grep '^ExecStart=' "$SERVICE_FILE" | head -1)
    cur_mid=$(echo "$cur_exec" | grep -oE -- '--machine-id[=[:space:]]+[^[:space:]]+' \
              | sed -E 's/--machine-id[=[:space:]]+//' | head -1 || true)

    echo -e "${BOLD}当前 ExecStart:${RESET}" >&2
    echo -e "  ${CYAN}${cur_exec}${RESET}" >&2
    echo

    if [ -n "$cur_mid" ]; then
        warn "已存在 machine-id: ${cur_mid}"
        echo -e "  ${BOLD}1)${RESET} 保留现有 machine-id（不改动）"
        echo -e "  ${BOLD}2)${RESET} 重新生成随机 UUID 并替换"
        echo -e "  ${BOLD}0)${RESET} 取消"
        printf "请选择 [0-2]（默认: 1）: " >&2
        read -r mid_choice </dev/tty
        case "${mid_choice:-1}" in
            1) info "保留现有 machine-id，未做改动。"; return 0 ;;
            2) : ;;
            *) info "已取消。"; return 0 ;;
        esac
    fi

    local uuid
    uuid=$(gen_uuid) || return 1

    echo -e "${BOLD}${CYAN}──────── 变更确认 ────────${RESET}"
    echo -e "  新增 machine-id: ${CYAN}${uuid}${RESET}"
    echo -e "  修改文件:        ${CYAN}${SERVICE_FILE}${RESET}"
    echo -e "  随后操作:        ${CYAN}daemon-reload 并重启 ${SERVICE_NAME}${RESET}"
    echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
    printf "${YELLOW}确认修改？[Y/n]: ${RESET}" >&2
    read -r ans </dev/tty
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消。"; return 0; }

    # 备份服务文件
    cp -a "$SERVICE_FILE" "${SERVICE_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    info "已备份原服务文件。"

    # 先移除可能存在的旧 --machine-id 参数，再追加新值（幂等）
    sed -i -E '/^ExecStart=/ s/[[:space:]]+--machine-id[=[:space:]]+[^[:space:]]+//g' "$SERVICE_FILE"
    sed -i -E "/^ExecStart=/ s|\$| --machine-id ${uuid}|" "$SERVICE_FILE"

    echo
    echo -e "${BOLD}修改后 ExecStart:${RESET}" >&2
    echo -e "  ${CYAN}$(grep '^ExecStart=' "$SERVICE_FILE" | head -1)${RESET}" >&2

    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME"
    show_status

    success "machine-id 已添加: ${uuid}"
    info "提示: 重新执行本菜单可查看当前 machine-id 或重新生成替换。"
}

# ================================================================
# 断网监控（systemd timer，每 15 分钟检测 tun0 与虚拟网连通性）
# ================================================================
readonly WD_SCRIPT="/usr/local/sbin/easytier-watchdog.sh"
readonly WD_SERVICE_FILE="/etc/systemd/system/easytier-watchdog.service"
readonly WD_TIMER_FILE="/etc/systemd/system/easytier-watchdog.timer"
readonly WD_TIMER_NAME="easytier-watchdog.timer"
readonly WD_INTERVAL_MIN=15
# 待检测的虚拟网地址列表（每行一个 IP，# 开头为注释），由 easytier-cli 自动维护
readonly WD_IP_LIST="/etc/easytier/watchdog-ips.txt"
# 每次刷新时最多取几个对端虚拟 IP
readonly WD_MAX_LIST_IP=5
# 联网判定的公网兜底对照地址（中转服务器探测失败时使用）
readonly WD_PUBLIC_PROBES=( "223.5.5.5" "114.114.114.114" )
# 重启服务后等待隧道重建的秒数，之后才用 easytier-cli 刷新地址列表
readonly WD_BOOT_WAIT=15
# 连续判定异常达到该次数才重启服务（1=单次失败即重启，2=需连续两次，可抗单次抖动）
readonly WD_FAIL_THRESHOLD=2
# 连续异常计数存放位置
readonly WD_FAIL_FILE="/etc/easytier/watchdog-failcount"
# 本地日志文件路径（同时写 journal + 落盘，防止 Armbian volatile journal 轮转掉）。
# 单文件封顶 100KB，超过自动保留 3 个轮转备份（总量 ≤ 400KB），不会撑爆硬盘。
readonly WD_LOG_FILE="/var/log/easytier-watchdog.log"

# ----------------------------------------------------------------
# 解析中转服务器地址（联网判定的探测目标）
# 输出: "协议 主机 端口"，解析不到时输出空
#   console_file 模式 → 取配置文件里的第一个 peer URI
#   console     模式 → 取 -w 参数中的控制台地址（去掉用户名部分）
#   relay       模式 → 自身即为中转，无上游可探测，输出空（交由公网兜底）
# ----------------------------------------------------------------
wd_resolve_relay_target() {
    local mode uri proto host port rest
    mode=$(read_current_mode)

    case "$mode" in
        "$MODE_CONSOLE_FILE")
            uri=$(read_current_conf_peer_uri)
            ;;
        "$MODE_CONSOLE")
            # read_current_config 已剥离用户名部分，返回 "协议://主机:端口"
            uri=$(read_current_config)
            ;;
        *)
            return 0
            ;;
    esac

    [ -n "$uri" ] || return 0
    [[ "$uri" == *://* ]] || return 0

    proto="${uri%%://*}"
    rest="${uri#*://}"
    rest="${rest%%/*}"
    host="${rest%%:*}"
    port=""
    if [ "$rest" != "$host" ]; then
        port="${rest##*:}"
    fi

    [ -n "$host" ] || return 0
    echo "${proto} ${host} ${port}"
}

# ----------------------------------------------------------------
# 生成监控脚本本体（配置写在文件头部，检测地址存放在独立文件）
# ----------------------------------------------------------------
generate_watchdog_script() {
    local iface="$1"
    local relay_host="$2"
    local relay_port="$3"
    local relay_proto="$4"
    local et_cli="$5"

    local probes="" p
    for p in "${WD_PUBLIC_PROBES[@]}"; do
        probes+="\"${p}\" "
    done
    probes="${probes% }"

    cat <<EOF
#!/usr/bin/env bash
# EasyTier 断网监控（由 easytier.sh「断网监控」菜单生成，可直接编辑本文件）
# 触发方式：systemd timer（easytier-watchdog.timer），每 ${WD_INTERVAL_MIN} 分钟一次。
#
# 检测顺序：
#   1. 联网判定：先探测中转服务器${relay_host:+ ${relay_host}}，不通则回退公网对照地址
#      → 判定为外网中断时直接跳过，不重启服务（重启也修不好外网）
#   2. 虚拟网卡 ${iface} 不存在 → 重启服务
#   3. 逐 IP ping 地址列表（强制走虚拟网卡），全部不通 → 重启服务
#   4. 收尾：联网正常时用 easytier-cli 取前 ${WD_MAX_LIST_IP} 个对端虚拟 IP 写回列表文件
#
# 待检测地址列表（每行一个 IP，# 开头为注释，本脚本自动维护，也可手动编辑）：
#   ${WD_IP_LIST}

IFACE="${iface}"
IP_LIST_FILE="${WD_IP_LIST}"
MAX_LIST_IP=${WD_MAX_LIST_IP}
COUNT=2
TIMEOUT=2
SERVICE="${SERVICE_NAME}"
ET_CLI="${et_cli}"
RELAY_HOST="${relay_host}"
RELAY_PORT="${relay_port}"
RELAY_PROTO="${relay_proto}"
PUBLIC_PROBES=(${probes})
BOOT_WAIT=${WD_BOOT_WAIT}
# 连续判定异常达到该次数才重启，避免单次抖动误重启
FAIL_THRESHOLD=${WD_FAIL_THRESHOLD}
FAIL_FILE="${WD_FAIL_FILE}"
LOG_FILE="${WD_LOG_FILE}"

# 同时写 stdout（进 journal）与本地日志文件；单文件超 100KB 自动轮转（最多 3 个备份，总量 ≤400KB）
log() {
    local msg="[watchdog \$(date '+%F %T')] \$*"
    echo "\$msg"
    if [ -n "\$LOG_FILE" ]; then
        mkdir -p "\$(dirname "\$LOG_FILE")" 2>/dev/null
        echo "\$msg" >> "\$LOG_FILE"
        if [ -f "\$LOG_FILE" ]; then
            local sz
            sz=\$(stat -c%s "\$LOG_FILE" 2>/dev/null || echo 0)
            if [ "\$sz" -gt 102400 ]; then
                local i
                for i in 3 2 1; do
                    [ -f "\$LOG_FILE.\$i" ] && mv -f "\$LOG_FILE.\$i" "\$LOG_FILE.\$((i+1))" 2>/dev/null
                done
                mv -f "\$LOG_FILE" "\$LOG_FILE.1" 2>/dev/null
            fi
        fi
    fi
}

# ---- 联网判定：中转服务器优先，公网对照兜底 ----
probe_ping() { ping -c 2 -W 2 "\$1" >/dev/null 2>&1; }

probe_tcp() {
    [ -n "\$2" ] || return 1
    timeout 3 bash -c "exec 3<>/dev/tcp/\$1/\$2" >/dev/null 2>&1
}

net_ok() {
    if [ -n "\$RELAY_HOST" ]; then
        if probe_ping "\$RELAY_HOST"; then
            log "联网判定: 中转服务器 \${RELAY_HOST} ping 可达 ✓"
            return 0
        fi
        case "\$RELAY_PROTO" in
            tcp|ws|wss)
                if probe_tcp "\$RELAY_HOST" "\$RELAY_PORT"; then
                    log "联网判定: 中转服务器 \${RELAY_HOST}:\${RELAY_PORT} (\${RELAY_PROTO}) 端口可连 ✓"
                    return 0
                fi
                ;;
        esac
        log "联网判定: 中转服务器 \${RELAY_HOST} 不可达，回退公网对照"
    fi

    local p
    for p in "\${PUBLIC_PROBES[@]}"; do
        if probe_ping "\$p"; then
            log "联网判定: 公网对照 \${p} 可达 ✓"
            return 0
        fi
        log "联网判定: 公网对照 \${p} 不可达"
    done
    return 1
}

# ---- 读取地址列表 ----
load_ips() {
    [ -s "\$IP_LIST_FILE" ] || return 1
    grep -oE '^[^#]*' "\$IP_LIST_FILE" \\
        | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || return 1
}

# ---- 用 easytier-cli 刷新地址列表（排除本机节点，最多 MAX_LIST_IP 个） ----
refresh_ip_list() {
    local tmp="\${IP_LIST_FILE}.tmp"
    if [ ! -x "\$ET_CLI" ]; then
        log "刷新地址列表失败: \${ET_CLI} 不存在或不可执行"
        return 1
    fi

    mkdir -p "\$(dirname "\$IP_LIST_FILE")"

    if command -v jq >/dev/null 2>&1; then
        "\$ET_CLI" -o json peer list 2>/dev/null \\
            | jq -r '.[] | select((.ipv4 != "") and (.cost != "Local")) | .ipv4' 2>/dev/null \\
            | head -n "\$MAX_LIST_IP" > "\$tmp"
        if [ ! -s "\$tmp" ]; then
            "\$ET_CLI" -o json peer list 2>/dev/null \\
                | jq -r '.[] | select(.ipv4 != "") | .ipv4' 2>/dev/null \\
                | head -n "\$MAX_LIST_IP" > "\$tmp"
        fi
    else
        # 无 jq：从表格输出里按 IP 形态提取，跳过本机行（cost 为 Local）
        "\$ET_CLI" peer list 2>/dev/null | awk -v max="\$MAX_LIST_IP" '
            /Local/ { next }
            {
                if (match(\$0, /([0-9]{1,3}\\.){3}[0-9]{1,3}/)) {
                    ip = substr(\$0, RSTART, RLENGTH)
                    if (ip != "0.0.0.0" && !(ip in seen)) {
                        seen[ip] = 1
                        print ip
                        if (++n >= max) exit
                    }
                }
            }' > "\$tmp"
    fi

    if [ ! -s "\$tmp" ]; then
        rm -f "\$tmp"
        log "刷新地址列表失败: easytier-cli 未返回任何虚拟 IP"
        return 1
    fi

    mv "\$tmp" "\$IP_LIST_FILE"
    log "地址列表已刷新为: \$(tr '\\n' ' ' < "\$IP_LIST_FILE")"
    return 0
}

# ---- 连续异常计数：达到阈值才重启，避免单次抖动误重启 ----
read_fail_count() {
    local n
    n=\$(cat "\$FAIL_FILE" 2>/dev/null | tr -d '[:space:]')
    case "\$n" in
        ''|*[!0-9]*) n=0 ;;
    esac
    echo "\$n"
}

reset_fail_count() {
    mkdir -p "\$(dirname "\$FAIL_FILE")"
    echo 0 > "\$FAIL_FILE"
}

on_fail_round() {
    local n
    n=\$((\$(read_fail_count) + 1))
    mkdir -p "\$(dirname "\$FAIL_FILE")"
    echo "\$n" > "\$FAIL_FILE"

    if [ "\$n" -ge "\$FAIL_THRESHOLD" ]; then
        log "连续第 \${n} 次判定异常（阈值 \${FAIL_THRESHOLD}），重启 \${SERVICE}..."
        systemctl restart "\$SERVICE"
        sleep "\$BOOT_WAIT"
        reset_fail_count
        refresh_ip_list
    else
        log "判定异常（连续第 \${n} 次 / 阈值 \${FAIL_THRESHOLD}），暂不重启，下一轮再确认。"
    fi
}

if ! command -v ping >/dev/null 2>&1; then
    log "缺少 ping 命令（iputils-ping），无法检测，跳过本次。"
    exit 0
fi

if ! net_ok; then
    log "外网不可达（中转服务器与公网对照均不通），判定为外网中断，与 \${SERVICE} 无关，跳过本次。"
    exit 0
fi

if ! ip link show dev "\$IFACE" >/dev/null 2>&1; then
    log "虚拟网卡 \${IFACE} 未创建（隧道未建立）"
    on_fail_round
    exit 0
fi

IPS=()
while IFS= read -r ip; do
    [ -n "\$ip" ] && IPS+=("\$ip")
done < <(load_ips)

if [ \${#IPS[@]} -eq 0 ]; then
    log "地址列表为空（\${IP_LIST_FILE}），尝试用 easytier-cli 初始化..."
    if refresh_ip_list; then
        reset_fail_count
        exit 0
    fi
    log "初始化失败"
    on_fail_round
    exit 0
fi

reachable=0
for ip in "\${IPS[@]}"; do
    if ping -c "\$COUNT" -W "\$TIMEOUT" -I "\$IFACE" "\$ip" >/dev/null 2>&1; then
        log "虚拟网 \${ip} 可达 ✓"
        reachable=1
        break
    fi
    log "虚拟网 \${ip} 不可达 ✗"
done

if [ "\$reachable" -eq 0 ]; then
    log "地址列表中所有地址都不通"
    on_fail_round
else
    reset_fail_count
fi

refresh_ip_list
EOF
}

# ----------------------------------------------------------------
# 生成 systemd service / timer 文件
# ----------------------------------------------------------------
generate_watchdog_service() {
    cat <<EOF
[Unit]
Description=EasyTier 断网监控检查
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WD_SCRIPT}
EOF
}

generate_watchdog_timer() {
    cat <<EOF
[Unit]
Description=EasyTier 断网监控（每 ${WD_INTERVAL_MIN} 分钟）

[Timer]
OnBootSec=2min
OnUnitActiveSec=${WD_INTERVAL_MIN}min
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# ----------------------------------------------------------------
# 启用/更新断网监控
# ----------------------------------------------------------------
watchdog_enable() {
    title "启用断网监控"

    if ! systemctl cat "${SERVICE_NAME}.service" &>/dev/null; then
        warn "未检测到 ${SERVICE_NAME} 服务，请先执行【全新安装】。"
        info "（监控会重启 ${SERVICE_NAME} 服务，服务不存在则监控无意义。）"
        return 1
    fi

    # ping 依赖检查
    if ! command -v ping &>/dev/null; then
        warn "未找到 ping 命令，正在安装 iputils-ping..."
        apt-get update -y -qq && apt-get install -y -qq iputils-ping || {
            error "iputils-ping 安装失败，请手动安装后重试。"
            return 1
        }
    fi

    # jq（用于解析 easytier-cli 的 JSON 输出；缺失时监控脚本自动退化为文本解析）
    local jq_status="已安装"
    if ! command -v jq &>/dev/null; then
        warn "未检测到 jq，尝试安装..."
        if apt-get update -y -qq && apt-get install -y -qq jq; then
            info "jq 安装完成。"
        else
            warn "jq 安装失败，监控脚本将自动退化为文本解析 easytier-cli 输出。"
            jq_status="未安装（文本解析回退）"
        fi
    fi

    # easytier-cli 路径（刷新地址列表用）
    local et_cli="${INSTALL_DIR}/easytier-cli"
    local cli_status="${et_cli}"
    if [ ! -x "$et_cli" ]; then
        et_cli="$(command -v easytier-cli 2>/dev/null || true)"
        cli_status="${et_cli:-未找到}"
        [ -n "$et_cli" ] || warn "未找到 easytier-cli，地址列表将无法自动刷新（可手动维护 ${WD_IP_LIST}）。"
    fi

    # 虚拟网卡名
    local iface
    read -r -e -p "请输入要监控的虚拟网卡名（默认: tun0）: " iface </dev/tty
    iface="${iface:-tun0}"

    # 中转服务器地址（联网判定目标）
    local relay_proto="" relay_host="" relay_port=""
    read -r relay_proto relay_host relay_port <<< "$(wd_resolve_relay_target)"

    # 可选预置地址：留空则由 easytier-cli 自动生成
    echo
    info "地址列表文件: ${WD_IP_LIST}"
    info "每次检测结束后，会用 easytier-cli 取前 ${WD_MAX_LIST_IP} 个对端虚拟 IP 自动覆盖该文件。"
    info "如需预置种子地址（可选），请输入；直接回车则由 easytier-cli 生成。"
    read -r -e -p "预置地址（空格分隔，可留空）: " ip_input </dev/tty

    local seed_ips=() ip bad=()
    for ip in $ip_input; do
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            seed_ips+=("$ip")
        else
            bad+=("$ip")
        fi
    done
    [ ${#bad[@]} -gt 0 ] && warn "已忽略格式非法的地址: ${bad[*]}"

    # 确认
    echo -e "\n${BOLD}${CYAN}──────── 监控配置确认 ────────${RESET}"
    echo -e "  监控网卡:   ${CYAN}${iface}${RESET}"
    echo -e "  地址列表:   ${CYAN}${WD_IP_LIST}${RESET}"
    echo -e "  中转服务器: ${CYAN}${relay_host:-未解析到（仅用公网对照兜底）}${RESET}"
    echo -e "  公网对照:   ${CYAN}${WD_PUBLIC_PROBES[*]}${RESET}"
    echo -e "  jq 状态:    ${CYAN}${jq_status}${RESET}"
    echo -e "  easytier-cli: ${CYAN}${cli_status}${RESET}"
    echo -e "  检测周期:   ${CYAN}每 ${WD_INTERVAL_MIN} 分钟（systemd timer）${RESET}"
    echo -e "  检测顺序:   ${CYAN}联网判定 → 网卡检查 → 列表 ping（全部不通才重启）${RESET}"
    echo -e "  触发动作:   ${CYAN}网卡不存在 或 全部 ping 不通 → 判定异常${RESET}"
    echo -e "  重启条件:   ${CYAN}连续 ${WD_FAIL_THRESHOLD} 次判定异常才重启（抗单次抖动误重启）${RESET}"
    echo -e "${BOLD}${CYAN}──────────────────────────────${RESET}\n"
    printf "${YELLOW}确认启用？[Y/n]: ${RESET}" >&2
    read -r ans </dev/tty
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消。"; return 0; }

    # 写入文件
    generate_watchdog_script "$iface" "$relay_host" "$relay_port" "$relay_proto" "${et_cli:-${INSTALL_DIR}/easytier-cli}" > "$WD_SCRIPT"
    chmod +x "$WD_SCRIPT"

    # 预置种子地址（用户填写时写入，否则留给监控脚本首次运行时自动生成）
    if [ ${#seed_ips[@]} -gt 0 ]; then
        mkdir -p "$(dirname "$WD_IP_LIST")"
        printf '%s\n' "${seed_ips[@]}" > "$WD_IP_LIST"
        info "已预置地址列表: ${seed_ips[*]}"
    fi
    generate_watchdog_service > "$WD_SERVICE_FILE"
    generate_watchdog_timer  > "$WD_TIMER_FILE"

    systemctl daemon-reload
    systemctl enable --now "$WD_TIMER_NAME" 2>&1 | while IFS= read -r line; do info "$line"; done

    success "断网监控已启用（每 ${WD_INTERVAL_MIN} 分钟检测一次）。"
    info "监控脚本: ${WD_SCRIPT}（可手动编辑调整配置）"

    # 立即试运行一次，展示输出
    echo
    info "立即试运行一次，输出如下："
    echo -e "${BOLD}────────────────────────────────${RESET}"
    "$WD_SCRIPT" 2>&1 || true
    echo -e "${BOLD}────────────────────────────────${RESET}"
}

# ----------------------------------------------------------------
# 停用断网监控
# ----------------------------------------------------------------
watchdog_disable() {
    title "停用断网监控"

    if [ ! -f "$WD_TIMER_FILE" ]; then
        warn "断网监控未启用。"
        return 0
    fi

    systemctl disable --now "$WD_TIMER_NAME" 2>/dev/null || true
    rm -f "$WD_TIMER_FILE" "$WD_SERVICE_FILE"
    systemctl daemon-reload
    systemctl reset-failed "$WD_TIMER_NAME" 2>/dev/null || true

    # 监控脚本保留，便于用户参考/手动执行
    if [ -f "$WD_SCRIPT" ]; then
        info "监控脚本 ${WD_SCRIPT} 已保留（不再被定时调用，可手动删除）。"
    fi

    success "断网监控已停用。"
}

# ----------------------------------------------------------------
# 查看监控状态与最近日志
# ----------------------------------------------------------------
watchdog_status() {
    title "断网监控状态"

    if systemctl is-enabled "$WD_TIMER_NAME" &>/dev/null; then
        echo -e "  定时器: ${GREEN}${BOLD}已启用 ✓${RESET}"
    elif [ -f "$WD_TIMER_FILE" ]; then
        echo -e "  定时器: ${RED}${BOLD}已停用 ✗${RESET}"
    else
        echo -e "  定时器: ${YELLOW}未配置${RESET}"
    fi

    if [ -f "$WD_SCRIPT" ]; then
        echo -e "  监控脚本: ${CYAN}${WD_SCRIPT}${RESET}"
        echo -e "  当前配置: ${CYAN}$(grep -E '^(IFACE|IP_LIST_FILE|MAX_LIST_IP|COUNT|TIMEOUT|SERVICE|RELAY_HOST|RELAY_PORT|RELAY_PROTO)=' "$WD_SCRIPT" | tr '\n' ' ')${RESET}"
    fi

    echo
    if [ -s "$WD_IP_LIST" ]; then
        echo -e "  地址列表: ${CYAN}${WD_IP_LIST}${RESET}"
        echo -e "  列表内容: ${CYAN}$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$WD_IP_LIST" 2>/dev/null | tr '\n' ' ')${RESET}"
    else
        echo -e "  地址列表: ${YELLOW}${WD_IP_LIST}（不存在或为空，首次检测时自动初始化）${RESET}"
    fi

    local fc=0
    [ -s "$WD_FAIL_FILE" ] && fc=$(tr -d '[:space:]' < "$WD_FAIL_FILE" 2>/dev/null)
    case "$fc" in ''|*[!0-9]*) fc=0 ;; esac
    if [ "$fc" -gt 0 ]; then
        echo -e "  连续异常: ${YELLOW}${fc} 次${RESET}（阈值 ${WD_FAIL_THRESHOLD}，再连续 $((WD_FAIL_THRESHOLD - fc)) 次将重启服务）"
    else
        echo -e "  连续异常: ${GREEN}0 次${RESET}（阈值 ${WD_FAIL_THRESHOLD}）"
    fi

    echo
    echo -e "${BOLD}────────── 下次执行时间 ──────────${RESET}" >&2
    systemctl list-timers "$WD_TIMER_NAME" --no-pager 2>/dev/null || true

    echo
    echo -e "${BOLD}────────── 最近 20 条监控日志 ──────────${RESET}" >&2
    journalctl -u easytier-watchdog.service -n 20 --no-pager 2>/dev/null \
        || info "暂无日志（监控可能尚未运行过）。"
}

# ----------------------------------------------------------------
# 立即执行一次检测（会实际重启服务，执行前需确认）
# ----------------------------------------------------------------
watchdog_run_once() {
    title "立即执行一次检测"

    if [ ! -x "$WD_SCRIPT" ]; then
        warn "监控脚本 ${WD_SCRIPT} 不存在，请先执行【启用 / 更新配置】。"
        return 1
    fi

    warn "注意：若判定虚拟网断开（列表中所有地址都不通），本操作会重启 ${SERVICE_NAME} 服务。"
    printf "${YELLOW}确认执行？[y/N]: ${RESET}" >&2
    read -r ans </dev/tty
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消。"; return 0; }

    echo -e "${BOLD}────────────────────────────────${RESET}"
    "$WD_SCRIPT" 2>&1 || true
    echo -e "${BOLD}────────────────────────────────${RESET}"

    if [ -s "$WD_IP_LIST" ]; then
        info "当前地址列表: $(tr '\n' ' ' < "$WD_IP_LIST")"
    fi
}

# ----------------------------------------------------------------
# 断网监控子菜单
# ----------------------------------------------------------------
do_watchdog() {
    while true; do
        title "断网监控"

        if systemctl is-enabled "$WD_TIMER_NAME" &>/dev/null; then
            echo -e "  当前状态: ${GREEN}${BOLD}已启用（每 ${WD_INTERVAL_MIN} 分钟检测）${RESET}"
        else
            echo -e "  当前状态: ${YELLOW}未启用${RESET}"
        fi

        echo
        echo -e "${BOLD}请选择操作:${RESET}"
        echo -e "  ${BOLD}1)${RESET} 启用 / 更新配置"
        echo -e "  ${BOLD}2)${RESET} 停用"
        echo -e "  ${BOLD}3)${RESET} 查看状态与日志"
        echo -e "  ${BOLD}4)${RESET} 立即执行一次检测（并刷新地址列表）"
        echo -e "  ${BOLD}0)${RESET} 返回主菜单"
        printf "请输入选项 [0-4]: "
        read -r wd_choice </dev/tty

        case "$wd_choice" in
            1) watchdog_enable  ;;
            2) watchdog_disable ;;
            3) watchdog_status  ;;
            4) watchdog_run_once ;;
            0) return 0 ;;
            *) warn "无效选项 '${wd_choice}'，请输入 0~4。" ;;
        esac

        echo
        printf "${YELLOW}按 Enter 键继续...${RESET}" >&2
        read -r </dev/tty
    done
}

# ================================================================
# 旁路网关（iptables 转发：LAN ↔ EasyTier 虚拟网互通）
#   由原 iptables-et.sh 合并而来，作为主菜单项 12；函数统一 etgw_ 前缀。
# ----------------------------------------------------------------
#
# 用途:
#   让 Debian 12 小主机/盒子作为 EasyTier 旁路网关，转发
#   EasyTier 虚拟网段 <-> 物理局域网段的双向数据。
#
# 关于 NAT（重要，决定了规则为何是现在这个样子）:
#   官方文档 https://easytier.cn/guide/network/network-to-network.html
#   只需 3 条命令，但前提是「节点 A 是该子网的网关」——回包必然经过本节点，
#   回程天然对称，所以不需要任何 NAT。旁路网关不满足该前提：
#   LAN 设备的默认网关是路由器，回包发给路由器，而路由器不认识虚拟网段，
#   回程断裂。补偿方式二选一：
#     a) 路由器加静态路由（本脚本默认，推荐）——零 NAT，两端互见真实 IP
#     b) LAN 出口 MASQUERADE（路由器不可控时的兜底）——LAN 侧看到的
#        来源 IP 变成本网关的 LAN IP
#   注意：无论选哪种，VPN 出口都不做 MASQUERADE。EasyTier 的子网代理
#   （配置文件 [[proxy_network]] cidr = "..."）已把 LAN 网段通告给全网，
#   远端节点天然有回程路由；在此做 SNAT 只会抹掉真实来源 IP。
#
# 设计要点（相对旧版 iptables-et.sh 的改进）:
#   1. 全部规则放入自定义链 ET-FWD / ET-SNAT / ET-MSS，
#      只 flush 自己的链 —— 绝不 `iptables -F FORWARD` /
#      `-t nat -F POSTROUTING`，避免误清 Docker 等已有规则。
#   2. 默认零 NAT；选了 MASQUERADE 才建立并挂载 ET-SNAT 链，
#      且由 yes 切回 no 时会主动摘除，不留残留。
#   3. mangle 表 TCPMSS --clamp-mss-to-pmtu，解决 TUN MTU(约 1380~1420)
#      小于物理网卡 MTU(1500) 导致的"ping 通网页打不开"。
#   4. 幂等：重复执行不会叠加规则（-C 先查再插）。
#   5. 支持卸载与状态查看。
# ================================================================

# --- 常量 ---
readonly FWD_CHAIN="ET-FWD"
readonly SNAT_CHAIN="ET-SNAT"
readonly MSS_CHAIN="ET-MSS"
readonly SYSCTL_FILE="/etc/sysctl.d/99-et-forward.conf"


# --- 全局配置（安装流程中填充） ---
LAN_IF=""
VPN_IF=""
LAN_NAT="no"    # VPN→LAN 是否在 LAN_IF 出口做 MASQUERADE
                # 默认 no（零 NAT）：回程由路由器静态路由保证
LAN_CIDR=""     # 局域网 CIDR，如 192.168.3.0/24
VPN_CIDR=""     # EasyTier 虚拟网 CIDR，如 10.144.144.0/24
LAN_IP=""       # 本机局域网 IP（路由器静态路由的下一跳）

# ==============================================================================
# 基础检查
# ==============================================================================

etgw_check_deps() {
    local missing=()
    for cmd in iptables ip; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        error "缺少依赖: ${missing[*]}，请先安装 iptables / iproute2。"
        exit 1
    fi
}

# ==============================================================================
# 接口选择
# ==============================================================================
# 自动猜测局域网物理网卡：取默认路由的出接口
etgw_detect_lan_if() {
    local ifname
    ifname=$(ip -4 route show default 2>/dev/null \
             | awk '{print $5; exit}' || true)
    [ -n "$ifname" ] && echo "$ifname" || echo "eth0"
}

# 自动猜测 EasyTier 虚拟网卡：
#   1) 优先 easytier*（用户显式 --dev-name 命名过的场景）
#   2) 其次 tun*（EasyTier 默认设备名是 tun0）
#   3) 都没有则默认 tun0（EasyTier 可能尚未启动）
etgw_detect_vpn_if() {
    local ifname
    ifname=$(ip -o link show 2>/dev/null \
             | awk -F': ' '$2 ~ /^easytier/ {print $2; exit}' || true)
    if [ -z "$ifname" ]; then
        ifname=$(ip -o link show 2>/dev/null \
                 | awk -F': ' '$2 ~ /^tun/ {print $2; exit}' || true)
    fi
    [ -n "$ifname" ] && echo "$ifname" || echo "tun0"
}

etgw_if_exists() {
    ip link show dev "$1" &>/dev/null
}

# 取某网卡的主 IPv4 CIDR（如 192.168.3.9/24），取不到返回空
etgw_iface_cidr() {
    ip -4 addr show dev "$1" 2>/dev/null | awk '/inet /{print $2; exit}' || true
}

# CIDR -> 纯 IP
etgw_cidr_ip() {
    echo "${1%%/*}"
}

# IP/前缀 -> 网络号 CIDR（192.168.3.9/24 -> 192.168.3.0/24）；无 ipcalc 也能算
etgw_cidr_net() {
    local cidr ip prefix i ip_dec mask_dec net_dec o1 o2 o3 o4
    cidr="$1"
    ip="${cidr%%/*}"
    prefix="${cidr##*/}"
    [ -z "$prefix" ] && prefix=24

    ip_dec=0
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    ip_dec=$(( (o1<<24) + (o2<<16) + (o3<<8) + o4 ))

    mask_dec=0
    for ((i=0; i<prefix; i++)); do
        mask_dec=$(( mask_dec + (1 << (31 - i)) ))
    done

    net_dec=$(( ip_dec & mask_dec ))
    echo "$(( (net_dec>>24) & 255 )).$(( (net_dec>>16) & 255 )).$(( (net_dec>>8) & 255 )).$(( net_dec & 255 ))/${prefix}"
}

etgw_show_interfaces() {
    echo -e "\n${BOLD}${CYAN}──────── 当前网络接口 ────────${RESET}"
    ip -br addr show 2>/dev/null || ip addr show
    echo -e "${BOLD}${CYAN}──────────────────────────────${RESET}"
}

etgw_prompt_interfaces() {
    local lan_def vpn_def
    lan_def=$(etgw_detect_lan_if)
    vpn_def=$(etgw_detect_vpn_if)

    etgw_show_interfaces

    while true; do
        read -r -e -p "请输入「局域网物理网卡」名称 (默认: ${lan_def}): " LAN_IF </dev/tty
        LAN_IF="${LAN_IF:-$lan_def}"
        if etgw_if_exists "$LAN_IF"; then
            break
        fi
        warn "接口 ${LAN_IF} 不存在，请重新输入（可参考上方接口列表）。"
    done

    while true; do
        read -r -e -p "请输入「EasyTier 虚拟网卡」名称 (默认: ${vpn_def}): " VPN_IF </dev/tty
        VPN_IF="${VPN_IF:-$vpn_def}"
        if etgw_if_exists "$VPN_IF"; then
            break
        fi
        # 允许接口暂不存在（EasyTier 可能尚未启动），但需二次确认
        warn "接口 ${VPN_IF} 当前不存在（EasyTier 可能未启动）。"
        read -r -p "仍使用该名称继续？[y/N]: " ans </dev/tty
        [[ "${ans:-N}" =~ ^[Yy]$ ]] && break
    done

    echo
    info "局域网物理网卡: ${CYAN}${LAN_IF}${RESET}"
    info "EasyTier 虚拟网卡: ${CYAN}${VPN_IF}${RESET}"

    # 采集网段信息，用于打印路由器静态路由命令
    local lan_cidr vpn_cidr
    lan_cidr=$(etgw_iface_cidr "$LAN_IF")
    vpn_cidr=$(etgw_iface_cidr "$VPN_IF")
    LAN_CIDR=$([ -n "$lan_cidr" ] && etgw_cidr_net "$lan_cidr" || echo "")
    VPN_CIDR=$([ -n "$vpn_cidr" ] && etgw_cidr_net "$vpn_cidr" || echo "")
    LAN_IP=$([ -n "$lan_cidr" ] && etgw_cidr_ip "$lan_cidr" || echo "")
    [ -n "$LAN_CIDR" ] && info "局域网网段: ${CYAN}${LAN_CIDR}${RESET}（本机 IP: ${LAN_IP}）"
    [ -n "$VPN_CIDR" ] && info "虚拟网网段: ${CYAN}${VPN_CIDR}${RESET}"
}

# ==============================================================================
# 回程路由策略选择
# ==============================================================================
etgw_prompt_lan_nat() {
    echo
    echo -e "${BOLD}${CYAN}──────── 回程路由策略 ────────${RESET}"
    echo -e "  VPN 侧设备访问局域网时，局域网设备的回包怎么回到本网关？"
    echo -e ""
    echo -e "  ${BOLD}1)${RESET} 路由器已加静态路由 / 局域网设备网关指向本机（${BOLD}默认，推荐${RESET}）"
    echo -e "     → 零 NAT，VPN 侧与局域网侧互见真实 IP"
    if [ -n "$VPN_CIDR" ] && [ -n "$LAN_IP" ]; then
        echo -e "     → 需在路由器上执行: ${CYAN}ip route add ${VPN_CIDR} via ${LAN_IP}${RESET}"
    else
        echo -e "     → 需在路由器上执行: ${CYAN}ip route add <虚拟网段> via <本机局域网IP>${RESET}"
    fi
    echo -e "  ${BOLD}2)${RESET} 路由器不可控，改不了路由表（兜底）"
    echo -e "     → 在局域网出口做 MASQUERADE，回包必然回到本机；"
    echo -e "       代价是局域网侧看到的来源 IP 是本网关的局域网 IP"
    echo -e ""
    read -r -p "请选择 [1/2]（默认: 1）: " ans </dev/tty
    case "${ans:-1}" in
        1) LAN_NAT="no"  ;;
        2) LAN_NAT="yes" ;;
        *) warn "无效选项，按默认 1 处理。"; LAN_NAT="no" ;;
    esac
}

# ==============================================================================
# 开启 IPv4 转发（独立 sysctl.d 文件，不动 /etc/sysctl.conf）
# ==============================================================================
etgw_enable_forward() {
    title "配置 IPv4 转发"
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] && [ -f "$SYSCTL_FILE" ]; then
        info "IPv4 转发已开启且已持久化。"
        return 0
    fi
    echo "net.ipv4.ip_forward=1" > "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE" >/dev/null
    info "IPv4 转发已开启并写入 ${SYSCTL_FILE}"
}

# 摘除 SNAT 链的挂载点与链本身（幂等，供 LAN_NAT=no 与卸载流程共用）
etgw_remove_snat() {
    while iptables -t nat -C POSTROUTING -j "$SNAT_CHAIN" 2>/dev/null; do
        iptables -t nat -D POSTROUTING -j "$SNAT_CHAIN"
    done
    iptables -t nat -F "$SNAT_CHAIN" 2>/dev/null || true
    iptables -t nat -X "$SNAT_CHAIN" 2>/dev/null || true
}

# ==============================================================================
# 应用规则（幂等：只清理/重建自己的链）
# ==============================================================================
etgw_apply_rules() {
    title "应用 iptables 转发规则"

    # ---- FORWARD 过滤：自定义链 ----
    iptables -N "$FWD_CHAIN" 2>/dev/null || true
    iptables -F "$FWD_CHAIN"

    # 已建立/相关连接放行（双向通信的状态维护）
    iptables -A "$FWD_CHAIN" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    # 局域网 → EasyTier
    iptables -A "$FWD_CHAIN" -i "$LAN_IF" -o "$VPN_IF" -j ACCEPT
    # EasyTier → 局域网
    iptables -A "$FWD_CHAIN" -i "$VPN_IF" -o "$LAN_IF" -j ACCEPT

    # 挂载点（幂等：已存在则不重复插入）
    if ! iptables -C FORWARD -j "$FWD_CHAIN" 2>/dev/null; then
        iptables -I FORWARD 1 -j "$FWD_CHAIN"
    fi

    # ---- NAT：默认不做 ----
    # EasyTier 的子网代理（[[proxy_network]] cidr）已把 LAN 网段通告给全网，
    # 远端节点天然有回程路由，再挂 MASQUERADE 只会抹掉真实来源 IP。
    # 仅当路由器加不了静态路由时，才用 LAN 出口 MASQUERADE 兜底回程。
    if [ "$LAN_NAT" = "yes" ]; then
        iptables -t nat -N "$SNAT_CHAIN" 2>/dev/null || true
        iptables -t nat -F "$SNAT_CHAIN"
        iptables -t nat -A "$SNAT_CHAIN" -o "$LAN_IF" -j MASQUERADE
        if ! iptables -t nat -C POSTROUTING -j "$SNAT_CHAIN" 2>/dev/null; then
            iptables -t nat -I POSTROUTING 1 -j "$SNAT_CHAIN"
        fi
        info "已启用 ${LAN_IF} 出口 MASQUERADE（回程兜底，LAN 侧看到的来源为本机 IP）。"
    else
        etgw_remove_snat
        info "零 NAT 模式：未添加任何 SNAT/MASQUERADE 规则。"
    fi

    # ---- MSS 钳制：解决 TUN MTU < 物理网卡 MTU 的黑洞问题 ----
    iptables -t mangle -N "$MSS_CHAIN" 2>/dev/null || true
    iptables -t mangle -F "$MSS_CHAIN"
    iptables -t mangle -A "$MSS_CHAIN" -p tcp --tcp-flags SYN,RST SYN \
             -j TCPMSS --clamp-mss-to-pmtu
    if ! iptables -t mangle -C FORWARD -j "$MSS_CHAIN" 2>/dev/null; then
        iptables -t mangle -I FORWARD 1 -j "$MSS_CHAIN"
    fi

    if [ "$LAN_NAT" = "yes" ]; then
        info "转发规则应用完成（自定义链: ${FWD_CHAIN} / ${SNAT_CHAIN} / ${MSS_CHAIN}）。"
    else
        info "转发规则应用完成（自定义链: ${FWD_CHAIN} / ${MSS_CHAIN}，无 NAT 链）。"
    fi
}

# ==============================================================================
# 持久化
# ==============================================================================
etgw_save_rules() {
    title "持久化 iptables 规则"
    if ! dpkg -s iptables-persistent &>/dev/null; then
        info "iptables-persistent 未安装，正在安装..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent
    fi
    netfilter-persistent save
    info "规则已保存，重启后自动恢复。"
}

# ==============================================================================
# 卸载
# ==============================================================================
etgw_uninstall() {
    title "卸载 EasyTier 旁路网关配置"

    # 摘除挂载点
    while iptables -C FORWARD -j "$FWD_CHAIN" 2>/dev/null; do
        iptables -D FORWARD -j "$FWD_CHAIN"
    done
    etgw_remove_snat
    while iptables -t mangle -C FORWARD -j "$MSS_CHAIN" 2>/dev/null; do
        iptables -t mangle -D FORWARD -j "$MSS_CHAIN"
    done

    # 删除自定义链（若有残留规则先清空）
    iptables -F "$FWD_CHAIN"  2>/dev/null || true
    iptables -X "$FWD_CHAIN"  2>/dev/null || true
    iptables -t mangle -F "$MSS_CHAIN" 2>/dev/null || true
    iptables -t mangle -X "$MSS_CHAIN" 2>/dev/null || true

    # 移除 sysctl 持久化文件（运行时 ip_forward 保持现状，避免影响其他转发场景）
    if [ -f "$SYSCTL_FILE" ]; then
        rm -f "$SYSCTL_FILE"
        info "已移除 ${SYSCTL_FILE}"
    fi

    # 更新持久化快照（否则下次重启旧规则又回来了）
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
        info "持久化快照已更新。"
    else
        warn "未安装 netfilter-persistent，跳过快照更新。"
    fi

    success "EasyTier 旁路网关配置已卸载。"
}

# ==============================================================================
# 清理旧版脚本规则（v1 直接写在 FORWARD / POSTROUTING 主链里）
# ==============================================================================
etgw_cleanup_legacy() {
    title "清理旧版脚本规则"

    echo -e "${YELLOW}旧版脚本把规则直接写在 FORWARD / POSTROUTING 主链中，${RESET}"
    echo -e "${YELLOW}与新版自定义链互不冲突但会重复生效，建议迁移前先清理。${RESET}"
    echo

    # 先展示当前主链规则，便于人工核对
    echo -e "${BOLD}${CYAN}──────── 当前 FORWARD 规则 ────────${RESET}"
    iptables -S FORWARD 2>/dev/null | grep -v -- "-j ET-FWD" || true
    echo
    echo -e "${BOLD}${CYAN}──────── 当前 POSTROUTING 规则 ────────${RESET}"
    iptables -t nat -S POSTROUTING 2>/dev/null | grep -v -- "-j ET-SNAT" || true
    echo

    # 询问旧脚本当时使用的接口名
    local lan_def vpn_def old_lan old_vpn
    lan_def=$(etgw_detect_lan_if)
    vpn_def=$(etgw_detect_vpn_if)
    read -r -e -p "旧脚本使用的「局域网物理网卡」名称 (默认: ${lan_def}): " old_lan </dev/tty
    old_lan="${old_lan:-$lan_def}"
    read -r -e -p "旧脚本使用的「VPN虚拟网卡」名称 (默认: ${vpn_def}): " old_vpn </dev/tty
    old_vpn="${old_vpn:-$vpn_def}"

    read -r -p "确认删除上述接口相关的旧版规则？[Y/n]: " ans </dev/tty
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消。"; return 0; }

    local n=0
    # 接口相关的转发规则（Docker 的规则只引用 docker* 接口，不会误删）
    while iptables -C FORWARD -i "$old_lan" -o "$old_vpn" -j ACCEPT 2>/dev/null; do
        iptables -D FORWARD -i "$old_lan" -o "$old_vpn" -j ACCEPT; n=$((n+1))
    done
    while iptables -C FORWARD -i "$old_vpn" -o "$old_lan" -j ACCEPT 2>/dev/null; do
        iptables -D FORWARD -i "$old_vpn" -o "$old_lan" -j ACCEPT; n=$((n+1))
    done
    # 旧版 NAT 伪装规则
    while iptables -t nat -C POSTROUTING -o "$old_vpn" -j MASQUERADE 2>/dev/null; do
        iptables -t nat -D POSTROUTING -o "$old_vpn" -j MASQUERADE; n=$((n+1))
    done
    info "已删除 ${n} 条旧版接口/NAT 规则。"

    # ESTABLISHED,RELATED 规则：可能与 Docker 等完全相同，无法区分归属。
    # 统计条数：若多于 1 条，删 1 条后仍有同类规则兜底，安全；
    # 若只有 1 条且来自旧脚本，删除后由新版 ET-FWD 链内的同款规则接管。
    local cnt
    cnt=$(iptables -S FORWARD 2>/dev/null | grep -c -- '-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT' || true)
    if [ "${cnt:-0}" -gt 0 ]; then
        warn "检测到 ${cnt} 条 ESTABLISHED,RELATED 规则（旧版脚本与 Docker 等可能写入同款）。"
        if [ "$cnt" -gt 1 ]; then
            info "多于 1 条，删除 1 条后仍有同类规则兜底，安全。"
            iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        else
            read -r -p "仅 1 条，删除它吗？(新版 ET-FWD 链会提供同款规则) [y/N]: " ans </dev/tty
            if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
                iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
                info "已删除。"
            else
                info "保留该规则（无碍，仅为冗余）。"
            fi
        fi
    fi

    # sysctl.conf 中旧版写入的 ip_forward 行：改为注释（新版走 sysctl.d 独立文件）
    if grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        warn "/etc/sysctl.conf 中存在旧版写入的 ip_forward=1。"
        read -r -p "将其注释掉吗？(新版使用 /etc/sysctl.d/ 独立文件) [y/N]: " ans </dev/tty
        if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
            sed -i 's/^net.ipv4.ip_forward=1/#net.ipv4.ip_forward=1/' /etc/sysctl.conf
            info "已注释。"
        else
            info "保留（无碍，仅为冗余）。"
        fi
    fi

    # 更新持久化快照，否则重启后旧规则复活
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
        info "持久化快照已更新。"
    else
        warn "未安装 netfilter-persistent，跳过快照更新。"
    fi

    success "旧版规则清理完成，请继续执行【配置/更新转发规则】完成迁移。"
}

# ==============================================================================
# 状态查看
# ==============================================================================
etgw_status() {
    title "EasyTier 旁路网关状态"

    echo -e "${BOLD}IPv4 转发:${RESET}" >&2
    local fwd
    fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "?")
    if [ "$fwd" = "1" ]; then
        echo -e "  ${GREEN}已开启 ✓${RESET} (持久化: $([ -f "$SYSCTL_FILE" ] && echo "是" || echo "否"))"
    else
        echo -e "  ${RED}未开启 ✗${RESET}"
    fi

    echo
    echo -e "${BOLD}转发链 ${FWD_CHAIN}:${RESET}" >&2
    iptables -S "$FWD_CHAIN" 2>/dev/null || echo -e "  ${YELLOW}不存在（未安装）${RESET}"

    echo
    echo -e "${BOLD}NAT 链 ${SNAT_CHAIN}:${RESET}" >&2
    iptables -t nat -S "$SNAT_CHAIN" 2>/dev/null || echo -e "  ${YELLOW}不存在（零 NAT 模式，正常）${RESET}"

    echo
    echo -e "${BOLD}MSS 钳制链 ${MSS_CHAIN}:${RESET}" >&2
    iptables -t mangle -S "$MSS_CHAIN" 2>/dev/null || echo -e "  ${YELLOW}不存在（未安装）${RESET}"

    echo
    echo -e "${BOLD}实时转发计数（前 10 条）:${RESET}" >&2
    iptables -vL "$FWD_CHAIN" 2>/dev/null | head -10 || true
}

# ==============================================================================
# 安装主流程
# ==============================================================================
etgw_install() {
    title "配置 EasyTier 旁路网关"

    etgw_prompt_interfaces
    etgw_prompt_lan_nat

    # 确认
    echo -e "\n${BOLD}${CYAN}──────── 配置确认 ────────${RESET}"
    echo -e "  局域网网卡:   ${CYAN}${LAN_IF}${RESET}"
    echo -e "  EasyTier 网卡: ${CYAN}${VPN_IF}${RESET}"
    echo -e "  LAN 出口 NAT: ${CYAN}$([ "$LAN_NAT" = "yes" ] && echo "启用（回程兜底，来源显示为网关 IP）" || echo "停用（零 NAT，需路由器静态路由）")${RESET}"
    echo -e "  规则载体:     ${CYAN}自定义链（不影响 Docker 等既有规则）${RESET}"
    echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
    read -r -p "确认应用？[Y/n]: " ans </dev/tty
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消。"; return 0; }

    etgw_enable_forward
    etgw_apply_rules
    etgw_save_rules

    echo
    success "EasyTier 旁路网关配置完成！"
    echo -e "  ${YELLOW}提示: 已启用 MSS 钳制，避免 TUN MTU 导致网页打不开。${RESET}"
    echo -e "  ${YELLOW}提示: EasyTier 侧需配置子网代理，在配置文件中加入：${RESET}"
    if [ -n "$LAN_CIDR" ]; then
        echo -e "        ${CYAN}[[proxy_network]]${RESET}"
        echo -e "        ${CYAN}cidr = \"${LAN_CIDR}\"${RESET}"
    else
        echo -e "        ${CYAN}[[proxy_network]]${RESET}"
        echo -e "        ${CYAN}cidr = \"<局域网网段，如 192.168.3.0/24>\"${RESET}"
    fi
    echo
    if [ "$LAN_NAT" = "yes" ]; then
        echo -e "  ${GREEN}当前为 MASQUERADE 兜底模式，现在起两个网段应已互通。${RESET}"
        echo -e "  ${YELLOW}注意: 局域网侧看到的来源 IP 是本机的局域网 IP（${LAN_IP:-本机}），非 VPN 源 IP。${RESET}"
    else
        echo -e "  ${GREEN}当前为零 NAT 模式，还需给回程指路，否则 VPN→LAN 单向不通。${RESET}"
        echo -e "  ${BOLD}方式 A（推荐，改一处即可双向互通）${RESET} —— 在路由器上加静态路由，"
        echo -e "      因为局域网设备的默认网关本来就是路由器，这一条同时覆盖去程与回程："
        if [ -n "$VPN_CIDR" ] && [ -n "$LAN_IP" ]; then
            echo -e "      ${CYAN}ip route add ${VPN_CIDR} via ${LAN_IP}${RESET}"
        else
            echo -e "      ${CYAN}ip route add <虚拟网段> via <本机局域网IP>${RESET}"
        fi
        echo -e "  ${BOLD}方式 B（路由器不可控时，逐台设备）${RESET} —— 二选一："
        if [ -n "$VPN_CIDR" ] && [ -n "$LAN_IP" ]; then
            echo -e "    ${BOLD}B-1 明细路由（推荐）${RESET} 仅 VPN 流量过本机，公网照常走路由器："
            echo -e "      Linux:   ${CYAN}ip route add ${VPN_CIDR} via ${LAN_IP}${RESET}"
            echo -e "      Windows: ${CYAN}route -p add ${VPN_CIDR} mask 255.255.255.0 ${LAN_IP}${RESET}"
            echo -e "    ${BOLD}B-2 整个网关指向本机${RESET}：把设备网关填 ${CYAN}${LAN_IP}${RESET}"
            echo -e "      ${YELLOW}注意: 该设备的全部流量（含公网）都过本机，本机成为其单点故障；${RESET}"
            echo -e "      ${YELLOW}      同接口进出还会触发 ICMP 重定向，导致流量路径不一致。${RESET}"
        else
            echo -e "    ${BOLD}B-1 明细路由（推荐）${RESET} Linux: ${CYAN}ip route add <虚拟网段> via <本机局域网IP>${RESET}"
            echo -e "    ${BOLD}B-2 整个网关指向本机${RESET}（全部流量过本机，有单点故障风险）"
        fi
    fi
}

# ==============================================================================
# 主菜单
# ==============================================================================
etgw_menu() {
    etgw_check_deps

    while true; do
        clear || true
        echo -e "${BOLD}${CYAN}"
        echo "╔══════════════════════════════════════╗"
        echo "║   EasyTier 旁路网关管理脚本 (Debian) ║"
        echo "╚══════════════════════════════════════╝"
        echo -e "${RESET}"

        echo -e "${BOLD}请选择操作:${RESET}"
        echo -e "  ${BOLD}1)${RESET} 配置/更新转发规则"
        echo -e "  ${BOLD}2)${RESET} 查看状态"
        echo -e "  ${BOLD}3)${RESET} 卸载"
        echo -e "  ${BOLD}4)${RESET} 清理旧版脚本规则（v1 迁移用）"
        echo -e "  ${BOLD}0)${RESET} 返回上级菜单"
        printf "请输入选项 [0-4]: "

        read -r etgw_choice </dev/tty
        case "$etgw_choice" in
            1) etgw_install        ;;
            2) etgw_status         ;;
            3) etgw_uninstall      ;;
            4) etgw_cleanup_legacy ;;
            0) return 0 ;;
            *) warn "无效选项 '${etgw_choice}'，请重新输入。" ;;
        esac

        echo ""
        printf "${YELLOW}按回车键返回上级菜单...${RESET}" >&2
        read -r </dev/tty
    done
}

# ================================================================
# 主入口
# ================================================================
check_root
install_deps
ARCH=$(get_arch)
main_menu
