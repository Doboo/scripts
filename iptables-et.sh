#!/bin/bash
# ==============================================================================
# EasyTier 旁路网关一键配置脚本（Debian 12）
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
LAN_NAT="no"    # VPN→LAN 是否在 LAN_IF 出口做 MASQUERADE
                # 默认 no（零 NAT）：回程由路由器静态路由保证
LAN_CIDR=""     # 局域网 CIDR，如 192.168.3.0/24
VPN_CIDR=""     # EasyTier 虚拟网 CIDR，如 10.144.144.0/24
LAN_IP=""       # 本机局域网 IP（路由器静态路由的下一跳）

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

# 取某网卡的主 IPv4 CIDR（如 192.168.3.9/24），取不到返回空
iface_cidr() {
    ip -4 addr show dev "$1" 2>/dev/null | awk '/inet /{print $2; exit}' || true
}

# CIDR -> 纯 IP
cidr_ip() {
    echo "${1%%/*}"
}

# IP/前缀 -> 网络号 CIDR（192.168.3.9/24 -> 192.168.3.0/24）；无 ipcalc 也能算
cidr_net() {
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

    # 采集网段信息，用于打印路由器静态路由命令
    local lan_cidr vpn_cidr
    lan_cidr=$(iface_cidr "$LAN_IF")
    vpn_cidr=$(iface_cidr "$VPN_IF")
    LAN_CIDR=$([ -n "$lan_cidr" ] && cidr_net "$lan_cidr" || echo "")
    VPN_CIDR=$([ -n "$vpn_cidr" ] && cidr_net "$vpn_cidr" || echo "")
    LAN_IP=$([ -n "$lan_cidr" ] && cidr_ip "$lan_cidr" || echo "")
    [ -n "$LAN_CIDR" ] && info "局域网网段: ${CYAN}${LAN_CIDR}${RESET}（本机 IP: ${LAN_IP}）"
    [ -n "$VPN_CIDR" ] && info "虚拟网网段: ${CYAN}${VPN_CIDR}${RESET}"
}

# ==============================================================================
# 回程路由策略选择
# ==============================================================================
prompt_lan_nat() {
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

# 摘除 SNAT 链的挂载点与链本身（幂等，供 LAN_NAT=no 与卸载流程共用）
remove_snat() {
    while iptables -t nat -C POSTROUTING -j "$SNAT_CHAIN" 2>/dev/null; do
        iptables -t nat -D POSTROUTING -j "$SNAT_CHAIN"
    done
    iptables -t nat -F "$SNAT_CHAIN" 2>/dev/null || true
    iptables -t nat -X "$SNAT_CHAIN" 2>/dev/null || true
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
        remove_snat
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
    remove_snat
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
do_install() {
    title "配置 EasyTier 旁路网关"

    prompt_interfaces
    prompt_lan_nat

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

    enable_forward
    apply_rules
    save_rules

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
