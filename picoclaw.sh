#!/bin/bash
# ================================================================
# PicoClaw 一键管理脚本（全交互式）
# 直接运行后通过菜单完成所有操作，无需记忆命令参数
# 项目主页: https://github.com/sipeed/picoclaw
# 文档:     https://docs.picoclaw.io
# ================================================================
set -euo pipefail

# ----------------------------------------------------------------
# 常量定义
# ----------------------------------------------------------------
readonly INSTALL_DIR="/root/picoclaw"
readonly SERVICE_FILE="/etc/systemd/system/picoclaw.service"
readonly SERVICE_NAME="picoclaw"
readonly LAUNCHER_BIN="${INSTALL_DIR}/picoclaw-launcher"
readonly GATEWAY_PORT="18800"

# 下载源
readonly GITHUB_BASE="https://github.com/sipeed/picoclaw/releases/latest/download"
readonly CN_MIRROR_BASE="http://119.45.46.205:8888/chfs/shared/picoclaw"

# GitHub 代理列表（备用）
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
TMP_TGZ=$(mktemp /tmp/picoclaw_XXXXXX.tar.gz)

# ----------------------------------------------------------------
# 清理与信号处理
# ----------------------------------------------------------------
cleanup() {
    rm -f "$TMP_TGZ"
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
    for cmd in wget curl tar; do
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
        exit 1
    fi
    info "依赖安装完成。"
}

# ----------------------------------------------------------------
# 获取 CPU 架构（返回 picoclaw 文件名中使用的架构标识）
# ----------------------------------------------------------------
get_arch() {
    case "$(uname -m)" in
        x86_64)        echo "x86_64"   ;;
        aarch64)       echo "arm64"    ;;
        armv7l)        echo "armv7"    ;;
        armv6l)        echo "armv6"    ;;
        riscv64)       echo "riscv64"  ;;
        loongarch64)   echo "loong64"  ;;
        *)
            error "不支持的 CPU 架构: $(uname -m)"
            error "PicoClaw 支持: x86_64 / arm64 / armv7 / armv6 / riscv64 / loong64"
            exit 1
            ;;
    esac
}

# ----------------------------------------------------------------
# 获取本机 IP 地址（用于安装完成后的访问提示）
# ----------------------------------------------------------------
get_public_ip() {
    local ip=""
    # 优先使用 curl 获取公网 IP
    ip=$(curl -s --connect-timeout 5 https://ifconfig.me 2>/dev/null || true)
    [ -n "$ip" ] && echo "$ip" && return 0

    # 回退：从 ip 命令获取本机 IP
    ip=$(ip -4 addr show scope global 2>/dev/null \
         | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
    [ -n "$ip" ] && echo "$ip" && return 0

    # 最终回退
    echo "本机IP"
}

# ----------------------------------------------------------------
# 交互：选择下载方式
# ----------------------------------------------------------------
prompt_download_method() {
    local choice

    while true; do
        printf "\n请选择下载方式:\n" >&2
        printf "  ${BOLD}1)${RESET} 国内腾讯云镜像（默认，推荐，速度快）\n" >&2
        printf "     地址: ${BLUE}${CN_MIRROR_BASE}${RESET}\n" >&2
        printf "  ${BOLD}2)${RESET} GitHub 代理下载（ghfast.top / gh-proxy.com 等）\n" >&2
        printf "  ${BOLD}3)${RESET} 直接从 GitHub 下载（需能直连 github.com）\n" >&2
        printf "请输入选项 [1/2/3]（默认: 1）: " >&2
        read -r choice </dev/tty
        choice="${choice:-1}"

        case "$choice" in
            1) echo "cn";     return 0 ;;
            2) echo "proxy";  return 0 ;;
            3) echo "direct"; return 0 ;;
            *) warn "无效选项 '${choice}'，请输入 1、2 或 3。" ;;
        esac
    done
}

