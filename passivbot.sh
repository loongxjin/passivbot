#!/bin/bash
# Passivbot v7.10.0+ 多机器人管理脚本
# 适配新版统一 CLI: passivbot live <config> -u <user>
#
# 用法:
#   ./passivbot.sh create <服务名> <配置> <api-key>   # 创建新机器人实例
#   ./passivbot.sh switch <服务名> <配置> [api-key]   # 切换配置
#   ./passivbot.sh list                               # 列出所有机器人
#   ./passivbot.sh status [服务名]                    # 查看状态
#   ./passivbot.sh start|stop|restart <服务名>        # 控制服务
#   ./passivbot.sh start-all|stop-all                  # 启动/停止所有机器人
#   ./passivbot.sh delete <服务名>                     # 删除机器人实例
#   ./passivbot.sh delete-all                           # 删除所有机器人实例
#   ./passivbot.sh logs <服务名> [行数]                # 查看日志
#   ./passivbot.sh configs                             # 列出可用配置和API key
#   ./passivbot.sh check                               # 运行配置兼容性检查
#   ./passivbot.sh clean-logs [保留天数]               # 清理历史日志

set -e

# 配置
PASSIVBOT_DIR="/home/ubuntu/passivbot"
CONFIGS_DIR="configs"
API_KEYS_FILE="api-keys.json"
SYSTEMD_DIR="/etc/systemd/system"

# 自动检测运行用户
if [ -n "$SUDO_USER" ]; then
    RUN_USER="$SUDO_USER"
else
    RUN_USER="$(whoami)"
fi
RUN_GROUP="$RUN_USER"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

show_help() {
    echo -e "========================================"
    echo -e "Passivbot v7.10.0+ 多机器人管理工具"
    echo -e "========================================"
    echo ""
    echo -e "用法: $0 <命令> [参数]"
    echo ""
    echo -e "命令:"
    echo ""
    echo -e "  ${GREEN}create${NC} <服务名> <配置> <api-key>"
    echo "      创建新机器人实例（使用 passivbot live CLI）"
    echo "      例: $0 create okx_btc btc_long.json okx_01"
    echo ""
    echo -e "  ${GREEN}switch${NC} <服务名> <新配置> [新api-key]"
    echo "      切换已有机器人的配置"
    echo ""
    echo -e "  ${GREEN}start${NC} <服务名>"
    echo "      启动指定机器人"
    echo ""
    echo -e "  ${GREEN}start-all${NC}"
    echo "      启动所有机器人"
    echo ""
    echo -e "  ${GREEN}stop${NC} <服务名>"
    echo "      停止指定机器人"
    echo ""
    echo -e "  ${RED}stop-all${NC}"
    echo "      停止所有机器人"
    echo ""
    echo -e "  ${GREEN}restart${NC} <服务名>"
    echo "      重启指定机器人"
    echo ""
    echo -e "  ${GREEN}delete${NC} <服务名>"
    echo "      删除机器人实例（保留配置备份）"
    echo ""
    echo -e "  ${RED}delete-all${NC}"
    echo "      删除所有机器人实例"
    echo ""
    echo -e "  ${GREEN}list${NC}"
    echo "      列出所有机器人实例及其状态"
    echo ""
    echo -e "  ${GREEN}status${NC} [服务名]"
    echo "      查看指定或所有机器人状态"
    echo ""
    echo -e "  ${GREEN}logs${NC} <服务名> [行数]"
    echo "      查看机器人日志（默认50行）"
    echo "      v7.10.0+ 日志读取自 logs/{user}.log"
    echo ""
    echo -e "  ${GREEN}configs${NC}"
    echo "      列出可用配置和API key"
    echo ""
    echo -e "  ${GREEN}check${NC}"
    echo "      运行配置兼容性检查（v7.7b → v7.10.0）"
    echo ""
  echo -e "  ${RED}panic${NC} <服务名> [--market]"
  echo "      一键 panic 指定机器人（设为 panic 模式并重启）"
  echo "      --market  使用市价单清仓（默认 limit 单）"
  echo "      例: $0 panic okx_btc"
  echo "      例: $0 panic okx_btc --market"
  echo ""
  echo -e "  ${RED}panic-all${NC} [--market]"
  echo "      一键 panic 所有机器人"
  echo "      --market  使用市价单清仓（默认 limit 单）"
  echo ""
  echo -e "  ${GREEN}unpanic${NC} <服务名>"
  echo "      恢复指定机器人到 panic 前的配置"
  echo ""
  echo -e "  ${GREEN}unpanic-all${NC}"
  echo "      恢复所有机器人到 panic 前的配置"
  echo ""
  echo -e "  ${GREEN}help${NC}"
  echo "      显示此帮助"
  echo ""
  echo -e "  ${GREEN}clean-logs${NC} [保留天数]"
  echo "      删除 N 天前的历史日志（默认 7 天）"
  echo ""
}

validate_service_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}错误: 服务名只能包含字母、数字、下划线和横线${NC}"
        return 1
    fi
    if [[ "$name" == passivbot ]] || [[ "$name" == passivbot-* ]]; then
        echo "$name"
        return 0
    fi
    echo "passivbot-$name"
}

