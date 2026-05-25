# RSS Keyword Telegram Bot

轻量级自托管 RSS 关键词 Telegram 推送机器人。

通过 Telegram Bot 管理 RSS 源和关键词，定时检查 RSS 内容，命中关键词后自动推送到 Telegram。

---

## 功能

- 添加 / 删除 RSS 源
- 添加 / 删除关键词
- 关键词命中后推送
- 支持推送全部 RSS 更新
- 支持 Telegram 按钮菜单
- 支持 SQLite 数据持久化
- 支持已处理内容去重
- 支持自动清理旧记录
- 支持 Docker Compose 部署
- 支持容器自启动

---

## 工作流程

```text
RSS 源
  ↓
定时检查
  ↓
匹配标题和摘要
  ↓
命中关键词
  ↓
Telegram 推送
```

---

## 推送格式

```text
🚀 RSS 新内容命中

📌 标题
🎯 命中：关键词1、关键词2
🕒 时间：发布时间

📝 内容：
摘要内容

🔗 查看原文：
原文链接
```

---

## 一键安装

root 用户执行：

```bash
curl -fsSL https://raw.githubusercontent.com/looklenx/rssbot/main/install.sh | bash
```

执行过程中会提示输入 Telegram Bot Token。

Token 会保存在服务器本地：

```text
/opt/rss-keyword-tgbot/.env
```

---

## 安装目录

默认安装目录：

```text
/opt/rss-keyword-tgbot
```

目录结构：

```text
/opt/rss-keyword-tgbot/
├── .env
├── .env.example
├── app.py
├── requirements.txt
├── Dockerfile
├── docker-compose.yml
└── data/
```

说明：

| 文件 / 目录 | 作用 |
|---|---|
| `.env` | 环境变量配置 |
| `.env.example` | 环境变量示例 |
| `app.py` | Bot 主程序 |
| `requirements.txt` | Python 依赖 |
| `Dockerfile` | Docker 镜像构建文件 |
| `docker-compose.yml` | Docker Compose 配置 |
| `data/` | SQLite 数据目录 |

---

## 环境变量

`.env` 示例：

```env
BOT_TOKEN=your_telegram_bot_token
CHECK_INTERVAL=120
DEFAULT_RSS=https://example.com/feed.xml
DB_PATH=/app/data/bot.db
CLEANUP_DAYS=30
```

| 变量 | 说明 |
|---|---|
| `BOT_TOKEN` | Telegram Bot Token |
| `CHECK_INTERVAL` | RSS 检查间隔，单位秒 |
| `DEFAULT_RSS` | 默认 RSS 示例地址 |
| `DB_PATH` | SQLite 数据库路径 |
| `CLEANUP_DAYS` | 自动清理多少天前的已处理记录，0 表示不清理 |

修改 `.env` 后重启：

```bash
cd /opt/rss-keyword-tgbot
docker restart rss-keyword-tgbot
```

---

## Telegram 命令

### 基础命令

```text
/start
/menu
/status
/checknow
```

| 命令 | 作用 |
|---|---|
| `/start` | 初始化 / 查看帮助 |
| `/menu` | 打开按钮菜单 |
| `/status` | 查看当前状态 |
| `/checknow` | 立即检查 RSS |

---

### RSS 源管理

```text
/addrss https://example.com/feed.xml
/listrss
/delrss ID
```

| 命令 | 作用 |
|---|---|
| `/addrss RSS地址` | 添加 RSS 源 |
| `/listrss` | 查看 RSS 源 |
| `/delrss ID` | 删除 RSS 源 |

示例：

```text
/addrss https://example.com/feed.xml
/listrss
/delrss 1
```

---

### 关键词管理

```text
/addkw 关键词
/listkw
/delkw ID
```

| 命令 | 作用 |
|---|---|
| `/addkw 关键词` | 添加关键词 |
| `/listkw` | 查看关键词 |
| `/delkw ID` | 删除关键词 |

示例：

```text
/addkw 更新
/addkw 发布
/addkw 公告
/listkw
/delkw 1
```

---

### 推送模式

```text
/mode keyword
/mode all
```

| 命令 | 作用 |
|---|---|
| `/mode keyword` | 只推送关键词命中内容 |
| `/mode all` | 推送 RSS 全部更新 |

推荐日常使用：

```text
/mode keyword
```

---

## 推荐初始化流程

部署完成后，在 Telegram 里发送：

```text
/start
/addrss https://example.com/feed.xml
/addkw 更新
/addkw 发布
/addkw 公告
/mode keyword
/status
```

说明：

```text
https://example.com/feed.xml 是示例 RSS 地址，请替换成自己的 RSS 源。
关键词也是示例，请按实际需求添加。
```

---

## 按钮菜单

发送：

```text
/menu
```

按钮内容：

```text
📊 状态        🔍 立即检查
📡 RSS 源      🎯 关键词
➕ 添加 RSS    ➕ 添加关键词
✅ 关键词模式  📢 全量模式
🧾 帮助
```

| 按钮 | 作用 |
|---|---|
| 📊 状态 | 查看当前运行状态 |
| 🔍 立即检查 | 立即检查 RSS |
| 📡 RSS 源 | 查看 RSS 源 |
| 🎯 关键词 | 查看关键词 |
| ➕ 添加 RSS | 显示添加 RSS 命令 |
| ➕ 添加关键词 | 显示添加关键词命令 |
| ✅ 关键词模式 | 只推送关键词命中内容 |
| 📢 全量模式 | 推送全部 RSS 更新 |
| 🧾 帮助 | 查看帮助 |

---

## 服务器维护命令

进入目录：

```bash
cd /opt/rss-keyword-tgbot
```

查看容器状态：

