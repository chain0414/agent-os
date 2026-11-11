"""Project Auth resolves an existing Agent OS user from a DevKit identity."""

import asyncio
import base64
import hashlib
import json
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest
from conftest import make_test_client
from test_auth import admin_token, bearer, user_id
from test_connector_deletion import add_session, create_device, create_project

SCOPE = {
    "projectId": "agent-os",
    "environmentId": "test",
    "realmId": "agent-os-test",
    "issuer": "https://devkit.example.test/auth",
    "audience": "agent-os-test",
}
METADATA = {
    "version": 1,
    **SCOPE,
    "subject": "devkit-user-1",
    "sessionId": "session-1",
    "sessionExpiresAt": "2099-01-01T00:00:00Z",
}
LINK = "/auth/devkit/link"
LOGIN = "/auth/devkit/login"
BODY = {"accessToken": "project-test-access"}


@pytest.fixture
def project_auth(monkeypatch):
    from agent_server.services import devkit_auth

    config = {
        **SCOPE,
        "apiUrl": "https://devkit.example.test",
        "appOrigin": "https://os.example.test",
        "publishableKey": "test-public-key",
    }
    monkeypatch.setenv("AGENT_SERVER_DEVKIT_AUTH", json.dumps(config))
    responses = {"project-test-access": METADATA}

    def metadata(request):
        assert request.url == httpx.URL(config["apiUrl"] + "/api/runtime/v1/auth/session-metadata")
        assert request.method == "GET"
        assert request.headers["origin"] == config["appOrigin"]
        assert request.headers["x-devkit-key"] == config["publishableKey"]
        access_token = request.headers["authorization"].removeprefix("Bearer ")
        body = responses.get(access_token)
        return httpx.Response(200, json=body) if body else httpx.Response(401)

    monkeypatch.setattr(devkit_auth, "_transport", httpx.MockTransport(metadata))
    return responses


def test_devkit_auth_is_opt_in(monkeypatch):
    monkeypatch.delenv("AGENT_SERVER_DEVKIT_AUTH", raising=False)
    with make_test_client() as client:
        assert client.get("/auth/config").json().get("devkit") is None
        assert client.post(LOGIN, json=BODY).status_code == 404


def test_linked_login_preserves_admin_and_works_with_mobile_exchange(project_auth):
    client = make_test_client()
    original_token = admin_token(client)
    original_id = user_id(client, "user1")
    existing_headers = bearer(original_token)
    device_id = create_device(client, existing_headers)
    project_id = create_project(client, existing_headers, device_id, "Original workspace")
    session_id = add_session(client, device_id, project_id, "Original session")
    asyncio.run(client.app.state.store.bind_oauth_account(
        user_id=original_id, provider="feishu", subject="ou_existing_feishu",
    ))
    assert client.get("/auth/config").json()["devkit"] == {
        "apiUrl": "https://devkit.example.test", "publishableKey": "test-public-key", "managedOnly": False,
    }
    assert client.post(LOGIN, json=BODY).status_code == 401
    assert client.post(LINK, json=BODY).status_code == 401

    for _ in range(2):
        linked = client.post(LINK, headers=bearer(original_token), json=BODY)
        assert linked.status_code == 204

    login = client.post(LOGIN, json=BODY)
    assert login.status_code == 200
    assert login.json()["userId"] == original_id
    assert login.json()["role"] == "admin"
    assert login.headers["cache-control"] == "no-store"
    assert client.get("/auth/me", headers=bearer(original_token)).json()["userId"] == original_id
    feishu = asyncio.run(client.app.state.store.oauth_user_for_subject(
        provider="feishu", subject="ou_existing_feishu",
    ))
    assert feishu.userId == original_id
    assert asyncio.run(client.app.state.store.count_users()) == 1

    linked_headers = bearer(login.json()["accessToken"])
    assert client.get(f"/connectors/{device_id}", headers=linked_headers).status_code == 200
    assert client.get(f"/sessions/{session_id}/meta", headers=linked_headers).status_code == 200
    qr = client.post("/auth/mobile-login/qr", headers=linked_headers)
    qr_token = qr.json()["loginToken"]
    mobile_payload = {"userId": original_id, "loginToken": qr_token}
    requested = client.post("/auth/mobile-login/request", json={**mobile_payload, "deviceName": "iPhone"})
    assert requested.status_code == 200
    confirmed = client.post(
        "/auth/mobile-login/confirm",
        headers=bearer(login.json()["accessToken"]),
        json={"loginToken": qr_token, "approved": True},
    )
    assert confirmed.status_code == 200
    mobile = client.post("/auth/mobile-login/exchange", json=mobile_payload)
    assert mobile.status_code == 200
    assert mobile.json()["auth"]["userId"] == original_id


def test_rejects_other_realms_and_identity_reassignment(project_auth):
    client = make_test_client()
    original_token = admin_token(client)
    original_id = user_id(client, "user1")
    store = client.app.state.store
    other = asyncio.run(store.create_email_user(
        email="other@example.test", display_name="Other", password="test-pass", role="member",
    ))
    other_login = client.post("/auth/login", json={"email": other.email, "password": "test-pass"})
    other_auth = bearer(other_login.json()["accessToken"])
    project_auth["different-realm"] = {**METADATA, "realmId": "unrelated"}
    project_auth["different-subject"] = {**METADATA, "subject": "devkit-user-2"}
    assert client.post(LINK, headers=other_auth, json={"accessToken": "different-realm"}).status_code == 401
    assert client.post(LINK, headers=bearer(original_token), json=BODY).status_code == 204
    assert client.post(LINK, headers=other_auth, json=BODY).status_code == 409
    assert client.post(LINK, headers=bearer(original_token), json={"accessToken": "different-subject"}).status_code == 409
    assert client.post(LOGIN, json=BODY).json()["userId"] == original_id
    assert client.post(LINK, headers=other_auth, json={"accessToken": "different-subject"}).status_code == 204
    assert client.post(LOGIN, json={"accessToken": "different-subject"}).status_code == 200
    asyncio.run(store.set_user_disabled(other.userId, True))
    assert client.post(LOGIN, json={"accessToken": "different-subject"}).status_code == 401
    del project_auth["project-test-access"]
    assert client.post(LOGIN, json=BODY).status_code == 401


