#!/bin/bash
# ================================================================
# EasyTier 一键管理脚本（全交互式）
# 直接运行后通过菜单完成所有操作，无需记忆命令参数
# ================================================================
set -euo pipefail

# ----------------------------------------------------------------
# 常量定义
# ----------------------------------------------------------------
readonly INSTALL_DIR="/root/easytier"
readonly SERVICE_FILE="/etc/systemd/system/easytier.service"
readonly SERVICE_NAME="easytier"
readonly CONFIG_FILE="/etc/easytier/easytier.yaml"
readonly DEFAULT_CONSOLE_HOST="cfgs.175419.xyz"
readonly DEFAULT_CONSOLE_PORT="22020"
readonly LOCAL_MIRROR="http://47.98.36.99:8888/chfs/shared/easytier"

# 服务运行模式
# console       : 连接控制台（命令行参数）
# console_file  : 连接控制台（使用配置文件）
# relay         : 不连接控制台，以服务端/中继模式运行
readonly MODE_CONSOLE="console"
readonly MODE_CONSOLE_FILE="console_file"
readonly MODE_RELAY="relay"

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
        apt-get update -y -qq && apt-get install -y -qq "${missing[@]}"
    elif [ -f /etc/redhat-release ]; then
        yum install -y -q "${missing[@]}"
    elif [ -f /etc/alpine-release ]; then
        apk add --quiet "${missing[@]}"
    else
        error "无法自动安装依赖，请手动安装: ${missing[*]}"
        exit 1
    fi
    info "依赖安装完成。"
}

# ----------------------------------------------------------------
# 获取 CPU 架构
# ----------------------------------------------------------------
get_arch() {
    case $(uname -m) in
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
    grep -oP '(?<=-w "udp://)[^/]+' "$SERVICE_FILE" 2>/dev/null || echo ""
}

read_current_username() {
    if [ ! -f "$SERVICE_FILE" ]; then
        echo ""
        return
    fi
    grep -oP '(?<=udp://[^/]{1,200}/)([^"]+)' "$SERVICE_FILE" 2>/dev/null | head -1 || echo ""
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
    _read_yaml_val "hostname" | head -1
}

# 读取网络名称
read_current_network_name() {
    _read_yaml_val "network_name" | head -1
}

# 读取网络密钥
read_current_network_secret() {
    _read_yaml_val "network_secret" | head -1
}

# 读取本机虚拟 IP
read_current_conf_ipv4() {
    _read_yaml_val "ipv4" | head -1
}

# 读取是否 dhcp
read_current_conf_dhcp() {
    _read_yaml_val "dhcp" | head -1
}

# 读取 peer URI
read_current_conf_peer_uri() {
    grep -E '^\[\[peer\]\]' "$CONFIG_FILE" -A 1 2>/dev/null | grep "^uri\s*=" | sed 's/^uri\s*=\s*//' | tr -d '"' | tr -d "'" | xargs | awk '{print $1}'
}

# 读取子网代理 CIDR
read_current_conf_proxy_cidr() {
    grep -E '^\[\[proxy_network\]\]' "$CONFIG_FILE" -A 1 2>/dev/null | grep "^cidr\s*=" | sed 's/^cidr\s*=\s*//' | tr -d '"' | tr -d "'" | xargs | awk '{print $1}'
}

# 读取加密开关
read_current_conf_encryption() {
    _read_yaml_val "enable_encryption" | head -1
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
            echo -e "  运行模式: ${CYAN}客户端模式（命令行参数）${RESET}"
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
    echo -e "${BOLD}${CYAN}──────────────────────────────────${RESET}\n"
}

