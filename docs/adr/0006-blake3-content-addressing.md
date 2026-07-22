# 0006. blake3 for content addressing
Date: 2026-07-06
Status: accepted
Context: The analysis cache key must be stable across re-decodes of the same audio and fast enough to hash hours of PCM at import time.
Decision: blake3 over decoded PCM (native sr/dtype, streamed in 1 s blocks) identifies audio content; cache_key = blake3("{audio_content_hash}|{kind}|{canonical_params_json}|{engine_version}")[:32]; blobs stored at blobs/<key[:2]>/<key>.<ext>.
Consequences: Deterministic resume-from-cache; multi-GB hashing at >1 GB/s; params must be canonically serialized (sort_keys, compact separators); engine_version bump discipline is mandatory to invalidate semantically-changed analyses.
Alternatives considered: SHA-256 (slower, no benefit locally), xxhash (faster but non-cryptographic; kept as dependency for non-key checksums), file-path+mtime keys (break on copies/moves).
