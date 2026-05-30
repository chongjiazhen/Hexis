"""
Hexis Channel System - Telegram Adapter

Connects to Telegram via bot token using python-telegram-bot.
Uses long-polling mode (works behind NAT, no webhook setup needed).
"""

from __future__ import annotations

import asyncio
import logging
import os
import random
import re
from typing import Any, Callable, Awaitable

from .base import ChannelAdapter, ChannelCapabilities, ChannelMessage, parse_allowlist, resolve_channel_token
from .media import Attachment

logger = logging.getLogger(__name__)


def _resolve_token(config: dict[str, Any]) -> str | None:
    """Resolve Telegram bot token from config (env var name) or environment."""
    return resolve_channel_token(config, "bot_token", "TELEGRAM_BOT_TOKEN")


_FENCE_LANG_RE = re.compile(r"^```[A-Za-z0-9_+\-]+\s*$", re.MULTILINE)

# MarkdownV2 specials per Telegram Bot API docs:
# https://core.telegram.org/bots/api#markdownv2-style
# In normal text context, all of these must be backslash-escaped unless they
# form a recognized formatting construct (bold *...*, italic _..._, inline
# code `...`, fenced code ```...```, link [text](url)).
_MDV2_SPECIALS = r"_*[]()~`>#+-=|{}.!\\"
# Pre-built translation table for fast text-context escaping.
_MDV2_TEXT_ESCAPE = str.maketrans({c: "\\" + c for c in _MDV2_SPECIALS})

# Inside inline code and fenced code, only ` and \ need escaping.
_MDV2_CODE_ESCAPE = str.maketrans({"`": "\\`", "\\": "\\\\"})

# Inside the URL portion of a link, only ) and \ need escaping per the
# MarkdownV2 spec (other specials within the URL are interpreted literally
# by Telegram once the link form is recognized).
_MDV2_URL_ESCAPE = str.maketrans({")": "\\)", "\\": "\\\\"})


def _escape_text(text: str) -> str:
    """Escape every MarkdownV2 special in a plain-text run."""
    return text.translate(_MDV2_TEXT_ESCAPE)


def _escape_code(text: str) -> str:
    """Escape only ` and \\ inside code spans / fenced blocks."""
    return text.translate(_MDV2_CODE_ESCAPE)


def _escape_url(url: str) -> str:
    """Escape only ) and \\ inside a MarkdownV2 link URL."""
    return url.translate(_MDV2_URL_ESCAPE)


# Tokenizer: walk the input and recognize a small set of intentional Markdown
# constructs. Anything we cannot match cleanly becomes a literal text token so
# the escape step makes it safe — guaranteeing no MarkdownV2 parse error from
# malformed model output (lone *, lone `, unbalanced markers, etc.).
#
# Token kinds:
#   ("text", content)         — escape-all-specials
#   ("inline_code", content)  — wrap in `...`, escape ` and \ inside
#   ("fenced_code", content)  — wrap in ```...```, escape ` and \ inside,
#                               language hint already stripped at parse time
#   ("bold", content)         — wrap in *...*, content re-tokenized as text-only
#   ("italic", content)       — wrap in _..._, content re-tokenized as text-only
#   ("link", (label, url))    — wrap as [label](url); label escaped as text,
#                               url escaped per URL rules
_FENCED_OPEN_RE = re.compile(r"```([A-Za-z0-9_+\-]*)\n?")
_LINK_RE = re.compile(r"\[([^\[\]\n]*)\]\(([^()\s]+)\)")


