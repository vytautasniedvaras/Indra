"""FastAPI app factory with lifespan-managed resources (BUILD_SPEC §4.1, §4.5)."""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse

from indra.api.errors import install_error_handlers
from indra.api.routes import router
from indra.config import ServerConfig
from indra.history.manager import HistoryManager
from indra.jobs.registry import JobRegistry
from indra.storage.cache import CacheIndex
from indra.storage.db import Database
from indra.storage.paths import ProjectPaths

_AUTH_EXEMPT = {"/health"}


def create_app(config: ServerConfig) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        paths = ProjectPaths(config.project_root)
        paths.ensure()
        db = Database(paths.db)

        def active_audio_ids() -> set[str]:
            return {str(row["id"]) for row in db.query("SELECT id FROM audio_files")}

        cache = CacheIndex(
            db, paths, config.cache_limit_bytes, active_ids_provider=active_audio_ids
        )
        registry = JobRegistry(db, cache, max_workers=config.resolved_max_workers())
        app.state.config = config
        app.state.paths = paths
        app.state.db = db
        app.state.cache = cache
        app.state.jobs = registry
        app.state.history = HistoryManager(db)
        try:
            yield
        finally:
            await registry.shutdown()
            db.close()

    app = FastAPI(title="Indra engine", version="0.1.0", lifespan=lifespan)
    install_error_handlers(app)

    @app.middleware("http")
    async def bearer_auth(request: Request, call_next) -> Response:  # type: ignore[no-untyped-def]
        if request.url.path not in _AUTH_EXEMPT:
            auth = request.headers.get("authorization", "")
            if auth != f"Bearer {config.token}":
                return JSONResponse(
                    status_code=401,
                    content={
                        "error": {
                            "code": "unauthorized",
                            "message": "missing or invalid bearer token",
                            "details": {},
                        }
                    },
                )
        response: Response = await call_next(request)
        return response

    app.include_router(router)
    return app
