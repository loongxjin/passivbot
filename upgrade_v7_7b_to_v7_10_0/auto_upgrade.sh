#!/bin/bash
# Passivbot v7.7b → v7.10.0 自动升级脚本
# 自动扫描现有 systemd 实例，提取信息，批量切换
#
# 用法:
#   sudo ./auto_upgrade.sh

set -e

PASSIVBOT_DIR="/home/ubuntu/passivbot"
SYSTEMD_DIR="/etc/systemd/system"

# 自动检测运行用户
if [ -n "$SUDO_USER" ]; then
    RUN_USER="$SUDO_USER"
else
    RUN_USER="$(whoami)"
fi
RUN_GROUP="$RUN_USER"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

get_service_name() {
    local input="$1"
    if [[ "$input" == passivbot ]] || [[ "$input" == passivbot-* ]]; then
        echo "$input"
    else
        echo "passivbot-$input"
    fi
}

extract_api_key() {
    local service_file="$1"
    # 尝试从新版 CLI -u 参数提取
    local api_key=$(grep -oP 'live -u \K[^ ]+' "$service_file" 2>/dev/null || true)
    if [ -n "$api_key" ]; then
        echo "$api_key"
        return 0
    fi
    # 尝试从旧版 config 文件提取 live.user
    local config=$(grep "ExecStart=" "$service_file" 2>/dev/null | grep -oP 'configs/[^[:space:]]+\.json' || echo "")
    if [ -n "$config" ] && [ -f "$PASSIVBOT_DIR/$config" ]; then
        python3 -c "
import json
try:
    with open('$PASSIVBOT_DIR/$config') as f:
        data = json.load(f)
    print(data.get('live', {}).get('user', ''))
except Exception:
    print('')
" 2>/dev/null
        return 0
    fi
    echo ""
}

extract_config() {
    local service_file="$1"
    grep "ExecStart=" "$service_file" 2>/dev/null | grep -oP 'configs/[^[:space:]]+\.json' || echo ""
}

scan_instances() {
    local instances=()
    for service_file in "$SYSTEMD_DIR"/passivbot*.service; do
        [ -f "$service_file" ] || continue
        local name=$(basename "$service_file" .service)
        local config=$(extract_config "$service_file")
        local user=$(extract_api_key "$service_file")
        local status="stopped"
        systemctl is-active --quiet "$name" 2>/dev/null && status="running"
        echo "$name|$config|$user|$status"
    done
}

find_matching_config() {
    local old_config="$1"
    local new_dir="$2"
    local basename=$(basename "$old_config" .json)
    # 尝试同名匹配
    if [ -f "$new_dir/${basename}.json" ]; then
        echo "$new_dir/${basename}.json"
        return 0
    fi
    # 尝试去掉前缀匹配
    local shortname=$(echo "$basename" | sed 's/^passivbot-//')
    if [ -f "$new_dir/${shortname}.json" ]; then
        echo "$new_dir/${shortname}.json"
        return 0
    fi
    echo ""
}

get_config_relative() {
    local config_file="$1"
    echo "${config_file#$PASSIVBOT_DIR/}"
}

echo "========================================"
echo "Passivbot v7.10.0 自动升级"
echo "========================================"
echo ""

# 检查代码版本
cd "$PASSIVBOT_DIR"
CURRENT_VER=$(git describe --tags --always 2>/dev/null || echo "unknown")
echo "当前代码版本: $CURRENT_VER"
echo "运行用户: $RUN_USER"
if [[ "$CURRENT_VER" != *"v7.10"* ]]; then
    echo -e "${YELLOW}警告: 当前代码不是 v7.10.0${NC}"
    echo "请先执行: git checkout v7.10.0"
    read -p "是否继续? (yes/no): " confirm
    [ "$confirm" == "yes" ] || exit 0
fi
echo ""

# 确保日志目录存在
mkdir -p "$PASSIVBOT_DIR/logs"

# 扫描现有实例
echo "扫描现有实例..."
echo ""

declare -a SVC_NAMES
declare -a OLD_CONFIGS
declare -a USERS
declare -a STATUSES
declare -a NEW_CONFIGS

idx=0
while IFS='|' read -r name config user status; do
    [ -z "$name" ] && continue
    SVC_NAMES[$idx]="$name"
    OLD_CONFIGS[$idx]="$config"
    USERS[$idx]="$user"
    STATUSES[$idx]="$status"
    idx=$((idx + 1))
done < <(scan_instances)

