"""In-memory sliding-window rate limits (docs/design.md §7.3). One process,
so memory is enough; a restart forgets, which only makes limits looser."""

from __future__ import annotations

import threading
import time
from collections import defaultdict, deque


class RateLimiter:
    def __init__(self, limit: int, window: float, clock=time.monotonic):
        self.limit = limit
        self.window = window
        self.clock = clock
        self.hits: dict[str, deque] = defaultdict(deque)
        self.lock = threading.Lock()

    def allow(self, key: str) -> bool:
        now = self.clock()
        with self.lock:
            hits = self.hits[key]
            while hits and now - hits[0] >= self.window:
                hits.popleft()
            if len(hits) >= self.limit:
                return False
            hits.append(now)
            return True

    def retry_after(self, key: str) -> int:
        with self.lock:
            hits = self.hits.get(key)
            if not hits:
                return 0
            return max(1, int(self.window - (self.clock() - hits[0])) + 1)
