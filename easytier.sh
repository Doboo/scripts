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
readonly VERSION_URL="http://etsh2.442230.xyz/etver"
readonly LOCAL_MIRROR="http://47.98.36.99:8888/chfs/shared/easytier"

readonly PROXY_LIST=(
    "https://ghfast.top/"
    "https://docker.mk/"
    "https://gh-proxy.com/"
)

# ----------------------------------------------------------------
# 彩色输出（修复：使用 $'...' 语法避免双重转义）
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
# 临时文件（修复：使用 mktemp 替代 PID 命名，避免竞争条件）
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
                    # 校验格式：X.Y.Z 纯数字点分隔
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
# 获取控制台地址（修复：使用 printf 替代 echo -e 内嵌在 $() 中）
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
        if ! 
