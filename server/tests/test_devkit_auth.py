"""Project Auth links a second sign-in method to an existing Agent OS user."""

import asyncio
import json

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
    client = make_test_client()
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
        "apiUrl": "https://devkit.example.test", "publishableKey": "test-public-key",
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
