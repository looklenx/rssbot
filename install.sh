#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/rss-keyword-tgbot"
IMAGE_NAME="rss-keyword-tgbot-local"

echo "======================================"
echo " RSS Keyword Telegram Bot Installer"
echo "======================================"

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 用户执行"
  exit 1
fi

echo "==> 安装必要组件"
apt-get update -y
apt-get install -y curl ca-certificates

echo "==> 检查 Docker"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | bash
fi

systemctl enable --now docker

echo "==> 创建目录"
mkdir -p "$APP_DIR/data"
cd "$APP_DIR"

echo "==> 创建 requirements.txt"
cat > requirements.txt <<'EOF'
python-telegram-bot==21.11.1
feedparser==6.0.11
EOF

echo "==> 创建 Dockerfile"
cat > Dockerfile <<'EOF'
FROM python:3.12-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY app.py /app/app.py

CMD ["python", "/app/app.py"]
EOF

echo "==> 创建 docker-compose.yml"
cat > docker-compose.yml <<'EOF'
services:
  rss-keyword-tgbot:
    build: .
    container_name: rss-keyword-tgbot
    restart: unless-stopped
    env_file:
      - .env
    volumes:
      - ./data:/app/data
EOF

echo "==> 创建 app.py"
cat > app.py <<'PYAPP'
import os
import re
import html
import time
import hashlib
import sqlite3
import asyncio
import logging
from typing import List, Tuple

import feedparser
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, BotCommand
from telegram.ext import Application, CommandHandler, ContextTypes, CallbackQueryHandler

