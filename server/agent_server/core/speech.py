from __future__ import annotations

import json
import os
import re
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, Field

SPEECH_MODEL = "qwen-audio-3.0-asr-flash-streaming"
SPEECH_TOKEN_TTL_SECONDS = 300
_OFFICIAL_HOST = re.compile(
    r"(?:dashscope(?:-intl)?\.aliyuncs\.com|"
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\."
    r"(?:cn-beijing|ap-southeast-1)\.maas\.aliyuncs\.com)"
)


@dataclass(frozen=True, slots=True)
class SpeechSettings:
    api_key: str = field(repr=False)
    base_url: str
    workspace_id: str | None = None
    model: str = SPEECH_MODEL

    @property
    def websocket_url(self) -> str:
        return f"wss://{urlsplit(self.base_url).netloc}/api-ws/v1/inference"


class SpeechCredentialsResponse(BaseModel):
    provider: Literal["aliyun"] = "aliyun"
    model: str
    websocketUrl: str
    token: str = Field(repr=False)
    expiresAt: int
    languageHints: list[str] = Field(default_factory=lambda: ["zh", "en"])
    sampleRate: int = 16000
    maxRecordingSeconds: int = 300


def _safe_header(value: object) -> bool:
    return (
        isinstance(value, str)
        and bool(value)
        and all(33 <= ord(char) <= 126 for char in value)
    )


def load_speech_settings(
    environ: Mapping[str, str] | None = None,
) -> SpeechSettings | None:
    """Read only an explicitly selected config; malformed settings disable speech.

    Never propagate parsing errors: a config path, JSON or invalid URL can
    contain credentials. No other subsystem depends on speech configuration.
    """
    source = os.environ if environ is None else environ
    try:
        values: dict[str, object] = {}
        config_path = source.get("AGENT_SERVER_ASR_CONFIG_FILE")
        if config_path:
            with Path(config_path).open("r", encoding="utf-8") as config:
                # A config is small; reject oversized files without reading them whole.
                contents = config.read(65537)
            if len(contents) > 65536:
                return None
            decoded = json.loads(contents)
            if not isinstance(decoded, dict):
                return None
            values = {
                key: decoded.get(key) for key in ("api_key", "base_url", "workspace_id")
            }
        api_key = source.get("AGENT_SERVER_ASR_API_KEY", values.get("api_key"))
        base_url = source.get(
            "AGENT_SERVER_ASR_BASE_URL",
            values.get("base_url") or "https://dashscope.aliyuncs.com",
        )
        workspace_id = source.get(
            "AGENT_SERVER_ASR_WORKSPACE_ID", values.get("workspace_id")
        )
        model = source.get("AGENT_SERVER_ASR_MODEL", SPEECH_MODEL)
        if (
            not _safe_header(api_key)
            or model != SPEECH_MODEL
            or not isinstance(base_url, str)
        ):
            return None
        if workspace_id is not None and not _safe_header(workspace_id):
            return None
        # urlsplit normalizes some controls; reject them before parsing.
        if (
            not base_url.isascii()
            or any(ord(char) <= 32 for char in base_url)
            or "\\" in base_url
        ):
            return None
        parsed = urlsplit(base_url)
        if (
            parsed.scheme != "https"
            or parsed.username is not None
            or parsed.password is not None
            or parsed.port not in (None, 443)
            or parsed.query
            or parsed.fragment
            or "?" in base_url
            or "#" in base_url
            or not _OFFICIAL_HOST.fullmatch(parsed.hostname or "")
            or parsed.path.rstrip("/") not in ("", "/compatible-mode/v1", "/api/v1")
        ):
            return None
        return SpeechSettings(
            api_key=api_key,
            base_url=f"https://{parsed.hostname}",
            workspace_id=workspace_id,
        )
    except (OSError, ValueError, TypeError, RecursionError):
        return None
