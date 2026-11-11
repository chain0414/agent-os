from __future__ import annotations

import hmac
import os
import re
import secrets
import time
from typing import Annotated, Any
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, ConfigDict, Field, SecretStr

from agent_server.core.api_namespace import api_v2_path
from agent_server.core.auth import (
    create_signed_token,
    create_user_access_token,
    hash_password_verifier,
    verify_signed_token,
)
from agent_server.core.models import (
    AuthConfigResponse,
    AuthMeResponse,
    AuthPasswordSaltRequest,
    AuthPasswordSaltResponse,
    AuthRequest,
    AuthResponse,
    BindEmailRequest,
    ChangePasswordRequest,
    DevKitPublicAuthConfig,
    EmailCodeRequest,
    EmailCodeResponse,
    MobileLoginConfirmRequest,
    MobileLoginExchangeRequest,
    MobileLoginExchangeResponse,
    MobileLoginQrCreateResponse,
    MobileLoginRefreshRequest,
    MobileLoginRequestRequest,
    MobileLoginStatusRequest,
    MobileLoginStatusResponse,
    OAuthFinalizeRequest,
    OAuthFinalizeResponse,
    OAuthStartResponse,
    UpdateAvatarRequest,
    UpdateProfileRequest,
    UserView,
)
from agent_server.core.oauth_clients import MOBILE_OAUTH_CLIENT
from agent_server.core.utc import utc_now
from agent_server.deps import current_user, get_store, user_id_from_authorization
from agent_server.infra.repositories.email_accounts import (
    EmailRateLimitError,
    EmailVerificationError,
    normalize_email,
)
from agent_server.infra.repositories.facade import Store
from agent_server.services.devkit_auth import (
    DevKitAuthConfig,
    DevKitAuthUnavailable,
    DevKitSessionRejected,
    load_devkit_auth,
    verify_devkit_session,
)
from agent_server.services.email_delivery import (
    EmailDeliveryError,
    get_email_settings,
    send_verification_email,
)
from agent_server.services.oauth import (
    OAUTH_TOKEN_EXPIRES_IN,
    OAuthConfigError,
    build_authorize_url,
    create_pending_token,
    exchange_code_for_identity,
    is_feishu,
    oauth_enabled,
    return_to_from_state,
    state_for_provider,
    verify_pending_token,
)
from agent_server.services.setup_tokens import SetupTokenService


def _setup_token(request: Request) -> SetupTokenService:
    return SetupTokenService(request.app.state.setup_token, request.app.state.redis)


router = APIRouter(tags=["auth"])
MOBILE_LOGIN_TOKEN_KIND = "mobile_login"
MOBILE_REFRESH_TOKEN_KIND = "mobile_refresh"
MOBILE_LOGIN_EXPIRES_IN = 120
MOBILE_REFRESH_EXPIRES_IN = 60 * 60 * 24 * 30
FEISHU_OAUTH_BROWSER_COOKIE = "agent_os_feishu_oauth"
FEISHU_MOBILE_BROWSER_COOKIE = "agent_os_feishu_mobile_oauth"
FEISHU_OAUTH_COOKIE_PATH = api_v2_path("/auth/oauth")


class FeishuMobileStartQuery(BaseModel):
    model_config = ConfigDict(extra="forbid")

    code_challenge: str = Field(pattern=r"^[A-Za-z0-9_-]{43}$")
    state: str = Field(pattern=r"^[A-Za-z0-9_-]{1,128}$")


@router.get("/auth/config", response_model=AuthConfigResponse)
async def auth_config(
    request: Request, db: Store = Depends(get_store)
) -> AuthConfigResponse:
    """Public endpoint so the login page can decide what to render.

    needsBootstrap=true  → no users yet; show "create first admin".
    registrationOpen=true → show the "register" link; otherwise hide it.
    setupTokenExpiresAt    → countdown source for the bootstrap form (UTC ISO);
                             never exposes the token value itself.
    """
    needs_bootstrap = await db.count_users() == 0
    expires_at: str | None = None
    if needs_bootstrap:
        # Touching the token here is intentional — if it expired since last
        # check, the operator should already see the freshly-generated one in
        # the server log by the time they hit refresh.
        expires_at = await _setup_token(request).current_expires_at_iso()
    oauth_config = await db.get_oauth_provider_config()
    email_enabled = bool((await get_email_settings(db)).get("enabled"))
    try:
        config = load_devkit_auth()
    except DevKitAuthUnavailable:
        config = None
    return AuthConfigResponse(
        devkit=DevKitPublicAuthConfig(apiUrl=config.apiUrl, publishableKey=config.publishableKey) if config else None,
        emailVerificationRequired=email_enabled,
        needsBootstrap=needs_bootstrap,
        registrationOpen=await db.is_registration_open(),
        oauthRegistrationOpen=await db.is_oauth_registration_open(),
        oauthEnabled=oauth_enabled(oauth_config),
        oauthProviderLabel=str(oauth_config.get("label") or "OAuth") if oauth_enabled(oauth_config) else None,
        passwordResetEnabled=email_enabled and await db.is_password_reset_enabled(),
        setupTokenExpiresAt=expires_at,
        serverTime=utc_now(),
    )


