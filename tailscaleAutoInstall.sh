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
        echo "[ERROR] 请以root权限运行此脚本（或使用sudo）"
        exit 1
    fi
}

# 函数：从远程URL获取内容（处理超时、空值、换行）
fetch_remote_content() {
    local url="$1"
    local content_name="$2"
    echo "[INFO] 从 ${url} 获取${content_name}..."
    
    # 使用curl获取内容：-f失败返回非0，-sS静默但显示错误，-m超时，-L跟随重定向
    local content
    content=$(curl -fsSL -m "${HTTP_TIMEOUT}" -L "${url}" | tr -d '\n\r' 2>/dev/null)
    
    # 检查获取结果是否为空
    if [ -z "${content}" ]; then
        echo "[ERROR] 无法获取${content_name}（URL: ${url}），内容为空或请求失败"
        exit 1
    fi
    
    echo "[INFO] 成功获取${content_name}：${content}"
    echo "${content}"
}

# 函数：等待网络启动完成（ping通8.8.8.8视为网络就绪）
wait_for_network() {
    echo "[INFO] 等待网络连接建立（超时${NETWORK_TIMEOUT}秒）..."
    local count=0
    while true; do
        if ping -c 1 -W 2 223.6.6.6 >/dev/null 2>&1; then
            echo "[INFO] 网络已就绪"
            break
        fi
        count=$((count + 1))
        if [ $count -ge $NETWORK_TIMEOUT ]; then
            echo "[ERROR] 网络等待超时，退出执行"
            exit 1
        fi
        sleep 1
    done
}

# 函数：验证Tailscale安装是否成功（ping指定IP 10次，有1次通即成功）
verify_tailscale() {
    local verify_ip="$1"
    echo "[INFO] 验证Tailscale安装结果，ping ${verify_ip} 共${PING_COUNT}次..."
    local ping_success=0
    for ((i=1; i<=PING_COUNT; i++)); do
        echo "[INFO] 第${i}次ping ${verify_ip}..."
        if ping -c 1 -W 2 "${verify_ip}" >/dev/null 2>&1; then
            echo "[INFO] 第${i}次ping成功，判定安装正常"
            ping_success=1
            break
        fi
        sleep 1
    done
    return $ping_success
}

# ===================== 主逻辑 =====================
# 1. 检查root权限
check_root

# 2. 检查标记文件，存在则直接退出
if [ -f "${MARK_FILE}" ]; then
    echo "[INFO] 检测到安装完成标记文件（${MARK_FILE}），无需重复执行，退出"
    exit 0
fi

# 3. 等待网络就绪（先确保能访问远程URL）
wait_for_network

# 4. 动态获取Tailscale Auth-Key和验证IP
TAILSCALE_AUTH_KEY=$(fetch_remote_content "${KEY_URL}" "Tailscale Auth-Key")
VERIFY_IP=$(fetch_remote_content "${IP_URL}" "验证IP")

# 5. 构造Tailscale安装&启动命令
TAILSCALE_CMD="curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up --auth-key=${TAILSCALE_AUTH_KEY} --advertise-exit-node"

# 6. 执行Tailscale安装&启动命令
echo "[INFO] 开始执行Tailscale安装命令..."
if ! eval "${TAILSCALE_CMD}"; then
    echo "[ERROR] Tailscale安装/启动命令执行失败"
    exit 1
fi

# 7. 验证安装结果
if verify_tailscale "${VERIFY_IP}"; then
    # 验证成功：创建标记文件（先确保目录存在）
    mkdir -p "$(dirname "${MARK_FILE}")"
    touch "${MARK_FILE}"
    echo "[INFO] Tailscale安装验证成功，标记文件已创建：${MARK_FILE}"
else
    # 验证失败：不创建标记，退出
    echo "[ERROR] ${PING_COUNT}次ping ${VERIFY_IP}全部失败，安装验证失败"
    exit 1
fi

echo "[INFO] Tailscale自动安装脚本执行完成"
exit 0
