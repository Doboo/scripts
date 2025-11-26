#!/bin/bash
set -euo pipefail  # 增强脚本容错性

# ===================== 配置项（可根据需求修改） =====================
# 安装完成标记文件（存在则不再执行）
MARK_FILE="/var/lib/tailscale/install_completed.mark"
# ping验证次数（10次内有1次通即判定成功）
PING_COUNT=10
# 网络等待超时时间（秒，默认5分钟）
NETWORK_TIMEOUT=300
# 远程获取Auth-Key和验证IP的URL
KEY_URL="https://cf.442230.xyz/tailscaleKEY"
IP_URL="https://cf.442230.xyz/tailscaleIP"
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

# 函数：等待网络启动完成（ping通8.8.8.8视为网络就绪）
wait_for_network() {
    echo "[INFO] 等待网络连接建立（超时${NETWORK_TIMEOUT}秒）..." >&2
    local count=0
    while true; do
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
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

# 函数：验证Tailscale安装是否成功
# 逻辑：ping指定IP 10次，只要有1次通即判定成功（Shell return 0=成功，1=失败）
verify_tailscale() {
    local verify_ip="$1"
    echo "[INFO] 验证Tailscale安装结果：ping ${verify_ip} 共${PING_COUNT}次，1次通即判定成功..." >&2
    
    # 初始化状态为「失败」（1=失败）
    local ping_result=1
    for ((i=1; i<=PING_COUNT; i++)); do
        echo "[INFO] 第${i}次ping ${verify_ip}..." >&2
        # ping 1次，超时2秒，静默执行
        if ping -c 1 -W 2 "${verify_ip}" >/dev/null 2>&1; then
            echo "[INFO] 第${i}次ping ${verify_ip}成功！直接判定安装验证通过" >&2
            ping_result=0  # 置为「成功」状态
            break  # 无需继续ping，直接退出循环
        fi
        sleep 1
    done
    
    # 返回结果：0=成功（至少1次通），1=失败（10次全不通）
    return ${ping_result}
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

# 4. 动态获取Tailscale Auth-Key和验证IP（仅捕获stdout的纯内容）
TAILSCALE_AUTH_KEY=$(fetch_remote_content "${KEY_URL}" "Tailscale Auth-Key")
VERIFY_IP=$(fetch_remote_content "${IP_URL}" "验证IP")

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

# 9. 验证安装结果（核心逻辑：10次ping只要1次通即成功）
if verify_tailscale "${VERIFY_IP}"; then
    # 验证成功：创建标记文件（先确保目录存在）
    mkdir -p "$(dirname "${MARK_FILE}")"
    touch "${MARK_FILE}"
    echo "[INFO] Tailscale安装验证成功（10次ping中至少1次通），标记文件已创建：${MARK_FILE}" >&2
else
    # 验证失败：不创建标记，退出
    echo "[ERROR] ${PING_COUNT}次ping ${VERIFY_IP}全部失败，安装验证失败" >&2
    exit 1
fi

echo "[INFO] Tailscale自动安装脚本执行完成" >&2
exit 0
