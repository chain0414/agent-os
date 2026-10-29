"""Native Codex turn timing; observation and import clocks are never durations."""

from __future__ import annotations

import math
from collections.abc import Mapping
from typing import Any


def native_turn_timing(turn: Mapping[str, Any]) -> dict[str, Any] | None:
    timing: dict[str, Any] = {}
    for native, snake, output in (
        ("durationMs", "duration_ms", "durationMs"),
        ("startedAt", "started_at", "startedAt"),
        ("completedAt", "completed_at", "completedAt"),
    ):
        value = turn.get(native, turn.get(snake))
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
            or value < 0
        ):
            continue
        # Codex Turn timestamps are Unix seconds; public timing uses milliseconds.
        timing[output] = value if output == "durationMs" else value * 1000
    status = turn.get("status")
    if isinstance(status, str) and status:
        normalized = (
            status
            if status in {"completed", "failed", "interrupted", "inProgress"}
            else "unknown"
        )
        # A completed item already has an accurate default state. Keep status-only
        # exceptional/active turns, but do not add redundant completion upserts.
        if timing or normalized != "completed":
            timing["status"] = normalized
    return timing or None