@router.post("/auth/password-salt", response_model=AuthPasswordSaltResponse)
async def auth_password_salt(
    payload: AuthPasswordSaltRequest,
    db: Store = Depends(get_store),
) -> AuthPasswordSaltResponse:
    try:
        salt = await db.password_salt_for_email(payload.email)
    except ValueError as exc:
        raise _value_error_to_http(exc) from exc
    return AuthPasswordSaltResponse(salt=salt or secrets.token_urlsafe(16), serverTime=utc_now())


@router.post("/auth/register", response_model=AuthResponse)
async def auth_register(
    payload: AuthRequest, request: Request, db: Store = Depends(get_store)
) -> AuthResponse:
    """Self-service registration with gating:

    - If no users exist: the new user becomes admin **and** must present the
      setup token printed to the server log. Registration is then closed.
    - If users exist and registration_open is true: new user is a member.
    - Otherwise: 403.
    """
    # Pre-check rather than relying on bootstrap_first_admin's None return —
    # we want to reject before touching the DB when the setup token is wrong.
    if await db.count_users() == 0:
        if not await _setup_token(request).verify(payload.setupToken):
            raise HTTPException(
                status_code=401,
                detail="invalid or expired setup token — find the current token in the server log",
            )

    require_verification = bool((await get_email_settings(db)).get("enabled"))
    try:
        password_hash = _password_hash_from_payload(payload)
        bootstrap_user = await db.bootstrap_email_admin(
            email=payload.email,
            display_name=payload.displayName,
            password=payload.password,
            password_hash=password_hash,
            verification_code=payload.code,
            require_verification=require_verification,
        )
    except ValueError as exc:
        raise _value_error_to_http(exc) from exc

    if bootstrap_user is not None:
        await _setup_token(request).consume()
        return _auth_response(bootstrap_user)

    if not await db.is_registration_open():
        raise HTTPException(status_code=403, detail="registration is closed")

    try:
        user = await db.create_email_user(
            email=payload.email,
            display_name=payload.displayName,
            password=payload.password,
            password_hash=password_hash,
            role="member",
            verification_code=payload.code,
            require_verification=require_verification,
        )
    except ValueError as exc:
        raise _value_error_to_http(exc) from exc
    return _auth_response(user)


@router.post("/auth/login", response_model=AuthResponse)
async def auth_login(payload: AuthRequest, db: Store = Depends(get_store)) -> AuthResponse:
    try:
        user = await db.verify_email_user(
            email=payload.email, password=payload.password, verifier=payload.passwordVerifier,
        )
    except ValueError as exc:
        raise _value_error_to_http(exc) from exc
    if user is None:
        raise HTTPException(status_code=401, detail="invalid credentials")
    return _auth_response(user)


class DevKitAuthRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", hide_input_in_errors=True)
    accessToken: SecretStr


async def _devkit_identity(payload: DevKitAuthRequest) -> tuple[DevKitAuthConfig, str]:
    try:
        config = load_devkit_auth()
        if config is None:
            raise HTTPException(status_code=404, detail="DevKit login is not enabled")
        access_token = payload.accessToken.get_secret_value()
        if not re.fullmatch(r"[A-Za-z0-9._~-]{1,8192}", access_token):
            raise DevKitSessionRejected
        return config, await verify_devkit_session(config, access_token)
    except DevKitSessionRejected:
        raise HTTPException(status_code=401, detail="DevKit session rejected") from None
    except DevKitAuthUnavailable:
        raise HTTPException(status_code=503, detail="DevKit Auth is unavailable") from None


@router.post("/auth/devkit/link", status_code=204)
async def link_devkit_auth(
    payload: DevKitAuthRequest,
    user: Annotated[UserView, Depends(current_user)],
    db: Annotated[Store, Depends(get_store)],
) -> Response:
    config, subject = await _devkit_identity(payload)
    if not await db.bind_devkit_identity(
        user_id=user.userId, scope=config.binding_scope(), subject=subject,
    ):
        raise HTTPException(status_code=409, detail="DevKit account binding conflicts with an existing account")
    return Response(status_code=204, headers={"Cache-Control": "no-store"})