BOT_TOKEN = os.getenv("BOT_TOKEN", "")
CHECK_INTERVAL = int(os.getenv("CHECK_INTERVAL", "120"))
DB_PATH = os.getenv("DB_PATH", "/app/data/bot.db")
DEFAULT_RSS = os.getenv("DEFAULT_RSS", "https://rss.nodeseek.com/")
CLEANUP_DAYS = int(os.getenv("CLEANUP_DAYS", "30"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s"
)

if not BOT_TOKEN:
    raise RuntimeError("BOT_TOKEN is required")


def db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = db()
    cur = conn.cursor()

    cur.execute("""
    CREATE TABLE IF NOT EXISTS users (
        chat_id INTEGER PRIMARY KEY,
        mode TEXT NOT NULL DEFAULT 'keyword',
        created_at INTEGER NOT NULL
    )
    """)

    cur.execute("""
    CREATE TABLE IF NOT EXISTS sources (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        chat_id INTEGER NOT NULL,
        url TEXT NOT NULL,
        title TEXT DEFAULT '',
        created_at INTEGER NOT NULL,
        UNIQUE(chat_id, url)
    )
    """)

    cur.execute("""
    CREATE TABLE IF NOT EXISTS keywords (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        chat_id INTEGER NOT NULL,
        keyword TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        UNIQUE(chat_id, keyword)
    )
    """)

    cur.execute("""
    CREATE TABLE IF NOT EXISTS sent_items (
        chat_id INTEGER NOT NULL,
        source_id INTEGER NOT NULL,
        item_hash TEXT NOT NULL,
        sent_at INTEGER NOT NULL,
        PRIMARY KEY(chat_id, source_id, item_hash)
    )
    """)

    conn.commit()
    conn.close()


def ensure_user(chat_id: int):
    conn = db()
    conn.execute(
        "INSERT OR IGNORE INTO users(chat_id, mode, created_at) VALUES (?, 'keyword', ?)",
        (chat_id, int(time.time()))
    )
    conn.commit()
    conn.close()


def normalize_url(url: str) -> str:
    url = url.strip()
    if not re.match(r"^https?://", url):
        raise ValueError("RSS 地址必须以 http:// 或 https:// 开头")
    return url


def item_hash(entry) -> str:
    raw = (
        getattr(entry, "id", "") or
        getattr(entry, "guid", "") or
        getattr(entry, "link", "") or
        getattr(entry, "title", "")
    )
    return hashlib.sha256(raw.encode("utf-8", errors="ignore")).hexdigest()


def clean_text(value: str) -> str:
    if not value:
        return ""
    value = re.sub(r"<[^>]+>", " ", value)
    value = re.sub(r"\s+", " ", value)
    return value.strip()


def get_keywords(chat_id: int) -> List[str]:
    conn = db()
    rows = conn.execute(
        "SELECT keyword FROM keywords WHERE chat_id=? ORDER BY id ASC",
        (chat_id,)
    ).fetchall()
    conn.close()
    return [r["keyword"] for r in rows]


def get_sources() -> List[sqlite3.Row]:
    conn = db()
    rows = conn.execute("""
        SELECT s.id, s.chat_id, s.url, s.title, u.mode
        FROM sources s
        JOIN users u ON s.chat_id = u.chat_id
        ORDER BY s.id ASC
    """).fetchall()
    conn.close()
    return rows


def has_sent(chat_id: int, source_id: int, h: str) -> bool:
    conn = db()
    row = conn.execute(
        "SELECT 1 FROM sent_items WHERE chat_id=? AND source_id=? AND item_hash=?",
        (chat_id, source_id, h)
    ).fetchone()
    conn.close()
    return row is not None


def mark_sent(chat_id: int, source_id: int, h: str):
    conn = db()
    conn.execute(
        "INSERT OR IGNORE INTO sent_items(chat_id, source_id, item_hash, sent_at) VALUES (?, ?, ?, ?)",
        (chat_id, source_id, h, int(time.time()))
    )
    conn.commit()
    conn.close()


def cleanup_old_items():
    if CLEANUP_DAYS <= 0:
        return

    cutoff = int(time.time()) - CLEANUP_DAYS * 86400
    conn = db()
    cur = conn.execute("DELETE FROM sent_items WHERE sent_at < ?", (cutoff,))
    deleted = cur.rowcount
    conn.commit()
    conn.close()

    if deleted:
        logging.info("Cleaned old sent_items: %s", deleted)


def match_keywords(title: str, summary: str, keywords: List[str]) -> Tuple[bool, List[str]]:
    text = f"{title}\n{summary}".lower()
    matched = []
    for kw in keywords:
        if kw.lower() in text:
            matched.append(kw)
    return bool(matched), matched


def build_message(entry, matched: List[str]) -> str:
    title = html.escape(clean_text(getattr(entry, "title", "无标题")))
    link = html.escape(getattr(entry, "link", ""))
    summary = html.escape(clean_text(getattr(entry, "summary", "")))

    published = (
        getattr(entry, "published", "") or
        getattr(entry, "updated", "") or
        ""
    )
    published = html.escape(clean_text(published))

    if len(summary) > 500:
        summary = summary[:500] + "..."

    if not summary:
        summary = "无摘要，请打开原帖查看。"

    kw_line = ""
    if matched:
        kw_line = "🎯 <b>命中：</b>" + "、".join(html.escape(x) for x in matched) + "\n"

    time_line = ""
    if published:
        time_line = f"🕒 <b>时间：</b>{published}\n"

    return (
        f"🚀 <b>NodeSeek 新帖命中</b>\n\n"
        f"📌 <b>{title}</b>\n"
        f"{kw_line}"
        f"{time_line}"
        f"\n"
        f"📝 <b>内容：</b>\n"
        f"{summary}\n\n"
        f"🔗 <b>查看原帖：</b>\n"
        f"{link}"
    )


def main_menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton("📊 状态", callback_data="status"),
            InlineKeyboardButton("🔍 立即检查", callback_data="checknow"),
        ],
        [
            InlineKeyboardButton("📡 RSS 源", callback_data="listrss"),
            InlineKeyboardButton("🎯 关键词", callback_data="listkw"),
        ],
        [
            InlineKeyboardButton("➕ 添加 RSS", callback_data="add_rss_help"),
            InlineKeyboardButton("➕ 添加关键词", callback_data="add_kw_help"),
        ],
        [
            InlineKeyboardButton("✅ 关键词模式", callback_data="mode_keyword"),
            InlineKeyboardButton("📢 全量模式", callback_data="mode_all"),
        ],
        [
            InlineKeyboardButton("🧾 帮助", callback_data="help"),
        ],
    ])


def help_text() -> str:
    return f"""RSS 关键词推送 Bot 已启动。

常用命令：

/addrss {DEFAULT_RSS}
添加 RSS 源

/listrss
查看 RSS 源

/delrss ID
删除 RSS 源

/addkw VPS
添加关键词

/listkw
查看关键词

/delkw ID
删除关键词

/mode keyword
只推送关键词命中内容

/mode all
推送 RSS 全部更新

/checknow
立即检查一次

/status
查看状态

/menu
打开按钮菜单

推荐 NodeSeek：
/addrss {DEFAULT_RSS}
"""


