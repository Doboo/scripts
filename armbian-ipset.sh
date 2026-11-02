#!/bin/bash
# =============================================================================
# armbian-ipset.sh v3.0 —— 基于 NetworkManager 的静态 IP 配置工具
#
# 适用环境：Armbian / Debian，NetworkManager 主导网络，netplan 仅负责把控制权
#          移交给 NM（本脚本不读取、不写入、不删除 /etc/netplan 下任何文件）。
#
# 与旧版（netplan + networkd + netplan try）的差异：
#   1. 配置写入 NetworkManager keyfile，不再使用 netplan / systemd-networkd；
#   2. 不使用 netplan try（该命令 120s 无人工确认会自动回滚，SSH 场景必然失败）；
#   3. 应用与守护回滚全部用 setsid 脱离 SSH 会话，输出写入日志文件；
#   4. 写入后强制 sync（根分区挂载参数 commit=600，直接断电有丢数据风险）；
#   5. 应用后有延时守护进程校验，网关不可达时自动回滚；
#   6. 支持非交互参数（供自动化调用）与 --rollback。
#
# 用法：
#   ./armbian-ipset.sh                         交互菜单
#   ./armbian-ipset.sh --status                只读查看当前配置
#   ./armbian-ipset.sh --ip 192.168.1.100 --mask 255.255.255.0 \
#                      --gw 192.168.1.1 --dns "223.6.6.6 114.114.114.114" --yes
#   ./armbian-ipset.sh --dhcp --yes
#   ./armbian-ipset.sh --rollback [--yes]
#
# 日志：/root/armbian-ipset.log    备份：/root/net-backup/<时间戳>/
# =============================================================================

set -uo pipefail

LOG="${ARMBIAN_IPSET_LOG:-/root/armbian-ipset.log}"
BACKUP_ROOT="/root/net-backup"
RESULT_FILE="/root/.ip-result"
GUARD_SCRIPT="/root/.ip-guard.sh"
DEFAULT_DNS="223.6.6.6 114.114.114.114"
DEFAULT_MASK="255.255.255.0"
GUARD_DELAY=90
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"

ASSUME_YES=0
ACTION=""
IP=""; MASK=""; GW=""; DNS=""
IFACE_ARG=""; CON_ARG=""; FROM_DIR=""
IFACE=""; CON=""; BACKUP_DIR=""

# ---------------------------------------------------------------- 日志
logline() { { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; } 2>/dev/null; return 0; }
say()     { printf '%s\n' "$*"; logline "$*"; }
warn()    { printf '警告：%s\n' "$*" >&2; logline "警告：$*"; }
die()     { printf '错误：%s\n' "$*" >&2; logline "错误：$*"; exit 1; }

rotate_log() {
    [ -f "$LOG" ] || return 0
    local size
    size=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
    [ "$size" -gt 1048576 ] && mv -f "$LOG" "$LOG.1"
    return 0
}

