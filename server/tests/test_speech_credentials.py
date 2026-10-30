from __future__ import annotations

import asyncio
import json
import time

import httpx
import pytest
from fakeredis import FakeServer
from fakeredis.aioredis import FakeRedis
from fastapi import FastAPI
from fastapi.testclient import TestClient

from agent_server.api import speech
from agent_server.core.auth import create_user_access_token
from agent_server.core.models import UserView
from agent_server.core.speech import SpeechSettings, load_speech_settings
from agent_server.deps import get_store
from agent_server.infra.aliyun_speech import AliyunSpeechGateway
from agent_server.infra.redis_coordinator import RedisCoordinator
from agent_server.infra.speech_rate_limit import SpeechRateLimiter
from agent_server.services.speech import SpeechCredentialsService

PERMANENT_KEY = "synthetic-permanent-key"
TEMPORARY_KEY = "synthetic-temporary-key"


def settings(**overrides: str) -> SpeechSettings:
    configured = load_speech_settings(
        {"AGENT_SERVER_ASR_API_KEY": PERMANENT_KEY, **overrides}
    )
    assert configured is not None
    return configured


def client_for(handler=None, *, configured=True, disabled=False):
    requests = []

    def upstream(request):
        requests.append(request)
        if handler is not None:
            return handler(request)
        return httpx.Response(
            200, json={"token": TEMPORARY_KEY, "expires_at": int(time.time()) + 300}
        )

    app = FastAPI()
    app.include_router(speech.router, prefix="/api/v2")
    app.state.speech_credentials = SpeechCredentialsService(
        settings() if configured else None,
        AliyunSpeechGateway(transport=httpx.MockTransport(upstream)),
        SpeechRateLimiter(RedisCoordinator()),
    )

    class Users:
        async def get_user(self, user_id):
            if user_id == "deleted":
                raise KeyError(user_id)
            return UserView(
                userId=user_id,
                role="member",
                disabled=disabled,
                createdAt="",
                updatedAt="",
            )

    app.dependency_overrides[get_store] = lambda: Users()
    return TestClient(app), requests


def auth(user_id="user-1"):
    return {"Authorization": f"Bearer {create_user_access_token(user_id)}"}


def test_credentials_require_current_active_user():
    client, requests = client_for()
    assert client.post("/api/v2/speech/credentials").status_code == 401
    assert (
        client.post("/api/v2/speech/credentials", headers=auth("deleted")).status_code
        == 401
    )
    disabled_client, _ = client_for(disabled=True)
    assert (
        disabled_client.post("/api/v2/speech/credentials", headers=auth()).status_code
        == 403
    )
    assert requests == []


def test_credentials_contract_and_upstream_ttl():
    client, requests = client_for()
    response = client.post("/api/v2/speech/credentials", headers=auth())
    assert response.status_code == 200
    result = response.json()
    assert result == {
        "provider": "aliyun",
        "model": "qwen-audio-3.0-asr-flash-streaming",
        "websocketUrl": "wss://dashscope.aliyuncs.com/api-ws/v1/inference",
        "token": TEMPORARY_KEY,
        "expiresAt": result["expiresAt"],
        "languageHints": ["zh", "en"],
        "sampleRate": 16000,
        "maxRecordingSeconds": 300,
    }
    assert 290 <= result["expiresAt"] - time.time() <= 300
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["pragma"] == "no-cache"
    assert len(requests) == 1
    assert (
        str(requests[0].url)
        == "https://dashscope.aliyuncs.com/api/v1/tokens?expire_in_seconds=300"
    )
    assert requests[0].headers["Authorization"] == f"Bearer {PERMANENT_KEY}"
    assert requests[0].extensions["timeout"] == {
        "connect": 5.0,
        "read": 10.0,
        "write": 10.0,
        "pool": 10.0,
    }
    assert PERMANENT_KEY not in response.text


def test_unconfigured_feature_and_rate_limit_are_safe():
    client, requests = client_for(configured=False)
    response = client.post("/api/v2/speech/credentials", headers=auth())
    assert response.status_code == 503
    assert response.json()["detail"]["code"] == "speech_unavailable"
    assert requests == []
    client, requests = client_for()
    for _ in range(10):
        assert (
            client.post("/api/v2/speech/credentials", headers=auth()).status_code == 200
        )
    response = client.post("/api/v2/speech/credentials", headers=auth())
    assert response.status_code == 429
    assert response.json()["detail"]["code"] == "speech_rate_limited"
    assert 1 <= int(response.headers["Retry-After"]) <= 60
    assert response.headers["cache-control"] == "no-store"
    assert len(requests) == 10
    assert (
        client.post("/api/v2/speech/credentials", headers=auth("user-2")).status_code
        == 200
    )


@pytest.mark.parametrize(
    "payload",
    [
        {"model": "untrusted"},
        {"base_url": "https://evil.test"},
        {"api_key": "untrusted"},
    ],
)
def test_client_cannot_supply_upstream_settings(payload):
    client, requests = client_for()
    assert (
        client.post(
            "/api/v2/speech/credentials", headers=auth(), json=payload
        ).status_code
        == 400
    )
    assert (
        client.post(
            "/api/v2/speech/credentials?model=untrusted", headers=auth()
        ).status_code
        == 400
    )
    assert requests == []