def status_text(chat_id: int) -> str:
    conn = db()
    user = conn.execute("SELECT mode FROM users WHERE chat_id=?", (chat_id,)).fetchone()
    source_count = conn.execute("SELECT COUNT(*) AS c FROM sources WHERE chat_id=?", (chat_id,)).fetchone()["c"]
    kw_count = conn.execute("SELECT COUNT(*) AS c FROM keywords WHERE chat_id=?", (chat_id,)).fetchone()["c"]
    sent_count = conn.execute("SELECT COUNT(*) AS c FROM sent_items WHERE chat_id=?", (chat_id,)).fetchone()["c"]
    conn.close()

    mode_raw = user["mode"] if user else "keyword"
    mode_name = "只推关键词命中" if mode_raw == "keyword" else "推送全部 RSS 更新"

    return (
        f"📊 当前状态：\n\n"
        f"模式：{mode_name}\n"
        f"RSS 源数量：{source_count}\n"
        f"关键词数量：{kw_count}\n"
        f"已处理记录：{sent_count}\n"
        f"检查间隔：{CHECK_INTERVAL} 秒\n"
        f"自动清理：{CLEANUP_DAYS} 天"
    )


def rss_list_text(chat_id: int) -> str:
    conn = db()
    rows = conn.execute(
        "SELECT id, url FROM sources WHERE chat_id=? ORDER BY id ASC",
        (chat_id,)
    ).fetchall()
    conn.close()

    if not rows:
        return f"当前没有 RSS 源。\n\n添加 NodeSeek：\n/addrss {DEFAULT_RSS}"

    return "📡 当前 RSS 源：\n\n" + "\n".join([f"{r['id']}. {r['url']}" for r in rows])


def kw_list_text(chat_id: int) -> str:
    conn = db()
    rows = conn.execute(
        "SELECT id, keyword FROM keywords WHERE chat_id=? ORDER BY id ASC",
        (chat_id,)
    ).fetchall()
    conn.close()

    if not rows:
        return "当前没有关键词。\n\n添加示例：\n/addkw VPS\n/addkw DMIT\n/addkw 甲骨文"

    return "🎯 当前关键词：\n\n" + "\n".join([f"{r['id']}. {r['keyword']}" for r in rows])


async def fetch_feed(url: str):
    return await asyncio.to_thread(feedparser.parse, url)


async def check_once(app: Application):
    sources = get_sources()

    for source in sources:
        source_id = source["id"]
        chat_id = source["chat_id"]
        url = source["url"]
        mode = source["mode"]

        try:
            parsed = await fetch_feed(url)
        except Exception as e:
            logging.warning("Fetch failed %s: %s", url, e)
            continue

        entries = list(getattr(parsed, "entries", []))
        if not entries:
            continue

        keywords = get_keywords(chat_id)

        for entry in reversed(entries[:15]):
            h = item_hash(entry)

            if has_sent(chat_id, source_id, h):
                continue

            title = clean_text(getattr(entry, "title", ""))
            summary = clean_text(getattr(entry, "summary", ""))
            matched_ok, matched = match_keywords(title, summary, keywords)

            should_send = False

            if mode == "all":
                should_send = True
            elif mode == "keyword":
                should_send = matched_ok

            mark_sent(chat_id, source_id, h)

            if should_send:
                msg = build_message(entry, matched)
                try:
                    await app.bot.send_message(
                        chat_id=chat_id,
                        text=msg,
                        parse_mode="HTML",
                        disable_web_page_preview=False
                    )
                except Exception as e:
                    logging.warning("Send failed to %s: %s", chat_id, e)


async def scheduler(app: Application):
    await asyncio.sleep(5)
    logging.info("RSS scheduler started, interval=%ss", CHECK_INTERVAL)

    while True:
        try:
            await check_once(app)
            cleanup_old_items()
        except Exception as e:
            logging.exception("Scheduler error: %s", e)

        await asyncio.sleep(CHECK_INTERVAL)


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.effective_chat.id
    ensure_user(chat_id)

    await update.message.reply_text(
        help_text(),
        reply_markup=main_menu()
    )


async def menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.effective_chat.id
    ensure_user(chat_id)

    await update.message.reply_text(
        "请选择操作：",
        reply_markup=main_menu()
    )