@router.post("/auth/devkit/login", response_model=AuthResponse)
async def login_devkit_auth(
    payload: DevKitAuthRequest,
    response: Response,
    db: Annotated[Store, Depends(get_store)],
) -> AuthResponse:
    config, subject = await _devkit_identity(payload)
    user = await db.devkit_user_for_subject(scope=config.binding_scope(), subject=subject)
    if user is None:
        raise HTTPException(status_code=401, detail="DevKit account is not linked to an active Agent OS user")
    response.headers["Cache-Control"] = "no-store"
    return _auth_response(user)


@router.post("/auth/email-code", response_model=EmailCodeResponse)
async def send_email_code(
    payload: EmailCodeRequest, request: Request, db: Store = Depends(get_store),
) -> EmailCodeResponse:
    user = None
    if request.headers.get("authorization"):
        user = await current_user(user_id_from_authorization(request.headers.get("authorization")), db)
    if payload.purpose == "bind" and user is None:
        raise HTTPException(status_code=401, detail="authentication required")
    if payload.purpose == "register":
        oauth_allowed = bool(
            payload.pendingToken and verify_pending_token(payload.pendingToken)
            and await db.is_oauth_registration_open()
        )
        bootstrap_allowed = await db.count_users() == 0 and await _setup_token(request).verify(payload.setupToken)
        if not (await db.is_registration_open() or (user and user.role == "admin") or oauth_allowed or bootstrap_allowed):
            raise HTTPException(status_code=403, detail="registration is closed")
    if payload.purpose == "reset" and not await db.is_password_reset_enabled():
        raise HTTPException(status_code=409, detail="password reset is disabled")
    if not (await get_email_settings(db)).get("enabled"):
        raise HTTPException(status_code=409, detail="email verification is disabled")
    try:
        email = normalize_email(payload.email)
        existing = await db.user_for_email(email)
        if payload.purpose == "reset":
            # Answer the same way for unknown addresses so the endpoint cannot
            # be used to discover which emails have accounts.
            if existing is None or existing.disabled:
                return EmailCodeResponse(serverTime=utc_now())
        elif existing and (payload.purpose != "bind" or existing.userId != user.userId):
            raise ValueError("email is already in use")
        user_id = user.userId if payload.purpose == "bind" else ""
        code = await db.issue_email_code(
            email=email, purpose=payload.purpose, user_id=user_id,
        )
    except ValueError as exc:
        raise _value_error_to_http(exc) from exc
    try:
        await send_verification_email(db, email, code)
    except EmailDeliveryError as exc:
        await db.invalidate_email_code(email=email, purpose=payload.purpose, user_id=user_id, code=code)
        raise HTTPException(status_code=502, detail="verification email could not be sent") from exc
    return EmailCodeResponse(serverTime=utc_now())


@router.put("/auth/me/email", response_model=AuthMeResponse)
async def bind_email(
    payload: BindEmailRequest, user: UserView = Depends(current_user), db: Store = Depends(get_store),
) -> AuthMeResponse:
    try:
        updated = await db.bind_user_email(
            user.userId, email=payload.email, verification_code=payload.code,
            require_verification=bool((await get_email_settings(db)).get("enabled")),
        )
    except ValueError as exc:
        raise _value_error_to_http(exc) from exc
    return _me_response(updated)


@router.put("/auth/me/profile", response_model=AuthMeResponse)
async def update_profile(
    payload: UpdateProfileRequest, user: UserView = Depends(current_user), db: Store = Depends(get_store),
) -> AuthMeResponse:
    try:
        updated = await db.update_user_display_name(user.userId, payload.displayName)
    except ValueError as exc:
        raise _value_error_to_http(exc) from exc
    return _me_response(updated)


@router.get("/auth/oauth/start", response_model=OAuthStartResponse)
async def oauth_start(
    request: Request,
    response: Response,
    returnTo: str | None = None,
    db: Store = Depends(get_store),
) -> OAuthStartResponse:
    config = await db.get_oauth_provider_config()
    browser_nonce = None
    if is_feishu(config):
        returnTo = _feishu_return_to(request, returnTo)
        browser_nonce = secrets.token_urlsafe(32)
    try:
        authorize_url = build_authorize_url(
            config,
            redirect_uri=_oauth_redirect_uri(request, return_to=returnTo),
            return_to=returnTo,
            browser_nonce=browser_nonce,
        )
    except OAuthConfigError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    if browser_nonce:
        response.set_cookie(
            FEISHU_OAUTH_BROWSER_COOKIE, browser_nonce, max_age=OAUTH_TOKEN_EXPIRES_IN,
            path=FEISHU_OAUTH_COOKIE_PATH, secure=True, httponly=True, samesite="lax",
        )
        response.headers["Cache-Control"] = "no-store"
    return OAuthStartResponse(authorizeUrl=authorize_url, serverTime=utc_now())