# ----------------------------------------------------------------
# 下载：国内腾讯云镜像
# ----------------------------------------------------------------
download_from_cn() {
    local file_name="$1"
    local output="$2"
    local url="${CN_MIRROR_BASE}/${file_name}"

    info "从国内腾讯云镜像下载: ${url}"
    if wget -q --timeout=30 -O "$output" "$url" 2>/dev/null; then
        info "腾讯云镜像下载成功。"
        return 0
    fi
    error "腾讯云镜像下载失败，请检查网络或服务器状态。"
    return 1
}

# ----------------------------------------------------------------
# 下载：GitHub 代理
# ----------------------------------------------------------------
download_from_proxy() {
    local github_url="$1"
    local output="$2"

    for proxy in "${PROXY_LIST[@]}"; do
        info "尝试 GitHub 代理: ${proxy}"
        if wget -q --timeout=30 -O "$output" "${proxy}${github_url}" 2>/dev/null; then
            info "代理下载成功: ${proxy}"
            return 0
        fi
        warn "代理 ${proxy} 失败，尝试下一个..."
    done

    error "所有 GitHub 代理均失败，请检查网络或改用国内镜像下载。"
    return 1
}

# ----------------------------------------------------------------
# 下载：直连 GitHub
# ----------------------------------------------------------------
download_from_github_direct() {
    local github_url="$1"
    local output="$2"

    info "直接从 GitHub 下载: ${github_url}"
    if wget -q --timeout=30 -O "$output" "$github_url" 2>/dev/null; then
        info "GitHub 直接下载成功。"
        return 0
    fi
    error "GitHub 直接下载失败，请确认网络可直连 github.com，或改用国内镜像下载。"
    return 1
}

# ----------------------------------------------------------------
# 下载并解压 PicoClaw
# ----------------------------------------------------------------
download_and_extract() {
    local arch="$1"
    local download_method="$2"
    local file_name="picoclaw_Linux_${arch}.tar.gz"
    local github_url="${GITHUB_BASE}/${file_name}"

    title "下载 PicoClaw (${arch})"

    case "$download_method" in
        cn)     download_from_cn "$file_name" "$TMP_TGZ" || return 1 ;;
        proxy)  download_from_proxy "$github_url" "$TMP_TGZ" || return 1 ;;
        direct) download_from_github_direct "$github_url" "$TMP_TGZ" || return 1 ;;
    esac

    title "解压文件"
    # 清理旧目录后重新解压
    [ -d "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    tar -xzf "$TMP_TGZ" -C "$INSTALL_DIR/" >&2

    # 检查解压结果：可能直接在根目录，也可能在子目录中
    local launcher="${INSTALL_DIR}/picoclaw-launcher"
    if [ ! -f "$launcher" ]; then
        # 尝试在子目录中查找
        local found
        found=$(find "$INSTALL_DIR" -name "picoclaw-launcher" -type f 2>/dev/null | head -1 || true)
        if [ -n "$found" ]; then
            local sub_dir
            sub_dir=$(dirname "$found")
            info "发现程序在子目录 ${sub_dir}，正在移动到 ${INSTALL_DIR}"
            find "$sub_dir" -maxdepth 1 -mindepth 1 -exec mv -t "$INSTALL_DIR/" {} +
            rmdir "$sub_dir" 2>/dev/null || true
        fi
    fi

    # 最终验证
    if [ ! -f "$launcher" ]; then
        error "解压后未找到 picoclaw-launcher，安装包可能损坏。"
        return 1
    fi
    chmod +x "$launcher"
    info "PicoClaw 文件准备完成: ${launcher}"
}

