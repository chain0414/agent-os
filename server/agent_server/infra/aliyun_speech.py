from __future__ import annotations

import json

import httpx

from agent_server.core.speech import SpeechSettings
from agent_server.services.speech import TemporarySpeechToken


class AliyunSpeechGateway:
    def __init__(self, *, transport: httpx.AsyncBaseTransport | None = None) -> None:
        self._transport = transport

    async def issue(
        self, settings: SpeechSettings, *, ttl_seconds: int
    ) -> TemporarySpeechToken:
        headers = {"Authorization": f"Bearer {settings.api_key}"}
        if settings.workspace_id:
            headers["X-DashScope-WorkSpace"] = settings.workspace_id
        # No ambient proxy credentials, redirects, response-body logging or retries.
        async with (
            httpx.AsyncClient(
                timeout=httpx.Timeout(10.0, connect=5.0),
                follow_redirects=False,
                trust_env=False,
                transport=self._transport,
            ) as client,
            client.stream(
                "POST",
                f"{settings.base_url}/api/v1/tokens",
                params={"expire_in_seconds": ttl_seconds},
                headers=headers,
            ) as response,
        ):
            if response.status_code != 200:
                raise ValueError("temporary credential request failed")
            # Bound the small credential response even for chunked replies.
            body = bytearray()
            async for chunk in response.aiter_bytes():
                body.extend(chunk)
                if len(body) > 65536:
                    raise ValueError("invalid temporary credential response")
            payload = json.loads(body)
            if not isinstance(payload, dict):
                raise TypeError("invalid temporary credential response")
            return TemporarySpeechToken(
                token=payload["token"], expires_at=payload["expires_at"]
            )
