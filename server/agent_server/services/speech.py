from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Protocol

from agent_server.core.speech import (
    SPEECH_TOKEN_TTL_SECONDS,
    SpeechCredentialsResponse,
    SpeechSettings,
)


@dataclass(frozen=True, slots=True)
class TemporarySpeechToken:
    token: str = field(repr=False)
    expires_at: int


class SpeechTokenGateway(Protocol):
    async def issue(
        self, settings: SpeechSettings, *, ttl_seconds: int
    ) -> TemporarySpeechToken: ...


class SpeechRateLimitPort(Protocol):
    async def acquire(self, user_id: str) -> int:
        """Return zero when allowed, or a Retry-After delay in seconds."""
        ...


class SpeechError(Exception):
    def __init__(self, code: str, *, retry_after: int | None = None) -> None:
        super().__init__(code)
        self.code = code
        self.retry_after = retry_after


class SpeechCredentialsService:
    def __init__(
        self,
        settings: SpeechSettings | None,
        gateway: SpeechTokenGateway,
        limiter: SpeechRateLimitPort,
    ) -> None:
        self._settings = settings
        self._gateway = gateway
        self._limiter = limiter

    async def issue(self, user_id: str) -> SpeechCredentialsResponse:
        settings = self._settings
        if settings is None:
            raise SpeechError("speech_unavailable")
        try:
            retry_after = await self._limiter.acquire(user_id)
        except Exception:  # noqa: BLE001 - discard potentially sensitive adapter exceptions
            # Do not bypass the distributed limit when coordination fails.
            raise SpeechError("speech_unavailable") from None
        if retry_after:
            raise SpeechError("speech_rate_limited", retry_after=retry_after)
        issued_at = time.time()
        try:
            issued = await self._gateway.issue(
                settings, ttl_seconds=SPEECH_TOKEN_TTL_SECONDS
            )
            if (
                not isinstance(issued.token, str)
                or not issued.token
                or len(issued.token) > 8192
                or issued.token == settings.api_key
                or any(not 33 <= ord(char) <= 126 for char in issued.token)
                or type(issued.expires_at) is not int
                or issued.expires_at <= time.time()
                or issued.expires_at > issued_at + SPEECH_TOKEN_TTL_SECONDS + 5
            ):
                raise ValueError("invalid temporary credential")
            return SpeechCredentialsResponse(
                model=settings.model,
                websocketUrl=settings.websocket_url,
                token=issued.token,
                expiresAt=issued.expires_at,
            )
        except Exception:  # noqa: BLE001 - discard potentially sensitive upstream exceptions
            # The gateway exception may include request headers or response bodies.
            # Deliberately discard it instead of logging it or chaining it.
            raise SpeechError("speech_credentials_failed") from None
