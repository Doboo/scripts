#!/bin/bash
# ==============================================================================
# EasyTier 旁路网关一键配置脚本（Debian 12）
#
# 用途:
#   让 Debian 12 小主机/盒子作为 EasyTier 旁路网关，转发
#   EasyTier 虚拟网段 <-> 物理局域网段的双向数据。
#
# 设计要点（相对旧版 iptables-et.sh 的改进）:
#   1. 全部规则放入自定义链 ET-FWD / ET-SNAT / ET-MSS，
#      只 flush 自己的链 —— 绝不 `iptables -F FORWARD` /
#      `-t nat -F POSTROUTING`，避免误清 Docker 等已有规则。
#   2. VPN→LAN 方向默认在 LAN_IF 出口做 MASQUERADE，
#      解决局域网设备默认网关不在本机时的回程路由问题。
#   3. mangle 表 TCPMSS --clamp-mss-to-pmtu，解决 TUN MTU(约1380)
#      小于物理网卡 MTU(1500) 导致的"ping 通网页打不开"。
#   4. 幂等：重复执行不会叠加规则（-C 先查再插）。
#   5. 支持卸载与状态查看。
# ==============================================================================
set -euo pipefail

# --- 常量 ---
readonly FWD_CHAIN="ET-FWD"
readonly SNAT_CHAIN="ET-SNAT"
readonly MSS_CHAIN="ET-MSS"
readonly SYSCTL_FILE="/etc/sysctl.d/99-et-forward.conf"

# --- 颜色定义（仓库统一风格） ---
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

# --- 全局配置（安装流程中填充） ---
LAN_IF=""
VPN_IF=""
LAN_NAT="yes"   # VPN→LAN 是否在 LAN_IF 出口做 MASQUERADE

# ==============================================================================
# 基础检查
# ==============================================================================
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "此脚本需要 root 权限运行，请使用 sudo 或切换到 root 用户。"
        exit 1
    fi
}

check_deps() {
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
detect_lan_if() {
    local ifname
    ifname=$(ip -4 route show default 2>/dev/null \
             | awk '{print $5; exit}' || true)
    [ -n "$ifname" ] && echo "$ifname" || echo "eth0"
}

# 自动猜测 EasyTier 虚拟网卡：
#   1) 优先 easytier*（用户显式 --dev-name 命名过的场景）
#   2) 其次 tun*（EasyTier 默认设备名是 tun0）
#   3) 都没有则默认 tun0（EasyTier 可能尚未启动）
detect_vpn_if() {
    local ifname
    ifname=$(ip -o link show 2>/dev/null \
             | awk -F': ' '$2 ~ /^easytier/ {print $2; exit}' || true)
    if [ -z "$ifname" ]; then
        ifname=$(ip -o link show 2>/dev/null \
                 | awk -F': ' '$2 ~ /^tun/ {print $2; exit}' || true)
    fi
    [ -n "$ifname" ] && echo "$ifname" || echo "tun0"
}

if_exists() {
    ip link show dev "$1" &>/dev/null
}

show_interfaces() {
    echo -e "\n${BOLD}${CYAN}──────── 当前网络接口 ────────${RESET}"
    ip -br addr show 2>/dev/null || ip addr show
    echo -e "${BOLD}${CYAN}──────────────────────────────${RESET}"
}

prompt_interfaces() {
    local lan_def vpn_def
    lan_def=$(detect_lan_if)
    vpn_def=$(detect_vpn_if)

    show_interfaces

    while true; do
        read -r -e -p "请输入「局域网物理网卡」名称 (默认: ${lan_def}): " LAN_IF </dev/tty
        LAN_IF="${LAN_IF:-$lan_def}"
        if if_exists "$LAN_IF"; then
            break
        fi
        warn "接口 ${LAN_IF} 不存在，请重新输入（可参考上方接口列表）。"
    done

    while true; do
        read -r -e -p "请输入「EasyTier 虚拟网卡」名称 (默认: ${vpn_def}): " VPN_IF </dev/tty
        VPN_IF="${VPN_IF:-$vpn_def}"
        if if_exists "$VPN_IF"; then
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
}

# ==============================================================================
# 回程路由策略选择
# ==============================================================================
prompt_lan_nat() {
    echo
    echo -e "${BOLD}${CYAN}──────── 回程路由策略 ────────${RESET}"
    echo -e "  VPN 侧设备访问局域网时，局域网设备的回包怎么找到本网关？"
    echo -e ""
    echo -e "  ${BOLD}1)${RESET} 局域网设备默认网关指向本机 / 路由器已加静态路由"
    echo -e "     → 不需要额外 NAT，VPN 侧能看到局域网设备真实 IP"
    echo -e "  ${BOLD}2)${RESET} 局域网设备默认网关指向路由器，且不方便改（${BOLD}默认，推荐${RESET}）"
    echo -e "     → 在局域网出口做 MASQUERADE，回包必然回到本机；"
    echo -e "       代价是 VPN 侧看到的来源 IP 是本网关的虚拟 IP"
    echo -e ""
    read -r -p "请选择 [1/2]（默认: 2）: " ans </dev/tty
    case "${ans:-2}" in
        1) LAN_NAT="no"  ;;
        2) LAN_NAT="yes" ;;
        *) warn "无效选项，按默认 2 处理。"; LAN_NAT="yes" ;;
    esac
}