def _tokenize_for_mdv2(text: str) -> list[tuple]:
    """Tokenize text into a flat list of MarkdownV2 tokens.

    Tokenization is intentionally simple and forgiving: anything that doesn't
    cleanly match a recognized construct (fenced code, inline code, bold,
    italic, link) is emitted as a literal text token.
    """
    tokens: list[tuple] = []
    i = 0
    n = len(text)
    buf: list[str] = []

    def flush_text() -> None:
        if buf:
            tokens.append(("text", "".join(buf)))
            buf.clear()

    while i < n:
        ch = text[i]

        # Fenced code block: ```[lang]\n...\n```
        if text.startswith("```", i):
            open_match = _FENCED_OPEN_RE.match(text, i)
            if open_match:
                close_idx = text.find("```", open_match.end())
                if close_idx != -1:
                    inner = text[open_match.end():close_idx]
                    # Trim a single trailing newline so the closing fence
                    # renders cleanly. Language hint already discarded by
                    # the regex capture group (we never re-emit it).
                    if inner.endswith("\n"):
                        inner = inner[:-1]
                    flush_text()
                    tokens.append(("fenced_code", inner))
                    i = close_idx + 3
                    continue
            # Unterminated fence: treat the ``` as literal text.
            buf.append(ch)
            i += 1
            continue

        # Blockquote: a line beginning with '>' (optionally '> '). MarkdownV2
        # renders consecutive '>'-prefixed lines as one quote block; the leading
        # '>' must stay UNescaped while line content is escaped/inline-parsed
        # normally. Only triggers at line start so mid-line '>' still escapes.
        if ch == ">" and (i == 0 or text[i - 1] == "\n"):
            j = i + 1
            if j < n and text[j] == " ":
                j += 1
            eol = text.find("\n", j)
            if eol == -1:
                eol = n
            flush_text()
            tokens.append(("blockquote", text[j:eol]))
            i = eol  # leave the newline as text to preserve the line break
            continue

        # Inline code: `...` (single backtick, no newline inside)
        if ch == "`":
            close_idx = text.find("`", i + 1)
            if close_idx != -1 and "\n" not in text[i + 1:close_idx]:
                inner = text[i + 1:close_idx]
                flush_text()
                tokens.append(("inline_code", inner))
                i = close_idx + 1
                continue
            # Lone backtick: literal.
            buf.append(ch)
            i += 1
            continue

        # Link: [label](url)
        if ch == "[":
            link_match = _LINK_RE.match(text, i)
            if link_match:
                label = link_match.group(1)
                url = link_match.group(2)
                flush_text()
                tokens.append(("link", (label, url)))
                i = link_match.end()
                continue
            buf.append(ch)
            i += 1
            continue

        # Bold (CommonMark **...**): models overwhelmingly emit double-asterisk
        # bold, but Telegram MarkdownV2 bold is a SINGLE *. Convert a clean
        # **...** pair (inline, non-empty) to a bold token so it renders instead
        # of leaking literal asterisks. Checked before the single-* case so the
        # pair is consumed as one unit.
        if text.startswith("**", i):
            close_idx = text.find("**", i + 2)
            if (
                close_idx != -1
                and close_idx > i + 2
                and "\n" not in text[i + 2:close_idx]
            ):
                inner = text[i + 2:close_idx]
                flush_text()
                tokens.append(("bold", inner))
                i = close_idx + 2
                continue
            # Not a clean ** pair: fall through to single-* / literal handling.

        # Bold: *...* — paired single asterisks, no newline inside, non-empty
        # content. We require the closing * to NOT be immediately followed by
        # another * (so we don't eat ** runs as malformed bold).
        if ch == "*":
            close_idx = text.find("*", i + 1)
            if (
                close_idx != -1
                and close_idx > i + 1
                and "\n" not in text[i + 1:close_idx]
            ):
                inner = text[i + 1:close_idx]
                flush_text()
                tokens.append(("bold", inner))
                i = close_idx + 1
                continue
            buf.append(ch)
            i += 1
            continue

        # Italic: _..._ — paired single underscores, no newline, non-empty.
        if ch == "_":
            close_idx = text.find("_", i + 1)
            if (
                close_idx != -1
                and close_idx > i + 1
                and "\n" not in text[i + 1:close_idx]
            ):
                inner = text[i + 1:close_idx]
                flush_text()
                tokens.append(("italic", inner))
                i = close_idx + 1
                continue
            buf.append(ch)
            i += 1
            continue

        buf.append(ch)
        i += 1

    flush_text()
    return tokens


def _render_tokens_mdv2(tokens: list[tuple]) -> str:
    """Render a token list to MarkdownV2-safe text."""
    out: list[str] = []
    for tok in tokens:
        kind = tok[0]
        if kind == "text":
            out.append(_escape_text(tok[1]))
        elif kind == "inline_code":
            out.append("`" + _escape_code(tok[1]) + "`")
        elif kind == "fenced_code":
            # Always emit bare fences (no language hint) — matches the prior
            # legacy-Markdown sanitizer behavior and keeps Telegram happy.
            out.append("```\n" + _escape_code(tok[1]) + "\n```")
        elif kind == "blockquote":
            # Leading '>' is the literal MarkdownV2 quote marker (unescaped);
            # the line content is re-tokenized so inline markup still renders.
            inner_tokens = _tokenize_for_mdv2(tok[1])
            out.append(">" + _render_tokens_mdv2(inner_tokens))
        elif kind == "bold":
            inner_tokens = _tokenize_for_mdv2(tok[1])
            out.append("*" + _render_tokens_mdv2(inner_tokens) + "*")
        elif kind == "italic":
            inner_tokens = _tokenize_for_mdv2(tok[1])
            out.append("_" + _render_tokens_mdv2(inner_tokens) + "_")
        elif kind == "link":
            label, url = tok[1]
            label_tokens = _tokenize_for_mdv2(label)
            out.append(
                "[" + _render_tokens_mdv2(label_tokens) + "](" + _escape_url(url) + ")"
            )
        else:  # pragma: no cover — defensive
            out.append(_escape_text(str(tok[1])))
    return "".join(out)


