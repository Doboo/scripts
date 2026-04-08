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
readonly DEFAULT_CONSOLE_HOST="cfgs.175419.xyz"
readonly DEFAULT_CONSOLE_PORT="22020"
readonly DEFAULT_VERSION="v2.4.5"
readonly LOCAL_MIRROR="http://47.98.36.99:8888/chfs/shared/easytier"

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
    printf "${BOLD}用法:${RESET} %s [install|modify|uninstall|update] [username] [hostname]\\n\\n" "$0" >&2
    printf "  install   <username> <hostname>  全新安装 EasyTier 服务\\n" >&2
    printf "  modify    <username> <hostname>  修改配置并重启服务\\n" >&2
    printf "  uninstall                        卸载服务并删除所有文件\\n" >&2
    printf "  update                           更新程序文件（保留配置）\\n\\n" >&2
    printf "${BOLD}示例:${RESET}\\n" >&2
    printf "  %s install myuser my-node-name\\n" "$0" >&2
    printf "  %s modify  myuser new-node-name\\n" "$0" >&2
    printf "  %s uninstall\\n" "$0" >&2
    printf "  %s update\\n" "$0" >&2
    exit 1
}

# ----------------------------------------------------------------
# 获取 EasyTier 版本号（交互式选择）
# ----------------------------------------------------------------
get_version() {
    local choice ver

    while true; do
        printf "\n请选择要安装的 EasyTier 版本:\n" >&2
        printf "  ${BOLD}1)${RESET} 安装 v2.4.5（默认稳定版）\n" >&2
        printf "  ${BOLD}2)${RESET} 安装 v2.6.0（最新版）\n" >&2
        printf "  ${BOLD}3)${RESET} 手动输入版本号\n" >&2
        printf "请输入选项 [1/2/3]（默认: 1）: " >&2
        read -r choice </dev/tty
        choice="${choice:-1}"

        case "$choice" in
            1)
                ver="v2.4.5"
                break
                ;;
            2)
                ver="v2.6.0"
                break
                ;;
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
            *)
                warn "无效选项 '${choice}'，请输入 1、2 或 3。"
                ;;
        esac
    done

    info "已选择版本: ${ver}"
    echo "$ver"
}

# ----------------------------------------------------------------
# 选择下载方式
# ----------------------------------------------------------------
choose_download_method() {
    local choice

    while true; do
        printf "\n请选择下载方式:\n" >&2
        printf "  ${BOLD}1)${RESET} 本地镜像服务器下载（默认，推荐）\n" >&2
        printf "     地址: ${BLUE}${LOCAL_MIRROR}${RESET}\n" >&2
        printf "  ${BOLD}2)${RESET} GitHub 代理下载（ghfast.top / gh-proxy.com / ghproxylist.com / mirror.ghproxy.com）\n" >&2
        printf "  ${BOLD}3)${RESET} 直接从 GitHub 下载（需能直连 github.com）\n" >&2
        printf "     地址: ${BLUE}https://github.com/EasyTier/EasyTier/releases${RESET}\n" >&2
        printf "请输入选项 [1/2/3]（默认: 1）: " >&2
        read -r choice </dev/tty
        choice="${choice:-1}"

        case "$choice" in
            1)
                echo "local"
                return 0
                ;;
            2)
                echo "proxy"
                return 0
                ;;
            3)
                echo "direct"
                return 0
                ;;
            *)
                warn "无效选项 '${choice}'，请输入 1、2 或 3。"
                ;;
        esac
    done
}