@router.get("/auth/oauth/mobile/feishu", response_class=RedirectResponse)
async def feishu_mobile_start(
    request: Request,
    query: Annotated[FeishuMobileStartQuery, Query()],
    db: Annotated[Store, Depends(get_store)],
) -> RedirectResponse:
    config = await db.get_oauth_provider_config()
    if not is_feishu(config) or not oauth_enabled(config):
        raise HTTPException(status_code=404, detail="Feishu login is not configured")
    browser_nonce = secrets.token_urlsafe(32)
    authorize_url = build_authorize_url(
        config,
        redirect_uri=_oauth_redirect_uri(request),
        browser_nonce=browser_nonce,
        mobile_request=query.model_dump(),
    )
    response = RedirectResponse(authorize_url, status_code=302, headers={"Cache-Control": "no-store"})
    response.set_cookie(
        FEISHU_MOBILE_BROWSER_COOKIE, browser_nonce, max_age=OAUTH_TOKEN_EXPIRES_IN,
        path=FEISHU_OAUTH_COOKIE_PATH, secure=True, httponly=True, samesite="lax",
    )
    return response


@router.get("/auth/oauth/callback")
async def oauth_callback(
    request: Request,
    code: str | None = None,
    state: str | None = None,
    error: str | None = None,
    db: Store = Depends(get_store),
) -> RedirectResponse:
    config = await db.get_oauth_provider_config()
    feishu = is_feishu(config)
    if feishu:
        payload = state_for_provider(config, state)
        expected = payload.get("browserNonce") if payload else None
        mobile_request = payload.get("mobileRequest") if payload else None
        if isinstance(mobile_request, dict):
            actual = request.cookies.get(FEISHU_MOBILE_BROWSER_COOKIE, "")
            if not _matches_browser_nonce(expected, actual):
                return _feishu_mobile_error(mobile_request["state"], "invalid_request", "Feishu login session expired.")
            result = await _feishu_mobile_callback(request, config, code, state, error, mobile_request, db)
            result.delete_cookie(FEISHU_MOBILE_BROWSER_COOKIE, path=FEISHU_OAUTH_COOKIE_PATH, secure=True, httponly=True)
            return result
        actual = request.cookies.get(FEISHU_OAUTH_BROWSER_COOKIE, "")
        if not _matches_browser_nonce(expected, actual):
            return _oauth_frontend_redirect(request, {"oauth_error": "invalid Feishu login session"})
    return_to = return_to_from_state(config, state)
    result = await _oauth_callback_result(request, config, code, state, error, return_to, db)
    if feishu:
        result.delete_cookie(FEISHU_OAUTH_BROWSER_COOKIE, path=FEISHU_OAUTH_COOKIE_PATH, secure=True, httponly=True)
        result.headers["Cache-Control"] = "no-store"
    return result


def _matches_browser_nonce(expected: Any, actual: str) -> bool:
    return isinstance(expected, str) and hmac.compare_digest(actual.encode(), expected.encode())


async def _feishu_mobile_callback(
    request: Request,
    config: dict[str, Any],
    code: str | None,
    state: str | None,
    error: str | None,
    mobile_request: dict[str, str],
    db: Store,
) -> RedirectResponse:
    app_state = mobile_request["state"]
    if error or not code:
        return _feishu_mobile_error(app_state, "access_denied", "Feishu sign-in was not authorized.")
    try:
        identity = await exchange_code_for_identity(
            config, code=code, state=state, redirect_uri=_oauth_redirect_uri(request),
        )
    except Exception:  # noqa: BLE001 - Keep provider errors and credentials out of the redirect.
        return _feishu_mobile_error(app_state, "server_error", "Feishu login could not be completed.")
    user = await db.oauth_user_for_subject(provider=identity.provider, subject=identity.subject)
    if user is None:
        return _feishu_mobile_error(
            app_state, "account_not_linked", "Link your Feishu account on the Agent OS website first.",
        )
    app_code = await db.create_oauth_authorization_code(
        client_id=MOBILE_OAUTH_CLIENT.client_id,
        user_id=user.userId,
        redirect_uri=MOBILE_OAUTH_CLIENT.redirect_uri,
        scope="profile",
        code_challenge=mobile_request["code_challenge"],
        code_challenge_method="S256",
    )
    return _feishu_mobile_redirect({"code": app_code, "state": app_state})


