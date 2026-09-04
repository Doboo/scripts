#!/bin/bash
# ================================================================
# Tailcat 服务端一键管理脚本（全交互式）
# 直接运行后通过菜单完成安装 / 更新 / 卸载 / 启停 / 密钥管理
# 项目主页: https://github.com/tailscale/tailcat
# 说明:     Tailcat 是 Tailscale 出品的 userspace 加密隧道工具，
#           无需账号、无需控制面，仅一个二进制即可提供文件服务 /
#           无认证 SSH / 出口节点等能力，连接地址以 tc 开头。
# ================================================================
set -euo pipefail

# ----------------------------------------------------------------
# 常量定义
# ----------------------------------------------------------------
readonly BIN_PATH="/root/tailcat"
readonly SERVICE_FILE="/etc/systemd/system/tailcat.service"
readonly SERVICE_NAME="tailcat"
readonly KEY_DIR="/root/.config/tailcat/keys"
readonly GITHUB_REPO="tailscale/tailcat"
# 腾讯云已解压二进制（按架构分目录，直接是可执行文件）
readonly CN_MIRROR_BASE="http://119.45.46.205:8888/chfs/shared/tailcat"
# 固定回退版本（API 取不到时使用）
readonly FALLBACK_VERSION="v0.5.0"

# serve 启动参数（用户指定）：以 / 为根提供读写文件服务，并开启
# 出口节点与无认证 SSH。如需调整，改这一行即可。
readonly SERVE_ARGS="serve --files=/:rw exit-node,no-auth-ssh"

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
TMP_TGZ=$(mktemp /tmp/tailcat_XXXXXX.tar.gz)
TMP_DIR=$(mktemp -d /tmp/tailcat_XXXXXX)

# ----------------------------------------------------------------
# 清理与信号处理
# ----------------------------------------------------------------
cleanup() {
    rm -f "$TMP_TGZ"
    rm -rf "$TMP_DIR"
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
# 获取 CPU 架构（返回本脚本使用的架构标识）
#   amd64 / arm64 / arm32
# Tailcat 的 Linux 构建仅提供这三种（arm32 对应 GitHub 上的 armv7）
# ----------------------------------------------------------------
get_arch() {
    case "$(uname -m)" in
        x86_64)        echo "amd64" ;;
        aarch64)       echo "arm64" ;;
        armv7l|armv6l) echo "arm32" ;;
        *)
            error "不支持的 CPU 架构: $(uname -m)"
            error "Tailcat 仅提供 amd64 / arm64 / arm32(armv7) 三种 Linux 构建"
            exit 1
            ;;
    esac
}

# ----------------------------------------------------------------
# 获取 GitHub 上对应架构的资源后缀（amd64/arm64/armv7）
# ----------------------------------------------------------------
github_arch() {
    case "$1" in
        amd64) echo "amd64" ;;
        arm64) echo "arm64" ;;
        arm32) echo "armv7" ;;
    esac
}