# ================================================================
# 主菜单
# ================================================================
main_menu() {
    while true; do
        clear
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
        echo -e "  ${BOLD}${RED}5)${RESET} 卸载 EasyTier"
        echo -e "  ${BOLD}6)${RESET} 查看运行日志"
        echo -e "  ${BOLD}0)${RESET} 退出"
        echo
        printf "请输入选项 [0-6]: "
        read -r choice </dev/tty

        case "$choice" in
            1) do_install "$MODE_CONSOLE" ;;
            2) do_install "$MODE_RELAY"   ;;
            3) do_modify   ;;
            4) do_update   ;;
            5) do_uninstall;;
            6) do_show_log ;;
            0)
                echo -e "\n${GREEN}再见！${RESET}"
                exit 0
                ;;
            *)
                warn "无效选项 '${choice}'，请输入 0~6。"
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
# 交互：输入控制台地址
# ----------------------------------------------------------------
prompt_console() {
    local cur_console cur_host cur_port
    cur_console=$(read_current_config)

    if [ -n "$cur_console" ]; then
        cur_host="${cur_console%%:*}"
        cur_port="${cur_console##*:}"
    else
        cur_host="$DEFAULT_CONSOLE_HOST"
        cur_port="$DEFAULT_CONSOLE_PORT"
    fi

    local host port

    while true; do
        printf "请输入控制台 IP 或域名 (当前: ${CYAN}%s${RESET}，直接回车保留): " "$cur_host" >&2
        read -r host </dev/tty
        host="${host:-$cur_host}"
        if [[ "$host" =~ [[:space:]] ]]; then
            warn "IP/域名不能包含空格，请重新输入。"
            continue
        fi
        break
    done

    while true; do
        printf "请输入控制台端口号 (当前: ${CYAN}%s${RESET}，直接回车保留): " "$cur_port" >&2
        read -r port </dev/tty
        port="${port:-$cur_port}"
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            warn "端口号无效（需为 1~65535 之间的整数），请重新输入。"
            continue
        fi
        break
    done

    info "控制台地址: ${host}:${port}"
    echo "${host}:${port}"
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

# 节点服务器地址（peer URI）
prompt_peer_uri() {
    local cur default
    cur=$(read_current_conf_peer_uri)
    default="${cur:-}"

    while true; do
        if [ -n "$default" ]; then
            printf "请输入节点服务器地址 (peer URI，直接回车保留): " >&2
            printf "\n  当前: ${CYAN}%s${RESET}\n" "$default" >&2
            printf "  (留空回车保留，或输入新地址，如: udp://1.2.3.4:11010): " >&2
        else
            printf "请输入节点服务器地址 (peer URI，如: ${CYAN}udp://1.2.3.4:11010${RESET}): " >&2
        fi
        read -r val </dev/tty
        val="${val:-$default}"
        # 留空也允许，不强制
        echo "$val"
        return
    done
}

# 子网代理
prompt_proxy_network() {
    local cur default
    cur=$(read_current_conf_proxy_cidr)
    default="$cur"

    while true; do
        printf "是否配置子网代理？如需访问本机局域网请输入 CIDR，否则直接回车跳过:\n" >&2
        printf "  (例如: ${CYAN}192.168.1.0/24${RESET}，直接回车跳过): " >&2
        read -r val </dev/tty
        val="${val:-$default}"
        if [ -z "$val" ]; then
            echo ""
            return
        fi
        if ! [[ "$val" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            warn "CIDR 格式无效，请输入类似 192.168.1.0/24 的格式。"
            continue
        fi
        echo "$val"
        return
    done
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

    mkdir -p "$(dirname "$CONFIG_FILE")"

    # 写入配置（TOML 格式）
    cat > "$CONFIG_FILE" <<EOF
# EasyTier 配置文件，由 easytier.sh 自动生成
# 如需手动修改，建议先备份

hostname = "${hostname}"
ipv4 = "${ipv4_mode}"
dhcp = $([ "$ipv4_mode" = "dhcp" ] && echo "true" || echo "false")
listeners = []

[network_identity]
network_name = "${network_name}"
network_secret = "${network_secret}"
EOF

    # peer URI（可选）
    if [ -n "$peer_uri" ]; then
        cat >> "$CONFIG_FILE" <<EOF

[[peer]]
uri = "${peer_uri}"
EOF
    fi

    # 子网代理（可选）
    if [ -n "$proxy_cidr" ]; then
        cat >> "$CONFIG_FILE" <<EOF

[[proxy_network]]
cidr = "${proxy_cidr}"
EOF
    fi

    cat >> "$CONFIG_FILE" <<EOF

[flags]
enable_encryption = ${encryption}
default_protocol = "udp"
EOF

    info "配置文件已写入: ${CONFIG_FILE}"
}

# ----------------------------------------------------------------
# 切换到命令行参数模式（do_modify 辅助函数）
# ----------------------------------------------------------------
_do_switch_to_console_mode() {
    local username node_hostname console_addr
    username=$(prompt_username)
    node_hostname=$(prompt_hostname)
    console_addr=$(prompt_console)

    echo -e "\n${BOLD}${CYAN}──────── 修改确认 ────────${RESET}"
    echo -e "  新模式:   ${CYAN}客户端模式（命令行参数）${RESET}"
    echo -e "  用户名:   ${CYAN}${username}${RESET}"
    echo -e "  机器名:   ${CYAN}${node_hostname}${RESET}"
    echo -e "  控制台:   ${CYAN}${console_addr}${RESET}"
    echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
    printf "${YELLOW}确认切换并重启服务？[Y/n]: ${RESET}" >&2
    read -r ans </dev/tty
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消。"; return 0; }

    rm -f "$CONFIG_FILE"
    apply_service "$MODE_CONSOLE" "$username" "$node_hostname" "$console_addr"
    show_status
}

# ----------------------------------------------------------------
# 切换到配置文件模式（do_modify 辅助函数）
# ----------------------------------------------------------------
_do_switch_to_config_mode() {
    info "直接回车可保留当前值。"

    local cfg_hostname cfg_netname cfg_netsec cfg_ip_mode cfg_peer cfg_proxy cfg_enc

    echo -e "\n${BOLD}── hostname ──${RESET}" >&2
    cfg_hostname=$(prompt_hostname)
    cfg_netname=$(prompt_network_name)
    cfg_netsec=$(prompt_network_secret)
    cfg_ip_mode=$(prompt_ipv4)
    cfg_peer=$(prompt_peer_uri)
    cfg_proxy=$(prompt_proxy_network)
    cfg_enc=$(prompt_encryption)

    echo -e "\n${BOLD}${CYAN}──────── 修改确认 ────────${RESET}"
    echo -e "  新模式:   ${CYAN}客户端模式（配置文件）${RESET}"
    echo -e "  主机名:   ${CYAN}${cfg_hostname}${RESET}"
    echo -e "  网络名称: ${CYAN}${cfg_netname}${RESET}"
    echo -e "  网络密钥: ${CYAN}${cfg_netsec}${RESET}"
    echo -e "  IP 方式:  ${CYAN}${cfg_ip_mode}${RESET}"
    [ -n "$cfg_peer"  ] && echo -e "  节点地址: ${CYAN}${cfg_peer}${RESET}"
    [ -n "$cfg_proxy" ] && echo -e "  子网代理: ${CYAN}${cfg_proxy}${RESET}"
    echo -e "  启用加密: ${CYAN}${cfg_enc}${RESET}"
    echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
    printf "${YELLOW}确认切换并重启服务？[Y/n]: ${RESET}" >&2
    read -r ans </dev/tty
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消。"; return 0; }

    write_config_file "$cfg_hostname" "$cfg_netname" "$cfg_netsec" "$cfg_ip_mode" "$cfg_peer" "$cfg_proxy" "$cfg_enc"
    apply_service "$MODE_CONSOLE_FILE"
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
# 交互：选择版本
# ----------------------------------------------------------------
prompt_version() {
    local choice ver

    while true; do
        printf "\n请选择要安装的 EasyTier 版本:\n" >&2
        printf "  ${BOLD}1)${RESET} v2.4.5（稳定版，默认）\n" >&2
        printf "  ${BOLD}2)${RESET} v2.6.0（最新版）\n" >&2
        printf "  ${BOLD}3)${RESET} 手动输入版本号\n" >&2
        printf "请输入选项 [1/2/3]（默认: 1）: " >&2
        read -r choice </dev/tty
        choice="${choice:-1}"

        case "$choice" in
            1) ver="v2.4.5"; break ;;
            2) ver="v2.6.0"; break ;;
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
        cat <<EOF
[Unit]
Description=EasyTier Relay Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/easytier-core \
  --hostname "${relay_hostname}" \
  --listeners "tcp://0.0.0.0:${tcp_port}" "udp://0.0.0.0:${udp_port}" "ws://0.0.0.0:${ws_port}" "wss://0.0.0.0:${wss_port}" \
  --relay-network-whitelist "*" \
  --relay-all-peer-rpc
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    elif [ "$mode" = "$MODE_CONSOLE_FILE" ]; then
        # 配置文件模式，仅指定 -c 参数
        cat <<EOF
[Unit]
Description=EasyTier Service (Config File Mode)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/easytier-core -c ${CONFIG_FILE}
Restart=always
RestartSec=5
LimitNOFILE=1048576
Environment=TOKIO_CONSOLE=1

[Install]
WantedBy=multi-user.target
EOF
    else
        local username="$2"
        local node_hostname="$3"
        local console_addr="$4"
        local relay_hostname="$2"
        local tcp_port="$3"
        local udp_port="$4"
        local ws_port="$5"
        local wss_port="$6"
        cat <<EOF
[Unit]
Description=EasyTier Relay Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/easytier-core \
  --hostname "${relay_hostname}" \
  --listeners "tcp://0.0.0.0:${tcp_port}" "udp://0.0.0.0:${udp_port}" "ws://0.0.0.0:${ws_port}" "wss://0.0.0.0:${wss_port}" \
  --relay-network-whitelist "*" \
  --relay-all-peer-rpc
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    else
        local username="$2"
        local node_hostname="$3"
        local console_addr="$4"
        cat <<EOF
[Unit]
Description=EasyTier Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/easytier-core -w "udp://${console_addr}/${username}" --hostname "${node_hostname}"
Restart=always
RestartSec=5
LimitNOFILE=1048576
Environment=TOKIO_CONSOLE=1

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
# 显示最近日志并判断启动状态
# ----------------------------------------------------------------
show_status() {
    local wait_sec=3
    info "等待服务启动（${wait_sec}s）..."
    sleep "$wait_sec"

    echo -e "\n${BOLD}────────── 最近 15 条日志 ──────────${RESET}" >&2
    journalctl -u "${SERVICE_NAME}.service" -n 15 --no-pager 2>/dev/null || true
    echo -e "${BOLD}────────────────────────────────────${RESET}\n" >&2

    local svc_active
    svc_active=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)

    if [ "$svc_active" != "active" ]; then
        echo -e "${RED}${BOLD}✗ 操作失败${RESET}" >&2
        error "服务状态异常（systemctl 报告: ${svc_active}），请检查上方日志。"
        info  "可运行以下命令查看完整日志:"
        echo  "    journalctl -xe -u ${SERVICE_NAME}.service" >&2
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
    success "EasyTier 已成功连接并启动。"
    info "如需持续监控日志，运行:"
    echo "    journalctl -f -u ${SERVICE_NAME}.service" >&2
}

# ================================================================
# 操作：全新安装
# ================================================================
do_install() {
    local mode="${1:-}"

    # 中继/服务端模式
    if [ "$mode" = "$MODE_RELAY" ]; then
        title "EasyTier 服务端/中继模式安装"

        if [ -f "$SERVICE_FILE" ] || [ -f "${INSTALL_DIR}/easytier-core" ]; then
            warn "检测到已有安装！全新安装将会覆盖现有程序和服务。"
            printf "${YELLOW}确认继续？[y/N]: ${RESET}" >&2
            read -r ans </dev/tty
            [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消安装。"; return 0; }
        fi

        echo -e "\n${BOLD}── 第 1 步：选择版本 ──${RESET}" >&2
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

        echo -e "\n${BOLD}── 第 3 步：配置服务端信息 ──${RESET}" >&2
        info "主机名将显示在 EasyTier 网络拓扑中，默认使用本机系统名。"
        local relay_hostname
        relay_hostname=$(prompt_relay_hostname)

        echo -e "\n${BOLD}── 第 4 步：配置侦听端口 ──${RESET}" >&2
        info "服务端需要对外开放以下端口，建议在防火墙/安全组中放行对应端口。"
        local ports_str tcp_port udp_port ws_port wss_port
        ports_str=$(prompt_listen_ports)
        read -r tcp_port udp_port ws_port wss_port <<< "$ports_str"

        echo -e "\n${BOLD}${CYAN}──────── 安装确认 ────────${RESET}"
        echo -e "  模式:     ${CYAN}服务端/中继模式${RESET}（不连接控制台）"
        echo -e "  版本:     ${CYAN}${version}${RESET}"
        echo -e "  下载方式: ${CYAN}${dm_label}${RESET}"
        echo -e "  主机名:   ${CYAN}${relay_hostname}${RESET}"
        echo -e "  TCP 端口: ${CYAN}${tcp_port}${RESET}"
        echo -e "  UDP 端口: ${CYAN}${udp_port}${RESET}"
        echo -e "  WS  端口: ${CYAN}${ws_port}${RESET}"
        echo -e "  WSS 端口: ${CYAN}${wss_port}${RESET}"
        echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
        printf "${YELLOW}确认安装？[Y/n]: ${RESET}" >&2
        read -r ans </dev/tty
        ans="${ans:-Y}"
        [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消安装。"; return 0; }

        info "模式: 服务端/中继 | 版本: $version | 架构: $ARCH | 下载方式: ${dm_label}"
        [ -d "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR"
        download_and_extract "$ARCH" "$version" "$download_method"
        apply_service "$MODE_RELAY" "$relay_hostname" "$tcp_port" "$udp_port" "$ws_port" "$wss_port"
        show_status
        return
    fi

    # 客户端模式（连接控制台）
    title "EasyTier 客户端模式安装"

    if [ -f "$SERVICE_FILE" ] || [ -f "${INSTALL_DIR}/easytier-core" ]; then
        warn "检测到已有安装！全新安装将会覆盖现有程序和服务。"
        printf "${YELLOW}确认继续？[y/N]: ${RESET}" >&2
        read -r ans </dev/tty
        [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消安装。"; return 0; }
    fi

    echo -e "\n${BOLD}── 第 1 步：选择安装方式 ──${RESET}" >&2
    local install_method
    while true; do
        printf "请选择客户端安装方式:\n" >&2
        printf "  ${BOLD}1)${RESET} 命令行参数模式（输入用户名、机器名、控制台地址）\n" >&2
        printf "  ${BOLD}2)${RESET} 配置文件模式（输入网络名称、密钥、节点地址等，写入 YAML）\n" >&2
        printf "请输入选项 [1/2]（默认: 2）: " >&2
        read -r install_method </dev/tty
        install_method="${install_method:-2}"
        case "$install_method" in
            1|2) break ;;
            *) warn "无效选项，请输入 1 或 2。" ;;
        esac
    done

    echo -e "\n${BOLD}── 第 2 步：选择版本 ──${RESET}" >&2
    local version
    version=$(prompt_version)

    echo -e "\n${BOLD}── 第 3 步：选择下载方式 ──${RESET}" >&2
    local download_method dm_label
    download_method=$(prompt_download_method)
    case "$download_method" in
        local)  dm_label="本地镜像" ;;
        proxy)  dm_label="GitHub 代理" ;;
        direct) dm_label="GitHub 直连" ;;
    esac

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
        echo -e "  启用加密: ${CYAN}${cfg_enc}${RESET}"
        echo -e "  配置文件: ${CYAN}${CONFIG_FILE}${RESET}"
        echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
        printf "${YELLOW}确认安装？[Y/n]: ${RESET}" >&2
        read -r ans </dev/tty
        ans="${ans:-Y}"
        [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消安装。"; return 0; }

        info "版本: $version | 架构: $ARCH | 下载方式: ${dm_label}"
        [ -d "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR"
        download_and_extract "$ARCH" "$version" "$download_method"
        write_config_file "$cfg_hostname" "$cfg_netname" "$cfg_netsec" "$cfg_ip_mode" "$cfg_peer" "$cfg_proxy" "$cfg_enc"
        apply_service "$MODE_CONSOLE_FILE"
        show_status
        return
    fi

    # ── 方式 1：命令行参数模式 ──
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
    echo -e "  模式:     ${CYAN}客户端模式（命令行参数）${RESET}"
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
    [ -d "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR"
    download_and_extract "$ARCH" "$version" "$download_method"
    apply_service "$MODE_CONSOLE" "$username" "$node_hostname" "$console_addr"
    show_status
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

                echo -e "\n${BOLD}${CYAN}──────── 修改确认 ────────${RESET}"
                echo -e "  主机名:   ${CYAN}${relay_hostname}${RESET}"
                echo -e "  TCP 端口: ${CYAN}${tcp_port}${RESET}"
                echo -e "  UDP 端口: ${CYAN}${udp_port}${RESET}"
                echo -e "  WS  端口: ${CYAN}${ws_port}${RESET}"
                echo -e "  WSS 端口: ${CYAN}${wss_port}${RESET}"
                echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
                printf "${YELLOW}确认修改并重启服务？[Y/n]: ${RESET}" >&2
                read -r ans </dev/tty
                ans="${ans:-Y}"
                [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消修改。"; return 0; }

                apply_service "$MODE_RELAY" "$relay_hostname" "$tcp_port" "$udp_port" "$ws_port" "$wss_port"
                show_status
                return
                ;;
            2)
                # 切换到客户端模式
                echo -e "\n${BOLD}── 选择切换后的客户端安装方式 ──${RESET}" >&2
                local switch_method
                while true; do
                    printf "请选择客户端安装方式:\n" >&2
                    printf "  ${BOLD}1)${RESET} 命令行参数模式\n" >&2
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
        echo -e "  ${BOLD}${GREEN}1)${RESET} 修改配置文件参数"
        echo -e "  ${BOLD}${YELLOW}2)${RESET} 切换为命令行参数模式"
        echo -e "  ${BOLD}0)${RESET} 取消，返回主菜单"
        printf "请输入选项 [0/1/2]: " >&2
        read -r cf_choice </dev/tty

        case "$cf_choice" in
            1)
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

                echo -e "\n${BOLD}${CYAN}──────── 修改确认 ────────${RESET}"
                echo -e "  主机名:   ${CYAN}${cfg_hostname}${RESET}"
                echo -e "  网络名称: ${CYAN}${cfg_netname}${RESET}"
                echo -e "  网络密钥: ${CYAN}${cfg_netsec}${RESET}"
                echo -e "  IP 方式:  ${CYAN}${cfg_ip_mode}${RESET}"
                [ -n "$cfg_peer"   ] && echo -e "  节点地址: ${CYAN}${cfg_peer}${RESET}"
                [ -n "$cfg_proxy"  ] && echo -e "  子网代理: ${CYAN}${cfg_proxy}${RESET}"
                echo -e "  启用加密: ${CYAN}${cfg_enc}${RESET}"
                echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
                printf "${YELLOW}确认修改并重启服务？[Y/n]: ${RESET}" >&2
                read -r ans </dev/tty
                ans="${ans:-Y}"
                [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消修改。"; return 0; }

                write_config_file "$cfg_hostname" "$cfg_netname" "$cfg_netsec" "$cfg_ip_mode" "$cfg_peer" "$cfg_proxy" "$cfg_enc"
                apply_service "$MODE_CONSOLE_FILE"
                show_status
                return
                ;;
            2)
                echo -e "\n${BOLD}── 切换为命令行参数模式 ──${RESET}" >&2
                _do_switch_to_console_mode
                return
                ;;
            *)
                info "已取消。"
                return 0
                ;;
        esac
    fi

    info "当前为客户端模式（命令行参数），直接回车可保留现有值："

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
    echo -e "  ${BOLD}2)${RESET} 实时追踪日志（Ctrl+C 退出）"
    echo -e "  ${BOLD}3)${RESET} 查看今日全部日志"
    printf "请输入选项 [1/2/3]（默认: 1）: "
    read -r choice </dev/tty
    choice="${choice:-1}"

    case "$choice" in
        1)
            journalctl -u "${SERVICE_NAME}.service" -n 50 --no-pager 2>/dev/null || true
            ;;
        2)
            info "开始实时追踪日志，按 Ctrl+C 退出..."
            journalctl -f -u "${SERVICE_NAME}.service" 2>/dev/null || true
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
# 主入口
# ================================================================
check_root
install_deps
ARCH=$(get_arch)
main_menu