# ---------------------------------------------------------------- 基础校验
valid_ip() {
    local ip=$1 o
    [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        [ ${#o} -gt 1 ] && [ "${o:0:1}" = "0" ] && return 1   # 拒绝 010 这类歧义写法
        [ "$o" -le 255 ] || return 1
    done
    return 0
}

ip2int() {
    local a b c d
    IFS=. read -r a b c d <<<"$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# 子网掩码 -> 前缀长度；接受 255.255.255.0 或 24 或 /24 三种写法
mask_to_cidr() {
    local m=$1 cidr=0 bit n rest
    if [[ $m =~ ^/?([0-9]{1,2})$ ]]; then
        cidr=${BASH_REMATCH[1]}
        [ "$cidr" -le 32 ] || return 1
        echo "$cidr"
        return 0
    fi
    valid_ip "$m" || return 1
    n=$(ip2int "$m")
    for ((bit = 31; bit >= 0; bit--)); do
        if (( (n >> bit) & 1 )); then
            cidr=$((cidr + 1))
        else
            rest=$(( n & ((1 << bit) - 1) ))
            [ "$rest" -eq 0 ] || return 1      # 掩码必须是连续的 1
            break
        fi
    done
    echo "$cidr"
}

cidr_to_mask() {
    local p=$1 n
    if [ "$p" -eq 0 ]; then
        echo "0.0.0.0"
        return 0
    fi
    n=$(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# $1=ip $2=cidr $3=是否网络号/广播地址 检查
check_host_addr() {
    local ip=$1 cidr=$2 i mask net bcast
    [ "$cidr" -ge 31 ] && return 0      # /31、/32 没有网络号/广播地址概念
    i=$(ip2int "$ip")
    if [ "$cidr" -eq 0 ]; then
        net=0; bcast=4294967295
    else
        mask=$(( (0xFFFFFFFF << (32 - cidr)) & 0xFFFFFFFF ))
        net=$(( i & mask ))
        bcast=$(( net | (~mask & 0xFFFFFFFF) ))
    fi
    [ "$i" -eq "$net" ] && { echo "网络号"; return 1; }
    [ "$i" -eq "$bcast" ] && { echo "广播地址"; return 1; }
    return 0
}

same_subnet() {
    local ip=$1 gw=$2 cidr=$3 mask
    if [ "$cidr" -eq 0 ]; then
        [ "$(ip2int "$ip")" -eq "$(ip2int "$gw")" ] && return 0 || return 1
    fi
    mask=$(( (0xFFFFFFFF << (32 - cidr)) & 0xFFFFFFFF ))
    [ $(( $(ip2int "$ip") & mask )) -eq $(( $(ip2int "$gw") & mask )) ]
}

# ---------------------------------------------------------------- 网络识别
detect_iface() {
    local i
    i=$(ip -4 route show default 2>/dev/null |
        awk '{for(n=1;n<=NF;n++) if($n=="dev"){print $(n+1); exit}}')
    if [ -z "$i" ]; then
        i=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null |
            awk -F: '$2=="ethernet" && $1!="lo"{print $1; exit}')
    fi
    if [ -z "$i" ]; then
        i=$(ip -o link show 2>/dev/null |
            awk -F': ' '$2!="lo" && $2 !~ /^(veth|docker|br-|bond|tun|tailscale|wg)/{print $2; exit}')
    fi
    echo "$i"
}

detect_conn() {
    local iface=$1 name=""
    [ -n "$iface" ] || { echo ""; return 0; }
    name=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null |
           awk -F: -v d="$iface" '$2==d{print $1; exit}')
    if [ -z "$name" ]; then
        name=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null |
               awk -F: -v d="$iface" '$2==d{print $1; exit}')
    fi
    echo "$name"
}

ensure_conn() {
    local name
    name=$(detect_conn "$IFACE")
    if [ -z "$name" ]; then
        name="armbian-ipset-$IFACE"
        nmcli connection add type ethernet ifname "$IFACE" con-name "$name" >/dev/null 2>&1 ||
            die "无法为网卡 $IFACE 创建 NetworkManager 连接"
        logline "已创建 NM 连接「$name」（$IFACE）"
    fi
    echo "$name"
}

iface_addr() { ip -4 -o addr show dev "$1" 2>/dev/null | awk 'NR==1{print $4}'; }
iface_gw()   { ip -4 route show default 2>/dev/null |
               awk '{for(n=1;n<=NF;n++) if($n=="via"){print $(n+1); exit}}'; }

keyfile_of() {
    local con=$1 uuid kf
    uuid=$(nmcli -g connection.uuid connection show "$con" 2>/dev/null | head -1)
    for kf in /etc/NetworkManager/system-connections/*.nmconnection; do
        [ -f "$kf" ] || continue
        if [ -n "$uuid" ] && grep -qx "uuid=$uuid" "$kf" 2>/dev/null; then
            echo "$kf"; return 0
        fi
        if grep -qx "id=$con" "$kf" 2>/dev/null; then
            echo "$kf"; return 0
        fi
    done
    return 1
}

# 从 keyfile 精确读取字段，避免 nmcli -g 多值分隔符歧义
kf_get() { awk -v k="$2" -F= '$1==k{sub("^[^=]*=",""); print; exit}' "$1" 2>/dev/null; }

norm_dns() {
    local s=${1//,/ }; s=${s//;/ }
    echo "$s" | xargs 2>/dev/null || echo "$s"
}

# ---------------------------------------------------------------- 备份 / 回滚
backup_now() {
    local dir="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)" kf uuid om oa og od
    mkdir -p "$dir" || return 1
    chmod 700 "$BACKUP_ROOT" 2>/dev/null

    nmcli connection show "$CON" >"$dir/con.txt" 2>/dev/null
    printf 'CON=%q\nIFACE=%q\n' "$CON" "$IFACE" >"$dir/meta.env"
    uuid=$(nmcli -g connection.uuid connection show "$CON" 2>/dev/null | head -1)
    printf 'UUID=%q\n' "$uuid" >>"$dir/meta.env"

    kf=""
    if [ -n "$uuid" ]; then
        kf=$(grep -lx "uuid=$uuid" /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null | head -1)
    fi
    [ -n "$kf" ] || kf=$(keyfile_of "$CON" || true)

    if [ -n "$kf" ] && [ -f "$kf" ]; then
        cp -a "$kf" "$dir/conn.nmconnection" || return 1
        om=$(kf_get "$kf" method);        [ -n "$om" ] || om=auto
        oa=$(kf_get "$kf" address1 | cut -d, -f1)
        og=$(kf_get "$kf" gateway)
        od=$(kf_get "$kf" dns | tr ';' ' ' | xargs 2>/dev/null)
        printf 'HAVE_KEYFILE=1\nKEYFILE_NAME=%q\n' "$(basename "$kf")" >>"$dir/meta.env"
    else
        # 连接由 NM 临时生成（keyfile 在 /run），只能靠 nmcli 查询值回滚
        om=$(nmcli -g ipv4.method connection show "$CON" 2>/dev/null)
        oa=$(nmcli -g ipv4.addresses connection show "$CON" 2>/dev/null | tr -d ' ' | tr '|' ',')
        og=$(nmcli -g ipv4.gateway connection show "$CON" 2>/dev/null)
        od=$(nmcli -g ipv4.dns connection show "$CON" 2>/dev/null | tr -d ' ' | tr '|' ' ' | tr ',' ' ')
        printf 'HAVE_KEYFILE=0\n' >>"$dir/meta.env"
    fi
    printf 'OLD_METHOD=%q\nOLD_ADDR=%q\nOLD_GW=%q\nOLD_DNS=%q\n' \
        "${om:-auto}" "$oa" "$og" "$od" >>"$dir/meta.env"

    sync
    logline "已备份到 $dir"
    BACKUP_DIR="$dir"
    echo "$dir"
}

latest_backup() {
    ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -1
}

rollback_from() {
    local dir=$1 name
    [ -n "$dir" ] && [ -d "$dir" ] || { err_msg "备份目录不存在：${dir:-未指定}"; return 1; }

    # meta.env 由 %q 生成，可直接 source
    # shellcheck disable=SC1091
    source "$dir/meta.env" || return 1

    if [ "${HAVE_KEYFILE:-0}" = "1" ] && [ -f "$dir/conn.nmconnection" ]; then
        name=$(kf_get "$dir/conn.nmconnection" id)
        [ -n "$name" ] || name="$CON"
        install -m 600 -o root -g root "$dir/conn.nmconnection" \
            "/etc/NetworkManager/system-connections/${name}.nmconnection" || return 1
        nmcli connection reload >/dev/null 2>&1
        logline "已从备份恢复 keyfile：${name}.nmconnection"
        sync
        nmcli connection up "$name" >>"$LOG" 2>&1
    else
        if [ "${OLD_METHOD:-auto}" = "auto" ]; then
            nmcli con mod "$CON" ipv4.method auto \
                ipv4.addresses "" ipv4.gateway "" ipv4.dns "" >>"$LOG" 2>&1 || return 1
        else
            nmcli con mod "$CON" ipv4.method manual \
                ipv4.addresses "${OLD_ADDR:-}" ipv4.gateway "${OLD_GW:-}" \
                ipv4.dns "${OLD_DNS:-}" >>"$LOG" 2>&1 || return 1
        fi
        sync
        nmcli con up "$CON" >>"$LOG" 2>&1
    fi
    logline "回滚完成（来源 $dir）"
    return 0
}

err_msg() { printf '错误：%s\n' "$*" >&2; logline "错误：$*"; }

do_rollback() {
    local dir=${FROM_DIR:-$(latest_backup)}
    if [ -z "$dir" ]; then
        die "未找到任何备份（$BACKUP_ROOT 为空）"
    fi
    dir=${dir%/}
    say "准备回滚到备份：$dir"
    [ -f "$dir/con.txt" ] && { echo "----- 备份时的连接参数 -----"; sed -n '1,12p' "$dir/con.txt"; }
    confirm "确认恢复该备份？" || { say "已取消。"; exit 0; }

    if ! rollback_from "$dir"; then
        die "回滚失败，请检查 $LOG"
    fi
    sleep 3
    say "回滚已下发，当前状态："
    status_brief
}

# ---------------------------------------------------------------- 守护进程
# $1=static|dhcp  $2=期望地址（ip/prefix，仅 static 使用）
apply_and_guard() {
    local mode=$1 expect=$2 txt i=0

    rm -f "$RESULT_FILE"
    cat >"$GUARD_SCRIPT" <<GUARD
#!/bin/bash
# 由 armbian-ipset.sh 生成：应用新配置 -> 延时校验 -> 失败自动回滚
LOG="${LOG}"
CON="${CON}"
IFACE="${IFACE}"
MODE="${mode}"
EXPECT="${expect}"
GUARD_DELAY="${GUARD_DELAY}"
RESULT="${RESULT_FILE}"
BACKUP="${BACKUP_DIR}"
SELF="${SELF}"

t() { date '+%F %T'; }
note() { echo "[\$(t)] \$*" >>"\$LOG"; }

add_reason() { reason="\${reason:+\$reason; }\$1"; }

note "开始应用新配置（\$MODE）"
nmcli connection up "\$CON" >>"\$LOG" 2>&1

sleep 6
if [ "\$MODE" = "static" ] && ! ip -4 addr show dev "\$IFACE" 2>/dev/null | grep -q "inet \$EXPECT "; then
    note "运行态地址未生效，执行 nmcli device reapply"
    nmcli device reapply "\$IFACE" >>"\$LOG" 2>&1
    sleep 4
fi
# con up 在个别版本上对已激活连接是空操作，仍不生效时强制 down/up 重载一次
if [ "\$MODE" = "static" ] && ! ip -4 addr show dev "\$IFACE" 2>/dev/null | grep -q "inet \$EXPECT "; then
    note "地址仍未生效，执行 down/up 强制重载"
    nmcli connection down "\$CON" >>"\$LOG" 2>&1
    sleep 1
    nmcli connection up "\$CON" >>"\$LOG" 2>&1
    sleep 5
fi

note "守护进程等待 \${GUARD_DELAY}s 后校验连通性"
sleep "\$GUARD_DELAY"

ok=1; reason=""
addr_now=\$(ip -4 -o addr show dev "\$IFACE" 2>/dev/null | awk 'NR==1{print \$4}')
gw_now=\$(ip route show default 2>/dev/null | awk '{for(n=1;n<=NF;n++) if(\$n=="via"){print \$(n+1); exit}}')

[ -n "\$addr_now" ] || { ok=0; add_reason "接口无 IPv4 地址"; }
[ -n "\$gw_now" ]   || { ok=0; add_reason "无默认路由"; }
if [ "\$MODE" = "static" ] && [ "\$addr_now" != "\$EXPECT" ]; then
    ok=0; add_reason "地址为 \${addr_now:-无}，预期 \$EXPECT"
fi
if [ -n "\$gw_now" ] && ! ping -c 2 -W 2 "\$gw_now" >/dev/null 2>&1; then
    ok=0; add_reason "网关 \$gw_now 不可达"
fi

if [ "\$ok" = "1" ]; then
    note "校验通过：addr=\$addr_now gw=\$gw_now"
    echo "OK|\$addr_now|\$gw_now" >"\$RESULT"
else
    note "校验失败（\$reason），开始自动回滚"
    if "\$SELF" --rollback --yes --from "\$BACKUP" >>"\$LOG" 2>&1; then
        echo "ROLLED_BACK|\$reason" >"\$RESULT"
        note "自动回滚已完成"
    else
        echo "ROLLBACK_FAILED|\$reason" >"\$RESULT"
        note "自动回滚失败，请现场排查或手动执行 \$SELF --rollback"
    fi
fi
rm -f "\$0"
GUARD

    chmod 700 "$GUARD_SCRIPT" || die "无法写入守护脚本 $GUARD_SCRIPT"
    logline "守护脚本已生成：$GUARD_SCRIPT（${GUARD_DELAY}s 后校验）"

    # setsid 脱离当前会话：SSH 断开、IP 切换导致连接中断都不影响应用与回滚
    setsid bash "$GUARD_SCRIPT" </dev/null >/dev/null 2>&1 &

    printf '\n'
    say "配置已下发，后台守护进程已启动。"
    say "稍后本机会切换 IP，SSH 会话可能中断——这不是失败，应用与校验在独立会话中进行。"
    say "等待校验结果（最长 $((GUARD_DELAY + 60))s）……"

    while [ ! -s "$RESULT_FILE" ] && [ "$i" -lt $((GUARD_DELAY + 60)) ]; do
        sleep 3
        i=$((i + 3))
        [ $((i % 15)) -eq 0 ] && printf '.'
    done
    printf '\n'

    if [ ! -s "$RESULT_FILE" ]; then
        warn "未在预期时间内取到校验结果，请稍后执行 $SELF --status，或查看 $LOG"
        return 2
    fi

    txt=$(cat "$RESULT_FILE" 2>/dev/null)
    case "$txt" in
        OK*)
            say "✔ 配置已生效：${txt#OK|}"
            say "  地址校验：$(echo "$txt" | cut -d'|' -f2)   网关：$(echo "$txt" | cut -d'|' -f3)"
            ;;
        ROLLED_BACK*)
            err_msg "新配置校验失败，已自动回滚到原配置"
            err_msg "原因：${txt#ROLLED_BACK|}"
            say "  配置文件已还原，本次设置未生效。请核对 IP/掩码/网关后重试。"
            return 1
            ;;
        ROLLBACK_FAILED*)
            err_msg "新配置校验失败，且自动回滚未成功，设备可能已失联"
            err_msg "原因：${txt#ROLLBACK_FAILED|}"
            say "  请通过 Tailscale（tailscale0）或其他通道登录后执行：$SELF --rollback"
            return 1
            ;;
        *)
            warn "未知的校验结果：$txt"
            return 2
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------- 状态
status_brief() {
    local addr gw
    addr=$(iface_addr "$IFACE")
    gw=$(iface_gw)
    echo "网卡：$IFACE    连接：$CON"
    echo "地址：${addr:-无}    网关：${gw:-无}    method：$(nmcli -g ipv4.method connection show "$CON" 2>/dev/null)"
}

do_status() {
    local m a g d ac kf perm prefix
    m=$(nmcli -g ipv4.method connection show "$CON" 2>/dev/null)
    a=$(nmcli -g ipv4.addresses connection show "$CON" 2>/dev/null)
    g=$(nmcli -g ipv4.gateway connection show "$CON" 2>/dev/null)
    d=$(nmcli -g ipv4.dns connection show "$CON" 2>/dev/null)
    ac=$(nmcli -g connection.autoconnect connection show "$CON" 2>/dev/null)

    echo "===== 配置（NetworkManager keyfile）====="
    printf '%-12s %s\n' "网卡" "$IFACE"
    printf '%-12s %s\n' "NM 连接" "$CON"
    printf '%-12s %s\n' "method" "${m:-未知}"
    printf '%-12s %s\n' "配置地址" "${a:-无}"
    prefix=${a%%,*}; prefix=${prefix##*/}
    if [[ $prefix =~ ^[0-9]{1,2}$ ]]; then
        printf '%-12s %s\n' "子网掩码" "$(cidr_to_mask "$prefix")（/$prefix）"
    fi
    printf '%-12s %s\n' "配置网关" "${g:-无}"
    printf '%-12s %s\n' "配置 DNS" "${d:-无}"
    printf '%-12s %s\n' "autoconnect" "${ac:-未知}"
    if kf=$(keyfile_of "$CON"); then
        printf '%-12s %s\n' "keyfile" "$kf"
        printf '%-12s %s\n' "权限" "$(ls -l "$kf" 2>/dev/null | awk '{print $1" "$3":"$4}')"
        perm=$(stat -c%a "$kf" 2>/dev/null)
        if [ -n "$perm" ] && [ "$perm" != "600" ]; then
            echo "  提示：keyfile 权限为 $perm，应为 600 —— 执行：chmod 600 '$kf'"
        fi
    else
        printf '%-12s %s\n' "keyfile" "未找到（连接可能仅在 /run 下，重启后不保留）"
    fi

    echo
    echo "===== 运行态 ====="
    if ip -4 addr show dev "$IFACE" >/dev/null 2>&1; then
        ip -4 addr show dev "$IFACE" | sed 's/^/  /'
    else
        echo "  无法读取 $IFACE 状态"
    fi
    ip route show default 2>/dev/null | sed 's/^/  /'

    echo
    echo "===== 连通性 ====="
    local gw
    gw=$(iface_gw)
    if [ -n "$gw" ]; then
        if ping -c 2 -W 2 "$gw" >/dev/null 2>&1; then echo "  网关 $gw 可达"; else echo "  网关 $gw 不可达"; fi
    else
        echo "  无默认网关，跳过探测"
    fi

    echo
    echo "===== 守护/备份 ====="
    [ -f "$RESULT_FILE" ] && echo "  最近校验结果：$(cat "$RESULT_FILE" 2>/dev/null)"
    [ -f "$GUARD_SCRIPT" ] && echo "  守护进程运行中（配置尚未完成校验）"
    echo "  备份目录：$(latest_backup 2>/dev/null || echo 无)"
    echo "  日志文件：$LOG"

    logline "status: iface=$IFACE con=$CON method=$m addr=$a gw=$g dns=$d"
}

# ---------------------------------------------------------------- 冲突探测
probe_conflict() {   # 返回 0=未发现占用  1=发现占用
    local ip=$1 cur
    cur=$(iface_addr "$IFACE"); cur=${cur%%/*}
    [ "$ip" = "$cur" ] && return 0      # 就是自己当前的地址，跳过
    if command -v arping >/dev/null 2>&1; then
        arping -c 2 -w 2 -I "$IFACE" "$ip" >/dev/null 2>&1 && return 1
        return 0
    fi
    ping -c 2 -W 1 "$ip" >/dev/null 2>&1 && return 1
    return 0
}

# ---------------------------------------------------------------- 交互辅助
confirm() {
    local ans
    if [ "$ASSUME_YES" = "1" ]; then
        logline "已按 --yes 自动确认：$1"
        return 0
    fi
    printf '%s [y/N]: ' "$1"
    read -r ans || die "无法读取输入（非交互环境请追加 --yes）"
    case "$ans" in
        y|Y|yes|YES|Yes) logline "用户确认：$1"; return 0 ;;
        *) logline "用户取消：$1"; return 1 ;;
    esac
}

# 注意：必须用全局变量回传，不能用 $(ask ...)。
# 命令替换会派生 subshell，subshell 里的 die 只退出子 shell，EOF 时会造成死循环。
ASK_RESULT=""
ask() {
    local prompt=$1 def=$2 v
    printf '%s' "$prompt"
    if ! read -r v; then
        die "无法读取输入（非交互环境请改用命令行参数，例如 --ip/--dhcp）"
    fi
    [ -n "$v" ] || v=$def
    ASK_RESULT=$v
}

require_tty() {
    [ -t 0 ] || die "当前 stdin 不是终端，交互模式无法进行。请改用参数：--status / --ip ... / --dhcp"
}

# ---------------------------------------------------------------- 应用
set_static() {
    local ip=$1 mask=$2 gw=$3 dns=$4 cidr addr_cur why one
    valid_ip "$ip" || die "IP 格式非法：$ip"
    cidr=$(mask_to_cidr "$mask") || die "子网掩码非法：$mask（必须是 255.255.255.0 这类连续掩码，或 0-32 的前缀长度）"
    valid_ip "$gw" || die "网关格式非法：$gw"
    [ "$gw" = "0.0.0.0" ] && die "网关不能为 0.0.0.0"
    [ "$ip" = "$gw" ] && die "IP 地址不能与网关地址相同"
    same_subnet "$ip" "$gw" "$cidr" ||
        die "$ip 与网关 $gw 不在同一 /$cidr 网段（掩码 $(cidr_to_mask "$cidr")），拒绝写入"
    if ! why=$(check_host_addr "$ip" "$cidr"); then
        die "$ip 是 /$cidr 网段的 $why，不能作为主机地址"
    fi

    dns=$(norm_dns "$dns")
    [ -n "$dns" ] || die "DNS 不能为空"
    for one in $dns; do
        valid_ip "$one" || die "DNS 格式非法：$one"
    done

    echo
    echo "----- 将写入的配置 -----"
    echo "  网卡        : $IFACE"
    echo "  NM 连接     : $CON"
    echo "  方式        : 静态（manual）"
    echo "  IP 地址     : $ip/$cidr  （掩码 $(cidr_to_mask "$cidr")）"
    echo "  网关        : $gw"
    echo "  DNS         : $dns"
    echo "  备份目录    : $BACKUP_ROOT/<时间戳>/"
    echo

    if ! probe_conflict "$ip"; then
        warn "目标地址 $ip 已有主机响应，可能存在地址冲突"
        confirm "仍然继续？" || { say "已取消，未做任何修改。"; exit 0; }
    fi

    confirm "确认写入并应用？" || { say "已取消，未做任何修改。"; exit 0; }

    addr_cur=$(iface_addr "$IFACE")
    backup_now >/dev/null || die "备份失败，已中止（未修改任何配置）"

    nmcli connection mod "$CON" \
        ipv4.method manual \
        ipv4.addresses "${ip}/${cidr}" \
        ipv4.gateway "$gw" \
        ipv4.dns "$dns" \
        connection.autoconnect yes >>"$LOG" 2>&1 || die "nmcli 写入失败，详见 $LOG"
    sync
    logline "已写入静态配置：$ip/$cidr gw=$gw dns=$dns（原地址 ${addr_cur:-无}）"

    say "配置文件已写入并 sync 落盘。"
    apply_and_guard static "${ip}/${cidr}"
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        say "提示：若 $ip 仍落在路由器 DHCP 分配池内，建议在路由器侧做地址保留或池排除，否则可能被分配给其他设备。"
    fi
    return "$rc"
}

set_dhcp() {
    echo
    echo "----- 将写入的配置 -----"
    echo "  网卡        : $IFACE"
    echo "  NM 连接     : $CON"
    echo "  方式        : DHCP（auto）"
    echo "  ipv4.addresses / gateway / dns 全部清空"
    echo
    confirm "确认写入并应用？" || { say "已取消，未做任何修改。"; exit 0; }

    backup_now >/dev/null || die "备份失败，已中止（未修改任何配置）"

    nmcli connection mod "$CON" \
        ipv4.method auto \
        ipv4.addresses "" ipv4.gateway "" ipv4.dns "" \
        connection.autoconnect yes >>"$LOG" 2>&1 || die "nmcli 写入失败，详见 $LOG"
    sync
    logline "已切换为 DHCP，addresses/gateway/dns 已清空"

    say "配置文件已写入并 sync 落盘。"
    apply_and_guard dhcp ""
    return $?
}

# 交互静态流程
interactive_static() {
    local cur_addr cur_ip cur_prefix cur_gw mask ip gw dns cidr ok one
    cur_addr=$(iface_addr "$IFACE")
    cur_ip=${cur_addr%%/*}
    cur_prefix=""
    [ -n "$cur_addr" ] && cur_prefix=${cur_addr##*/}
    cur_gw=$(iface_gw)
    [ "$cur_prefix" = "32" ] && cur_ip=""

    echo
    while :; do
        ask "IP 地址（默认: ${cur_ip:-无}）: " "$cur_ip"
        ip=$ASK_RESULT
        valid_ip "$ip" && break
        echo "  无效的 IP 地址格式，请重新输入。"
    done

    if [ -n "$cur_prefix" ] && [ "$cur_prefix" != "32" ]; then
        mask=$(cidr_to_mask "$cur_prefix")
    else
        mask=$DEFAULT_MASK
    fi
    while :; do
        ask "子网掩码（默认: $mask）: " "$mask"
        cidr=$(mask_to_cidr "$ASK_RESULT") && break
        echo "  无效的子网掩码，请重新输入。"
    done

    while :; do
        ask "网关（默认: ${cur_gw:-无}）: " "$cur_gw"
        gw=$ASK_RESULT
        valid_ip "$gw" && break
        echo "  无效的网关地址格式，请重新输入。"
    done

    while :; do
        ask "DNS（多个用空格分隔，默认: $DEFAULT_DNS）: " "$DEFAULT_DNS"
        dns=$(norm_dns "$ASK_RESULT")
        ok=1
        for one in $dns; do valid_ip "$one" || { ok=0; break; }; done
        [ "$ok" = "1" ] && [ -n "$dns" ] && break
        echo "  无效的 DNS 地址，请重新输入。"
    done

    set_static "$ip" "$mask" "$gw" "$dns"
}

menu() {
    require_tty
    local choice
    echo "=================================================="
    echo " Armbian 静态 IP 配置工具（NetworkManager）"
    echo "=================================================="
    status_brief
    echo "--------------------------------------------------"
    echo " 1) 恢复 DHCP（自动获取）"
    echo " 2) 设置静态 IP"
    echo " 3) 仅查看当前配置（只读）"
    echo " 0) 退出"
    echo "--------------------------------------------------"
    while :; do
        read -rp "请选择 (0-3): " choice || die "无法读取输入"
        case "$choice" in
            1) set_dhcp; exit $? ;;
            2) interactive_static; exit $? ;;
            3) do_status; exit 0 ;;
            0|"") say "已退出，未做任何修改。"; exit 0 ;;
            *) echo "无效选项，请重新输入。" ;;
        esac
    done
}

