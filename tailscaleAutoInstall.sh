#!/bin/bash
set -euo pipefail  # 增强脚本容错性

# ===================== 配置项（可根据需求修改） =====================
# 安装完成标记文件（存在则不再执行）
MARK_FILE="/var/lib/tailscale/install_completed.mark"
# 网络等待超时时间（秒，默认5分钟）
NETWORK_TIMEOUT=300
# 远程获取Auth-Key的URL（验证IP不再需要，已删除）
KEY_URL="https://cf.442230.xyz/tailscaleKEY"
# 远程请求超时时间（秒）
HTTP_TIMEOUT=10
# ====================================================================

# 函数：检查是否为root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "[ERROR] 请以root权限运行此脚本（或使用sudo）" >&2
        exit 1
    fi
}

# 函数：从远程URL获取内容（日志输出到stderr，纯内容输出到stdout）
# 参数1：URL；参数2：内容名称（仅用于日志）
fetch_remote_content() {
    local url="$1"
    local content_name="$2"
    
    # 日志输出到stderr（>&2），避免混入stdout导致变量污染
    echo "[INFO] 从 ${url} 获取${content_name}..." >&2
    
    # 使用curl获取内容：-f失败返回非0，-sS静默但显示错误，-m超时，-L跟随重定向
    # 仅将纯内容输出到stdout，日志输出到stderr
    local content
    content=$(curl -fsSL -m "${HTTP_TIMEOUT}" -L "${url}" 2>/dev/null | tr -d '\n\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    
    # 检查获取结果是否为空
    if [ -z "${content}" ]; then
        echo "[ERROR] 无法获取${content_name}（URL: ${url}），内容为空或请求失败" >&2
        exit 1
    fi
    
    # 日志输出到stderr，纯内容输出到stdout
    echo "[INFO] 成功获取${content_name}，长度：${#content} 字符" >&2
    echo "${content}"  # 仅返回纯内容，供变量捕获
}

# 函数：验证Auth-Key格式（Tailscale Auth-Key以tskey-auth开头）
validate_auth_key() {
    local auth_key="$1"
    if [[ ! "${auth_key}" =~ ^tskey-auth- ]]; then
        echo "[ERROR] 获取的Auth-Key格式错误（非tskey-auth开头）：${auth_key}" >&2
        exit 1
    fi
}

# 函数：等待网络启动完成（ping通223.5.5.5视为网络就绪）
wait_for_network() {
    echo "[INFO] 等待网络连接建立（超时${NETWORK_TIMEOUT}秒）..." >&2
    local count=0
    while true; do
        if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; then
            echo "[INFO] 网络已就绪" >&2
            break
        fi
        count=$((count + 1))
        if [ $count -ge $NETWORK_TIMEOUT ]; then
            echo "[ERROR] 网络等待超时，退出执行" >&2
            exit 1
        fi
        sleep 1
    done
}

# ==================== 核心函数：获取并验证Tailscale IPv4地址 ====================
# 函数：获取本机Tailscale网卡的IPv4地址并验证有效性
# 成功：返回0，纯IP输出到stdout；失败：返回1，输出空字符串
get_and_verify_tailscale_ip() {
    echo "[INFO] 正在获取并验证本机Tailscale IPv4地址..." >&2
    
    # 最多重试5次（避免刚启动tailscale时网卡未就绪）
    local retry_count=5
    local ts_ip=""
    
    for ((i=1; i<=retry_count; i++)); do
        # 使用Tailscale官方命令获取IPv4地址（最可靠）
        ts_ip=$(tailscale ip -4 2>/dev/null | tr -d '\n\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
        # 检查IP是否非空且格式合法
        if [ -n "${ts_ip}" ] && [[ "${ts_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "[INFO] 第${i}次尝试：成功获取有效Tailscale IPv4地址：${ts_ip}" >&2
            echo "${ts_ip}"
            return 0
        fi
        
        echo "[INFO] 第${i}次尝试：未获取到有效Tailscale IPv4地址（当前值：${ts_ip}），1秒后重试..." >&2
        sleep 1
    done
    
    # 重试完毕仍未获取到有效IP
    echo "[ERROR] 重试${retry_count}次后仍未获取到有效Tailscale IPv4地址" >&2
    echo ""
    return 1
}

# ===================== 主逻辑 =====================
# 1. 检查root权限
check_root

# 2. 检查标记文件，存在则直接退出
if [ -f "${MARK_FILE}" ]; then
    echo "[INFO] 检测到安装完成标记文件（${MARK_FILE}），无需重复执行，退出" >&2
    exit 0
fi

# 3. 等待网络就绪（先确保能访问远程URL）
wait_for_network

# 4. 动态获取Tailscale Auth-Key（验证IP已移除，无需获取）
TAILSCALE_AUTH_KEY=$(fetch_remote_content "${KEY_URL}" "Tailscale Auth-Key")

# 5. 验证Auth-Key格式合法性
validate_auth_key "${TAILSCALE_AUTH_KEY}"

# 6. 构造Tailscale安装&启动命令（加引号防止参数拆分）
TAILSCALE_INSTALL_CMD="curl -fsSL https://tailscale.com/install.sh | sh"
TAILSCALE_UP_CMD="sudo tailscale up --auth-key='${TAILSCALE_AUTH_KEY}' --advertise-exit-node"

# 7. 执行Tailscale安装命令
echo "[INFO] 开始执行Tailscale安装命令..." >&2
if ! bash -c "${TAILSCALE_INSTALL_CMD}"; then
    echo "[ERROR] Tailscale安装命令执行失败" >&2
    exit 1
fi

# 8. 执行Tailscale启动命令（单独执行，便于排查错误）
echo "[INFO] 开始执行Tailscale启动命令（绑定exit-node）..." >&2
if ! bash -c "${TAILSCALE_UP_CMD}"; then
    echo "[ERROR] Tailscale启动命令执行失败（Auth-Key可能无效/过期）" >&2
    exit 1
fi

# 9. 核心验证：获取并验证Tailscale IPv4地址（判定安装是否成功）
TAILSCALE_IP=$(get_and_verify_tailscale_ip)
if [ -n "${TAILSCALE_IP}" ] && [[ "${TAILSCALE_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    # 验证成功：创建标记文件（先确保目录存在）
    mkdir -p "$(dirname "${MARK_FILE}")"
    touch "${MARK_FILE}"
    
    # 高亮显示成功信息和IP地址
    echo -e "\n[SUCCESS] Tailscale安装成功！" >&2
    echo -e "[SUCCESS] 本机Tailscale IPv4地址：\033[32m${TAILSCALE_IP}\033[0m" >&2
    echo "[INFO] 安装完成标记文件已创建：${MARK_FILE}" >&2
else
    # 验证失败：不创建标记，退出
    echo "[ERROR] 未能获取到有效Tailscale IPv4地址，安装验证失败" >&2
    exit 1
fi

echo "[INFO] Tailscale自动安装脚本执行完成" >&2
exit 0
