from __future__ import annotations

from openai_codex.generated.v2_all import Thread, Turn

from connector.runtimes.codex.sdk.events import CodexSdkEvent
from connector.runtimes.codex.timeline.accumulator import CodexTimelineAccumulator
from connector.server.runtime_host import _timeline_item_payload
from connector.server.runtime_rpc_payloads import server_payload_without_turn_data


def native_turn(**extra):
    return {
        "id": "turn-a",
        "status": "completed",
        "startedAt": 100,
        "completedAt": 129,
        "durationMs": 29025,
        "items": [{"id": "a", "type": "agentMessage", "text": "ok"}],
        **extra,
    }


def timing(item):
    return item.content.get("turnTiming")


def test_raw_history_native_turn_timing_survives_server_projection():
    items = CodexTimelineAccumulator().items_from_thread_snapshot(
        "session", "thread", {"turns": [native_turn()]}, None
    )
    expected = {
        "startedAt": 100000,
        "completedAt": 129000,
        "durationMs": 29025,
        "status": "completed",
    }
    assert timing(items[0]) == expected
    payload = server_payload_without_turn_data(_timeline_item_payload(items[0]))
    assert payload["content"]["turnTiming"] == expected
    assert "turnId" not in payload


def test_typed_sdk_history_keeps_native_turn_timing():
    thread = Thread.model_construct(turns=[Turn.model_validate(native_turn())])
    items = CodexTimelineAccumulator().items_from_sdk_thread_snapshot(
        "session", "thread", thread, None
    )
    assert timing(items[0])["durationMs"] == 29025
    assert timing(items[0])["startedAt"] == 100000


def test_history_without_native_timing_does_not_use_observation_clock():
    turn = native_turn(startedAt=None, completedAt=None, durationMs=None)
    item = CodexTimelineAccumulator().items_from_thread_snapshot(
        "session", "thread", {"turns": [turn]}, None
    )[0]
    assert timing(item) is None


def test_live_turn_completion_backfills_native_timing_before_cleanup():
    accumulator = CodexTimelineAccumulator()
    accumulator.begin_turn("thread", "turn-a")
    accumulator.item_from_notification(
        "session",
        "thread",
        "item/completed",
        {"threadId": "thread", "turnId": "turn-a", "item": native_turn()["items"][0]},
    )
    event = CodexSdkEvent.from_parts(
        event_type="turn/completed",
        params={"threadId": "thread", "turn": native_turn()},
        raw={},
    )
    items = accumulator.finish_turn_timing("session", "thread", event)
    assert len(items) == 1
    assert timing(items[0])["durationMs"] == 29025
    accumulator.end_turn("thread", "turn-a")
    assert accumulator.finish_turn_timing("session", "thread", event) == ()


def test_invalid_native_duration_is_not_exported():
    for duration in [True, -1, float("inf"), "29000"]:
        turn = native_turn(startedAt=None, completedAt=None, durationMs=duration)
        item = CodexTimelineAccumulator().items_from_thread_snapshot(
            "session", "thread", {"turns": [turn]}, None
        )[0]
        assert timing(item) is None


def test_native_status_without_clock_remains_available_without_inventing_duration():
    from connector.runtimes.codex.timeline.timing import native_turn_timing

    for status in ["failed", "interrupted", "inProgress"]:
        value = native_turn_timing({"status": status})
        assert value == {"status": status}
        assert "durationMs" not in value
        turn = native_turn(
            status=status, startedAt=None, completedAt=None, durationMs=None
        )
        item = CodexTimelineAccumulator().items_from_thread_snapshot(
            "session", "thread", {"turns": [turn]}, None
        )[0]
        assert timing(item) == {"status": status}
    assert native_turn_timing({"status": "future-state"}) == {"status": "unknown"}
    assert native_turn_timing({"status": "completed"}) is None
    assert native_turn_timing({}) is None
