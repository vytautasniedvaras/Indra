# 0005. SSE (not WebSocket) for job progress streaming
Date: 2026-07-06
Status: accepted
Context: The app needs server→client streams of job progress/log/done/failed events. Client→server messages already have REST endpoints (cancel, etc.); full duplex is unnecessary.
Decision: Server-Sent Events via sse-starlette (GET /jobs/{id}/events). Swift side parses URLSession.bytes into an AsyncThrowingStream; stream termination triggers POST /jobs/{id}/cancel.
Consequences: Simpler protocol and testing (plain HTTP, curl -N works); reconnection semantics come free with SSE; no binary frames on the event channel (tiles go over plain GET).
Alternatives considered: WebSocket (duplex not needed, harder to test/proxy), long-polling (worse latency and lifecycle).