usage() {
    cat <<EOF
armbian-ipset.sh v3.0 —— 基于 NetworkManager 的静态 IP 配置工具

用法:
  $0                                          交互菜单
  $0 --status                                 只读查看当前配置
  $0 --ip <IP> --mask <MASK> --gw <GW> [--dns "<DNS...>"] [--yes]
  $0 --dhcp [--yes]
  $0 --rollback [--yes] [--from <备份目录>]

选项:
  --ip <IP>            静态 IP 地址
  --mask <MASK>        子网掩码，如 255.255.255.0 或 24
  --gw <GW>            网关地址
  --dns "<DNS...>"     DNS，空格/逗号/分号分隔，默认 "$DEFAULT_DNS"
  --iface <IFACE>      指定网卡（默认自动识别默认出口网卡）
  --con <NAME>         指定 NM 连接名（默认自动识别）
  --guard-delay <秒>   守护进程校验延时，默认 $GUARD_DELAY
  --from <目录>        配合 --rollback，指定备份目录（默认最近一次）
  -y, --yes            跳过二次确认（自动化用）
  -h, --help           显示本帮助

说明:
  配置写入 NetworkManager（/etc/NetworkManager/system-connections），
  本脚本不修改 /etc/netplan 与 /etc/network/interfaces。
  日志：$LOG    备份：$BACKUP_ROOT/<时间戳>/
EOF
}