# ----------------------------------------------------------------
# 获取最新版本号（优先调 GitHub API，失败用回退版本）
# ----------------------------------------------------------------
get_latest_version() {
    local v
    v=$(curl -s --connect-timeout 8 \
        "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null \
        | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1 || true)
    [ -n "$v" ] && echo "$v" || echo "$FALLBACK_VERSION"
}

# ----------------------------------------------------------------
# 交互：选择下载方式
# ----------------------------------------------------------------
prompt_download_method() {
    local choice
    while true; do
        printf "\n请选择下载方式:\n" >&2
        printf "  ${BOLD}1)${RESET} 国内腾讯云镜像（默认，推荐，速度快）\n" >&2
        printf "     地址: ${BLUE}${CN_MIRROR_BASE}/${arch}/${RESET}\n" >&2
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
# 下载：国内腾讯云镜像（已是解压好的二进制）
# ----------------------------------------------------------------
download_from_cn() {
    local arch="$1"
    local url="${CN_MIRROR_BASE}/${arch}/tailcat"

    info "从国内腾讯云镜像下载: ${url}"
    if wget -q --timeout=30 -O "$BIN_PATH" "$url" 2>/dev/null && [ -s "$BIN_PATH" ]; then
        chmod +x "$BIN_PATH"
        info "腾讯云镜像下载成功。"
        return 0
    fi
    rm -f "$BIN_PATH"
    error "腾讯云镜像下载失败，请检查网络或服务器状态。"
    return 1
}

# ----------------------------------------------------------------
# 下载：GitHub（tar.gz，需解压提取二进制）
# ----------------------------------------------------------------
download_from_github() {
    local arch="$1"
    local gharch dm="$2"
    gharch=$(github_arch "$arch")

    local version asset github_url
    version=$(get_latest_version)
    asset="tailcat_${version#v}_linux_${gharch}.tar.gz"
    github_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${asset}"

    info "目标版本: ${version} | 资源: ${asset}"

    local ok=0
    if [ "$dm" = "proxy" ]; then
        for proxy in "${PROXY_LIST[@]}"; do
            info "尝试 GitHub 代理: ${proxy}"
            if wget -q --timeout=30 -O "$TMP_TGZ" "${proxy}${github_url}" 2>/dev/null && [ -s "$TMP_TGZ" ]; then
                info "代理下载成功: ${proxy}"
                ok=1
                break
            fi
            warn "代理 ${proxy} 失败，尝试下一个..."
        done
    else
        info "直接从 GitHub 下载: ${github_url}"
        if wget -q --timeout=30 -O "$TMP_TGZ" "$github_url" 2>/dev/null && [ -s "$TMP_TGZ" ]; then
            ok=1
        fi
    fi

    [ "$ok" -eq 0 ] && { error "GitHub 下载失败，请改用国内镜像或检查网络。"; return 1; }

    title "解压二进制"
    tar -xzf "$TMP_TGZ" -C "$TMP_DIR" >&2
    local bin
    bin=$(find "$TMP_DIR" -name tailcat -type f 2>/dev/null | head -1 || true)
    if [ -z "$bin" ]; then
        error "解压后未找到 tailcat 二进制，安装包可能损坏。"
        return 1
    fi
    mv "$bin" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    info "Tailcat 二进制已安装至: ${BIN_PATH}"
}

# ----------------------------------------------------------------
# 生成持久密钥（default + 固定区域）并显示连接地址
# ----------------------------------------------------------------
generate_key() {
    if [ -f "${KEY_DIR}/default.private.json" ]; then
        info "已存在 default 持久密钥，跳过生成。"
    else
        title "生成持久密钥（固定 DERP 区域）"
        info "执行: ${BIN_PATH} genkey --key=default --fixed-region"
        "$BIN_PATH" genkey --key=default --fixed-region
        echo
    fi

    title "已保存的密钥列表"
    "$BIN_PATH" genkey --list
    echo
    warn "请务必保存上方 tc 开头的连接地址！"
    warn "该地址已绑定固定区域，服务端重启后地址保持不变。"
    printf "${YELLOW}按回车键继续...${RESET}" >&2
    read -r </dev/tty
}

# ----------------------------------------------------------------
# 生成 systemd 服务内容
#   修正点：原模板把注释串行在 WorkingDirectory 行尾
#   （WorkingDirectory=/root# 持久密钥自动加载），会导致
#   WorkingDirectory 被错误解析。此处拆为独立行 + 独立注释。
# ----------------------------------------------------------------
generate_service() {
    cat <<EOF
[Unit]
Description=Tailcat Encrypted File Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
# 持久密钥自动加载（genkey 生成的 default 密钥位于 /root/.config/tailcat/keys/）
ExecStart=${BIN_PATH} ${SERVE_ARGS}
Restart=always
RestartSec=5
# 1048576 正好卡在 fs.nr_open 默认临界值，容器/LXC/部分云镜像会
# Failed at step RESOURCE_LIMITS 起不来，降到 65535 已足够
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

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

    if [ -f "$BIN_PATH" ]; then
        local ver
        ver=$("$BIN_PATH" --version 2>/dev/null | head -1 || echo "未知")
        echo -e "  程序版本: ${CYAN}${ver}${RESET}"
    fi

    if [ -f "$SERVICE_FILE" ]; then
        echo -e "  二进制:   ${CYAN}${BIN_PATH}${RESET}"
        echo -e "  服务文件: ${CYAN}${SERVICE_FILE}${RESET}"
        echo -e "  密钥目录: ${CYAN}${KEY_DIR}${RESET}"
    fi

    echo -e "${BOLD}${CYAN}──────────────────────────────────${RESET}"
}

# ----------------------------------------------------------------
# 显示最近日志并提取连接地址
# ----------------------------------------------------------------
show_status() {
    local wait_sec=3
    info "等待服务启动（${wait_sec}s）..."
    sleep "$wait_sec"

    echo -e "\n${BOLD}────────── 最近 20 条日志 ──────────${RESET}" >&2
    journalctl -u "${SERVICE_NAME}.service" -n 20 --no-pager 2>/dev/null || true
    echo -e "${BOLD}────────────────────────────────────${RESET}\n" >&2

    local svc_active
    svc_active=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)

    if [ "$svc_active" != "active" ]; then
        echo -e "${RED}${BOLD}✗ 服务未运行${RESET}" >&2
        error "服务状态异常（systemctl 报告: ${svc_active}），请检查上方日志。"
        info "可运行以下命令查看完整日志:"
        echo "    journalctl -xe -u ${SERVICE_NAME}.service" >&2
        return 1
    fi

    # 提取 tc 开头的连接地址
    local addr
    addr=$(journalctl -u "${SERVICE_NAME}.service" -n 50 --no-pager 2>/dev/null \
           | grep -oP 'tc[A-Za-z0-9_-]+' | head -1 || true)

    if [ -n "$addr" ]; then
        success "✓ 服务运行正常，连接地址: ${addr}"
        info "将此地址分享给客户端即可建立加密隧道。"
        info "客户端连接示例: tailcat ${addr}"
    else
        echo -e "${GREEN}${BOLD}✓ 服务运行正常！${RESET}" >&2
        warn "未在日志中找到 tc 连接地址，请手动查看: journalctl -u ${SERVICE_NAME}.service -n 50"
    fi
}

# ----------------------------------------------------------------
# 显示已保存密钥 / 当前连接地址
# ----------------------------------------------------------------
show_key() {
    title "Tailcat 密钥与地址"
    if [ ! -f "$BIN_PATH" ]; then
        error "未检测到 tailcat 二进制，请先安装。"
        return 1
    fi
    echo -e "${BOLD}已保存密钥:${RESET}" >&2
    "$BIN_PATH" genkey --list 2>&1 || true
    echo
    echo -e "${BOLD}服务当前连接地址（来自日志）:${RESET}" >&2
    local addr
    addr=$(journalctl -u "${SERVICE_NAME}.service" -n 100 --no-pager 2>/dev/null \
           | grep -oP 'tc[A-Za-z0-9_-]+' | tail -1 || true)
    if [ -n "$addr" ]; then
        success "地址: ${addr}"
    else
        warn "未找到地址。服务可能未运行，或地址尚未打印。"
    fi
}

# ================================================================
# 操作：全新安装
# ================================================================
do_install() {
    title "Tailcat 服务端安装"

    local arch
    arch=$(get_arch)

    # 已有二进制检测
    local choice="download"
    if [ -f "$BIN_PATH" ]; then
        echo -e "\n${YELLOW}检测到 ${CYAN}${BIN_PATH}${YELLOW} 已存在。${RESET}"
        echo -e "${BOLD}请选择：${RESET}"
        echo -e "  ${CYAN}1)${RESET} 使用已有二进制（跳过下载，推荐）"
        echo -e "  ${CYAN}2)${RESET} 重新下载并覆盖"
        echo -e "  ${CYAN}3)${RESET} 取消安装"
        printf "${YELLOW}请输入选项 [1/2/3]（默认: 1）: ${RESET}" >&2
        read -r ans </dev/tty
        case "${ans:-1}" in
            1) choice="use" ;;
            2) choice="download" ;;
            *) info "已取消安装。"; return 0 ;;
        esac
    fi

    local download_method dm_label=""
    if [[ "$choice" = "download" ]]; then
        echo -e "\n${BOLD}── 第 1 步：选择下载方式 ──${RESET}" >&2
        download_method=$(prompt_download_method)
        case "$download_method" in
            cn)     dm_label="国内腾讯云镜像" ;;
            proxy)  dm_label="GitHub 代理" ;;
            direct) dm_label="GitHub 直连" ;;
        esac
    else
        dm_label="（使用已有二进制）"
    fi

    echo -e "\n${BOLD}${CYAN}──────── 安装确认 ────────${RESET}"
    echo -e "  程序:     ${CYAN}Tailcat${RESET}"
    echo -e "  架构:     ${CYAN}${arch}${RESET}"
    echo -e "  下载方式: ${CYAN}${dm_label}${RESET}"
    echo -e "  安装位置: ${CYAN}${BIN_PATH}${RESET}"
    echo -e "  服务名称: ${CYAN}${SERVICE_NAME}${RESET}"
    echo -e "  启动参数: ${CYAN}${SERVE_ARGS}${RESET}"
    echo -e "  密钥目录: ${CYAN}${KEY_DIR}${RESET}"
    echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
    printf "${YELLOW}确认安装？[Y/n]: ${RESET}" >&2
    read -r ans </dev/tty
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消安装。"; return 0; }

    if [[ "$choice" = "download" ]]; then
        case "$download_method" in
            cn)     download_from_cn "$arch" || { error "下载失败，安装中止。"; return 1; } ;;
            proxy)  download_from_github "$arch" "proxy"  || { error "下载失败，安装中止。"; return 1; } ;;
            direct) download_from_github "$arch" "direct" || { error "下载失败，安装中止。"; return 1; } ;;
        esac
    fi

    # 生成持久密钥（必须在启动服务之前）
    generate_key

    apply_service
    show_status
}