def _feishu_mobile_error(state: str, error: str, description: str) -> RedirectResponse:
    return _feishu_mobile_redirect({"state": state, "error": error, "error_description": description})


def _feishu_mobile_redirect(params: dict[str, str]) -> RedirectResponse:
    return RedirectResponse(
        f"{MOBILE_OAUTH_CLIENT.redirect_uri}?{urlencode(params)}",
        status_code=302,
        headers={"Cache-Control": "no-store"},
    )


async def _oauth_callback_result(
    request: Request,
    config: dict[str, Any],
    code: str | None,
    state: str | None,
    error: str | None,
    return_to: str | None,
    db: Store,
) -> RedirectResponse:
    if error:
        return _oauth_frontend_redirect(request, {"oauth_error": error}, return_to=return_to)
    if not code:
        return _oauth_frontend_redirect(
            request,
            {"oauth_error": "missing oauth callback code"},
            return_to=return_to,
        )
    try:
        identity = await exchange_code_for_identity(
            config,
            code=code,
            state=state,
            redirect_uri=_oauth_redirect_uri(request, return_to=return_to),
        )
    except Exception as exc:  # noqa: BLE001 - OAuth provider failures return to the UI.
        detail = "Feishu login could not be completed" if is_feishu(config) else str(exc)
        return _oauth_frontend_redirect(request, {"oauth_error": detail}, return_to=return_to)

    bound = await db.oauth_user_for_subject(provider=identity.provider, subject=identity.subject)
    if bound is not None:
        return _oauth_frontend_redirect(
            request,
            {
                "oauth_status": "authenticated",
                "oauth_pending": create_pending_token(identity),
                "oauth_email": bound.email or "",
                "oauth_display_name": bound.displayName,
            },
            return_to=return_to,
        )

    existing = None
    if identity.email:
        try:
            existing = await db.user_for_email(identity.email)
        except ValueError:
            pass
    link_only = is_feishu(config) and not await db.is_oauth_registration_open()
    return _oauth_frontend_redirect(
        request,
        {
            "oauth_status": "needs_password" if existing or link_only else "needs_registration",
            "oauth_pending": create_pending_token(identity),
            "oauth_email": identity.email if identity.email and (existing or not link_only) else "",
            "oauth_display_name": identity.display_name or "",
        },
        return_to=return_to,
    )


@router.post("/auth/oauth/finalize", response_model=OAuthFinalizeResponse)
async def oauth_finalize(
    payload: OAuthFinalizeRequest,
    db: Store = Depends(get_store),
) -> OAuthFinalizeResponse:
    identity = verify_pending_token(payload.pendingToken)
    if identity is None:
        raise HTTPException(status_code=401, detail="oauth session expired")
    existing = await db.oauth_user_for_subject(provider=identity.provider, subject=identity.subject)
    if existing is not None:
        return OAuthFinalizeResponse(auth=_auth_response(existing), serverTime=utc_now())
    try:
        email = normalize_email(payload.email or "")
        target = await db.user_for_email(email)
        if target is not None:
            verified = await db.verify_email_user(
                email=email, password=payload.password, verifier=payload.passwordVerifier,
            )
            if verified is None:
                raise HTTPException(status_code=401, detail="password is required to link this account")
            user = await db.bind_oauth_account(
                user_id=verified.userId, provider=identity.provider, subject=identity.subject,
                email=identity.email, display_name=identity.display_name,
            )
            return OAuthFinalizeResponse(auth=_auth_response(user), serverTime=utc_now())
        if not await db.is_oauth_registration_open():
            raise HTTPException(status_code=403, detail="oauth registration is closed")
        password_hash = _password_hash_from_oauth_finalize(payload)
        user = await db.create_email_user(
            email=email, display_name=payload.displayName,
            password=(payload.password if payload.setPassword else None) or secrets.token_urlsafe(32),
            password_hash=password_hash, verification_code=payload.code,
            require_verification=bool((await get_email_settings(db)).get("enabled")),
            oauth_account={
                "provider": identity.provider, "subject": identity.subject,
                "email": identity.email, "display_name": identity.display_name,
            },
        )
    except ValueError as exc:
        raise _value_error_to_http(exc) from exc
    return OAuthFinalizeResponse(auth=_auth_response(user), serverTime=utc_now())


@router.get("/auth/me", response_model=AuthMeResponse)
async def auth_me(user: UserView = Depends(current_user)) -> AuthMeResponse:
    return _me_response(user)