def _escape_for_markdown_v2(text: str) -> str:
    """Convert arbitrary model output into MarkdownV2-safe text.

    Preserves intentional formatting (bold, italic, inline code, fenced code,
    links). Escapes every other MarkdownV2 special so malformed model output
    (lone `*`, stray `_`, unbalanced backticks, etc.) cannot cause a parse
    error on Telegram's side.
    """
    if not text:
        return text
    return _render_tokens_mdv2(_tokenize_for_mdv2(text))


def _sanitize_for_telegram_markdown(text: str) -> str:
    """Backwards-compat shim — delegates to MarkdownV2 escaper.

    Kept so any external caller (or future re-introduction of the legacy
    `Markdown` parse_mode for fallback) sees the same name.
    """
    return _escape_for_markdown_v2(text)


class TelegramAdapter(ChannelAdapter):
    """
    Telegram channel adapter using python-telegram-bot.

    Config keys (from DB config table):
        channel.telegram.bot_token: env var name holding the bot token
        channel.telegram.allowed_chat_ids: JSON array of chat IDs, or "*"
        channel.telegram.ambient_reply_chance: float 0.0-1.0 (default 0.0).
            Probability that the bot replies to a non-@mention message in an
            allowed group. 0.0 = mention-only, 1.0 = always reply.

    The bot responds to:
        - Private messages (always)
        - Group messages where the bot is mentioned (@botname) (always)
        - Group messages in allowed chats:
            * always when mentioned
            * with probability ambient_reply_chance otherwise
        - Group messages NOT in allowlist: only when mentioned
    """

    def __init__(self, config: dict[str, Any] | None = None) -> None:
        self._config = config or {}
        self._application = None
        self._on_message: Callable[[ChannelMessage], Awaitable[None]] | None = None
        self._connected = False
        self._bot_username: str | None = None
        self._allowed_chat_ids = self._parse_allowlist(self._config.get("allowed_chat_ids"))
        try:
            self._ambient_reply_chance = float(self._config.get("ambient_reply_chance") or 0.0)
        except (TypeError, ValueError):
            self._ambient_reply_chance = 0.0
        self._ambient_reply_chance = max(0.0, min(1.0, self._ambient_reply_chance))

    @staticmethod
    def _parse_allowlist(value: Any) -> set[str] | None:
        """Parse an allowlist value. Returns None for '*' (allow all)."""
        return parse_allowlist(value)

    @property
    def channel_type(self) -> str:
        return "telegram"

    @property
    def capabilities(self) -> ChannelCapabilities:
        return ChannelCapabilities(
            threads=True,  # Telegram forum topics = threads
            reactions=True,
            media=True,
            typing_indicator=True,
            edit_message=True,
            max_message_length=4096,
        )

    @property
    def is_connected(self) -> bool:
        return self._connected

    async def start(
        self,
        on_message: Callable[[ChannelMessage], Awaitable[None]],
    ) -> None:
        try:
            from telegram import Update
            from telegram.ext import (
                Application,
                MessageHandler,
                filters,
            )
        except ImportError:
            raise RuntimeError(
                "python-telegram-bot is required for the Telegram adapter. "
                "Install it with: pip install python-telegram-bot"
            )

        token = _resolve_token(self._config)
        if not token:
            raise RuntimeError(
                "Telegram bot token not found. Set TELEGRAM_BOT_TOKEN env var "
                "or configure channel.telegram.bot_token in the database."
            )

        self._on_message = on_message

        application = Application.builder().token(token).build()
        self._application = application

        # Register message handler
        async def handle_message(update: Update, context) -> None:
            await self._handle_telegram_message(update)

        application.add_handler(
            MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message)
        )

        # Get bot info
        await application.initialize()
        bot_info = await application.bot.get_me()
        self._bot_username = bot_info.username
        self._connected = True
        logger.info(
            "Telegram connected as @%s (ID: %s)",
            bot_info.username,
            bot_info.id,
        )

        try:
            # Start polling (blocking)
            await application.start()
            await application.updater.start_polling(
                # Keep queued updates across restarts: channel workers are
                # bounced routinely (model swaps, deploys, power-mode flips).
                # Dropping pending updates silently loses any user message
                # that arrived during the restart window.
                drop_pending_updates=False,
                allowed_updates=["message"],
            )

            # Keep running until cancelled
            while self._connected:
                await asyncio.sleep(1)

        except asyncio.CancelledError:
            pass
        finally:
            self._connected = False
            try:
                if application.updater and application.updater.running:
                    await application.updater.stop()
                if application.running:
                    await application.stop()
                await application.shutdown()
            except Exception:
                logger.debug("Telegram shutdown warning", exc_info=True)

    async def _handle_telegram_message(self, update) -> None:
        """Filter and normalize a Telegram message."""
        if not update.message:
            return

        message = update.message
        chat = message.chat
        user = message.from_user

        if not user:
            return

        # Accept text, photos, or documents
        has_text = bool(message.text or message.caption)
        has_media = bool(message.photo or message.document)
        if not has_text and not has_media:
            return

        is_private = chat.type == "private"
        raw_text = message.text or message.caption or ""

        if not is_private:
            mention_tag = f"@{self._bot_username}" if self._bot_username else None
            mentioned = bool(mention_tag and mention_tag in raw_text)
            allowed_here = (
                self._allowed_chat_ids is None
                or str(chat.id) in self._allowed_chat_ids
            )
            if not allowed_here:
                # Chat not on allowlist: only respond when mentioned.
                if not mentioned:
                    return
            elif not mentioned:
                # Chat on allowlist, no mention: roll for ambient reply.
                if self._ambient_reply_chance <= 0.0:
                    return
                if random.random() >= self._ambient_reply_chance:
                    return

        # Strip bot mention from content
        content = raw_text
        if self._bot_username:
            content = content.replace(f"@{self._bot_username}", "").strip()

        if not content and not has_media:
            return

        # Convert Telegram attachments to Attachment instances
        attachments: list[Attachment] = []
        if message.photo:
            # Telegram provides multiple sizes; pick the largest
            photo = message.photo[-1]
            attachments.append(Attachment(
                url="",  # Telegram requires bot.get_file() to get the URL
                filename=f"photo_{photo.file_unique_id}.jpg",
                mime_type="image/jpeg",
                size=photo.file_size,
                platform_id=photo.file_id,
            ))
        if message.document:
            doc = message.document
            attachments.append(Attachment(
                url="",
                filename=doc.file_name or f"doc_{doc.file_unique_id}",
                mime_type=doc.mime_type,
                size=doc.file_size,
                platform_id=doc.file_id,
            ))

        sender_name = user.full_name or user.username or str(user.id)

        # Extract forum topic ID if available (I.1: Telegram topic support)
        topic_id = None
        if hasattr(message, "message_thread_id") and message.message_thread_id:
            topic_id = str(message.message_thread_id)

        channel_msg = ChannelMessage(
            channel_type="telegram",
            channel_id=str(chat.id),
            sender_id=str(user.id),
            sender_name=sender_name,
            content=content or "",
            message_id=str(message.message_id),
            reply_to_id=str(message.reply_to_message.message_id) if message.reply_to_message else None,
            thread_id=topic_id,
            attachments=attachments,
            metadata={
                "chat_type": chat.type,
                "is_private": is_private,
                "username": user.username,
                "topic_id": topic_id,
                "is_topic_message": getattr(message, "is_topic_message", False),
            },
        )

        if self._on_message:
            await self._on_message(channel_msg)

    async def stop(self) -> None:
        self._connected = False
        if self._application:
            try:
                if self._application.updater and self._application.updater.running:
                    await self._application.updater.stop()
                if self._application.running:
                    await self._application.stop()
                await self._application.shutdown()
            except Exception:
                logger.debug("Telegram stop warning", exc_info=True)
            self._application = None

    async def send(
        self,
        channel_id: str,
        text: str,
        *,
        reply_to: str | None = None,
        thread_id: str | None = None,
    ) -> str | None:
        if not self._application or not self._application.bot:
            logger.error("Telegram bot not connected")
            return None

        try:
            kwargs: dict[str, Any] = {
                "chat_id": int(channel_id),
                "text": _escape_for_markdown_v2(text),
                "parse_mode": "MarkdownV2",
            }
            if reply_to:
                kwargs["reply_to_message_id"] = int(reply_to)
            # I.1: Telegram forum topic support — route to specific topic
            if thread_id:
                kwargs["message_thread_id"] = int(thread_id)

            sent = await self._application.bot.send_message(**kwargs)
            return str(sent.message_id)

        except Exception:
            # Retry without parse_mode in case of parse errors. Log the original
            # parse error so the regression class (which char, which fence, etc.)
            # is diagnosable instead of silently degrading to plain text.
            logger.warning(
                "Telegram MarkdownV2 parse failed for %s, retrying plain-text",
                channel_id,
                exc_info=True,
            )
            try:
                kwargs.pop("parse_mode", None)
                kwargs["text"] = text  # raw, un-sanitized for plain-text retry
                sent = await self._application.bot.send_message(**kwargs)
                return str(sent.message_id)
            except Exception:
                logger.exception("Failed to send Telegram message to %s", channel_id)
                return None

    async def send_typing(self, channel_id: str) -> None:
        if not self._application or not self._application.bot:
            return
        try:
            await self._application.bot.send_chat_action(
                chat_id=int(channel_id),
                action="typing",
            )
        except Exception:
            logger.debug("Silent exception in TelegramAdapter", exc_info=True)

    async def edit_message(
        self, channel_id: str, message_id: str, text: str,
    ) -> bool:
        if not self._application or not self._application.bot:
            return False
        try:
            await self._application.bot.edit_message_text(
                chat_id=int(channel_id),
                message_id=int(message_id),
                text=_escape_for_markdown_v2(text),
                parse_mode="MarkdownV2",
            )
            return True
        except Exception as e:
            # Telegram returns BadRequest "Message is not modified" when the
            # new content matches what's already rendered. Streaming senders
            # commonly fire a final edit identical to the last chunk — treat
            # as a successful no-op. Falling through to the plain-text retry
            # would replace the MarkdownV2-rendered message (which differs
            # textually from the raw input) with raw text, destroying code
            # formatting the user already sees correctly.
            if "Message is not modified" in str(e):
                return True
            # Retry without parse_mode. Log so MarkdownV2-escape regressions
            # are diagnosable instead of silently degrading to plain text.
            logger.warning(
                "Telegram MarkdownV2 edit_message parse failed for %s, retrying plain-text",
                channel_id,
                exc_info=True,
            )
            try:
                await self._application.bot.edit_message_text(
                    chat_id=int(channel_id),
                    message_id=int(message_id),
                    text=text,
                )
                return True
            except Exception:
                logger.exception("Failed to edit Telegram message %s", message_id)
                return False

    async def send_media(
        self,
        channel_id: str,
        attachment: "Attachment",
        caption: str | None = None,
        *,
        reply_to: str | None = None,
    ) -> str | None:
        """G.3: Send media attachments (images, documents) via Telegram."""
        if not self._application or not self._application.bot:
            return None

        try:
            kwargs: dict[str, Any] = {
                "chat_id": int(channel_id),
            }
            if caption:
                kwargs["caption"] = caption[:1024]
            if reply_to:
                kwargs["reply_to_message_id"] = int(reply_to)

            mime = attachment.mime_type or ""

            if mime.startswith("image/"):
                # Send as photo
                if attachment.local_path:
                    kwargs["photo"] = attachment.local_path
                elif attachment.url:
                    kwargs["photo"] = attachment.url
                elif attachment.platform_id:
                    kwargs["photo"] = attachment.platform_id
                else:
                    return None
                sent = await self._application.bot.send_photo(**kwargs)
            elif mime.startswith("video/"):
                if attachment.local_path:
                    kwargs["video"] = attachment.local_path
                elif attachment.url:
                    kwargs["video"] = attachment.url
                elif attachment.platform_id:
                    kwargs["video"] = attachment.platform_id
                else:
                    return None
                sent = await self._application.bot.send_video(**kwargs)
            elif mime.startswith("audio/"):
                if attachment.local_path:
                    kwargs["audio"] = attachment.local_path
                elif attachment.url:
                    kwargs["audio"] = attachment.url
                elif attachment.platform_id:
                    kwargs["audio"] = attachment.platform_id
                else:
                    return None
                sent = await self._application.bot.send_audio(**kwargs)
            else:
                # Send as document
                if attachment.local_path:
                    kwargs["document"] = attachment.local_path
                elif attachment.url:
                    kwargs["document"] = attachment.url
                elif attachment.platform_id:
                    kwargs["document"] = attachment.platform_id
                else:
                    return None
                sent = await self._application.bot.send_document(**kwargs)

            return str(sent.message_id)

        except Exception:
            logger.exception("Failed to send media to Telegram %s", channel_id)
            return None
