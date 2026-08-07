## Rejoined ensemble

This transport run **rejoins** the harness-native sessions paired under an
earlier Duet run (`@OLD_SESSION_DIR@`). Your restored context may mention that
run's `DUET_SESSION`, `DUET_CONFIG`, session paths, roster, or pane values,
and your ambient environment may still carry that run's `DUET_SELF`/
`DUET_SESSION` — a child process cannot rewrite them, and duet's send/end
commands tolerate exactly that stale pair. All of it is **stale**: the pinned
session dir and config in THIS brief and your exact pane identity are the only
authority; use the paths shown above, never the ones in restored history or
inherited variables.

The earlier run's queues were **not** replayed: @OLD_UNDELIVERED@ queued message(s) were left undelivered. Its transcript is kept for reference at `@OLD_TRANSCRIPT@`.
