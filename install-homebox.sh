#!/bin/bash
set -euo pipefail

# 定义常量
APP_NAME="homebox"
SERVICE_NAME="${APP_NAME}.service"
INSTALL_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"
GITHUB_REPO="XGHeaven/homebox"
# 加速域名，优先使用docker.mk加速GitHub下载
ACCELERATOR_DOMAINS=(
  "https://docker.mk/https://github.com"
  "https://github.com"
)

# 颜色输出函数
info() { echo -e "\033[34m[INFO] $*\033[0m"; }
success() { echo -e "\033[32m[SUCCESS] $*\033[0m"; }
error() { echo -e "\033[31m[ERROR] $*\033[0m" >&2; exit 1; }

# 检查是否为root用户
if [ "$(id -u)" -ne 0 ]; then
  error "请使用root权限运行此脚本 (sudo $0)"
fi

# 检查必要工具
check_dependency() {
  if ! command -v "$1" &> /dev/null; then
    error "缺少必要工具: $1，请先安装"
  fi
}

info "检查系统依赖..."
check_dependency "curl"
check_dependency "tar"
check_dependency "systemctl"
check_dependency "uname"

# 检测系统架构
detect_architecture() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64) echo "linux-amd64" ;;
    aarch64) echo "linux-arm64" ;;
    armv7l|armhf) echo "linux-arm64" ;;  # ARM 32位兼容处理
    i386|i686) echo "linux-386" ;;
    *) error "不支持的架构: $arch，请手动安装" ;;
  esac
}

# 获取最新版本号
get_latest_version() {
  local version_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
  local version
  if version=$(curl -sSL "$version_url" | grep -oP '"tag_name": "\K(.*)(?=")'); then
    echo "$version"
  else
    error "无法获取最新版本，请检查网络连接"
  fi
}

# 尝试不同加速域名下载
download_with_accelerator() {
  local url_template=$1
  local output=$2
  
  for domain in "${ACCELERATOR_DOMAINS[@]}"; do
    local full_url="${domain}/${GITHUB_REPO}/releases/download/${VERSION}/${FILE_NAME}"
    info "尝试从 $full_url 下载..."
    if curl -sSL --connect-timeout 10 --retry 3 -o "$output" "$full_url"; then
      return 0
    fi
    info "从 $domain 下载失败，尝试下一个加速节点..."
  done
  
  error "所有下载节点均失败，请检查网络或手动下载"
}

# 主流程
main() {
  # 检测架构
  local ARCH
  ARCH=$(detect_architecture)
  info "检测到系统架构: $ARCH"

  # 获取版本
  local VERSION
  VERSION=$(get_latest_version)
  info "最新版本: $VERSION"

  # 构建文件名
  local FILE_NAME="${APP_NAME}-${ARCH}.tar.gz"
  local TEMP_FILE="/tmp/${FILE_NAME}"

  # 提示输入端口
  local PORT
  read -p "请输入服务侦听端口 (默认: 3300): " PORT
  PORT=${PORT:-3300}

  # 验证端口有效性
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    error "无效的端口号: $PORT"
  fi

  # 下载文件
  info "开始下载对应版本..."
  download_with_accelerator "${GITHUB_REPO}/releases/download/${VERSION}/${FILE_NAME}" "$TEMP_FILE"

  # 解压安装
  info "安装到 ${INSTALL_DIR}..."
  tar -zxf "$TEMP_FILE" -C "$INSTALL_DIR"
  chmod +x "${INSTALL_DIR}/${APP_NAME}-${ARCH}"
  ln -sf "${INSTALL_DIR}/${APP_NAME}-${ARCH}" "${INSTALL_DIR}/${APP_NAME}"

  # 创建服务文件
  info "创建系统服务..."
  cat > "${SERVICE_DIR}/${SERVICE_NAME}" << EOF
[Unit]
Description=Homebox - 家庭网络工具箱
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/${APP_NAME} serve --port ${PORT} --host 0.0.0.0
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

  # 启动服务
  info "启动服务..."
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"

  # 检查服务状态
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    success "安装成功! Homebox 服务已启动，端口: ${PORT}"
    success "访问地址: http://$(hostname -I | awk '{print $1}'):${PORT}"
  else
    error "服务启动失败，请运行 systemctl status ${SERVICE_NAME} 查看详情"
  fi

  # 清理临时文件
  rm -f "$TEMP_FILE"
}

# 执行主流程
main