def test_managed_auth_keeps_original_ownership_and_disables_local_identity(project_auth, monkeypatch):
    from agent_server.services.devkit_auth import load_devkit_auth

    client = make_test_client()
    original_headers = bearer(admin_token(client))
    original_id = user_id(client, "user1")
    device_id = create_device(client, original_headers)
    project_id = create_project(client, original_headers, device_id, "Original workspace")
    session_id = add_session(client, device_id, project_id, "Original session")
    original_config = load_devkit_auth()
    assert original_config is not None
    assert asyncio.run(client.app.state.store.bind_devkit_identity(
        user_id=original_id, scope=original_config.binding_scope(), subject=METADATA["subject"],
    ))
    monkeypatch.setenv("AGENT_SERVER_DEVKIT_AUTH", original_config.model_copy(
        update={"managedOnly": True},
    ).model_dump_json())

    config = client.get("/auth/config").json()
    assert config["devkit"]["managedOnly"] is True
    assert all(config[name] is False for name in (
        "emailVerificationRequired", "needsBootstrap", "registrationOpen",
        "oauthRegistrationOpen", "oauthEnabled", "passwordResetEnabled",
    ))
    local_paths = (
        ("POST", "/auth/password-salt"), ("POST", "/auth/register"),
        ("POST", "/auth/login"), ("POST", LINK), ("POST", "/auth/email-code"),
        ("PUT", "/auth/me/email"), ("PUT", "/auth/me/profile"),
        ("GET", "/auth/oauth/start"), ("GET", "/auth/oauth/callback"),
        ("POST", "/auth/oauth/finalize"), ("PUT", "/auth/me/avatar"),
        ("DELETE", "/auth/me/avatar"), ("POST", "/auth/change-password"),
        ("GET", "/admin/settings"), ("PATCH", "/admin/settings"), ("GET", "/admin/users"),
        ("GET", "/admin/usage/report"), ("GET", "/admin/usage/live"),
        ("POST", "/admin/users"), ("PATCH", f"/admin/users/{original_id}"),
        ("DELETE", f"/admin/users/{original_id}"),
    )
    for method, path in local_paths:
        response = client.request(method, path, headers=original_headers, json={})
        assert response.status_code == 404, (method, path)
        assert response.json()["detail"] == "This endpoint is disabled in DevKit managed mode"

    login = client.post(LOGIN, json=BODY)
    assert login.status_code == 200
    assert login.json()["userId"] == original_id
    assert login.json()["role"] == "admin"
    managed_headers = bearer(login.json()["accessToken"])
    assert client.get(f"/sessions/{session_id}/meta", headers=managed_headers).status_code == 200
    assert client.get(f"/connectors/{device_id}", headers=managed_headers).status_code == 200
    assert client.post("/auth/mobile-login/qr", headers=managed_headers).status_code == 200
    assert asyncio.run(client.app.state.store.count_users()) == 1

    verifier = "A" * 43
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    redirect = client.get(
        "/auth/oauth/mobile/feishu",
        params={"code_challenge": challenge, "state": "native_state"},
        follow_redirects=False,
    )
    assert redirect.status_code == 302
    location = urlsplit(redirect.headers["location"])
    assert f"{location.scheme}://{location.netloc}" == original_config.appOrigin
    route, _, params = location.fragment.partition("?")
    assert route == "/mobile-oauth"
    parsed_params = parse_qs(params)
    assert parsed_params == {
        "response_type": ["code"],
        "client_id": ["agents-anywhere-mobile"],
        "redirect_uri": ["agents-anywhere://oauth/callback"],
        "code_challenge_method": ["S256"],
        "code_challenge": [challenge],
        "state": ["native_state"],
    }
    authorization = client.post("/oauth/authorize", headers=managed_headers, json={
        key: values[0] for key, values in parsed_params.items()
    })
    assert authorization.status_code == 200
    callback = parse_qs(urlsplit(authorization.json()["redirectUrl"]).query)
    assert callback["state"] == ["native_state"]
    exchanged = client.post("/oauth/token", data={
        "grant_type": "authorization_code",
        "code": callback["code"][0],
        "client_id": "agents-anywhere-mobile",
        "redirect_uri": "agents-anywhere://oauth/callback",
        "code_verifier": verifier,
    })
    assert exchanged.status_code == 200
    mobile_headers = bearer(exchanged.json()["access_token"])
    assert client.get("/auth/me", headers=mobile_headers).json()["userId"] == original_id


@pytest.mark.parametrize("invalid_config", ["", "{", '{"managedOnly": true}'])
def test_invalid_devkit_config_does_not_enable_local_auth(monkeypatch, invalid_config):
    monkeypatch.setenv("AGENT_SERVER_DEVKIT_AUTH", invalid_config)
    client = make_test_client()
    assert client.get("/auth/config").status_code == 503
    assert client.post("/auth/login", json={}).status_code == 503
    assert client.post(LOGIN, json=BODY).status_code == 503