# Cap stored avatar payload at ~256 KB. The data URL prefix + 256 KB of base64
# easily fits any reasonable 256×256 PNG once the frontend has resized it.
AVATAR_MAX_LENGTH = 256 * 1024
AVATAR_DATA_URL_RE = re.compile(r"^data:image/(png|jpeg|jpg|webp|gif);base64,[A-Za-z0-9+/=]+$")


@router.put("/auth/me/avatar", response_model=AuthMeResponse)
async def update_avatar(
    payload: UpdateAvatarRequest,
    user: UserView = Depends(current_user),
    db: Store = Depends(get_store),
) -> AuthMeResponse:
    avatar = payload.avatar.strip()
    if len(avatar) > AVATAR_MAX_LENGTH:
        raise HTTPException(status_code=413, detail="avatar exceeds 256KB limit")
    if not AVATAR_DATA_URL_RE.match(avatar):
        raise HTTPException(
            status_code=422,
            detail="avatar must be a data:image/{png,jpeg,webp,gif};base64,... URL",
        )
    updated = await db.set_user_avatar(user.userId, avatar)
    return _me_response(updated)


@router.delete("/auth/me/avatar", response_model=AuthMeResponse)
async def clear_avatar(
    user: UserView = Depends(current_user),
    db: Store = Depends(get_store),
) -> AuthMeResponse:
    updated = await db.set_user_avatar(user.userId, None)
    return _me_response(updated)


@router.post("/auth/change-password", status_code=204)
async def change_password(
    payload: ChangePasswordRequest,
    request: Request,
    db: Store = Depends(get_store),
) -> None:
    """Caller changes their own password.

    The bearer token is the authentication factor here. Until 2FA exists, do
    not require users to re-enter the current password just to set a new one.

    Without a bearer token, ``email`` + ``code`` (issued by
    ``/auth/email-code`` with purpose=reset) reset a forgotten password when
    the instance enabled password reset.
    """
    authorization = request.headers.get("authorization")
    if authorization is None and payload.email and payload.code:
        await _reset_password(payload, db)
        return
    user = await current_user(user_id_from_authorization(authorization), db)
    if not payload.newPassword and not payload.newPasswordVerifier:
        raise HTTPException(status_code=422, detail="new password is required")
    await db.update_user_password(
        user.userId,
        payload.newPassword,
        password_hash=_password_hash_from_change(payload),
    )


@router.post("/auth/mobile-login/qr", response_model=MobileLoginQrCreateResponse)
async def create_mobile_login_qr(
    user: UserView = Depends(current_user),
    db: Store = Depends(get_store),
) -> MobileLoginQrCreateResponse:
    expires_at_ts = int(time.time()) + MOBILE_LOGIN_EXPIRES_IN
    expires_at = _iso_from_epoch(expires_at_ts)
    login_token = create_signed_token(
        MOBILE_LOGIN_TOKEN_KIND,
        {
            "sub": user.userId,
            "aud": "agents-anywhere-mobile",
            "nonce": secrets.token_urlsafe(12),
        },
        MOBILE_LOGIN_EXPIRES_IN,
    )
    await db.record_mobile_login_token(
        token=login_token,
        user_id=user.userId,
        expires_at=expires_at,
    )
    return MobileLoginQrCreateResponse(
        userId=user.userId,
        loginToken=login_token,
        expiresAt=expires_at,
        serverTime=utc_now(),
    )


@router.post("/auth/mobile-login/exchange", response_model=MobileLoginExchangeResponse)
async def exchange_mobile_login(
    payload: MobileLoginExchangeRequest,
    db: Store = Depends(get_store),
) -> MobileLoginExchangeResponse:
    token_payload = verify_signed_token(MOBILE_LOGIN_TOKEN_KIND, payload.loginToken)
    if token_payload is None or token_payload.get("sub") != payload.userId:
        raise HTTPException(status_code=401, detail="invalid or expired mobile login token")
    if not await db.consume_mobile_login_token(token=payload.loginToken, user_id=payload.userId):
        raise HTTPException(status_code=401, detail="invalid or expired mobile login token")
    try:
        user = await db.get_user(payload.userId)
    except KeyError:
        raise HTTPException(status_code=401, detail="user no longer exists") from None
    if user.disabled:
        raise HTTPException(status_code=403, detail="account disabled")
    refresh_token = create_signed_token(
        MOBILE_REFRESH_TOKEN_KIND,
        {
            "sub": user.userId,
            "aud": "agents-anywhere-mobile",
            "nonce": secrets.token_urlsafe(16),
        },
        MOBILE_REFRESH_EXPIRES_IN,
    )
    return MobileLoginExchangeResponse(
        auth=_auth_response(user),
        refreshToken=refresh_token,
        expiresAt=_iso_from_epoch(int(time.time()) + MOBILE_REFRESH_EXPIRES_IN),
        serverTime=utc_now(),
    )