TOTAL=${#SVC_NAMES[@]}

if [ "$TOTAL" -eq 0 ]; then
    echo -e "${RED}未找到任何 passivbot systemd 实例${NC}"
    exit 1
fi

echo "发现 $TOTAL 个实例:"
echo "----------------------------------------"
for i in "${!SVC_NAMES[@]}"; do
    st="${STATUSES[$i]}"
    if [ "$st" == "running" ]; then
        st_color="${GREEN}运行中${NC}"
    else
        st_color="${YELLOW}已停止${NC}"
    fi
    echo -e "  $((i+1)). ${CYAN}${SVC_NAMES[$i]}${NC}"
    echo -e "     配置: ${OLD_CONFIGS[$i]}"
    echo -e "     用户: ${MAGENTA}${USERS[$i]}${NC}"
    echo -e "     状态: $st_color"
done
echo "----------------------------------------"
echo ""

# 询问新配置目录
read -ep "新配置文件目录 (默认: $PASSIVBOT_DIR/configs/v710/): " NEW_CONFIG_DIR
NEW_CONFIG_DIR=${NEW_CONFIG_DIR:-$PASSIVBOT_DIR/configs/v710/}
NEW_CONFIG_DIR="${NEW_CONFIG_DIR%/}/"

if [ ! -d "$NEW_CONFIG_DIR" ]; then
    echo -e "${RED}目录不存在: $NEW_CONFIG_DIR${NC}"
    exit 1
fi

echo ""
echo "自动匹配新配置..."
echo ""

for i in "${!SVC_NAMES[@]}"; do
    old_cfg="${OLD_CONFIGS[$i]}"
    matched=$(find_matching_config "$old_cfg" "$NEW_CONFIG_DIR")
    if [ -n "$matched" ]; then
        NEW_CONFIGS[$i]="$matched"
        echo -e "  ${GREEN}✓${NC} ${SVC_NAMES[$i]}: $(basename "$old_cfg") → $(basename "$matched")"
    else
        NEW_CONFIGS[$i]=""
        echo -e "  ${YELLOW}?${NC} ${SVC_NAMES[$i]}: $(basename "$old_cfg") → 未找到匹配"
    fi
done

echo ""

# 处理未匹配项
for i in "${!SVC_NAMES[@]}"; do
    [ -n "${NEW_CONFIGS[$i]}" ] && continue

    echo "----------------------------------------"
    echo -e "为 ${CYAN}${SVC_NAMES[$i]}${NC} 选择新配置:"
    echo "  原配置: ${OLD_CONFIGS[$i]}"
    echo ""

    # 列出可用配置
    mapfile -t avail < <(ls -1 "$NEW_CONFIG_DIR"/*.json 2>/dev/null | sort)
    if [ ${#avail[@]} -eq 0 ]; then
        echo -e "${RED}  新配置目录中没有 .json 文件${NC}"
        continue
    fi

    for j in "${!avail[@]}"; do
        echo "  $((j+1)). $(basename "${avail[$j]}")"
    done
    echo "  s. 跳过此实例"
    echo ""
    read -p "选择 (1-${#avail[@]}/s): " choice

    if [ "$choice" == "s" ] || [ "$choice" == "S" ]; then
        NEW_CONFIGS[$i]="SKIP"
        continue
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#avail[@]}" ]; then
        NEW_CONFIGS[$i]="${avail[$((choice-1))]}"
    else
        echo -e "${YELLOW}无效选择，跳过此实例${NC}"
        NEW_CONFIGS[$i]="SKIP"
    fi
done

echo ""
echo "========================================"
echo "升级计划"
echo "========================================"
echo ""

for i in "${!SVC_NAMES[@]}"; do
    if [ "${NEW_CONFIGS[$i]}" == "SKIP" ]; then
        echo -e "  $((i+1)). ${YELLOW}[跳过]${NC} ${SVC_NAMES[$i]}"
        continue
    fi
    new_rel=$(get_config_relative "${NEW_CONFIGS[$i]}")
    echo -e "  $((i+1)). ${CYAN}${SVC_NAMES[$i]}${NC}"
    echo -e "     用户: ${MAGENTA}${USERS[$i]}${NC}"
    echo -e "     新配置: $new_rel"
done

echo ""
read -p "确认执行升级? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "已取消"
    exit 0
fi

# 执行升级
SUCCESS=0
FAILED=0
SKIPPED=0

for i in "${!SVC_NAMES[@]}"; do
    svc="${SVC_NAMES[$i]}"
    user="${USERS[$i]}"
    new_cfg="${NEW_CONFIGS[$i]}"

    echo ""
    echo "========================================"
    echo "[$((i+1))/$TOTAL] $svc"
    echo "========================================"

    if [ "$new_cfg" == "SKIP" ]; then
        echo -e "${YELLOW}跳过${NC}"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    new_rel=$(get_config_relative "$new_cfg")

    # 停止
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "停止..."
        sudo systemctl stop "$svc"
        sleep 2
    fi

    # 备份
    backup="$SYSTEMD_DIR/$svc.service.pre_v710.$(date +%Y%m%d_%H%M%S)"
    sudo cp "$SYSTEMD_DIR/$svc.service" "$backup"

    # 重写服务文件
    log_dir="$PASSIVBOT_DIR/logs"
    sudo tee "$SYSTEMD_DIR/$svc.service" > /dev/null << EOF
[Unit]
Description=Passivbot Trading Bot ($svc)
After=network.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$PASSIVBOT_DIR
Environment="PATH=$PASSIVBOT_DIR/venv/bin"
ExecStart=$PASSIVBOT_DIR/venv/bin/passivbot live -u $user -c $new_rel --log-level info
Restart=always
RestartSec=10
StandardOutput=append:$log_dir/${svc}.systemd.log
StandardError=append:$log_dir/${svc}.systemd.log

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload

    # 启动
    echo "启动..."
    sudo systemctl start "$svc"
    sleep 3

    if systemctl is-active --quiet "$svc"; then
        echo -e "${GREEN}✓ 成功${NC}"
        SUCCESS=$((SUCCESS + 1))
    else
        echo -e "${RED}✗ 失败${NC}"
        echo "  日志: tail -n 50 $PASSIVBOT_DIR/logs/$user.log"
        echo "  systemd日志: tail -n 50 $log_dir/${svc}.systemd.log"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "========================================"
echo "升级完成"
echo "========================================"
echo -e "成功: ${GREEN}$SUCCESS${NC}"
echo -e "失败: ${RED}$FAILED${NC}"
echo -e "跳过: ${YELLOW}$SKIPPED${NC}"
echo ""

if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}有实例启动失败，请检查日志${NC}"
    exit 1
fi

echo -e "${GREEN}升级完成${NC}"