# ==============================================================================
# 开启 IPv4 转发（独立 sysctl.d 文件，不动 /etc/sysctl.conf）
# ==============================================================================
enable_forward() {
    title "配置 IPv4 转发"
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ] && [ -f "$SYSCTL_FILE" ]; then
        info "IPv4 转发已开启且已持久化。"
        return 0
    fi
    echo "net.ipv4.ip_forward=1" > "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE" >/dev/null
    info "IPv4 转发已开启并写入 ${SYSCTL_FILE}"
}

# ==============================================================================
# 应用规则（幂等：只清理/重建自己的链）
# ==============================================================================
apply_rules() {
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

    # ---- NAT：自定义链 ----
    iptables -t nat -N "$SNAT_CHAIN" 2>/dev/null || true
    iptables -t nat -F "$SNAT_CHAIN"

    # 局域网 → EasyTier 出口做伪装
    iptables -t nat -A "$SNAT_CHAIN" -o "$VPN_IF" -j MASQUERADE
    # EasyTier → 局域网出口做伪装（解决回程路由，见 prompt_lan_nat）
    if [ "$LAN_NAT" = "yes" ]; then
        iptables -t nat -A "$SNAT_CHAIN" -o "$LAN_IF" -j MASQUERADE
    fi

    if ! iptables -t nat -C POSTROUTING -j "$SNAT_CHAIN" 2>/dev/null; then
        iptables -t nat -I POSTROUTING 1 -j "$SNAT_CHAIN"
    fi

    # ---- MSS 钳制：解决 TUN MTU < 物理网卡 MTU 的黑洞问题 ----
    iptables -t mangle -N "$MSS_CHAIN" 2>/dev/null || true
    iptables -t mangle -F "$MSS_CHAIN"
    iptables -t mangle -A "$MSS_CHAIN" -p tcp --tcp-flags SYN,RST SYN \
             -j TCPMSS --clamp-mss-to-pmtu
    if ! iptables -t mangle -C FORWARD -j "$MSS_CHAIN" 2>/dev/null; then
        iptables -t mangle -I FORWARD 1 -j "$MSS_CHAIN"
    fi

    info "转发规则应用完成（自定义链: ${FWD_CHAIN} / ${SNAT_CHAIN} / ${MSS_CHAIN}）。"
}

