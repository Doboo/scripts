#!/bin/bash
set -euo pipefail

# 定义常量
APP_NAME="homebox"
SERVICE_NAME="${APP_NAME}.service"
INSTALL_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"
GITHUB_REPO="XGHeaven/homebox"
ACCELERATOR_DOMAINS=(
  "https://docker.mk/https://github.com"
  "https://github.com"
)

# 颜色输出函数
info()    { echo -e "\033[34m[INFO] $*\033[0m"; }
success() { echo -e "\033[32m[SUCCESS] $*\033[0m"; }
error()   { echo -e "\033[31m[ERROR] $*\033[0m" >&2; exit 1; }

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
    x86_64)         echo "linux-amd64" ;;
    aarch64)        echo "linux-arm64" ;;
    armv7l|armhf)   echo "linux-arm"   ;;  # ARM 32位
    i386|i686)      echo "linux-386"   ;;
    *)              error "不支持的架构: $arch，请手动安装" ;;
  esac
}

# 获取最新版本号
get_latest_version() {
  local version_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
  local version
  version=$(curl -sSL --max-time 15 "$version_url" \
      | grep -oP '"tag_name": "\K(.*)(?=")' || true)
  if [ -z "$version" ]; then
    error "无法获取最新版本，请检查网络连接"
  fi
  echo "$version"
}

# 带加速节点的下载函数（修复：VERSION 和 FILE_NAME 作为参数传入，而非依赖全局变量）
download_with_accelerator() {
  local version="$1"
  local file_name="$2"
  local output="$3"

  for domain in "${ACCELERATOR_DOMAINS[@]}"; do
    local full_url="${domain}/${GITHUB_REPO}/releases/download/${version}/${file_name}"
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
  local ARCH
  ARCH=$(detect_architecture)
  info "检测到系统架构: $ARCH"

  local VERSION
  VERSION=$(get_latest_version)
  info "最新版本: $VERSION"

  local FILE_NAME="${APP_NAME}-${ARCH}.tar.gz"
  local TEMP_FILE
  TEMP_FILE=$(mktemp /tmp/homebox_XXXXXX.tar.gz)
  trap 'rm -f "$TEMP_FILE"' EXIT

  # 提示输入端口
  local PORT
  read -r -p "请输入服务侦听端口 (默认: 3300): " PORT
  PORT=${PORT:-3300}

  # 验证端口有效性
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    error "无效的端口号: $PORT"
  fi

  # 下载文件（将 VERSION 和 FILE_NAME 作为参数传入，修复原版全局变量依赖问题）
  info "开始下载 ${VERSION} 版本..."
  download_with_accelerator "$VERSION" "$FILE_NAME" "$TEMP_FILE"

  # 解压安装
  info "安装到 ${INSTALL_DIR}..."
  tar -zxf "$TEMP_FILE" -C "$INSTALL_DIR"

  # 兼容解压后文件名包含架构后缀的情况
  local binary_path="${INSTALL_DIR}/${APP_NAME}-${ARCH}"
  if [ ! -f "$binary_path" ]; then
    # 尝试找到实际解压出的可执行文件
    binary_path=$(find "$INSTALL_DIR" -maxdepth 1 -name "${APP_NAME}*" -type f -print -quit || true)
    if [ -z "$binary_path" ]; then
      error "解压后未找到 ${APP_NAME} 可执行文件，请手动检查 ${INSTALL_DIR}"
    fi
  fi

  chmod +x "$binary_path"
  ln -sf "$binary_path" "${INSTALL_DIR}/${APP_NAME}"

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
}

main