# ----------------------------------------------------------------
# 已有程序文件时，提示用户选择
# ----------------------------------------------------------------
prompt_existing_binary_choice() {
    echo -e "
${YELLOW}检测到安装目录 ${CYAN}${INSTALL_DIR}${YELLOW} 中已有程序文件。${RESET}"
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

# ----------------------------------------------------------------
# 生成 systemd 服务内容
# ----------------------------------------------------------------
generate_service() {
    cat <<EOF
[Unit]
Description=PicoClaw Gateway Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${LAUNCHER_BIN} -public
WorkingDirectory=${INSTALL_DIR}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

# ----------------------------------------------------------------
# 写入服务文件并启动
# ----------------------------------------------------------------
apply_service() {
    generate_service > "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" 2>&1 | while IFS= read -r line; do
        info "$line"
    done
    systemctl restart "$SERVICE_NAME" 2>/dev/null || true
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

    if [ -f "$LAUNCHER_BIN" ]; then
        local ver
        ver=$("$LAUNCHER_BIN" --version 2>/dev/null | head -1 || echo "未知")
        echo -e "  程序版本: ${CYAN}${ver}${RESET}"
    fi

    if [ -f "$SERVICE_FILE" ]; then
        echo -e "  安装目录: ${CYAN}${INSTALL_DIR}${RESET}"
        echo -e "  服务文件: ${CYAN}${SERVICE_FILE}${RESET}"
        echo -e "  访问端口: ${CYAN}${GATEWAY_PORT}${RESET}"
    fi

    echo -e "${BOLD}${CYAN}──────────────────────────────────${RESET}"
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
        info "可运行以下命令查看完整日志:"
        echo  "    journalctl -xe -u ${SERVICE_NAME}.service" >&2
        return 1
    fi

    local logs logs_lower
    logs=$(journalctl -u "${SERVICE_NAME}.service" -n 15 --no-pager 2>/dev/null || true)
    logs_lower=$(echo "$logs" | tr '[:upper:]' '[:lower:]')

    local warn_patterns=("refused" "timeout" "unable to" "no such file" "permission denied" "address already in use")
    for pat in "${warn_patterns[@]}"; do
        if echo "$logs_lower" | grep -q "$pat"; then
            warn "日志中检测到异常关键字 \"${pat}\"，服务虽在运行但请确认状态。"
            info "可运行以下命令查看完整日志:"
            echo "    journalctl -xe -u ${SERVICE_NAME}.service" >&2
            return 0
        fi
    done

    echo -e "${GREEN}${BOLD}✓ 操作成功，服务运行正常！${RESET}" >&2

    # 显示访问信息
    local public_ip
    public_ip=$(get_public_ip)

    echo -e "\n${BOLD}${CYAN}────────── 访问信息 ──────────${RESET}" >&2
    echo -e "  PicoClaw 网关已启动，请使用浏览器访问:" >&2
    echo -e ""
    echo -e "  ${BOLD}${GREEN}http://${public_ip}:${GATEWAY_PORT}${RESET}" >&2
    echo -e ""
    echo -e "  ${YELLOW}首次访问需在页面中配置 API Key、机器人令牌等。${RESET}" >&2
    echo -e "  ${YELLOW}请确保服务器已放行 TCP ${GATEWAY_PORT} 端口。${RESET}" >&2
    echo -e "${BOLD}${CYAN}──────────────────────────────────${RESET}\n" >&2

    success "PicoClaw 已成功安装并启动。"
    info "如需持续监控日志，运行:"
    echo "    journalctl -f -u ${SERVICE_NAME}.service" >&2
}

# ================================================================
# 操作：全新安装
# ================================================================
do_install() {
    title "PicoClaw 安装"

    local arch
    arch=$(get_arch)

    # 已有程序检测
    local choice="download"
    if [ -f "$LAUNCHER_BIN" ]; then
        choice=$(prompt_existing_binary_choice)
        [[ "$choice" = "cancel" ]] && { info "已取消安装。"; return 0; }
    fi

    local dm_label
    if [[ "$choice" = "download" ]]; then
        echo -e "\n${BOLD}── 第 1 步：选择下载方式 ──${RESET}" >&2
        local download_method
        download_method=$(prompt_download_method)
        case "$download_method" in
            cn)     dm_label="国内腾讯云镜像" ;;
            proxy)  dm_label="GitHub 代理" ;;
            direct) dm_label="GitHub 直连" ;;
        esac
    else
        dm_label="（使用已有程序）"
    fi

    # 确认安装
    echo -e "\n${BOLD}${CYAN}──────── 安装确认 ────────${RESET}"
    echo -e "  程序:     ${CYAN}PicoClaw${RESET}"
    echo -e "  架构:     ${CYAN}${arch}${RESET}"
    echo -e "  下载方式: ${CYAN}${dm_label}${RESET}"
    echo -e "  安装目录: ${CYAN}${INSTALL_DIR}${RESET}"
    echo -e "  服务名称: ${CYAN}${SERVICE_NAME}${RESET}"
    echo -e "  启动命令: ${CYAN}${LAUNCHER_BIN} -public${RESET}"
    echo -e "  访问端口: ${CYAN}${GATEWAY_PORT}${RESET}"
    echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
    printf "${YELLOW}确认安装？[Y/n]: ${RESET}" >&2
    read -r ans </dev/tty
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消安装。"; return 0; }

    info "架构: $arch | 下载方式: ${dm_label}"
    if [[ "$choice" = "download" ]]; then
        download_and_extract "$arch" "$download_method" || {
            error "下载或解压失败，安装中止。"
            return 1
        }
    fi
    apply_service
    show_status
}

