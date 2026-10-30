from __future__ import annotations

import asyncio
import hashlib
import math
import secrets
import time
from collections import deque
from collections.abc import Callable

from agent_server.infra.redis_coordinator import RedisCoordinator

_ACQUIRE = """
local clock = redis.call('TIME')
local now = tonumber(clock[1]) * 1000 + math.floor(tonumber(clock[2]) / 1000)
redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now - 60000)
if redis.call('ZCARD', KEYS[1]) >= 10 then
  local oldest = redis.call('ZRANGE', KEYS[1], 0, 0, 'WITHSCORES')
  return math.max(1, math.ceil((tonumber(oldest[2]) + 60000 - now) / 1000))
end
redis.call('ZADD', KEYS[1], now, ARGV[1])
redis.call('PEXPIRE', KEYS[1], 60000)
return 0
"""


class SpeechRateLimiter:
    """A rolling minute limit shared through Redis; bounded local fallback."""

    def __init__(
        self,
        coordinator: RedisCoordinator,
        *,
        max_local_users: int = 4096,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._coordinator = coordinator
        self._max_local_users = max_local_users
        self._clock = clock
        self._local: dict[str, deque[float]] = {}
        self._lock = asyncio.Lock()

    async def acquire(self, user_id: str) -> int:
        user_key = hashlib.sha256(user_id.encode("utf-8")).hexdigest()
        if self._coordinator.distributed:
            return int(
                await self._coordinator.client.eval(
                    _ACQUIRE,
                    1,
                    self._coordinator.key("speech-rate", user_key),
                    secrets.token_hex(16),
                )
            )
        async with self._lock:
            now = self._clock()
            for key in list(self._local):
                timestamps = self._local[key]
                while timestamps and timestamps[0] <= now - 60:
                    timestamps.popleft()
                if not timestamps:
                    del self._local[key]
            if user_key not in self._local:
                if len(self._local) >= self._max_local_users:
                    # Evicting active users would let callers reset their limits.
                    return 60
                self._local[user_key] = deque()
            timestamps = self._local[user_key]
            if len(timestamps) >= 10:
                return max(1, math.ceil(timestamps[0] + 60 - now))
            timestamps.append(now)
            return 0
