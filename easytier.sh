#!/bin/bash
# ================================================================
# EasyTier 一键管理脚本
# 支持: install | modify | uninstall | update
# ================================================================
set -euo pipefail

# ----------------------------------------------------------------
# 常量定义
# ----------------------------------------------------------------
readonly INSTALL_DIR="/root/easytier"
readonly SERVICE_FILE="/etc/systemd/system/easytier.service"
readonly SERVICE_NAME="easytier"
readonly TMP_ZIP="/tmp/easytier_$$.zip"
readonly DEFAULT_CONSOLE_HOST="cfgs.175419.xyz"
readonly DEFAULT_CONSOLE_PORT="22020"
readonly DEFAULT_VERSION="v2.4.5"
readonly VERSION_URL="http://etsh2.442230.xyz/etver"
readonly LOCAL_MIRROR="http://47.98.36.99:8888/chfs/shared/easytier"

readonly PROXY_LIST=(
    "https://ghfast.top/"
    "https://docker.mk/"
    "https://gh-proxy.com/"
)

# ----------------------------------------------------------------
# 彩色输出（全部输出到 stderr）
# ----------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${GREEN}[INFO]${RESET}  $*" >&2; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
title()   { echo -e "\n${BOLD}${BLUE}>>> $* ${RESET}" >&2; }
success() { echo -e "${BOLD}${GREEN}$*${RESET}" >&2; }

# ----------------------------------------------------------------
# 清理函数
# ----------------------------------------------------------------
cleanup() {
    rm -f "$TMP_ZIP"
}
trap cleanup EXIT
trap 'error "脚本被中断"; exit 130' INT TERM

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
# 帮助信息
# ----------------------------------------------------------------
usage() {
    echo -e "${BOLD}用法:${RESET} $0 [install|modify|uninstall|update] [username] [hostname]" >&2
    echo "" >&2
    echo "  install   <username> <hostname>  全新安装 EasyTier 服务" >&2
    echo "  modify    <username> <hostname>  修改配置并重启服务" >&2
    echo "  uninstall                        卸载服务并删除所有文件" >&2
    echo "  update                           更新程序文件（保留配置）" >&2
    echo "" >&2
    echo -e "${BOLD}示例:${RESET}" >&2
    echo "  $0 install myuser my-node-name" >&2
    echo "  $0 modify  myuser new-node-name" >&2
    echo "  $0 uninstall" >&2
    echo "  $0 update" >&2
    exit 1
}

# ----------------------------------------------------------------
# 获取 EasyTier 版本号
# 所有提示走 stderr，只有版本号字符串走 stdout
# ----------------------------------------------------------------
get_version() {
    local ver
    ver=$(curl -fsSL --connect-timeout 5 "$VERSION_URL" 2>/dev/null || true)
    if [ -z "$ver" ]; then
        warn "无法从 $VERSION_URL 获取版本号，使用默认版本 $DEFAULT_VERSION"
        echo "$DEFAULT_VERSION"
    else
        echo "$ver"
    fi
}

# ----------------------------------------------------------------
# 获取控制台地址
# 使用 /dev/tty 直接读取终端输入，避免 $() 子shell中 stdin 被关闭
# 所有提示走 stderr，只有 "host:port" 走 stdout
# ----------------------------------------------------------------
get_console_host() {
    local host port

    # 输入 IP 或域名
    while true; do
        read -r -p "请输入控制台 IP 或域名 (默认: ${DEFAULT_CONSOLE_HOST}): " host </dev/tty
        host="${host:-$DEFAULT_CONSOLE_HOST}"
        if [[ "$host" =~ [[:space:]] ]]; then
            warn "IP/域名不能包含空格，请重新输入。"
            continue
        fi
        break
    done

    # 输入端口号
    while true; do
        read -r -p "请输入控制台端口号 (默认: ${DEFAULT_CONSOLE_PORT}): " port </dev/tty
        port="${port:-$DEFAULT_CONSOLE_PORT}"
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            warn "端口号无效（需为 1~65535 之间的整数），请重新输入。"
            continue
        fi
        break
    done

    info "控制台地址: ${host}:${port}"
    echo "${host}:${port}"   # 唯一走 stdout 的输出
}