# ==============================================================================
# 持久化
# ==============================================================================
save_rules() {
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
do_uninstall() {
    title "卸载 EasyTier 旁路网关配置"

    # 摘除挂载点
    while iptables -C FORWARD -j "$FWD_CHAIN" 2>/dev/null; do
        iptables -D FORWARD -j "$FWD_CHAIN"
    done
    while iptables -t nat -C POSTROUTING -j "$SNAT_CHAIN" 2>/dev/null; do
        iptables -t nat -D POSTROUTING -j "$SNAT_CHAIN"
    done
    while iptables -t mangle -C FORWARD -j "$MSS_CHAIN" 2>/dev/null; do
        iptables -t mangle -D FORWARD -j "$MSS_CHAIN"
    done

    # 删除自定义链（若有残留规则先清空）
    iptables -F "$FWD_CHAIN"  2>/dev/null || true
    iptables -X "$FWD_CHAIN"  2>/dev/null || true
    iptables -t nat -F "$SNAT_CHAIN" 2>/dev/null || true
    iptables -t nat -X "$SNAT_CHAIN" 2>/dev/null || true
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
do_cleanup_legacy() {
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
    lan_def=$(detect_lan_if)
    vpn_def=$(detect_vpn_if)
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
do_status() {
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
    iptables -t nat -S "$SNAT_CHAIN" 2>/dev/null || echo -e "  ${YELLOW}不存在（未安装）${RESET}"

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
do_install() {
    title "配置 EasyTier 旁路网关"

    prompt_interfaces
    prompt_lan_nat

    # 确认
    echo -e "\n${BOLD}${CYAN}──────── 配置确认 ────────${RESET}"
    echo -e "  局域网网卡:   ${CYAN}${LAN_IF}${RESET}"
    echo -e "  EasyTier 网卡: ${CYAN}${VPN_IF}${RESET}"
    echo -e "  LAN 出口 NAT: ${CYAN}$([ "$LAN_NAT" = "yes" ] && echo "启用（回包可靠，来源显示为网关 IP）" || echo "停用（需设备网关指向本机/静态路由）")${RESET}"
    echo -e "  规则载体:     ${CYAN}自定义链（不影响 Docker 等既有规则）${RESET}"
    echo -e "${BOLD}${CYAN}──────────────────────────${RESET}\n"
    read -r -p "确认应用？[Y/n]: " ans </dev/tty
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消。"; return 0; }

    enable_forward
    apply_rules
    save_rules

    echo
    success "EasyTier 旁路网关配置完成！"
    echo -e "  ${GREEN}1. 局域网设备可访问 EasyTier 虚拟网（需把网关/DNS 指向本机或按需路由）${RESET}"
    echo -e "  ${GREEN}2. EasyTier 虚拟网设备可访问局域网${RESET}"
    echo -e "  ${YELLOW}提示: 已启用 MSS 钳制，避免 TUN MTU 导致网页打不开。${RESET}"
    echo -e "  ${YELLOW}提示: 局域网设备使用本网关方式 —— 手动改网关，或路由器加静态路由，${RESET}"
    echo -e "  ${YELLOW}      或在 EasyTier 客户端将本机设为代理/子网节点。${RESET}"
}

# ==============================================================================
# 主菜单
# ==============================================================================
main_menu() {
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
        echo -e "  ${BOLD}0)${RESET} 退出"
        printf "请输入选项 [0-4]: "

        read -r choice </dev/tty
        case "$choice" in
            1) do_install        ;;
            2) do_status         ;;
            3) do_uninstall      ;;
            4) do_cleanup_legacy ;;
            0) echo -e "${GREEN}再见！${RESET}"; exit 0 ;;
            *) warn "无效选项 '${choice}'，请重新输入。" ;;
        esac

        echo ""
        printf "${YELLOW}按回车键返回主菜单...${RESET}" >&2
        read -r </dev/tty
    done
}

# ==============================================================================
# 入口
# ==============================================================================
main() {
    check_root
    check_deps
    main_menu
}

main "$@"