@router.post("/auth/mobile-login/refresh", response_model=AuthResponse)
async def refresh_mobile_login(
    payload: MobileLoginRefreshRequest,
    db: Store = Depends(get_store),
) -> AuthResponse:
    token_payload = verify_signed_token(MOBILE_REFRESH_TOKEN_KIND, payload.refreshToken)
    if token_payload is None or token_payload.get("aud") != "agents-anywhere-mobile":
        raise HTTPException(status_code=401, detail="invalid or expired mobile refresh token")
    subject = token_payload.get("sub")
    if not isinstance(subject, str) or not subject:
        raise HTTPException(status_code=401, detail="invalid or expired mobile refresh token")
    try:
        user = await db.get_user(subject)
    except KeyError:
        raise HTTPException(status_code=401, detail="user no longer exists") from None
    if user.disabled:
        raise HTTPException(status_code=403, detail="account disabled")
    return _auth_response(user)


@router.post("/auth/mobile-login/request", response_model=MobileLoginStatusResponse)
async def request_mobile_login(
    payload: MobileLoginRequestRequest,
    db: Store = Depends(get_store),
) -> MobileLoginStatusResponse:
    token_payload = verify_signed_token(MOBILE_LOGIN_TOKEN_KIND, payload.loginToken)
    if token_payload is None or token_payload.get("sub") != payload.userId:
        raise HTTPException(status_code=401, detail="invalid or expired mobile login token")
    row = await db.request_mobile_login_token(
        token=payload.loginToken,
        user_id=payload.userId,
        device_name=payload.deviceName,
    )
    if row is None:
        raise HTTPException(status_code=401, detail="invalid or expired mobile login token")
    return _mobile_login_status_response(row)


@router.post("/auth/mobile-login/status", response_model=MobileLoginStatusResponse)
async def mobile_login_status(
    payload: MobileLoginStatusRequest,
    db: Store = Depends(get_store),
) -> MobileLoginStatusResponse:
    row = await db.mobile_login_token_status(token=payload.loginToken)
    if row is None:
        raise HTTPException(status_code=404, detail="mobile login token not found")
    return _mobile_login_status_response(row)


@router.post("/auth/mobile-login/confirm", response_model=MobileLoginStatusResponse)
async def confirm_mobile_login(
    payload: MobileLoginConfirmRequest,
    user: UserView = Depends(current_user),
    db: Store = Depends(get_store),
) -> MobileLoginStatusResponse:
    token_payload = verify_signed_token(MOBILE_LOGIN_TOKEN_KIND, payload.loginToken)
    if token_payload is None or token_payload.get("sub") != user.userId:
        raise HTTPException(status_code=401, detail="invalid or expired mobile login token")
    row = await db.resolve_mobile_login_token(token=payload.loginToken, approved=payload.approved)
    if row is None:
        raise HTTPException(status_code=401, detail="invalid or expired mobile login token")
    return _mobile_login_status_response(row)


async def _reset_password(payload: ChangePasswordRequest, db: Store) -> None:
    if not (
        await db.is_password_reset_enabled()
        and (await get_email_settings(db)).get("enabled")
    ):
        raise HTTPException(status_code=409, detail="password reset is disabled")
    if not payload.newPassword and not payload.newPasswordVerifier:
        raise HTTPException(status_code=422, detail="new password is required")
    try:
        await db.reset_password_with_code(
            email=payload.email or "",
            verification_code=payload.code,
            password=payload.newPassword,
            password_hash=_password_hash_from_change(payload),
        )
    except ValueError as exc:
        raise _value_error_to_http(exc) from exc


def _me_response(user: UserView) -> AuthMeResponse:
    return AuthMeResponse(
        userId=user.userId, email=user.email, emailVerified=user.emailVerified,
        displayName=user.displayName, role=user.role, disabled=user.disabled,
        avatar=user.avatar, serverTime=utc_now(),
    )


def _auth_response(user: UserView) -> AuthResponse:
    return AuthResponse(
        userId=user.userId,
        role=user.role,
        email=user.email, emailVerified=user.emailVerified, displayName=user.displayName,
        accessToken=create_user_access_token(user.userId),
        serverTime=utc_now(),
    )