@pytest.mark.parametrize(
    "payload",
    [
        {},
        {"token": "", "expires_at": 9999999999},
        {"token": TEMPORARY_KEY, "expires_at": 1},
        {"token": TEMPORARY_KEY, "expires_at": 9999999999},
        {"token": TEMPORARY_KEY, "expires_at": True},
        {"token": TEMPORARY_KEY, "expires_at": "9999999999"},
        {"token": PERMANENT_KEY, "expires_at": 1},
    ],
)
def test_upstream_invalid_token_and_expiry_fail_closed(payload):
    client, _ = client_for(lambda _: httpx.Response(200, json=payload))
    response = client.post("/api/v2/speech/credentials", headers=auth())
    assert response.status_code == 502
    assert response.json()["detail"]["code"] == "speech_credentials_failed"
    assert PERMANENT_KEY not in response.text
    assert TEMPORARY_KEY not in response.text


@pytest.mark.parametrize("status", [301, 400, 401, 429, 500])
def test_upstream_errors_never_expose_response_or_follow_redirects(status, caplog):
    client, requests = client_for(
        lambda _: httpx.Response(
            status,
            text=f"secret {PERMANENT_KEY} {TEMPORARY_KEY}",
            headers={"Location": "https://evil.test"},
        )
    )
    response = client.post("/api/v2/speech/credentials", headers=auth())
    assert response.status_code == 502
    assert len(requests) == 1
    for secret in (PERMANENT_KEY, TEMPORARY_KEY):
        assert secret not in response.text
        assert secret not in caplog.text


def test_upstream_transport_exceptions_are_sanitized(caplog):
    def failure(request):
        raise httpx.ReadTimeout(f"secret {PERMANENT_KEY}", request=request)

    client, _ = client_for(failure)
    response = client.post("/api/v2/speech/credentials", headers=auth())
    assert response.status_code == 502
    assert PERMANENT_KEY not in response.text + caplog.text


@pytest.mark.parametrize("body", [b"{broken", b"[]", b"x" * 65537])
def test_malformed_or_oversized_upstream_response_is_sanitized(body):
    client, _ = client_for(lambda _: httpx.Response(200, content=body))
    response = client.post("/api/v2/speech/credentials", headers=auth())
    assert response.status_code == 502
    assert response.headers["cache-control"] == "no-store"
    assert response.json()["detail"]["code"] == "speech_credentials_failed"


def test_failed_redis_does_not_bypass_rate_limit_or_leak_errors():
    class FailedLimiter:
        async def acquire(self, _user_id):
            raise RuntimeError(PERMANENT_KEY)

    client, requests = client_for()
    client.app.state.speech_credentials = SpeechCredentialsService(
        settings(),
        AliyunSpeechGateway(),
        FailedLimiter(),
    )
    response = client.post("/api/v2/speech/credentials", headers=auth())
    assert response.status_code == 503
    assert PERMANENT_KEY not in response.text
    assert requests == []


@pytest.mark.parametrize(
    "base_url",
    [
        "http://dashscope.aliyuncs.com",
        "https://dashscope.aliyuncs.com.evil.test",
        "https://evil.test",
        "https://user:pass@dashscope.aliyuncs.com",
        "https://dashscope.aliyuncs.com?key=secret",
        "https://dashscope.aliyuncs.com/#secret",
        "https://dashscope.aliyuncs.com:444",
        "https://dashscope.aliyuncs.com/../../evil",
        "https://workspace.eu-west-1.maas.aliyuncs.com",
        "https://dashscope.aliyuncs.com\\@evil.test",
    ],
)
def test_malicious_config_is_unavailable(base_url):
    assert (
        load_speech_settings(
            {
                "AGENT_SERVER_ASR_API_KEY": PERMANENT_KEY,
                "AGENT_SERVER_ASR_BASE_URL": base_url,
            }
        )
        is None
    )


@pytest.mark.parametrize(
    "host",
    [
        "dashscope.aliyuncs.com",
        "dashscope-intl.aliyuncs.com",
        "example-workspace.cn-beijing.maas.aliyuncs.com",
        "example-workspace.ap-southeast-1.maas.aliyuncs.com",
    ],
)
def test_official_hosts_are_normalized(host):
    configured = settings(
        AGENT_SERVER_ASR_BASE_URL=f"https://{host}/compatible-mode/v1"
    )
    assert configured.base_url == f"https://{host}"
    assert configured.websocket_url == f"wss://{host}/api-ws/v1/inference"
    assert PERMANENT_KEY not in repr(configured)


