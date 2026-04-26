# Passivbot v7.7b → v7.10.0 升级步骤

## 一、升级前快照（30秒）

```bash
cd /home/ubuntu/passivbot
git describe --tags --always > ~/passivbot_version_before.txt
```

## 二、升级代码

```bash
cd /home/ubuntu/passivbot
git checkout v7.10.0
source venv/bin/activate
python3 -m pip install -e ".[full]"
cd passivbot-rust && maturin develop --release && cd ..
```

## 三、自动升级所有实例

```bash
sudo upgrade_v7_7b_to_v7_10_0/auto_upgrade.sh
```

脚本会自动扫描现有实例、匹配新配置、确认后批量切换。

切管理脚本：

```bash
sudo cp upgrade_v7_7b_to_v7_10_0/passivbot_v710.sh passivbot.sh
./passivbot.sh list
```

---

## 四、回滚（升级失败时）

### 情况 A：只想换回旧配置，代码保持 v7.10.0

```bash
# 停止所有实例，恢复升级前备份的 systemd 服务文件
sudo upgrade_v7_7b_to_v7_10_0/rollback.sh

# 重启（此时跑的是旧配置文件 + v7.10.0 代码）
# 注意：v7.10.0 向后兼容大部分 v7.7 配置（会自动迁移缺少的字段）
# 但如果旧配置中使用了 v7.10.0 不支持的参数，可能会报错
for svc in $(systemctl list-units --plain --no-legend 'passivbot*' | awk '{print $1}'); do
  sudo systemctl start $svc
done
```

### 情况 B：彻底回退到旧版本（代码+配置）

```bash
# 1. 停止并恢复旧服务文件
sudo upgrade_v7_7b_to_v7_10_0/rollback.sh

# 2. 回退代码
cd /home/ubuntu/passivbot
git checkout $(cat ~/passivbot_version_before.txt)
source venv/bin/activate
pip install -e ".[full]"
cd passivbot-rust && maturin develop --release && cd ..

# 3. 重启所有实例
for svc in $(systemctl list-units --plain --no-legend 'passivbot*' | awk '{print $1}'); do
  sudo systemctl start $svc
done
```

### 手动恢复单个实例

```bash
# 找到备份文件
ls -la /etc/systemd/system/passivbot-xxx.service.pre_v710.*

# 恢复
sudo cp /etc/systemd/system/passivbot-xxx.service.pre_v710.2026xxxx \
        /etc/systemd/system/passivbot-xxx.service
sudo systemctl daemon-reload
sudo systemctl restart passivbot-xxx
```