# ================================================================
# 操作：更新
# ================================================================
do_update() {
    title "更新 Tailcat 程序"

    if [ ! -f "$BIN_PATH" ]; then
        error "未检测到已安装的 Tailcat，请先执行【全新安装】。"
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
    echo -e "  目标程序: ${CYAN}Tailcat (latest)${RESET}"
    echo -e "  架构:     ${CYAN}${arch}${RESET}"
    echo -e "  下载方式: ${CYAN}${dm_label}${RESET}"
    echo -e "  (持久密钥与服务配置保持不变)${RESET}"
    echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
    printf "${YELLOW}确认更新？[Y/n]: ${RESET}" >&2
    read -r ans </dev/tty
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消更新。"; return 0; }

    local backup_dir
    backup_dir=$(mktemp -d /tmp/tailcat_backup_XXXXXX)
    trap 'rm -rf "$backup_dir"' RETURN
    [ -f "$BIN_PATH" ] && cp "$BIN_PATH" "${backup_dir}/"

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true

    case "$download_method" in
        cn)     download_from_cn "$arch" || true ;;
        proxy)  download_from_github "$arch" "proxy"  || true ;;
        direct) download_from_github "$arch" "direct" || true ;;
    esac

    if [ ! -x "$BIN_PATH" ]; then
        warn "下载失败，正在回滚到备份版本..."
        [ -f "${backup_dir}/tailcat" ] && mv "${backup_dir}/tailcat" "$BIN_PATH"
        chmod +x "$BIN_PATH" 2>/dev/null || true
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
    title "卸载 Tailcat"

    if [ ! -f "$SERVICE_FILE" ] && [ ! -f "$BIN_PATH" ] && [ ! -d "$KEY_DIR" ]; then
        warn "未检测到 Tailcat 的安装文件，可能已经卸载。"
        return 0
    fi

    echo -e "${RED}${BOLD}警告：此操作将删除 Tailcat 程序、服务及持久密钥，不可恢复！${RESET}" >&2
    printf "${YELLOW}请输入 \"yes\" 确认卸载（其他输入取消）: ${RESET}" >&2
    read -r ans </dev/tty
    [ "$ans" = "yes" ] || { info "已取消卸载。"; return 0; }

    systemctl stop    "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    rm -f "$SERVICE_FILE"
    rm -f "$BIN_PATH"
    rm -rf "$KEY_DIR"

    success "Tailcat 已完全卸载（含持久密钥）。"
}