# ================================================================
# 操作：更新
# ================================================================
do_update() {
    title "更新 PicoClaw 程序"

    if [ ! -f "$LAUNCHER_BIN" ]; then
        error "未检测到已安装的 PicoClaw，请先执行【全新安装】。"
        return 1
    fi

    local arch
    arch=$(get_arch)

    echo -e "\n${BOLD}── 第 1 步：选择下载方式 ──${RESET}" >&2
    local download_method dm_label
    download_method=$(prompt_download_method)
    case "$download_method" in
        cn)     dm_label="国内腾讯云镜像" ;;
        proxy)  dm_label="GitHub 代理" ;;
        direct) dm_label="GitHub 直连" ;;
    esac

    echo -e "\n${BOLD}${CYAN}──────── 更新确认 ────────${RESET}"
    echo -e "  目标程序: ${CYAN}PicoClaw (latest)${RESET}"
    echo -e "  架构:     ${CYAN}${arch}${RESET}"
    echo -e "  下载方式: ${CYAN}${dm_label}${RESET}"
    echo -e "  (服务配置保持不变)${RESET}"
    echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
    printf "${YELLOW}确认更新？[Y/n]: ${RESET}" >&2
    read -r ans </dev/tty
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消更新。"; return 0; }

    info "架构: $arch | 下载方式: ${dm_label}"

    # 备份当前程序
    local backup_dir
    backup_dir=$(mktemp -d /tmp/picoclaw_backup_XXXXXX)
    trap 'rm -rf "$backup_dir"' RETURN

    [ -f "$LAUNCHER_BIN" ] && cp "$LAUNCHER_BIN" "${backup_dir}/"

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true

    if ! download_and_extract "$arch" "$download_method"; then
        warn "下载失败，正在回滚到备份版本..."
        [ -f "${backup_dir}/picoclaw-launcher" ] && cp "${backup_dir}/picoclaw-launcher" "$LAUNCHER_BIN"
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
    title "卸载 PicoClaw"

    if [ ! -f "$SERVICE_FILE" ] && [ ! -d "$INSTALL_DIR" ]; then
        warn "未检测到 PicoClaw 的安装文件，可能已经卸载。"
        return 0
    fi

    echo -e "${RED}${BOLD}警告：此操作将删除所有 PicoClaw 程序文件和服务，不可恢复！${RESET}" >&2
    printf "${YELLOW}请输入 \"yes\" 确认卸载（其他输入取消）: ${RESET}" >&2
    read -r ans </dev/tty
    [ "$ans" = "yes" ] || { info "已取消卸载。"; return 0; }

    systemctl stop    "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    rm -f "$SERVICE_FILE"
    rm -rf "$INSTALL_DIR"

    success "PicoClaw 已完全卸载。"
}

