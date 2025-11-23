#!/bin/bash
set -euo pipefail

# 检查必要工具 jq 是否安装
if ! command -v jq &> /dev/null; then
    echo "❌ 错误：未检测到 jq 工具，请先安装（Debian/Ubuntu：apt install jq -y；CentOS/RHEL：yum install jq -y）"
    exit 1
fi

# 定义关键路径
EASYTIER_CLI="/root/easytier/easytier-cli"
OUTPUT_YAML="/root/easytier/et.yaml"
SERVICE_FILE="/etc/systemd/system/easytier.service"

# 第一步：执行 easytier-cli 命令并提取配置
echo "🔧 正在执行 easytier 配置查询命令..."
if [ ! -x "$EASYTIER_CLI" ]; then
    echo "❌ 错误：$EASYTIER_CLI 不存在或无执行权限"
    exit 1
fi

# 执行命令并捕获输出（包含错误信息）
cli_output=$("$EASYTIER_CLI" -v node 2>&1)
if [ $? -ne 0 ]; then
    echo "❌ 错误：执行 easytier-cli 命令失败，输出：$cli_output"
    exit 1
fi

# 提取 config 字段并过滤不需要的行（instance_name/instance_id）
echo "📤 正在提取并处理配置内容..."
extracted_config=$(echo "$cli_output" | jq -r '.config' | grep -vE '^instance_(name|id) =')

# 验证提取结果
if [ -z "$extracted_config" ] || [ "$extracted_config" == "null" ]; then
    echo "❌ 错误：未能从命令输出中提取到有效配置"
    exit 1
fi

# 第二步：写入配置文件并回显
echo "💾 正在写入配置到 $OUTPUT_YAML..."
mkdir -p "$(dirname "$OUTPUT_YAML")"  # 确保目录存在
echo "$extracted_config" > "$OUTPUT_YAML"

# 回显提取的配置
echo -e "\n✅ 提取的配置内容如下："
echo "========================================"
echo "$extracted_config"
echo "========================================"
echo -e "✅ 配置已成功写入 $OUTPUT_YAML\n"

# 第三步：获取控制台用户名
read -p "🔑 请输入控制台用户名（无引号）：" username
if [ -z "$username" ]; then
    echo "❌ 错误：用户名不能为空"
    exit 1
fi

# 第四步：修改 systemd service 文件
echo -e "\n📝 正在修改 $SERVICE_FILE 文件..."
if [ ! -f "$SERVICE_FILE" ]; then
    echo "❌ 错误：文件 $SERVICE_FILE 不存在"
    exit 1
fi

# 检查用户名是否存在（匹配无引号的纯字符串，避免误匹配）
# 使用单词边界 \b 确保匹配完整用户名（避免部分匹配，如用户名是 test 不匹配 test123）
if ! grep -q "\b$username\b" "$SERVICE_FILE"; then
    read -p "⚠️  警告：在 $SERVICE_FILE 中未找到用户名 \"$username\"，是否继续执行替换？(y/n) " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "🚫 取消操作，脚本退出"
        exit 0
    fi
fi

# 执行替换（在用户名前添加 udp 地址，保持无引号格式）
# 同样使用单词边界确保完整匹配，避免部分替换
sed -i "s#\b$username\b#udp://cfgs.175419.xyz:22020/$username#g" "$SERVICE_FILE"

echo "✅ $SERVICE_FILE 文件修改成功！"
echo -e "\n📌 修改说明：已将用户名 \"$username\" 替换为 \"udp://cfgs.175419.xyz:22020/$username\""
echo -e "\n📌 后续建议执行以下命令使配置生效："
echo "systemctl daemon-reload"
echo "systemctl restart easytier.service"

echo -e "\n🎉 所有操作已完成！"