# ---------------------------------------------------------------- 参数解析
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --ip)           [ $# -ge 2 ] || die "--ip 缺少参数";     IP=$2; ACTION=static; shift 2 ;;
            --mask)         [ $# -ge 2 ] || die "--mask 缺少参数";   MASK=$2; shift 2 ;;
            --gw)           [ $# -ge 2 ] || die "--gw 缺少参数";     GW=$2; shift 2 ;;
            --dns)          [ $# -ge 2 ] || die "--dns 缺少参数";    DNS=$2; shift 2 ;;
            --iface)        [ $# -ge 2 ] || die "--iface 缺少参数";  IFACE_ARG=$2; shift 2 ;;
            --con)          [ $# -ge 2 ] || die "--con 缺少参数";    CON_ARG=$2; shift 2 ;;
            --from)         [ $# -ge 2 ] || die "--from 缺少参数";   FROM_DIR=$2; shift 2 ;;
            --guard-delay)  [ $# -ge 2 ] || die "--guard-delay 缺少参数"
                            [[ $2 =~ ^[0-9]+$ ]] || die "--guard-delay 必须是整数秒"
                            GUARD_DELAY=$2; shift 2 ;;
            --dhcp)         ACTION=dhcp; shift ;;
            --status)       ACTION=status; shift ;;
            --rollback)     ACTION=rollback; shift ;;
            -y|--yes)       ASSUME_YES=1; shift ;;
            -h|--help)      usage; exit 0 ;;
            *)              usage; die "未知参数：$1" ;;
        esac
    done
}

