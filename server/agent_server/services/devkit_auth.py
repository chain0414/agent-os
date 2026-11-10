"""Verify a DevKit Project Auth session before issuing an Agent OS session."""

from __future__ import annotations

import hashlib
import json
import os
from datetime import datetime
from urllib.parse import urlsplit

import httpx
from pydantic import (
    AwareDatetime,
    BaseModel,
    ConfigDict,
    Field,
    ValidationError,
    field_validator,
)

_MAX_METADATA_BYTES = 16_384
_transport: httpx.AsyncBaseTransport | None = None


class DevKitSessionRejected(ValueError):
    pass


class DevKitAuthUnavailable(RuntimeError):
    pass


class AuthScope(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, hide_input_in_errors=True)

    projectId: str = Field(min_length=1, max_length=512)
    environmentId: str = Field(min_length=1, max_length=512)
    realmId: str = Field(min_length=1, max_length=512)
    issuer: str = Field(min_length=1, max_length=512)
    audience: str = Field(min_length=1, max_length=512)


class DevKitAuthConfig(AuthScope):
    apiUrl: str
    appOrigin: str
    publishableKey: str = Field(pattern=r"^[!-~]{1,512}$")

    @field_validator("apiUrl", "appOrigin")
    @classmethod
    def validate_origin(cls, value: str) -> str:
        parsed = urlsplit(value)
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or value != f"https://{parsed.netloc}"
            or any(character.isspace() or character == "\\" for character in value)
        ):
            raise ValueError("Expected an HTTPS origin")
        return value

    def scope(self) -> dict[str, str]:
        return self.model_dump(include=set(AuthScope.model_fields))

    def binding_scope(self) -> str:
        scope = json.dumps(self.scope(), sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(scope.encode()).hexdigest()


class SessionMetadata(AuthScope):
    version: int
    subject: str = Field(pattern=r"^[!-~]{1,512}$")
    sessionId: str = Field(pattern=r"^[!-~]{1,512}$")
    sessionExpiresAt: AwareDatetime


def load_devkit_auth() -> DevKitAuthConfig | None:
    value = os.environ.get("AGENT_SERVER_DEVKIT_AUTH")
    if not value:
        return None
    try:
        return DevKitAuthConfig.model_validate_json(value)
    except ValidationError:
        raise DevKitAuthUnavailable from None


async def verify_devkit_session(config: DevKitAuthConfig, access_token: str) -> str:
    try:
        async with httpx.AsyncClient(
            timeout=10, follow_redirects=False, trust_env=False, transport=_transport,
        ) as client, client.stream(
            "GET",
            config.apiUrl + "/api/runtime/v1/auth/session-metadata",
            headers={
                "Accept": "application/json",
                "Origin": config.appOrigin,
                "X-DevKit-Key": config.publishableKey,
                "Authorization": f"Bearer {access_token}",
            },
        ) as response:
            if response.status_code in {401, 403}:
                raise DevKitSessionRejected
            if response.status_code != 200:
                raise DevKitAuthUnavailable
            body = bytearray()
            async for chunk in response.aiter_bytes():
                if len(body) + len(chunk) > _MAX_METADATA_BYTES:
                    raise DevKitAuthUnavailable
                body.extend(chunk)
        metadata = SessionMetadata.model_validate_json(body)
    except (httpx.HTTPError, ValidationError):
        raise DevKitAuthUnavailable from None

    if (
        metadata.version != 1
        or metadata.model_dump(include=set(AuthScope.model_fields)) != config.scope()
        or metadata.sessionExpiresAt <= datetime.now(metadata.sessionExpiresAt.tzinfo)
    ):
        raise DevKitSessionRejected
    return metadata.subject
