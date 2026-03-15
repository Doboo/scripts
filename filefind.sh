#!/bin/bash

# ============================================================
# 磁盘空间分析脚本
# ============================================================

# 颜色定义
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 默认参数
TARGET_DIR="${1:-/}"
TOP_N="${2:-20}"
MIN_SIZE="100M"

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}        Linux 磁盘空间占用分析工具${NC}"
echo -e "${CYAN}============================================================${NC}"
echo -e "分析目录: ${GREEN}${TARGET_DIR}${NC}"
echo -e "时间: $(date '+%Y-%m-%d %H:%M:%S')\n"

# ---------- 1. 整体磁盘使用情况 ----------
echo -e "${YELLOW}【1】磁盘挂载点使用情况${NC}"
echo "------------------------------------------------------------"
df -hT | grep -v tmpfs | grep -v udev
echo ""

# ---------- 2. 当前目录各子目录大小排序 ----------
echo -e "${YELLOW}【2】目录 ${TARGET_DIR} 下一级子目录占用（前 ${TOP_N} 名）${NC}"
echo "------------------------------------------------------------"
du -h --max-depth=1 "${TARGET_DIR}" 2>/dev/null \
  | sort -rh \
  | head -n "$((TOP_N + 1))"
echo ""

# ---------- 3. 全局最大目录（递归，超过 MIN_SIZE）----------
echo -e "${YELLOW}【3】全局占用超过 ${MIN_SIZE} 的目录（递归扫描）${NC}"
echo "------------------------------------------------------------"
du -h --threshold="${MIN_SIZE}" "${TARGET_DIR}" 2>/dev/null \
  | sort -rh \
  | head -n "${TOP_N}"
echo ""

# ---------- 4. 最大的前20个文件 ----------
echo -e "${YELLOW}【4】最大的前 ${TOP_N} 个文件${NC}"
echo "------------------------------------------------------------"
find "${TARGET_DIR}" -xdev -type f -printf '%s\t%p\n' 2>/dev/null \
  | sort -rn \
  | head -n "${TOP_N}" \
  | awk '{
      size=$1; path=$2;
      if (size >= 1073741824) printf "%.2f GB\t%s\n", size/1073741824, path;
      else if (size >= 1048576) printf "%.2f MB\t%s\n", size/1048576, path;
      else printf "%.2f KB\t%s\n", size/1024, path;
    }'
echo ""

# ---------- 5. 常见高占用目录快速检查 ----------
echo -e "${YELLOW}【5】常见高占用目录快速检查${NC}"
echo "------------------------------------------------------------"
COMMON_DIRS=(
  "/var/log"
  "/var/cache"
  "/tmp"
  "/home"
  "/root"
  "/opt"
  "/usr"
)
for dir in "${COMMON_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    size=$(du -sh "$dir" 2>/dev/null | cut -f1)
    echo -e "  ${GREEN}${size}${NC}\t${dir}"
  fi
done
echo ""

# ---------- 6. 日志文件检查 ----------
echo -e "${YELLOW}【6】/var/log 下大于 50MB 的日志文件${NC}"
echo "------------------------------------------------------------"
find /var/log -type f -size +50M -printf '%s\t%p\n' 2>/dev/null \
  | sort -rn \
  | awk '{printf "%.2f MB\t%s\n", $1/1048576, $2}'
echo ""

# ---------- 7. 已删除但仍被占用的文件 ----------
echo -e "${YELLOW}【7】已删除但进程仍占用的文件（需要 root）${NC}"
echo "------------------------------------------------------------"
if [ "$EUID" -eq 0 ]; then
  lsof 2>/dev/null | grep '(deleted)' \
    | awk '{print $7, $1, $2, $9}' \
    | sort -rn \
    | head -n 10 \
    | awk '{
        if ($1 >= 1073741824) printf "%.2f GB  进程:%-10s PID:%-6s %s\n", $1/1073741824, $2, $3, $4;
        else if ($1 >= 1048576) printf "%.2f MB  进程:%-10s PID:%-6s %s\n", $1/1048576, $2, $3, $4;
      }'
else
  echo -e "  ${RED}请使用 root 权限运行以检查此项${NC}"
fi
echo ""

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  分析完成！建议优先处理上方标红/体积最大的目录和文件${NC}"
echo -e "${CYAN}============================================================${NC}"