# ---------------------------------------------------------------- 主流程
# 先解析参数：--help 在任何环境（含非 root、无 nmcli 的本机）都能正常显示
parse_args "$@"

[ "$(id -u)" -eq 0 ] || { echo "错误：请使用 root 权限运行" >&2; exit 1; }
command -v nmcli >/dev/null 2>&1 || { echo "错误：未找到 nmcli，本机可能不是 NetworkManager 管理网络" >&2; exit 1; }

rotate_log
logline "===== armbian-ipset.sh 启动：$* ====="

IFACE=${IFACE_ARG:-$(detect_iface)}
[ -n "$IFACE" ] || die "未能识别到可用网卡"
ip link show dev "$IFACE" >/dev/null 2>&1 || die "网卡 $IFACE 不存在"
CON=${CON_ARG:-$(ensure_conn "$IFACE")}
[ -n "$CON" ] || die "未能识别 $IFACE 对应的 NetworkManager 连接"

case "$ACTION" in
    status)   do_status; exit 0 ;;
    rollback) do_rollback; exit $? ;;
    dhcp)     set_dhcp; exit $? ;;
    static)
        [ -n "$IP" ]   || die "--ip 必填"
        [ -n "$MASK" ] || MASK=$DEFAULT_MASK
        [ -n "$GW" ]   || GW=$(iface_gw)
        [ -n "$GW" ]   || die "未能自动识别网关，请用 --gw 指定"
        [ -n "$DNS" ]  || DNS=$DEFAULT_DNS
        set_static "$IP" "$MASK" "$GW" "$DNS"; exit $? ;;
    "")       menu ;;
    *)        die "未知动作：$ACTION" ;;
esac