get_service_name() {
    local input="$1"
    if [[ "$input" == passivbot ]] || [[ "$input" == passivbot-* ]]; then
        echo "$input"
    else
        echo "passivbot-$input"
    fi
}

get_api_key_from_service() {
    local service_name="$1"
    local service_file="$SYSTEMD_DIR/$service_name.service"
    if [ ! -f "$service_file" ]; then
        echo ""
        return 1
    fi
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

find_log_file() {
    local user="$1"
    local log_dir="$PASSIVBOT_DIR/logs"
    # 优先匹配 {user}.log
    if [ -f "$log_dir/$user.log" ]; then
        echo "$log_dir/$user.log"
        return 0
    fi
    # 匹配带时间戳的日志
    local latest=$(ls -t "$log_dir"/*_passivbot_live_*_-u_"${user}"_*.log 2>/dev/null | head -1)
    if [ -n "$latest" ]; then
        echo "$latest"
        return 0
    fi
    echo ""
    return 1
}

list_bots() {
    echo "========================================"
    echo "Passivbot 机器人实例列表 (v7.10.0+)"
    echo "========================================"
    echo ""

    local found=0
    for service_file in "$SYSTEMD_DIR"/passivbot*.service; do
        if [ -f "$service_file" ]; then
            found=1
            local service_name=$(basename "$service_file" .service)
            local config=$(grep "ExecStart=" "$service_file" 2>/dev/null | grep -oP 'configs/[^[:space:]]+\.json' || echo "未知")
            local api_key=$(get_api_key_from_service "$service_name")
            local status="${RED}停止${NC}"
            local pid=""
            local uptime=""

            if systemctl is-active --quiet "$service_name" 2>/dev/null; then
                status="${GREEN}运行中${NC}"
                pid=$(systemctl show --property=MainPID --value "$service_name" 2>/dev/null)
                uptime=$(systemctl show --property=ActiveEnterTimestamp --value "$service_name" 2>/dev/null | xargs -I {} date -d "{}" "+%m-%d %H:%M" 2>/dev/null || echo "")
            fi

            echo -e "服务名: ${CYAN}$service_name${NC}"
            echo -e "  配置: $config"
            echo -e "  用户: ${MAGENTA}${api_key:-未知}${NC}"
            if [ -n "$uptime" ]; then
                echo -e "  状态: $status (PID: $pid, 启动: $uptime)"
            else
                echo -e "  状态: $status"
            fi
            # 统计该用户的日志文件数量
            local log_total=$(find "$PASSIVBOT_DIR/logs" -maxdepth 1 -type f \( -name "*_-u_${api_key}_*.log" -o -name "${api_key}.log" \) 2>/dev/null | wc -l | xargs)
            local log_current=$(find_log_file "$api_key")
            if [ -n "$log_current" ]; then
                echo -e "  日志: ${log_current#$PASSIVBOT_DIR/logs/} (共 ${log_total} 个文件)"
            fi
            echo ""
        fi
    done

    if [ $found -eq 0 ]; then
        echo -e "${YELLOW}暂无机器人实例${NC}"
        echo ""
        echo "创建新实例:"
        echo "  $0 create <服务名> <配置> <api-key>"
        echo ""
    fi
}

list_configs() {
    echo "========================================"
    echo "可用配置文件 (configs/):"
    echo "========================================"
    if [ -d "$PASSIVBOT_DIR/$CONFIGS_DIR" ]; then
        find "$PASSIVBOT_DIR/$CONFIGS_DIR" -maxdepth 2 -name "*.json" -type f 2>/dev/null | \
            sed "s|$PASSIVBOT_DIR/||" | \
            grep -v ".example" | \
            sort | \
            nl -w2 -s'. '
    else
        echo "  目录不存在"
    fi

    echo ""
    echo "========================================"
    echo "可用 API Keys ($API_KEYS_FILE):"
    echo "========================================"
    if [ -f "$PASSIVBOT_DIR/$API_KEYS_FILE" ]; then
        python3 -c "
import json
try:
    with open('$PASSIVBOT_DIR/$API_KEYS_FILE', 'r') as f:
        data = json.load(f)
    keys = [k for k in data.keys() if k != 'referrals' and not k.startswith('_')]
    for i, k in enumerate(keys, 1):
        exchange = data[k].get('exchange', 'unknown')
        print(f'{i:2}. {k} ({exchange})')
except (OSError, ValueError, KeyError) as e:
    print(f'Error: {e}')
"
    else
        echo "  文件不存在"
    fi
    echo ""
}

validate_api_key() {
    local key_name="$1"
    if [ ! -f "$PASSIVBOT_DIR/$API_KEYS_FILE" ]; then
        echo -e "${RED}错误: API keys 文件不存在${NC}"
        return 1
    fi

    local key_exists=$(python3 -c "
import json
try:
    with open('$PASSIVBOT_DIR/$API_KEYS_FILE', 'r') as f:
        data = json.load(f)
    if '$key_name' in data and '$key_name' != 'referrals':
        print('true')
    else:
        print('false')
except (OSError, ValueError, KeyError):
    print('false')
" 2>/dev/null)

    if [ "$key_exists" != "true" ]; then
        echo -e "${RED}错误: API key '$key_name' 不存在${NC}"
        list_configs
        return 1
    fi
    return 0
}

resolve_config_path() {
    local input="$1"
    if [[ "$input" == /* ]]; then
        echo "$input"
    elif [[ "$input" == configs/* ]]; then
        echo "$PASSIVBOT_DIR/$input"
    else
        echo "$PASSIVBOT_DIR/configs/$input"
    fi
}

get_config_relative() {
    local config_file="$1"
    echo "${config_file#$PASSIVBOT_DIR/}"
}

create_bot() {
    local service_name=$(get_service_name "$1")
    local config_input="$2"
    local api_key="$3"

    echo "========================================"
    echo "创建新机器人实例 (v7.10.0 CLI)"
    echo "========================================"
    echo ""

    if [ -z "$service_name" ] || [ -z "$config_input" ] || [ -z "$api_key" ]; then
        echo -e "${RED}错误: 参数不足${NC}"
        echo "用法: $0 create <服务名> <配置> <api-key>"
        return 1
    fi

    if [ -f "$SYSTEMD_DIR/$service_name.service" ]; then
        echo -e "${RED}错误: 服务 '$service_name' 已存在${NC}"
        echo "使用 '$0 list' 查看现有服务"
        return 1
    fi

    local config_file=$(resolve_config_path "$config_input")
    local config_rel=$(get_config_relative "$config_file")

    if [ ! -f "$config_file" ]; then
        echo -e "${RED}错误: 配置文件不存在: $config_file${NC}"
        list_configs
        return 1
    fi

    if ! validate_api_key "$api_key"; then
        return 1
    fi

    echo -e "服务名: ${CYAN}$service_name${NC}"
    echo "配置: $config_rel"
    echo -e "API Key: ${CYAN}$api_key${NC}"
    echo ""

    # 创建日志目录
    local log_dir="$PASSIVBOT_DIR/logs"
    mkdir -p "$log_dir"

    # 创建systemd服务文件（使用新版 passivbot live CLI）
    echo "创建 systemd 服务..."
    sudo tee "$SYSTEMD_DIR/$service_name.service" > /dev/null << EOF
[Unit]
Description=Passivbot Trading Bot ($service_name)
After=network.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$PASSIVBOT_DIR
Environment="PATH=$PASSIVBOT_DIR/venv/bin:/home/ubuntu/.cargo/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$PASSIVBOT_DIR/venv/bin/passivbot live $config_rel -u $api_key --log-level info
Restart=always
RestartSec=10
StandardOutput=append:$log_dir/${service_name}.systemd.log
StandardError=append:$log_dir/${service_name}.systemd.log

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable "$service_name"

    echo ""
    echo -e "${GREEN}机器人实例创建成功!${NC}"
    echo ""
    echo "启动命令:"
    echo "  $0 start $service_name"
    echo ""
    echo "日志位置:"
    echo "  passivbot 主日志: logs/$api_key.log"
    echo "  systemd 侧日志:  logs/${service_name}.systemd.log"
}

switch_bot() {
    local service_name=$(get_service_name "$1")
    local config_input="$2"
    local api_key="${3:-}"

    echo "========================================"
    echo "切换机器人配置"
    echo "========================================"
    echo ""

    if [ ! -f "$SYSTEMD_DIR/$service_name.service" ]; then
        echo -e "${RED}错误: 服务 '$service_name' 不存在${NC}"
        return 1
    fi

    local config_file=$(resolve_config_path "$config_input")
    local config_rel=$(get_config_relative "$config_file")

    if [ ! -f "$config_file" ]; then
        echo -e "${RED}错误: 配置文件不存在: $config_file${NC}"
        return 1
    fi

    echo -e "服务名: ${CYAN}$service_name${NC}"
    echo "新配置: $config_rel"

    # 如果没传 api_key，尝试从旧服务提取
    if [ -z "$api_key" ]; then
        api_key=$(get_api_key_from_service "$service_name")
        if [ -n "$api_key" ]; then
            echo -e "保留用户: ${MAGENTA}$api_key${NC}"
        else
            echo -e "${RED}错误: 无法从现有服务提取 api_key，请显式提供${NC}"
            return 1
        fi
    else
        if ! validate_api_key "$api_key"; then
            return 1
        fi
        echo -e "新用户: ${CYAN}$api_key${NC}"
    fi

    echo ""

    local was_running=false
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        was_running=true
        echo "停止当前服务..."
        sudo systemctl stop "$service_name"
        sleep 2
    fi

    # 备份原配置
    sudo cp "$SYSTEMD_DIR/$service_name.service" "$SYSTEMD_DIR/$service_name.service.bak.$(date +%Y%m%d_%H%M%S)"

    local log_dir="$PASSIVBOT_DIR/logs"
    mkdir -p "$log_dir"

    sudo tee "$SYSTEMD_DIR/$service_name.service" > /dev/null << EOF
[Unit]
Description=Passivbot Trading Bot ($service_name)
After=network.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_GROUP
WorkingDirectory=$PASSIVBOT_DIR
Environment="PATH=$PASSIVBOT_DIR/venv/bin:/home/ubuntu/.cargo/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$PASSIVBOT_DIR/venv/bin/passivbot live $config_rel -u $api_key --log-level info
Restart=always
RestartSec=10
StandardOutput=append:$log_dir/${service_name}.systemd.log
StandardError=append:$log_dir/${service_name}.systemd.log

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload

    if [ "$was_running" = true ]; then
        echo "重新启动服务..."
        sudo systemctl start "$service_name"
        sleep 2

        if systemctl is-active --quiet "$service_name"; then
            echo -e "${GREEN}服务启动成功!${NC}"
        else
            echo -e "${RED}服务启动失败，请检查日志${NC}"
            echo "查看日志: $0 logs $service_name"
        fi
    fi

    echo ""
    echo -e "${GREEN}配置切换完成!${NC}"
}

delete_bot() {
    local service_name=$(get_service_name "$1")

    echo "========================================"
    echo "删除机器人实例"
    echo "========================================"
    echo ""

    if [ -z "$service_name" ]; then
        echo -e "${RED}错误: 请指定服务名${NC}"
        return 1
    fi

    if [ ! -f "$SYSTEMD_DIR/$service_name.service" ]; then
        echo -e "${RED}错误: 服务 '$service_name' 不存在${NC}"
        return 1
    fi

    echo -e "将要删除: ${CYAN}$service_name${NC}"
    echo ""

    read -p "确认删除? 这将停止服务并删除systemd配置 (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "已取消"
        return 0
    fi

    echo "停止服务..."
    sudo systemctl stop "$service_name" 2>/dev/null || true
    sudo systemctl disable "$service_name" 2>/dev/null || true

    sudo mv "$SYSTEMD_DIR/$service_name.service" "$SYSTEMD_DIR/$service_name.service.deleted.$(date +%Y%m%d_%H%M%S)"

    sudo systemctl daemon-reload

    echo ""
    echo -e "${GREEN}机器人实例已删除${NC}"
    echo "注意: 配置文件和日志文件仍保留在服务器上"
}

show_status() {
    local service_name="${1:-}"

    if [ -z "$service_name" ]; then
        list_bots
        return 0
    fi

    service_name=$(get_service_name "$service_name")

    if [ ! -f "$SYSTEMD_DIR/$service_name.service" ]; then
        echo -e "${RED}错误: 服务 '$service_name' 不存在${NC}"
        return 1
    fi

    echo "========================================"
    echo "机器人状态: $service_name"
    echo "========================================"
    echo ""

    systemctl status "$service_name" --no-pager || true

    local api_key=$(get_api_key_from_service "$service_name")
    local config=$(grep "ExecStart=" "$SYSTEMD_DIR/$service_name.service" 2>/dev/null | grep -oP 'configs/[^[:space:]]+\.json' || echo "未知")
    echo ""
    echo "配置文件: $config"
    echo -e "API用户: ${MAGENTA}${api_key:-未知}${NC}"

    echo ""
    echo "最近日志 (passivbot主日志, 10行):"
    local log_file=$(find_log_file "$api_key")
    if [ -n "$api_key" ] && [ -n "$log_file" ]; then
        tail -n 10 "$log_file" 2>/dev/null || echo "无法读取日志文件"
    else
        echo "未找到 passivbot 主日志 (user=$api_key)"
        echo "尝试 systemd 日志..."
        journalctl -u "$service_name" -n 10 --no-pager 2>/dev/null || echo "无日志"
    fi
}

show_logs() {
    local service_name=$(get_service_name "$1")
    local lines="${2:-50}"

    if [ -z "$service_name" ]; then
        echo -e "${RED}错误: 请指定服务名${NC}"
        return 1
    fi

    if [ ! -f "$SYSTEMD_DIR/$service_name.service" ]; then
        echo -e "${RED}错误: 服务 '$service_name' 不存在${NC}"
        return 1
    fi

    local api_key=$(get_api_key_from_service "$service_name")

    local log_file=$(find_log_file "$api_key")

    echo "========================================"
    echo "Passivbot 主日志 (user=$api_key, 最后$lines行)"
    echo "========================================"

    if [ -n "$api_key" ] && [ -n "$log_file" ]; then
        tail -n "$lines" "$log_file"
    else
        echo -e "${YELLOW}未找到 passivbot 主日志 (user=$api_key)${NC}"
        echo "尝试 systemd 日志..."
        journalctl -u "$service_name" -n "$lines" --no-pager
    fi
}

control_service() {
    local action="$1"
    local service_name=$(get_service_name "$2")

    if [ -z "$service_name" ]; then
        echo -e "${RED}错误: 请指定服务名${NC}"
        return 1
    fi

    if [ ! -f "$SYSTEMD_DIR/$service_name.service" ]; then
        echo -e "${RED}错误: 服务 '$service_name' 不存在${NC}"
        return 1
    fi

    echo "执行: $action $service_name"
    sudo systemctl "$action" "$service_name"

    sleep 1

    if systemctl is-active --quiet "$service_name"; then
        echo -e "状态: ${GREEN}运行中${NC}"
    else
        echo -e "状态: ${RED}停止${NC}"
    fi
}

run_config_check() {
    echo "========================================"
    echo "配置文件检查"
    echo "========================================"
    echo ""
    local errors=0
    while IFS= read -r cfg; do
        [ -f "$cfg" ] || continue
        local rel="${cfg#$PASSIVBOT_DIR/}"
        local info=$(python3 -c "
import json
try:
    with open('$cfg') as f:
        d = json.load(f)
    cv = d.get('config_version', '未设置')
    u = d.get('live', {}).get('user', '未设置')
    print(f'config_version={cv} user={u}')
except json.JSONDecodeError as e:
    print(f'ERR|JSON解析错误: {e}')
except OSError as e:
    print(f'ERR|文件读取错误: {e}')
" 2>/dev/null)
        if [ -n "$info" ]; then
            local status="${info%%|*}"
            if [ "$status" == "ERR" ]; then
                echo -e "  ${RED}✗${NC} $rel ${info#*|}"
                errors=$((errors + 1))
            else
                echo -e "  ${GREEN}✓${NC} $rel ($info)"
            fi
        else
            echo -e "  ${RED}✗${NC} $rel 未知错误"
            errors=$((errors + 1))
        fi
    done < <(find "$PASSIVBOT_DIR/$CONFIGS_DIR" -maxdepth 2 -name "*.json" -type f 2>/dev/null | sort)
    echo ""
    if [ "$errors" -gt 0 ]; then
        echo -e "${RED}发现 $errors 个配置文件有问题${NC}"
        return 1
    fi
    echo -e "${GREEN}全部检查通过${NC}"
}

panic_single() {
    local input_name="$1"
    local market_flag="${2:-}"
    local service_name=$(get_service_name "$input_name")

    echo "========================================"
    echo -e "${RED}⚡ PANIC 模式${NC} - 紧急清仓"
    echo "========================================"
    echo ""

    if [ -z "$service_name" ]; then
        echo -e "${RED}错误: 请指定服务名${NC}"
        echo "用法: $0 panic <服务名> [--market]"
        return 1
    fi

    if [ ! -f "$SYSTEMD_DIR/$service_name.service" ]; then
        echo -e "${RED}错误: 服务 '$service_name' 不存在${NC}"
        return 1
    fi

    # 提取配置文件路径
    local config_rel=$(grep "ExecStart=" "$SYSTEMD_DIR/$service_name" 2>/dev/null | grep -oP 'configs/[^[:space:]]+\.json' || echo "")
    if [ -z "$config_rel" ]; then
        echo -e "${RED}错误: 无法从服务文件提取配置路径${NC}"
        return 1
    fi
    local config_file="$PASSIVBOT_DIR/$config_rel"

    if [ ! -f "$config_file" ]; then
        echo -e "${RED}错误: 配置文件不存在: $config_file${NC}"
        return 1
    fi

    local use_market=false
    if [ "$market_flag" = "--market" ] || [ "$market_flag" = "-m" ]; then
        use_market=true
    fi

    echo -e "服务: ${CYAN}$service_name${NC}"
    echo -e "配置: $config_rel"
    if [ "$use_market" = true ]; then
        echo -e "清仓方式: ${RED}市价单 (market)${NC}"
    else
        echo -e "清仓方式: ${YELLOW}限价单 (limit)${NC}"
    fi
    echo ""
    echo -e "${YELLOW}警告: 这将把所有仓位设为 panic 模式，bot 会立即尝试平掉全部仓位！${NC}"
    echo ""

    read -p "确认执行 panic? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "已取消"
        return 0
    fi

    # 备份原配置
    local backup_file="${config_file}.pre_panic.$(date +%Y%m%d_%H%M%S)"
    cp "$config_file" "$backup_file"
    echo ""
    echo "原配置已备份: $backup_file"

    # 用 Python 修改配置
    local market_val="limit"
    if [ "$use_market" = true ]; then
        market_val="market"
    fi

    python3 -c "
import json, sys

config_path = '$config_file'
try:
    with open(config_path, 'r') as f:
        cfg = json.load(f)
except Exception as e:
    print(f'错误: 无法读取配置文件: {e}', file=sys.stderr)
    sys.exit(1)

# 设置 forced_mode 为 panic
cfg.setdefault('live', {})
cfg['live']['forced_mode_long'] = 'panic'
cfg['live']['forced_mode_short'] = 'panic'

# 设置 panic close 订单类型（需要同时开启 hsl_enabled 才能生效）
cfg.setdefault('bot', {})
for pside in ('long', 'short'):
    cfg['bot'].setdefault(pside, {})
    cfg['bot'][pside]['hsl_panic_close_order_type'] = '$market_val'
    if '$market_val' == 'market':
        # 市价清仓需要 hsl_enabled=true 才会走 market 路径
        # 但要设置极高的 red_threshold 防止 HSL 自行干预覆盖 panic
        cfg['bot'][pside]['hsl_enabled'] = True
        cfg['bot'][pside]['hsl_red_threshold'] = 0.99
        cfg['bot'][pside]['hsl_no_restart_drawdown_threshold'] = 1.0

try:
    with open(config_path, 'w') as f:
        json.dump(cfg, f, indent=4, ensure_ascii=False)
except Exception as e:
    print(f'错误: 无法写入配置文件: {e}', file=sys.stderr)
    sys.exit(1)

print('配置修改成功')
"

    if [ $? -ne 0 ]; then
        echo -e "${RED}配置修改失败，正在恢复备份...${NC}"
        cp "$backup_file" "$config_file"
        return 1
    fi

    echo -e "${GREEN}配置已修改${NC}"
    echo ""

    # 重启服务
    echo "重启服务..."
    sudo systemctl restart "$service_name"
    sleep 3

    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        echo -e "${GREEN}服务已重启，panic 模式已生效！${NC}"
    else
        echo -e "${RED}服务启动失败，请检查日志${NC}"
        echo "查看日志: $0 logs $input_name"
    fi
    echo ""
    echo "恢复原配置: $0 unpanic $input_name"
}

panic_all() {
    local market_flag="${1:-}"
    local use_market=false
    if [ "$market_flag" = "--market" ] || [ "$market_flag" = "-m" ]; then
        use_market=true
    fi

    echo "========================================"
    echo -e "${RED}⚡⚡⚡ PANIC ALL ⚡⚡⚡${NC}"
    echo -e "${RED}所有机器人紧急清仓${NC}"
    echo "========================================"
    echo ""

    if [ "$use_market" = true ]; then
        echo -e "清仓方式: ${RED}市价单 (market)${NC}"
    else
        echo -e "清仓方式: ${YELLOW}限价单 (limit)${NC}"
    fi
    echo ""
    echo -e "${RED}警告: 这将把所有运行中的机器人设为 panic 模式！${NC}"
    echo -e "${RED}每个机器人会立即尝试平掉全部仓位！${NC}"
    echo ""

    read -p "确认对所有机器人执行 panic? 输入 YES 确认: " confirm
    if [ "$confirm" != "YES" ]; then
        echo "已取消"
        return 0
    fi

    local count=0
    local failed=0
    for service_file in "$SYSTEMD_DIR"/passivbot*.service; do
        if [ ! -f "$service_file" ]; then
            continue
        fi
        local svc_name=$(basename "$service_file" .service)
        local config_rel=$(grep "ExecStart=" "$service_file" 2>/dev/null | grep -oP 'configs/[^[:space:]]+\\.json' || echo "")
        if [ -z "$config_rel" ]; then
            echo -e "${RED}跳过 $svc_name: 无法提取配置路径${NC}"
            failed=$((failed + 1))
            continue
        fi
        local config_file="$PASSIVBOT_DIR/$config_rel"
        if [ ! -f "$config_file" ]; then
            echo -e "${RED}跳过 $svc_name: 配置文件不存在${NC}"
            failed=$((failed + 1))
            continue
        fi

        echo ""
        echo -e "处理: ${CYAN}$svc_name${NC} ($config_rel)"

        # 备份
        local backup_file="${config_file}.pre_panic.$(date +%Y%m%d_%H%M%S)"
        cp "$config_file" "$backup_file"

        # 修改配置
        local market_val="limit"
        if [ "$use_market" = true ]; then
            market_val="market"
        fi

        python3 -c "
import json, sys
cfg_path = '$config_file'
try:
    with open(cfg_path, 'r') as f:
        cfg = json.load(f)
except Exception as e:
    print(f'错误: 无法读取 {cfg_path}: {e}', file=sys.stderr)
    sys.exit(1)
cfg.setdefault('live', {})
cfg['live']['forced_mode_long'] = 'panic'
cfg['live']['forced_mode_short'] = 'panic'
cfg.setdefault('bot', {})
for pside in ('long', 'short'):
    cfg['bot'].setdefault(pside, {})
    cfg['bot'][pside]['hsl_panic_close_order_type'] = '$market_val'
    if '$market_val' == 'market':
        cfg['bot'][pside]['hsl_enabled'] = True
        cfg['bot'][pside]['hsl_red_threshold'] = 0.99
        cfg['bot'][pside]['hsl_no_restart_drawdown_threshold'] = 1.0
try:
    with open(cfg_path, 'w') as f:
        json.dump(cfg, f, indent=4, ensure_ascii=False)
except Exception as e:
    print(f'错误: 无法写入 {cfg_path}: {e}', file=sys.stderr)
    sys.exit(1)
"

        if [ $? -ne 0 ]; then
            echo -e "${RED}配置修改失败，恢复备份${NC}"
            cp "$backup_file" "$config_file"
            failed=$((failed + 1))
            continue
        fi

        # 重启
        sudo systemctl restart "$svc_name" 2>/dev/null
        count=$((count + 1))
        echo -e "  ${GREEN}已重启${NC}"
    done

    echo ""
    echo "========================================"
    echo -e "${GREEN}已完成: $count 个机器人已进入 panic 模式${NC}"
    if [ $failed -gt 0 ]; then
        echo -e "${RED}失败: $failed 个${NC}"
    fi
    echo ""
    echo "恢复所有: $0 unpanic-all"
    echo "========================================"
}

unpanic_single() {
    local input_name="$1"
    local service_name=$(get_service_name "$input_name")

    echo "========================================"
    echo "恢复 panic 前配置"
    echo "========================================"
    echo ""

    if [ -z "$service_name" ]; then
        echo -e "${RED}错误: 请指定服务名${NC}"
        return 1
    fi

    if [ ! -f "$SYSTEMD_DIR/$service_name.service" ]; then
        echo -e "${RED}错误: 服务 '$service_name' 不存在${NC}"
        return 1
    fi

    local config_rel=$(grep "ExecStart=" "$SYSTEMD_DIR/$service_name" 2>/dev/null | grep -oP 'configs/[^[:space:]]+\\.json' || echo "")
    if [ -z "$config_rel" ]; then
        echo -e "${RED}错误: 无法提取配置路径${NC}"
        return 1
    fi
    local config_file="$PASSIVBOT_DIR/$config_rel"

    # 找到最新的 pre_panic 备份
    local backup_file=$(ls -t "${config_file}".pre_panic.* 2>/dev/null | head -1)
    if [ -z "$backup_file" ]; then
        echo -e "${RED}错误: 未找到 panic 备份文件${NC}"
        return 1
    fi

    echo -e "服务: ${CYAN}$service_name${NC}"
    echo -e "恢复配置: $config_rel"
    echo -e "从备份: $backup_file"
    echo ""

    cp "$backup_file" "$config_file"
    echo -e "${GREEN}配置已恢复${NC}"

    # 重启服务
    echo "重启服务..."
    sudo systemctl restart "$service_name"
    sleep 3

    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        echo -e "${GREEN}服务已重启，恢复正常模式${NC}"
    else
        echo -e "${RED}服务启动失败，请检查日志${NC}"
    fi
}

unpanic_all() {
    echo "========================================"
    echo "恢复所有机器人 panic 前配置"
    echo "========================================"
    echo ""

    local count=0
    local failed=0
    for service_file in "$SYSTEMD_DIR"/passivbot*.service; do
        if [ ! -f "$service_file" ]; then
            continue
        fi
        local svc_name=$(basename "$service_file" .service)
        local config_rel=$(grep "ExecStart=" "$service_file" 2>/dev/null | grep -oP 'configs/[^[:space:]]+\\.json' || echo "")
        if [ -z "$config_rel" ]; then
            continue
        fi
        local config_file="$PASSIVBOT_DIR/$config_rel"

        local backup_file=$(ls -t "${config_file}".pre_panic.* 2>/dev/null | head -1)
        if [ -z "$backup_file" ]; then
            continue
        fi

        echo -e "恢复 ${CYAN}$svc_name${NC} <- $backup_file"
        cp "$backup_file" "$config_file"
        sudo systemctl restart "$svc_name" 2>/dev/null
        count=$((count + 1))
    done

    echo ""
    if [ $count -gt 0 ]; then
        echo -e "${GREEN}已恢复 $count 个机器人${NC}"
    else
        echo -e "${YELLOW}未找到需要恢复的机器人${NC}"
    fi
}

stop_all() {
    echo "========================================"
    echo "停止所有机器人"
    echo "========================================"
    echo ""

    local count=0
    for service_file in "$SYSTEMD_DIR"/passivbot*.service; do
        if [ ! -f "$service_file" ]; then
            continue
        fi
        local svc_name=$(basename "$service_file" .service)
        if systemctl is-active --quiet "$svc_name" 2>/dev/null; then
            echo -e "停止 ${CYAN}$svc_name${NC}..."
            sudo systemctl stop "$svc_name"
            count=$((count + 1))
        else
            echo -e "跳过 ${CYAN}$svc_name${NC} (未运行)"
        fi
    done

    echo ""
    echo -e "${GREEN}已停止 $count 个机器人${NC}"
}

start_all() {
    echo "========================================"
    echo "启动所有机器人"
    echo "========================================"
    echo ""

    local count=0
    for service_file in "$SYSTEMD_DIR"/passivbot*.service; do
        if [ ! -f "$service_file" ]; then
            continue
        fi
        local svc_name=$(basename "$service_file" .service)
        if systemctl is-active --quiet "$svc_name" 2>/dev/null; then
            echo -e "跳过 ${CYAN}$svc_name${NC} (已运行)"
        else
            echo -e "启动 ${CYAN}$svc_name${NC}..."
            sudo systemctl start "$svc_name"
            count=$((count + 1))
        fi
    done

    echo ""
    echo -e "${GREEN}已启动 $count 个机器人${NC}"
}

delete_all() {
    echo "========================================"
    echo -e "${RED}⚠  删除所有机器人实例  ⚠${NC}"
    echo "========================================"
    echo ""

    # 列出所有实例
    local svc_list=()
    for service_file in "$SYSTEMD_DIR"/passivbot*.service; do
        [ -f "$service_file" ] || continue
        svc_list+=("$(basename "$service_file" .service)")
    done

    if [ ${#svc_list[@]} -eq 0 ]; then
        echo -e "${YELLOW}没有可删除的机器人${NC}"
        return 0
    fi

    echo "将要删除以下所有实例:"
    for svc in "${svc_list[@]}"; do
        echo -e "  ${CYAN}$svc${NC}"
    done
    echo ""
    echo -e "${RED}此操作不可逆！${NC}"

    read -p "确认删除? 输入 YES 确认: " confirm
    if [ "$confirm" != "YES" ]; then
        echo "已取消"
        return 0
    fi

    local count=0
    for svc in "${svc_list[@]}"; do
        echo ""
        echo -e "删除 ${CYAN}$svc${NC}..."
        systemctl is-active --quiet "$svc" 2>/dev/null && sudo systemctl stop "$svc"
        sudo systemctl disable "$svc" 2>/dev/null || true
        sudo mv "$SYSTEMD_DIR/$svc.service" "$SYSTEMD_DIR/$svc.service.deleted.$(date +%Y%m%d_%H%M%S)"
        count=$((count + 1))
    done

    sudo systemctl daemon-reload

    echo ""
    echo -e "${GREEN}已删除 $count 个机器人实例${NC}"
    echo "配置文件和日志文件仍保留在服务器上"
}

clean_logs() {
    local days="${1:-7}"
    local log_dir="$PASSIVBOT_DIR/logs"

    echo "========================================"
    echo "清理日志"
    echo "========================================"
    echo ""

    if [ ! -d "$log_dir" ]; then
        echo -e "${YELLOW}日志目录不存在${NC}"
        return 0
    fi

    local total_before=$(find "$log_dir" -maxdepth 1 -type f -name "*.log" 2>/dev/null | wc -l | xargs)
    echo "当前日志文件总数: $total_before"
    echo ""

    # 收集所有活跃 user（从已有 systemd 服务提取）
    declare -A active_users
    for service_file in "$SYSTEMD_DIR"/passivbot*.service; do
        [ -f "$service_file" ] || continue
        local svc=$(basename "$service_file" .service)
        local u=$(get_api_key_from_service "$svc")
        [ -n "$u" ] && active_users["$u"]=1
    done

    local deleted=0

    # 对每个活跃用户，保留最新的 ONE 个带时间戳的日志，删除其余旧的
    for user in "${!active_users[@]}"; do
        local ts_files=$(ls -t "$log_dir"/*_passivbot_live_*_-u_"${user}"_*.log 2>/dev/null)
        local count=0
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            count=$((count + 1))
            if [ $count -eq 1 ]; then
                continue  # 保留最新一个
            fi
            echo -e "  删除: ${YELLOW}$(basename "$f")${NC}"
            rm -f "$f"
            deleted=$((deleted + 1))
        done <<< "$ts_files"
    done

    # 删除已被删除的服务对应的孤立日志（无对应 systemd 服务的 user 的日志）
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        local name=$(basename "$f")
        # 跳过 systemd 日志和非时间戳日志
        [[ "$name" == *.systemd.log ]] && continue
        [[ "$name" =~ ^[0-9]{8}_ ]] || continue
        local file_user=$(echo "$name" | grep -oP -- '-u_\K[^_]+(?=_)' 2>/dev/null || echo "")
        if [ -n "$file_user" ] && [ -z "${active_users[$file_user]}" ]; then
            echo -e "  删除孤立日志: ${YELLOW}$name${NC}"
            rm -f "$f"
            deleted=$((deleted + 1))
        fi
    done < <(find "$log_dir" -maxdepth 1 -type f -name "*.log" -mtime +$days 2>/dev/null)

    local total_after=$(find "$log_dir" -maxdepth 1 -type f -name "*.log" 2>/dev/null | wc -l | xargs)
    echo ""
    echo -e "${GREEN}清理完成: $total_before -> $total_after (删除 $deleted 个)${NC}"
}

main() {
    local cmd="${1:-help}"

    case "$cmd" in
        create|c)
            shift
            create_bot "$@"
            ;;
        switch|sw|s)
            shift
            switch_bot "$@"
            ;;
        start)
            shift
            control_service "start" "$1"
            ;;
        start-all)
            start_all
            ;;
        stop)
            shift
            control_service "stop" "$1"
            ;;
        stop-all|sa)
            stop_all
            ;;
        restart|reboot|r)
            shift
            control_service "restart" "$1"
            ;;
        delete|remove|rm|d)
            shift
            delete_bot "$1"
            ;;
        delete-all|da)
            delete_all
            ;;
        list|ls|l)
            list_bots
            ;;
        status|st)
            shift
            show_status "$1"
            ;;
        logs|log)
            shift
            show_logs "$@"
            ;;
        configs|conf)
            list_configs
            ;;
        check)
            run_config_check
            ;;
        panic|p)
            shift
            panic_single "$1" "$2"
            ;;
        panic-all|pa)
            shift
            panic_all "$1"
            ;;
        unpanic|up)
            shift
            unpanic_single "$1"
            ;;
        unpanic-all|upa)
            unpanic_all
            ;;
        clean-logs)
            shift
            clean_logs "$@"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            echo -e "${RED}未知命令: $cmd${NC}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