async def addrss(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.effective_chat.id
    ensure_user(chat_id)

    if not context.args:
        await update.message.reply_text(f"用法：/addrss {DEFAULT_RSS}")
        return

    try:
        url = normalize_url(context.args[0])
    except ValueError as e:
        await update.message.reply_text(str(e))
        return

    conn = db()
    try:
        conn.execute(
            "INSERT OR IGNORE INTO sources(chat_id, url, created_at) VALUES (?, ?, ?)",
            (chat_id, url, int(time.time()))
        )
        conn.commit()
        await update.message.reply_text(f"已添加 RSS：\n{url}")
    finally:
        conn.close()


async def listrss(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.effective_chat.id
    ensure_user(chat_id)
    await update.message.reply_text(rss_list_text(chat_id))


async def delrss(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.effective_chat.id
    ensure_user(chat_id)

    if not context.args or not context.args[0].isdigit():
        await update.message.reply_text("用法：/delrss ID")
        return

    rss_id = int(context.args[0])
    conn = db()
    conn.execute("DELETE FROM sources WHERE id=? AND chat_id=?", (rss_id, chat_id))
    conn.execute("DELETE FROM sent_items WHERE source_id=? AND chat_id=?", (rss_id, chat_id))
    conn.commit()
    conn.close()

    await update.message.reply_text(f"已删除 RSS：{rss_id}")


async def addkw(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.effective_chat.id
    ensure_user(chat_id)

    if not context.args:
        await update.message.reply_text("用法：/addkw VPS")
        return

    keyword = " ".join(context.args).strip()

    conn = db()
    conn.execute(
        "INSERT OR IGNORE INTO keywords(chat_id, keyword, created_at) VALUES (?, ?, ?)",
        (chat_id, keyword, int(time.time()))
    )
    conn.commit()
    conn.close()

    await update.message.reply_text(f"已添加关键词：{keyword}")


async def listkw(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.effective_chat.id
    ensure_user(chat_id)
    await update.message.reply_text(kw_list_text(chat_id))


async def delkw(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.effective_chat.id
    ensure_user(chat_id)

    if not context.args or not context.args[0].isdigit():
        await update.message.reply_text("用法：/delkw ID")
        return

    kw_id = int(context.args[0])

    conn = db()
    conn.execute("DELETE FROM keywords WHERE id=? AND chat_id=?", (kw_id, chat_id))
    conn.commit()
    conn.close()

    await update.message.reply_text(f"已删除关键词：{kw_id}")


async def mode(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.effective_chat.id
    ensure_user(chat_id)

    if not context.args or context.args[0] not in ["keyword", "all"]:
        await update.message.reply_text("用法：/mode keyword 或 /mode all")
        return

    m = context.args[0]

    conn = db()
    conn.execute("UPDATE users SET mode=? WHERE chat_id=?", (m, chat_id))
    conn.commit()
    conn.close()

    if m == "keyword":
        await update.message.reply_text("已切换为：只推送关键词命中内容")
    else:
        await update.message.reply_text("已切换为：推送 RSS 全部更新")


async def checknow(update: Update, context: ContextTypes.DEFAULT_TYPE):
    ensure_user(update.effective_chat.id)
    await update.message.reply_text("开始检查 RSS...")
    await check_once(context.application)
    cleanup_old_items()
    await update.message.reply_text("检查完成。")


async def status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.effective_chat.id
    ensure_user(chat_id)
    await update.message.reply_text(status_text(chat_id))


async def menu_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()

    chat_id = query.message.chat_id
    ensure_user(chat_id)

    data = query.data

    if data == "help":
        await query.edit_message_text(help_text(), reply_markup=main_menu())
        return

    if data == "status":
        await query.edit_message_text(status_text(chat_id), reply_markup=main_menu())
        return

    if data == "listrss":
        await query.edit_message_text(rss_list_text(chat_id), reply_markup=main_menu())
        return

    if data == "listkw":
        await query.edit_message_text(kw_list_text(chat_id), reply_markup=main_menu())
        return

    if data == "add_rss_help":
        await query.edit_message_text(
            f"添加 RSS 源请发送：\n\n/addrss {DEFAULT_RSS}\n\n查看 RSS：\n/listrss",
            reply_markup=main_menu()
        )
        return

    if data == "add_kw_help":
        await query.edit_message_text(
            "添加关键词请发送：\n\n/addkw VPS\n/addkw DMIT\n/addkw 甲骨文\n/addkw 优惠\n/addkw 补货\n\n查看关键词：\n/listkw",
            reply_markup=main_menu()
        )
        return

    if data == "mode_keyword":
        conn = db()
        conn.execute("UPDATE users SET mode=? WHERE chat_id=?", ("keyword", chat_id))
        conn.commit()
        conn.close()

        await query.edit_message_text(
            "已切换为：只推送关键词命中内容",
            reply_markup=main_menu()
        )
        return

    if data == "mode_all":
        conn = db()
        conn.execute("UPDATE users SET mode=? WHERE chat_id=?", ("all", chat_id))
        conn.commit()
        conn.close()

        await query.edit_message_text(
            "已切换为：推送 RSS 全部更新",
            reply_markup=main_menu()
        )
        return

    if data == "checknow":
        await query.edit_message_text("开始检查 RSS...")
        await check_once(context.application)
        cleanup_old_items()
        await query.edit_message_text(
            "检查完成。\n\n" + status_text(chat_id),
            reply_markup=main_menu()
        )
        return


async def post_init(app: Application):
    await app.bot.set_my_commands([
        BotCommand("start", "启动 / 查看帮助"),
        BotCommand("menu", "打开按钮菜单"),
        BotCommand("addrss", "添加 RSS 源"),
        BotCommand("listrss", "查看 RSS 源"),
        BotCommand("addkw", "添加关键词"),
        BotCommand("listkw", "查看关键词"),
        BotCommand("mode", "切换推送模式"),
        BotCommand("status", "查看状态"),
        BotCommand("checknow", "立即检查"),
    ])
    app.create_task(scheduler(app))


def main():
    init_db()

    app = Application.builder().token(BOT_TOKEN).post_init(post_init).build()

    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("help", start))
    app.add_handler(CommandHandler("menu", menu))

    app.add_handler(CommandHandler("addrss", addrss))
    app.add_handler(CommandHandler("listrss", listrss))
    app.add_handler(CommandHandler("delrss", delrss))

    app.add_handler(CommandHandler("addkw", addkw))
    app.add_handler(CommandHandler("listkw", listkw))
    app.add_handler(CommandHandler("delkw", delkw))

    app.add_handler(CommandHandler("mode", mode))
    app.add_handler(CommandHandler("status", status))
    app.add_handler(CommandHandler("checknow", checknow))

    app.add_handler(CallbackQueryHandler(menu_callback))

    logging.info("Bot started")
    app.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
PYAPP

echo "==> 创建 .env.example"
cat > .env.example <<'EOF'
BOT_TOKEN=your_telegram_bot_token
CHECK_INTERVAL=120
DEFAULT_RSS=https://rss.nodeseek.com/
DB_PATH=/app/data/bot.db
CLEANUP_DAYS=30
EOF

if [ ! -f ".env" ]; then
  echo "==> 创建 .env"

  if [ -n "${BOT_TOKEN:-}" ]; then
    TOKEN_VALUE="$BOT_TOKEN"
  else
    echo
    echo "请输入 Telegram Bot Token："
    read -r TOKEN_VALUE < /dev/tty
  fi

  cat > .env <<EOF
BOT_TOKEN=${TOKEN_VALUE}
CHECK_INTERVAL=120
DEFAULT_RSS=https://rss.nodeseek.com/
DB_PATH=/app/data/bot.db
CLEANUP_DAYS=30
EOF

  chmod 600 .env
else
  echo "==> 检测到已有 .env，不覆盖"
fi

echo "==> 检查 Python 语法"
if command -v python3 >/dev/null 2>&1; then
  python3 -m py_compile app.py
else
  echo "本机未安装 python3，跳过宿主机语法检查"
fi

echo "==> 构建并启动"
docker compose up -d --build

echo "==> 启动状态"
docker ps | grep rss-keyword-tgbot || true

echo
echo "安装完成"
echo
echo "常用命令："
echo "cd /opt/rss-keyword-tgbot"
echo "docker logs -f --tail=100 rss-keyword-tgbot"
echo "docker restart rss-keyword-tgbot"
echo
echo "Telegram 初始化："
echo "/start"
echo "/addkw 关键词"
echo "/mode keyword"
echo "/status"
echo "/menu"