# ----------------------------------------------------------------
# 获取控制台地址
# ----------------------------------------------------------------
get_console_host() {
    local host port

    while true; do
        printf "请输入控制台 IP 或域名 (默认: %s): " "${DEFAULT_CONSOLE_HOST}" >&2
        read -r host </dev/tty
        host="${host:-$DEFAULT_CONSOLE_HOST}"
        if [[ "$host" =~ [[:space:]] ]]; then
            warn "IP/域名不能包含空格，请重新输入。"
            continue
        fi
        break
    done

    while true; do
        printf "请输入控制台端口号 (默认: %s): " "${DEFAULT_CONSOLE_PORT}" >&2
        read -r port </dev/tty
        port="${port:-$DEFAULT_CONSOLE_PORT}"
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
# 通过本地镜像下载
# ----------------------------------------------------------------
download_from_local() {
    local rel_path="$1"   # e.g. v2.4.5/easytier-linux-x86_64-v2.4.5.zip
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
# 通过 GitHub 代理下载
# ----------------------------------------------------------------
download_from_proxy() {
    local github_url="$1"   # 完整 GitHub URL
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
# 直接从 GitHub 下载
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
    local username="$1"
    local node_hostname="$2"
    local console_addr="$3"

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
}

# ----------------------------------------------------------------
# 写入服务文件并重载
# ----------------------------------------------------------------
apply_service() {
    local username="$1"
    local node_hostname="$2"
    local console_addr="$3"

    generate_service "$username" "$node_hostname" "$console_addr" > "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" 2>&1 | while IFS= read -r line; do
        info "$line"
    done
    systemctl restart "$SERVICE_NAME" 2>/dev/null
}

# ----------------------------------------------------------------
# 显示最近 15 条日志并判断启动状态
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
        echo -e "${RED}${BOLD}✗ 安装失败${RESET}" >&2
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

    echo -e "${GREEN}${BOLD}✓ 安装成功，服务运行正常！${RESET}" >&2
    success "EasyTier 已成功连接并启动。"
    info "如需持续监控日志，运行:"
    echo "    journalctl -f -u ${SERVICE_NAME}.service" >&2
}

# ----------------------------------------------------------------
# 确认卸载
# ----------------------------------------------------------------
confirm_uninstall() {
    local ans
    printf "${YELLOW}确认卸载 EasyTier？此操作不可恢复 [y/N]: ${RESET}" >&2
    read -r ans </dev/tty
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消卸载。"; exit 0; }
}

# ================================================================
# 操作函数
# ================================================================

do_install() {
    local username="$1" node_hostname="$2"
    local version download_method console_addr

    title "EasyTier 全新安装"
    version=$(get_version)
    download_method=$(choose_download_method)
    case "$download_method" in
        local)  _dm_label="本地镜像" ;;
        proxy)  _dm_label="GitHub 代理" ;;
        direct) _dm_label="GitHub 直连" ;;
    esac
    info "版本: $version | 架构: $ARCH | 下载方式: ${_dm_label}"
    console_addr=$(get_console_host)

    [ -d "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR"
    download_and_extract "$ARCH" "$version" "$download_method"
    apply_service "$username" "$node_hostname" "$console_addr"

    show_status
}

do_modify() {
    local username="$1" node_hostname="$2"
    local console_addr

    title "修改 EasyTier 配置"
    if [ ! -f "$SERVICE_FILE" ]; then
        error "未找到服务文件，请先执行 install 安装。"
        exit 1
    fi
    if [ ! -f "${INSTALL_DIR}/easytier-core" ]; then
        error "未找到 easytier-core，程序文件可能已损坏，请先执行 update 或 install。"
        exit 1
    fi

    console_addr=$(get_console_host)
    apply_service "$username" "$node_hostname" "$console_addr"

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
    local version download_method

    version=$(get_version)
    download_method=$(choose_download_method)
    case "$download_method" in
        local)  _dm_label="本地镜像" ;;
        proxy)  _dm_label="GitHub 代理" ;;
        direct) _dm_label="GitHub 直连" ;;
    esac
    info "目标版本: $version | 架构: $ARCH | 下载方式: ${_dm_label}"

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
        exit 1
    fi

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" 2>&1 | while IFS= read -r line; do
        info "$line"
    done
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
        if [[ "$USERNAME" =~ [[:space:]/\\] ]]; then
            error "username 不能包含空格或斜杠"
            exit 1
        fi
        if [[ "$HOSTNAME_ARG" =~ [[:space:]/\\] ]]; then
            error "hostname 不能包含空格或斜杠"
            exit 1
        fi
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
