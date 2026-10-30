from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.routing import APIRoute

from agent_server.core.models import UserView
from agent_server.core.speech import SpeechCredentialsResponse
from agent_server.deps import current_user
from agent_server.services.speech import SpeechCredentialsService, SpeechError

_NO_STORE = {"Cache-Control": "no-store", "Pragma": "no-cache"}
_ERRORS = {
    "speech_unavailable": (503, "Speech input is unavailable"),
    "speech_credentials_failed": (502, "Unable to issue speech credentials"),
    "speech_rate_limited": (429, "Too many speech credential requests"),
}


class _NoStoreRoute(APIRoute):
    def get_route_handler(self):
        original = super().get_route_handler()

        async def handle(request: Request) -> Response:
            try:
                response = await original(request)
            except HTTPException as exc:
                exc.headers = {**(exc.headers or {}), **_NO_STORE}
                raise
            response.headers.update(_NO_STORE)
            return response

        return handle


router = APIRouter(tags=["speech"], route_class=_NoStoreRoute)


def get_speech_credentials_service(request: Request) -> SpeechCredentialsService:
    return request.app.state.speech_credentials


@router.post("/speech/credentials", response_model=SpeechCredentialsResponse)
async def speech_credentials(
    request: Request,
    user: Annotated[UserView, Depends(current_user)],
    service: Annotated[
        SpeechCredentialsService, Depends(get_speech_credentials_service)
    ],
) -> SpeechCredentialsResponse:
    if request.query_params or (await request.body()).strip():
        raise HTTPException(
            status_code=400,
            detail={
                "code": "speech_invalid_request",
                "message": "Speech credential requests must be empty",
            },
        )
    try:
        return await service.issue(user.userId)
    except SpeechError as exc:
        status, message = _ERRORS[exc.code]
        headers = dict(_NO_STORE)
        if exc.retry_after is not None:
            headers["Retry-After"] = str(exc.retry_after)
        raise HTTPException(
            status_code=status,
            detail={"code": exc.code, "message": message},
            headers=headers,
        ) from None
