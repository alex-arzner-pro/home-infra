#!/usr/bin/env python3
"""
Telegram bot that forwards messages to a persistent Claude Code session.
Uses claude -p with --continue to maintain context and --dangerously-skip-permissions
for non-interactive tool use. Access restricted to ALLOWED_USER_IDS.
"""

import asyncio
import os
import subprocess
import logging
import tempfile
from pathlib import Path
from telegram import Update
from telegram.ext import Application, MessageHandler, CommandHandler, filters, ContextTypes

# Load env
ENV_FILE = Path.home() / ".secrets" / "telegram.env"
for line in ENV_FILE.read_text().splitlines():
    if "=" in line and not line.startswith("#"):
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip())

TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
ALLOWED_USER_IDS = {609676348}  # Only allow Alex
WORK_DIR = Path.home() / "home-infra"
CLAUDE_TIMEOUT = 1800  # 30 minutes — complex multi-step tasks need time
IMAGES_DIR = Path.home() / ".claude" / "telegram-images"
IMAGES_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

# Lock to prevent concurrent claude calls (only one session at a time)
claude_lock = asyncio.Lock()


async def run_claude(text: str, image_paths: list[str] | None = None) -> str:
    """Run claude with persistent session, tools enabled."""
    cmd = [
        "claude",
        "-p", text,
        "--continue",
        "--dangerously-skip-permissions",
        "--output-format", "text",
    ]

    # Attach images if provided
    if image_paths:
        for path in image_paths:
            cmd.extend(["--add-file", path])

    loop = asyncio.get_event_loop()
    try:
        result = await asyncio.wait_for(
            loop.run_in_executor(
                None,
                lambda: subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=CLAUDE_TIMEOUT,
                    cwd=WORK_DIR,
                ),
            ),
            timeout=CLAUDE_TIMEOUT + 10,
        )
        return result.stdout.strip() or result.stderr.strip() or "(empty response)"
    except (subprocess.TimeoutExpired, asyncio.TimeoutError):
        return "(timeout — claude took too long, 30 min limit)"
    except FileNotFoundError:
        return "(claude not found in PATH)"
    except Exception as e:
        return f"(error: {e})"


async def download_photo(update: Update) -> str | None:
    """Download the largest photo from a message, return local path."""
    photo = update.message.photo[-1]  # largest resolution
    file = await photo.get_file()
    path = IMAGES_DIR / f"{photo.file_unique_id}.jpg"
    await file.download_to_drive(str(path))
    log.info("Downloaded photo: %s (%dx%d)", path, photo.width, photo.height)
    return str(path)


async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user.id not in ALLOWED_USER_IDS:
        return

    text = update.message.text or update.message.caption or ""
    image_paths = []

    if not text and not update.message.photo:
        return

    log.info("From %s: %s", update.effective_user.id, text[:80])

    # Download photo if present
    if update.message.photo:
        path = await download_photo(update)
        if path:
            image_paths.append(path)
            if not text:
                text = "Describe this image"

    async with claude_lock:
        await update.message.chat.send_action("typing")

        # Send typing every 5s while claude works
        response_future = asyncio.ensure_future(run_claude(text, image_paths))
        while not response_future.done():
            await asyncio.sleep(5)
            if not response_future.done():
                await update.message.chat.send_action("typing")

        response = await response_future

    # Telegram message limit is 4096 chars
    for i in range(0, len(response), 4000):
        await update.message.reply_text(response[i:i + 4000])


async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if update.effective_user.id not in ALLOWED_USER_IDS:
        return
    await update.message.reply_text(
        "Claude Code bot ready.\n"
        "Full session with tools and memory.\n"
        "Send text, photos, or photos with captions.\n"
        "/new — start fresh session"
    )


async def cmd_new(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Start a fresh session (drop --continue for next message)."""
    if update.effective_user.id not in ALLOWED_USER_IDS:
        return
    # Clear the resume file so next call starts fresh
    resume_hint = WORK_DIR / ".claude" / ".last-session-id"
    if resume_hint.exists():
        resume_hint.unlink()
    await update.message.reply_text("New session started. Context cleared.")


def main() -> None:
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("new", cmd_new))
    app.add_handler(MessageHandler(filters.PHOTO, handle_message))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))
    log.info("Bot starting (persistent session mode)...")
    app.run_polling(allowed_updates=["message"])


if __name__ == "__main__":
    main()