# ----------------------------------------------------------------
# 带代理的下载函数
# ----------------------------------------------------------------
download_with_proxy() {
    local url="$1"
    local output="$2"

    for proxy in "${PROXY_LIST[@]}"; do
        info "尝试代理: ${proxy}"
        if wget -q --timeout=30 -O "$output" "${proxy}${url}" 2>/dev/null; then
            info "代理下载成功: ${proxy}"
            return 0
        fi
    done

    warn "所有代理均失败，尝试本地镜像服务器..."
    local filename
    filename=$(basename "$url")
    if wget -q --timeout=30 -O "$output" "${LOCAL_MIRROR}/${filename}" 2>/dev/null; then
        info "本地镜像下载成功"
        return 0
    fi

    error "所有下载方式均失败，请检查网络或手动下载。"
    return 1
}

# ----------------------------------------------------------------
# 下载并解压 EasyTier
# ----------------------------------------------------------------
download_and_extract() {
    local arch="$1"
    local version="$2"
    local base_name="easytier-linux-${arch}"
    local zip_name="${base_name}-${version}.zip"
    local download_url="https://github.com/EasyTier/EasyTier/releases/download/${version}/${zip_name}"

    title "下载 EasyTier ${version} (${arch})"
    download_with_proxy "$download_url" "$TMP_ZIP"

    title "解压文件"
    mkdir -p "$INSTALL_DIR"
    unzip -o "$TMP_ZIP" -d "$INSTALL_DIR/" >&2

    local sub_dir="${INSTALL_DIR}/${base_name}"
    if [ -d "$sub_dir" ]; then
        mv "$sub_dir"/* "$INSTALL_DIR/"
        rmdir "$sub_dir" 2>/dev/null || true
    else
        warn "未找到预期子目录 ${sub_dir}，请手动检查 ${INSTALL_DIR}"
    fi

    chmod +x "${INSTALL_DIR}/easytier-core" "${INSTALL_DIR}/easytier-cli"
    info "EasyTier 文件准备完成。"
}

# ----------------------------------------------------------------
# 生成 systemd 服务内容（纯数据输出，无任何提示）
# console_addr 格式为 "host:port"
# ----------------------------------------------------------------
generate_service() {
    local username="$1"
    local hostname="$2"
    local console_addr="$3"

    cat <<EOF
[Unit]
Description=EasyTier Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/easytier-core -w udp://${console_addr}/${username} --hostname ${hostname}
Restart=always
RestartSec=5
LimitNOFILE=1048576
Environment=TOKIO_CONSOLE=1

[Install]
WantedBy=multi-user.target
EOF
}

# ----------------------------------------------------------------
# 写入服务文件并重载
# ----------------------------------------------------------------
apply_service() {
    local username="$1"
    local hostname="$2"
    local console_addr="$3"

    generate_service "$username" "$hostname" "$console_addr" > "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >&2
    systemctl restart "$SERVICE_NAME"
}

# ----------------------------------------------------------------
# 显示最近 30 条日志并判断启动状态
# ----------------------------------------------------------------
show_status() {
    local wait_sec=3
    info "等待服务启动（${wait_sec}s）..."
    sleep "$wait_sec"

    echo -e "\n${BOLD}────────── 最近 30 条日志 ──────────${RESET}" >&2
    local logs
    logs=$(journalctl -u "${SERVICE_NAME}.service" -n 30 --no-pager 2>/dev/null || true)
    echo "$logs" >&2
    echo -e "${BOLD}────────────────────────────────────${RESET}\n" >&2

    # 失败关键字（优先判断）
    local fail_patterns=(
        "failed"
        "error"
        "错误"
        "refused"
        "timeout"
        "unable to"
        "no such file"
        "permission denied"
        "address already in use"
    )
    # 成功关键字
    local ok_patterns=(
        "started"
        "connected"
        "running"
        "listening"
        "peer"
        "route"
        "tunnel"
    )

    local logs_lower
    logs_lower=$(echo "$logs" | tr '[:upper:]' '[:lower:]')

    local svc_active
    svc_active=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)

    local found_fail=0
    local fail_hint=""
    for pat in "${fail_patterns[@]}"; do
        if echo "$logs_lower" | grep -q "$pat"; then
            found_fail=1
            fail_hint="$pat"
            break
        fi
    done

    local found_ok=0
    for pat in "${ok_patterns[@]}"; do
        if echo "$logs_lower" | grep -q "$pat"; then
            found_ok=1
            break
        fi
    done

    # 综合判断输出
    if [ "$svc_active" != "active" ]; then
        echo -e "${RED}${BOLD}✗ 安装失败${RESET}" >&2
        error "服务状态异常（systemctl 报告: ${svc_active}），请检查上方日志。"
        info  "可运行以下命令查看完整日志:"
        echo  "    journalctl -xe -u ${SERVICE_NAME}.service" >&2
    elif [ "$found_fail" -eq 1 ] && [ "$found_ok" -eq 0 ]; then
        echo -e "${YELLOW}${BOLD}⚠ 安装可能存在问题${RESET}" >&2
        warn "日志中检测到异常关键字 \"${fail_hint}\"，服务虽在运行但请确认连接状态。"
        info "可运行以下命令查看完整日志:"
        echo "    journalctl -xe -u ${SERVICE_NAME}.service" >&2
    else
        echo -e "${GREEN}${BOLD}✓ 安装成功，服务运行正常！${RESET}" >&2
        success "EasyTier 已成功连接并启动。"
        info "如需持续监控日志，运行:"
        echo "    journalctl -f -u ${SERVICE_NAME}.service" >&2
    fi
}

# ----------------------------------------------------------------
# 确认卸载
# 使用 /dev/tty 直接读取终端输入
# ----------------------------------------------------------------
confirm_uninstall() {
    local ans
    read -r -p "$(echo -e "${YELLOW}确认卸载 EasyTier？此操作不可恢复 [y/N]: ${RESET}")" ans </dev/tty
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消卸载。"; exit 0; }
}

# ================================================================
# 操作函数
# ================================================================

do_install() {
    local username="$1" hostname="$2"
    local version console_addr

    title "EasyTier 全新安装"
    version=$(get_version)
    info "版本: $version | 架构: $ARCH"
    console_addr=$(get_console_host)

    [ -d "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR"
    download_and_extract "$ARCH" "$version"
    apply_service "$username" "$hostname" "$console_addr"

    show_status
}

do_modify() {
    local username="$1" hostname="$2"
    local console_addr

    title "修改 EasyTier 配置"
    if [ ! -f "$SERVICE_FILE" ]; then
        error "未找到服务文件，请先执行 install 安装。"
        exit 1
    fi

    console_addr=$(get_console_host)
    apply_service "$username" "$hostname" "$console_addr"

    show_status
}

do_uninstall() {
    title "卸载 EasyTier"
    confirm_uninstall

    systemctl stop    "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    rm -f "$SERVICE_FILE"
    rm -rf "$INSTALL_DIR"

    info "✓ EasyTier 已完全卸载。"
}

do_update() {
    title "更新 EasyTier"
    local version
    version=$(get_version)
    info "目标版本: $version | 架构: $ARCH"

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    rm -f "${INSTALL_DIR}/easytier-core" "${INSTALL_DIR}/easytier-cli"

    download_and_extract "$ARCH" "$version"

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >&2
    systemctl restart "$SERVICE_NAME"

    show_status
}

# ================================================================
# 主入口
# ================================================================
check_root
install_deps

[ $# -lt 1 ] && usage
ACTION="$1"
ARCH=$(get_arch)

case "$ACTION" in
    install|modify)
        [ $# -ne 3 ] && { error "${ACTION} 需要 <username> 和 <hostname> 两个参数"; usage; }
        USERNAME="$2"; HOSTNAME_ARG="$3"
        [ "$ACTION" = "install" ] && do_install "$USERNAME" "$HOSTNAME_ARG"
        [ "$ACTION" = "modify"  ] && do_modify  "$USERNAME" "$HOSTNAME_ARG"
        ;;
    uninstall)
        do_uninstall
        ;;
    update)
        do_update
        ;;
    *)
        error "未知操作: '$ACTION'"
        usage
        ;;
esac
