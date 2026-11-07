"""In-process HTTP carrier for the DSH integration probes."""

import asyncio
import json
from collections.abc import Callable

import httpx


class IngestTransport(httpx.AsyncBaseTransport):
    def __init__(self, app) -> None:
        self.inner = httpx.ASGITransport(app)
        self.notifications: list[dict] = []
        self.lose_snapshot_reply = False
        self.lost = False
        self.fail_before_ingest: Callable[[list[dict]], bool] | None = None
        self.pending: set[asyncio.Task[httpx.Response]] = set()

    async def handle_async_request(self, request):
        notices = json.loads(await request.aread())["notifications"]
        if self.fail_before_ingest is not None and self.fail_before_ingest(notices):
            raise httpx.ConnectError("Simulated Server outage before ingestion", request=request)
        # A real HTTP disconnect does not cancel the server's request task.
        # Keep ASGI ingestion alive when the probe stops its Connector mid-request,
        # and drain it before disposing the test database.
        task = asyncio.create_task(self.ingest(request, notices))
        self.pending.add(task)
        try:
            response = await asyncio.shield(task)
        except asyncio.CancelledError:
            raise
        except BaseException:
            self.pending.discard(task)
            raise
        else:
            self.pending.discard(task)
        if self.lose_snapshot_reply and any(n["method"] == "timeline.sync" for n in notices):
            self.lose_snapshot_reply = False
            self.lost = True
            raise httpx.ReadError("Simulated lost HTTP reply after ingestion", request=request)
        return response

    async def ingest(self, request, notices):
        assert request.url.path == "/api/v2/connector/ingest"
        response = await self.inner.handle_async_request(request)
        await response.aread()
        assert response.status_code == 200, response.text
        assert not response.json().get("rejected"), response.text
        self.notifications.extend(notices)
        return response

    async def aclose(self):
        results = await asyncio.gather(*self.pending, return_exceptions=True)
        self.pending.clear()
        await self.inner.aclose()
        for result in results:
            if isinstance(result, BaseException):
                raise result