```bash
docker ps | grep rss-keyword-tgbot
```

查看日志：

```bash
docker logs -f --tail=100 rss-keyword-tgbot
```

重启：

```bash
docker restart rss-keyword-tgbot
```

停止：

```bash
docker stop rss-keyword-tgbot
```

启动：

```bash
docker start rss-keyword-tgbot
```

重建：

```bash
cd /opt/rss-keyword-tgbot
docker compose up -d --build
```

查看重启策略：

```bash
docker inspect rss-keyword-tgbot --format '{{.HostConfig.RestartPolicy.Name}}'
```

正常返回：

```text
unless-stopped
```

---

## 开机自启动

确认 Docker 开机自启：

```bash
systemctl is-enabled docker
```

如果不是 `enabled`：

```bash
systemctl enable --now docker
```

容器使用：

```yaml
restart: unless-stopped
```

含义：

```text
服务器重启后自动启动
Docker 重启后自动启动
程序异常退出后自动拉起
手动 docker stop 后不会自动启动
```

---

## 数据持久化

数据目录：

```text
/opt/rss-keyword-tgbot/data
```

数据库：

```text
/opt/rss-keyword-tgbot/data/bot.db
```

保存内容：

```text
RSS 源
关键词
用户配置
已处理记录
```

---

## 自动清理

通过 `.env` 控制：

```env
CLEANUP_DAYS=30
```

说明：

| 配置 | 作用 |
|---|---|
| `CLEANUP_DAYS=7` | 保留最近 7 天记录 |
| `CLEANUP_DAYS=30` | 推荐配置 |
| `CLEANUP_DAYS=90` | 保留最近 90 天记录 |
| `CLEANUP_DAYS=0` | 不自动清理 |

清理的是已处理记录，不会删除 RSS 源、关键词和用户配置。

---

## 备份

```bash
tar -czf /opt/rss-keyword-tgbot-backup-$(date +%F-%H%M%S).tar.gz /opt/rss-keyword-tgbot
```

备份内容：

```text
程序文件
.env
SQLite 数据库
RSS 源
关键词
已处理记录
Docker 配置
```

---

## 恢复

```bash
cd /opt/rss-keyword-tgbot
docker compose up -d --build
```

---

## 卸载

### 停止并删除容器

```bash
cd /opt/rss-keyword-tgbot
docker compose down
```

### 删除程序和数据

```bash
rm -rf /opt/rss-keyword-tgbot
```

### 删除备份文件

```bash
rm -f /opt/rss-keyword-tgbot-backup-*.tar.gz
```

### 删除 Docker 镜像，可选

查看镜像：

```bash
docker images | grep rss-keyword
```

删除镜像：

```bash
docker rmi 镜像ID
```

---

## 排障

### Bot 没反应

查看日志：

```bash
docker logs -f --tail=100 rss-keyword-tgbot
```

检查 Token 是否进入容器：

```bash
docker exec rss-keyword-tgbot sh -c 'echo ${BOT_TOKEN:0:8}******'
```

---

### 没有推送

在 Telegram 里检查：

```text
/status
/listrss
/listkw
/mode keyword
/checknow
```

确认：

```text
RSS 源已添加
关键词已添加
当前模式是 keyword
RSS 源有新内容
新内容标题或摘要命中关键词
```

---

### 检查 RSS 是否能抓取

```bash
docker exec rss-keyword-tgbot python - <<'PY'
import feedparser

url = 'https://example.com/feed.xml'
feed = feedparser.parse(url)

print('bozo:', feed.bozo)
print('entries:', len(feed.entries))

for e in feed.entries[:5]:
    print('-', e.get('title'))
PY
```

请把 `https://example.com/feed.xml` 替换成自己的 RSS 地址。

---

### 测试 Telegram 推送

```bash
docker exec rss-keyword-tgbot python - <<'PY'
import os
import sqlite3
import asyncio
from telegram import Bot

async def main():
    conn = sqlite3.connect('/app/data/bot.db')
    row = conn.execute('SELECT chat_id FROM users LIMIT 1').fetchone()
    conn.close()

    if not row:
        print('请先在 Telegram 里发送 /start')
        return

    await Bot(os.environ['BOT_TOKEN']).send_message(
        chat_id=row[0],
        text='✅ RSS Bot 推送测试成功'
    )
    print('sent')

asyncio.run(main())
PY
```

---

## 常见问题

### 为什么没有立即推送？

首次添加 RSS 后，Bot 会记录已处理内容，避免历史内容刷屏。之后只有新内容命中关键词才会推送。

### 为什么已处理记录比推送数量多？

Bot 会记录所有已处理 RSS 条目，用于去重和避免重复检查。

```text
已处理记录 ≠ 已推送数量
```

### 可以添加多个 RSS 源吗？

可以。

```text
/addrss https://example.com/feed.xml
/addrss https://example.org/rss
/addrss https://example.net/atom.xml
```

### 可以添加多个关键词吗？

可以。

```text
/addkw 更新
/addkw 发布
/addkw 公告
/addkw 活动
```

### 关键词是精确匹配还是模糊匹配？

当前是简单包含匹配。

例如关键词：

```text
发布
```

可以命中：

```text
新版本发布
项目发布公告
发布计划
```

---

## 常用命令汇总

### 服务器

```bash
cd /opt/rss-keyword-tgbot
docker logs -f --tail=100 rss-keyword-tgbot
docker restart rss-keyword-tgbot
docker compose up -d --build
```

### Telegram

```text
/start
/menu
/addrss https://example.com/feed.xml
/addkw 更新
/addkw 发布
/addkw 公告
/mode keyword
/status
/checknow
```

---

## License

仅供个人自建使用，可按需修改。