# ================================================================
# 操作：查看日志
# ================================================================
do_show_log() {
    title "Tailcat 运行日志"

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
        1) journalctl -u "${SERVICE_NAME}.service" -n 50 --no-pager 2>/dev/null || true ;;
        2)
            echo -e "\n${BOLD}────────── 实时日志监控 ──────────${RESET}" >&2
            echo -e "  ${GREEN}按 ${BOLD}Ctrl+C${RESET}${GREEN} 返回主菜单${RESET}" >&2
            echo -e "${BOLD}────────────────────────────────────${RESET}\n" >&2
            trap 'echo -e "\n${YELLOW}已退出日志监控，返回主菜单...${RESET}" >&2; trap - INT; return 0' INT
            journalctl -f -u "${SERVICE_NAME}.service" --no-pager
            ;;
        3) journalctl -u "${SERVICE_NAME}.service" --since today --no-pager 2>/dev/null || true ;;
        *) warn "无效选项，显示最近 50 条日志。"
           journalctl -u "${SERVICE_NAME}.service" -n 50 --no-pager 2>/dev/null || true ;;
    esac
}

# ================================================================
# 操作：启动 / 停止 / 重启服务
# ================================================================
do_start() {
    title "启动 Tailcat 服务"
    if [ ! -f "$SERVICE_FILE" ]; then
        error "服务未安装，请先执行【全新安装】。"
        return 1
    fi
    systemctl start "$SERVICE_NAME"
    sleep 1
    if systemctl is-active "$SERVICE_NAME" &>/dev/null; then
        success "✓ Tailcat 服务已启动。"
        show_key
    else
        error "服务启动失败，请查看日志: journalctl -xe -u ${SERVICE_NAME}.service"
    fi
}

do_stop() {
    title "停止 Tailcat 服务"
    if [ ! -f "$SERVICE_FILE" ]; then
        error "服务未安装。"
        return 1
    fi
    systemctl stop "$SERVICE_NAME"
    sleep 1
    success "✓ Tailcat 服务已停止。"
}

do_restart() {
    title "重启 Tailcat 服务"
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
        echo "║       Tailcat 服务端管理脚本          ║"
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
        echo -e "  ${BOLD}7)${RESET} 查看密钥与连接地址"
        echo -e "  ${BOLD}8)${RESET} 查看日志"
        echo -e "  ${BOLD}0)${RESET} 退出"
        printf "请输入选项 [0-8]: "

        read -r choice </dev/tty

        case "$choice" in
            1) do_install    ;;
            2) do_update    ;;
            3) do_uninstall ;;
            4) do_start     ;;
            5) do_stop      ;;
            6) do_restart   ;;
            7) show_key     ;;
            8) do_show_log  ;;
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