def _iso_from_epoch(value: int) -> str:
    from datetime import UTC, datetime

    return datetime.fromtimestamp(value, UTC).isoformat().replace("+00:00", "Z")


def _mobile_login_status_response(row: dict[str, object]) -> MobileLoginStatusResponse:
    now = utc_now()
    if row.get("consumed_at"):
        status = "consumed"
    elif str(row.get("expires_at") or "") < now:
        status = "expired"
    elif row.get("rejected_at"):
        status = "rejected"
    elif row.get("approved_at"):
        status = "approved"
    elif row.get("requested_at"):
        status = "pending_web_confirm"
    else:
        status = "pending_scan"
    return MobileLoginStatusResponse(
        status=status,
        userId=str(row.get("user_id") or "") or None,
        deviceName=str(row.get("device_name") or "") or None,
        expiresAt=str(row.get("expires_at") or "") or None,
        requestedAt=str(row.get("requested_at") or "") or None,
        approvedAt=str(row.get("approved_at") or "") or None,
        serverTime=now,
    )


def _value_error_to_http(exc: ValueError) -> HTTPException:
    detail = str(exc)
    if isinstance(exc, EmailRateLimitError):
        return HTTPException(status_code=429, detail=detail, headers={"Retry-After": "60"})
    if isinstance(exc, EmailVerificationError):
        return HTTPException(status_code=422, detail=detail)
    if detail in {"user already exists", "email is already in use"}:
        return HTTPException(status_code=409, detail=detail)
    return HTTPException(status_code=422, detail=detail)


def _password_hash_from_payload(payload: AuthRequest) -> str | None:
    if payload.passwordVerifier is None:
        return None
    if not payload.passwordSalt:
        raise ValueError("password salt is required")
    return hash_password_verifier(payload.passwordVerifier, salt=payload.passwordSalt)


def _password_hash_from_change(payload: ChangePasswordRequest) -> str | None:
    if payload.newPasswordVerifier is None:
        return None
    if not payload.newPasswordSalt:
        raise HTTPException(status_code=422, detail="new password salt is required")
    return hash_password_verifier(payload.newPasswordVerifier, salt=payload.newPasswordSalt)


def _password_hash_from_oauth_finalize(payload: OAuthFinalizeRequest) -> str | None:
    if not payload.setPassword:
        return None
    if payload.passwordVerifier is None:
        return None
    if not payload.passwordSalt:
        raise HTTPException(status_code=422, detail="password salt is required")
    return hash_password_verifier(payload.passwordVerifier, salt=payload.passwordSalt)


def _oauth_redirect_uri(request: Request, *, return_to: str | None = None) -> str:
    return f"{_oauth_public_origin(request, return_to=return_to)}{api_v2_path('/auth/oauth/callback')}"


def _feishu_return_to(request: Request, return_to: str | None) -> str:
    origin = _oauth_public_origin(request)
    target = return_to or f"{origin}/"
    try:
        parts = urlsplit(target)
        if parts.scheme == "https" and f"{parts.scheme}://{parts.netloc}" == origin and "\\" not in target:
            return target
    except ValueError:
        pass
    raise HTTPException(status_code=422, detail="Feishu login requires a same-origin HTTPS return URL")


def _oauth_public_origin(request: Request, *, return_to: str | None = None) -> str:
    if return_to:
        try:
            parts = urlsplit(return_to)
            if parts.scheme in {"http", "https"} and parts.netloc:
                return f"{parts.scheme}://{parts.netloc}"
        except ValueError:
            pass
    configured_origin = os.environ.get("AGENT_SERVER_PUBLIC_ORIGIN")
    if configured_origin:
        return configured_origin.rstrip("/")
    return _public_origin(request)


def _public_origin(request: Request) -> str:
    forwarded_proto = request.headers.get("x-forwarded-proto")
    forwarded_host = request.headers.get("x-forwarded-host")
    scheme = forwarded_proto or request.url.scheme
    host = forwarded_host or request.url.netloc
    return f"{scheme}://{host}"


def _oauth_frontend_redirect(
    request: Request,
    params: dict[str, str],
    *,
    return_to: str | None = None,
) -> RedirectResponse:
    base = return_to or f"{_public_origin(request)}/"
    try:
        parts = urlsplit(base)
        query = dict(parse_qsl(parts.query, keep_blank_values=True))
        query.update(params)
        target = urlunsplit((parts.scheme, parts.netloc, parts.path or "/", urlencode(query), parts.fragment))
    except ValueError:
        target = f"{_public_origin(request)}/?{urlencode(params)}"
    return RedirectResponse(target)
