from __future__ import annotations

import asyncio
import json
from dataclasses import replace
from typing import Any

from connector.runtime_protocol import (
    RuntimeInvalidRequestError,
    RuntimeSessionSourceStateCache,
    RuntimeSessionStateCache,
    SessionNotice,
)
from connector.runtimes.codex.domain.notices import CodexNoticeRegistry
from connector.runtimes.codex.notifications.notices import CodexNoticeHandler
from connector.runtimes.codex.sdk.runtime_client import CodexThreadReadResult
from connector.runtimes.codex.sessions.reader import CodexSessionReader


class _Host:
    def __init__(self) -> None:
        self.notices: list[SessionNotice] = []

    async def notice_upsert(self, notice: SessionNotice) -> None:
        self.notices.append(notice)


class _Client:
    def __init__(self) -> None:
        self.reads = 0
        self.answer_call_id: str | None = None
        self.fail_next = False

    async def read_thread(self, *, thread_id: str, include_turns: bool) -> CodexThreadReadResult:
        self.reads += 1
        if self.fail_next:
            self.fail_next = False
            raise RuntimeInvalidRequestError("synthetic read failure")
        items: list[dict[str, Any]] = [{
            "id": "question", "type": "function_call",
            "name": "request_user_input_async", "call_id": "question-call",
            "arguments": json.dumps({"questions": [{"title": "Synthetic question?"}]}),
        }]
        if self.answer_call_id is not None:
            question_id = json.dumps(["request_user_input_async", self.answer_call_id, 0])
            payload = json.dumps([{
                "questionItemId": question_id,
                "question": "Synthetic question?", "answer": "Synthetic answer.",
            }])
            items.append({
                "id": "answer", "type": "message", "role": "user",
                "content": [{"type": "input_text", "text":
                    "<send_user_message_question_reply>\n" + payload
                    + "\n</send_user_message_question_reply>"}],
            })
        return CodexThreadReadResult(thread={"id": thread_id, "status": "idle", "items": items})


async def _noop(*args: Any, **kwargs: Any) -> Any:
    return None


def _reader() -> tuple[CodexSessionReader, _Client, _Host, CodexNoticeRegistry]:
    host = _Host()
    client = _Client()
    notices = CodexNoticeRegistry()
    states = RuntimeSessionStateCache("codex", host)
    handler = CodexNoticeHandler(host=host, session_states=states, active_turn_ids={}, notices=notices)
    reader = CodexSessionReader(
        host=host, client=client, session_states=states,
        source_states=RuntimeSessionSourceStateCache("codex", host),
        ensure_started=_noop, list_model_catalog=_noop, list_permission_catalog=_noop,
        notice_handler=handler,
    )
    return reader, client, host, notices


def test_external_codex_answer_resolves_a_previously_cached_async_question() -> None:
    async def run() -> None:
        reader, client, host, notices = _reader()
        await reader.refresh_async_input_notices("session", "thread")
        assert len(notices.current_for_session("session")) == 1
        client.answer_call_id = "question-call"
        await reader.refresh_async_input_notices("session", "thread")
        assert client.reads == 2
        assert notices.current_for_session("session") == ()
        assert host.notices[-1].status == "resolved"
        assert host.notices[-1].response_required is False
        assert host.notices[-1].actions == ()
    asyncio.run(run())


def test_answered_async_questions_keep_the_no_pending_read_fast_path() -> None:
    async def run() -> None:
        reader, client, _, notices = _reader()
        client.answer_call_id = "question-call"
        await reader.refresh_async_input_notices("session", "thread")
        assert notices.current_for_session("session") == ()
        await reader.refresh_async_input_notices("session", "thread")
        assert client.reads == 1
        await reader.refresh_async_input_notices("session", "thread", force=True)
        assert client.reads == 2
    asyncio.run(run())


def test_failed_recheck_preserves_pending_question_and_retries_later() -> None:
    async def run() -> None:
        reader, client, _, notices = _reader()
        await reader.refresh_async_input_notices("session", "thread")
        client.fail_next = True
        await reader.refresh_async_input_notices("session", "thread")
        assert client.reads == 2
        assert notices.current_for_session("session")[0].status == "open"
        client.answer_call_id = "question-call"
        await reader.refresh_async_input_notices("session", "thread")
        assert client.reads == 3
        assert notices.current_for_session("session") == ()
    asyncio.run(run())


def test_idle_or_another_question_reply_does_not_resolve_pending_input() -> None:
    async def run() -> None:
        reader, client, _, notices = _reader()
        await reader.refresh_async_input_notices("session", "thread")
        await reader.refresh_async_input_notices("session", "thread")
        assert client.reads == 2
        assert notices.current_for_session("session")[0].status == "open"
        client.answer_call_id = "different-call"
        await reader.refresh_async_input_notices("session", "thread")
        assert client.reads == 3
        assert notices.current_for_session("session")[0].status == "open"
    asyncio.run(run())


def test_only_async_questions_in_the_requested_session_bypass_the_cache() -> None:
    async def run() -> None:
        reader, client, host, notices = _reader()
        client.answer_call_id = "question-call"
        await reader.refresh_async_input_notices("session", "thread")
        completed = host.notices[-1]
        notices.upsert(replace(completed, notice_id="foreign", session_id="other", status="open"))
        notices.upsert(replace(completed, notice_id="approval", status="open", context={"method": "approval"}))
        await reader.refresh_async_input_notices("session", "thread")
        assert client.reads == 1
    asyncio.run(run())