def test_config_file_is_explicit_and_overrides_are_validated(tmp_path):
    path = tmp_path / "synthetic-config.json"
    path.write_text(
        json.dumps(
            {
                "api_key": PERMANENT_KEY,
                "base_url": "https://demo.cn-beijing.maas.aliyuncs.com",
                "workspace_id": "demo",
            }
        )
    )
    configured = load_speech_settings({"AGENT_SERVER_ASR_CONFIG_FILE": str(path)})
    assert configured is not None and configured.workspace_id == "demo"
    assert configured.base_url == "https://demo.cn-beijing.maas.aliyuncs.com"
    assert load_speech_settings({}) is None
    assert (
        load_speech_settings(
            {
                "AGENT_SERVER_ASR_CONFIG_FILE": str(path),
                "AGENT_SERVER_ASR_MODEL": "unsupported",
            }
        )
        is None
    )
    path.write_text("{broken synthetic JSON")
    assert load_speech_settings({"AGENT_SERVER_ASR_CONFIG_FILE": str(path)}) is None
    path.write_text("[]")
    assert load_speech_settings({"AGENT_SERVER_ASR_CONFIG_FILE": str(path)}) is None
    assert (
        load_speech_settings({"AGENT_SERVER_ASR_CONFIG_FILE": str(path / "missing")})
        is None
    )


def test_environment_overrides_file_and_workspace_is_forwarded(tmp_path):
    path = tmp_path / "synthetic-config.json"
    path.write_text(
        json.dumps(
            {
                "api_key": "synthetic-old-key",
                "base_url": "https://dashscope.aliyuncs.com",
                "workspace_id": "synthetic-old-workspace",
            }
        )
    )
    configured = load_speech_settings(
        {
            "AGENT_SERVER_ASR_CONFIG_FILE": str(path),
            "AGENT_SERVER_ASR_API_KEY": PERMANENT_KEY,
            "AGENT_SERVER_ASR_BASE_URL": "https://demo.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
            "AGENT_SERVER_ASR_WORKSPACE_ID": "synthetic-new-workspace",
        }
    )
    assert configured is not None

    def upstream(request):
        assert request.headers["Authorization"] == f"Bearer {PERMANENT_KEY}"
        assert request.headers["X-DashScope-WorkSpace"] == "synthetic-new-workspace"
        assert request.url.host == "demo.ap-southeast-1.maas.aliyuncs.com"
        return httpx.Response(
            200, json={"token": TEMPORARY_KEY, "expires_at": int(time.time()) + 300}
        )

    service = SpeechCredentialsService(
        configured,
        AliyunSpeechGateway(transport=httpx.MockTransport(upstream)),
        SpeechRateLimiter(RedisCoordinator()),
    )
    response = asyncio.run(service.issue("user-1"))
    assert (
        response.websocketUrl
        == "wss://demo.ap-southeast-1.maas.aliyuncs.com/api-ws/v1/inference"
    )
    assert TEMPORARY_KEY not in repr(response)


def test_server_composition_mounts_authenticated_speech_route(monkeypatch):
    from agent_server.app import create_app

    # This test exercises app composition; all speech configuration is synthetic.
    monkeypatch.delenv("AGENT_SERVER_ASR_CONFIG_FILE", raising=False)
    monkeypatch.setenv("AGENT_SERVER_ASR_API_KEY", PERMANENT_KEY)
    monkeypatch.setenv("AGENT_SERVER_ASR_BASE_URL", "https://dashscope.aliyuncs.com")
    monkeypatch.delenv("AGENT_SERVER_ASR_WORKSPACE_ID", raising=False)
    monkeypatch.delenv("AGENT_SERVER_ASR_MODEL", raising=False)
    app = create_app()
    response = TestClient(app).post("/api/v2/speech/credentials")
    assert response.status_code == 401
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["pragma"] == "no-cache"
    asyncio.run(app.state.store.close())


def test_rate_limit_is_shared_across_process_adapters():
    async def exercise():
        redis_server = FakeServer()
        coordinators = [
            RedisCoordinator(
                client=FakeRedis(server=redis_server, decode_responses=True)
            )
            for _ in range(2)
        ]
        adapters = [SpeechRateLimiter(coordinator) for coordinator in coordinators]
        results = await asyncio.gather(
            *(adapters[i % 2].acquire("same-user") for i in range(16))
        )
        assert results.count(0) == 10
        assert all(1 <= result <= 60 for result in results if result)
        assert await adapters[0].acquire("another-user") == 0
        for coordinator in coordinators:
            keys = await coordinator.client.keys("*speech-rate*")
            assert keys
            for key in keys:
                assert 0 < await coordinator.client.ttl(key) <= 60
            await coordinator.client.aclose()

    asyncio.run(exercise())


def test_local_rate_limiter_bounds_memory_and_does_not_evict_active_users():
    async def exercise():
        now = [0.0]
        limiter = SpeechRateLimiter(
            RedisCoordinator(), max_local_users=2, clock=lambda: now[0]
        )
        assert await limiter.acquire("a") == 0
        assert await limiter.acquire("b") == 0
        assert await limiter.acquire("c") == 60
        for _ in range(9):
            assert await limiter.acquire("a") == 0
        assert await limiter.acquire("a") == 60
        now[0] = 60.1
        assert await limiter.acquire("c") == 0
        assert await limiter.acquire("a") == 0

    asyncio.run(exercise())
