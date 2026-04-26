#!/bin/bash
# Passivbot v7.10.0 回滚脚本
# 一键恢复到升级前的 systemd 服务文件
#
# 用法:
#   sudo ./rollback.sh [--stop-only]
#
#   --stop-only  只停止所有实例，不恢复服务文件

set -e

SYSTEMD_DIR="/etc/systemd/system"
PASSIVBOT_DIR="/home/ubuntu/passivbot"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

STOP_ONLY=false
if [ "$1" == "--stop-only" ]; then
    STOP_ONLY=true
fi

echo "========================================"
echo "Passivbot 回滚工具"
echo "========================================"
echo ""

# 扫描实例
declare -a SERVICES
idx=0
for f in "$SYSTEMD_DIR"/passivbot*.service; do
    [ -f "$f" ] || continue
    # 排除备份文件和已删除文件
    local_name=$(basename "$f")
    [[ "$local_name" == *.pre_v710.* ]] && continue
    [[ "$local_name" == *.bak.* ]] && continue
    [[ "$local_name" == *.deleted.* ]] && continue
    SERVICES[$idx]="${local_name%.service}"
    idx=$((idx + 1))
done

if [ ${#SERVICES[@]} -eq 0 ]; then
    echo -e "${YELLOW}未找到 passivbot 服务${NC}"
    exit 0
fi

echo "发现 ${#SERVICES[@]} 个实例:"
for svc in "${SERVICES[@]}"; do
    echo "  - $svc"
done
echo ""

# 停止
if [ "$STOP_ONLY" = true ]; then
    echo "仅停止实例..."
else
    echo "即将停止所有实例并恢复备份的服务文件"
fi

read -p "确认? (yes/no): " confirm
[ "$confirm" == "yes" ] || exit 0

echo ""
for svc in "${SERVICES[@]}"; do
    echo "停止 $svc ..."
    sudo systemctl stop "$svc" 2>/dev/null || true
done

sleep 2

if [ "$STOP_ONLY" = true ]; then
    echo -e "${GREEN}所有实例已停止${NC}"
    exit 0
fi

# 恢复备份
RESTORED=0
FAILED_RESTORE=0

for svc in "${SERVICES[@]}"; do
    current="$SYSTEMD_DIR/$svc.service"
    # 精确匹配该服务的 pre_v710 备份，取最新的
    backup=$(find "$SYSTEMD_DIR" -maxdepth 1 -name "${svc}.service.pre_v710.*" -type f 2>/dev/null | sort -t. -k6 -r | head -1)

    if [ -z "$backup" ]; then
        echo -e "${YELLOW}  $svc: 未找到 pre_v710 备份文件，跳过${NC}"
        FAILED_RESTORE=$((FAILED_RESTORE + 1))
        continue
    fi

    echo "  恢复 $svc: $(basename "$backup")"
    sudo cp "$backup" "$current"
    RESTORED=$((RESTORED + 1))
done

sudo systemctl daemon-reload

echo ""
echo "========================================"
if [ "$FAILED_RESTORE" -gt 0 ]; then
    echo -e "${YELLOW}部分实例未找到备份，请手动检查${NC}"
fi
echo -e "已恢复: ${GREEN}$RESTORED${NC} 个实例的服务文件"
echo ""

# 检查当前代码版本并给出提示
cd "$PASSIVBOT_DIR" 2>/dev/null || true
CURRENT_VER=$(git describe --tags --always 2>/dev/null || echo "unknown")
echo "当前代码版本: $CURRENT_VER"
echo ""

if [[ "$CURRENT_VER" == *"v7.10"* ]]; then
    echo -e "${YELLOW}注意: 当前代码仍为 v7.10.0${NC}"
    echo "如果需要彻底回退到旧版本代码，请执行:"
    echo "  cd $PASSIVBOT_DIR"
    if [ -f ~/passivbot_version_before.txt ]; then
        OLD_VER=$(cat ~/passivbot_version_before.txt)
        echo "  git checkout $OLD_VER  # (升级前版本: $OLD_VER)"
    else
        echo "  git checkout <旧版本tag>"
    fi
    echo "  source venv/bin/activate && pip install -e ."
    echo "  cd passivbot-rust && maturin develop --release && cd .."
    echo ""
fi

echo "下一步（手动）:"
echo "  重启所有已恢复的实例:"
for svc in "${SERVICES[@]}"; do
    echo "     sudo systemctl start $svc"
done
echo ""
echo "  或直接启动全部:"
echo "     for svc in ${SERVICES[*]}; do sudo systemctl start \$svc; done"