# ================================================================
# 操作：查看日志
# ================================================================
do_show_log() {
    title "PicoClaw 运行日志"

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
            echo -e "\n${BOLD}────────── 实时日志监控 ──────────${RESET}" >&2
            echo -e "  ${GREEN}按 ${BOLD}Ctrl+C${RESET}${GREEN} 返回主菜单${RESET}" >&2
            echo -e "${BOLD}────────────────────────────────────${RESET}\n" >&2
            trap 'echo -e "\n${YELLOW}已退出日志监控，返回主菜单...${RESET}" >&2; trap - INT; return 0' INT
            journalctl -f -u "${SERVICE_NAME}.service" --no-pager
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
# 操作：启动 / 停止 / 重启服务
# ================================================================
do_start() {
    title "启动 PicoClaw 服务"
    if [ ! -f "$SERVICE_FILE" ]; then
        error "服务未安装，请先执行【全新安装】。"
        return 1
    fi
    systemctl start "$SERVICE_NAME"
    sleep 1
    if systemctl is-active "$SERVICE_NAME" &>/dev/null; then
        success "✓ PicoClaw 服务已启动。"
    else
        error "服务启动失败，请查看日志:"
        echo "    journalctl -xe -u ${SERVICE_NAME}.service" >&2
    fi
}

do_stop() {
    title "停止 PicoClaw 服务"
    if [ ! -f "$SERVICE_FILE" ]; then
        error "服务未安装。"
        return 1
    fi
    systemctl stop "$SERVICE_NAME"
    sleep 1
    success "✓ PicoClaw 服务已停止。"
}

do_restart() {
    title "重启 PicoClaw 服务"
    if [ ! -f "$SERVICE_FILE" ]; then
        error "服务未安装，请先执行【全新安装】。"
        return 1
    fi
    systemctl restart "$SERVICE_NAME"
    show_status
}

# ================================================================
# 主菜单
# ================================================================
main_menu() {
    while true; do
        clear || true
        echo -e "${BOLD}${CYAN}"
        echo "╔══════════════════════════════════════╗"
        echo "║       PicoClaw 一键管理脚本          ║"
        echo "╚══════════════════════════════════════╝"
        echo -e "${RESET}"

        show_current_info

        echo -e "${BOLD}请选择操作:${RESET}"
        echo -e "  ${BOLD}1)${RESET} 全新安装"
        echo -e "  ${BOLD}2)${RESET} 更新程序"
        echo -e "  ${BOLD}3)${RESET} 卸载"
        echo -e "  ${BOLD}4)${RESET} 启动服务"
        echo -e "  ${BOLD}5)${RESET} 停止服务"
        echo -e "  ${BOLD}6)${RESET} 重启服务"
        echo -e "  ${BOLD}7)${RESET} 查看日志"
        echo -e "  ${BOLD}0)${RESET} 退出"
        printf "请输入选项 [0-7]: "

        read -r choice </dev/tty

        case "$choice" in
            1) do_install   ;;
            2) do_update    ;;
            3) do_uninstall ;;
            4) do_start     ;;
            5) do_stop      ;;
            6) do_restart   ;;
            7) do_show_log  ;;
            0) echo -e "${GREEN}再见！${RESET}"; exit 0 ;;
            *) warn "无效选项 '${choice}'，请重新输入。" ;;
        esac

        echo ""
        printf "${YELLOW}按回车键返回主菜单...${RESET}" >&2
        read -r </dev/tty
    done
}

# ================================================================
# 入口
# ================================================================
main() {
    check_root
    install_deps

    local arch
    arch=$(get_arch)
    info "检测到系统架构: ${arch}"

    main_menu
}

main "$@"
