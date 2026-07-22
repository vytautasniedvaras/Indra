"""Project bundle (.indra directory) layout. See BUILD_SPEC §4.2."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from indra import ENGINE_VERSION

PROJECT_FORMAT_VERSION = 1


@dataclass(frozen=True)
class ProjectPaths:
    root: Path

    @property
    def db(self) -> Path:
        return self.root / "project.sqlite"

    @property
    def manifest(self) -> Path:
        return self.root / "manifest.json"

    @property
    def audio_dir(self) -> Path:
        return self.root / "audio"

    @property
    def arrays_dir(self) -> Path:
        return self.root / "arrays"

    @property
    def blobs_dir(self) -> Path:
        return self.root / "blobs"

    def waveform_zarr(self, audio_id: str) -> Path:
        return self.arrays_dir / "waveform" / f"{audio_id}.zarr"

    def spec_zarr(self, audio_id: str) -> Path:
        return self.arrays_dir / "spec" / f"{audio_id}.zarr"

    def features_dir(self, audio_id: str) -> Path:
        return self.arrays_dir / "features" / audio_id

    def blob_path(self, key: str, ext: str) -> Path:
        return self.blobs_dir / key[:2] / f"{key}.{ext}"

    def ensure(self) -> None:
        """Create the bundle skeleton and manifest if missing."""
        for d in (
            self.root,
            self.audio_dir,
            self.arrays_dir / "waveform",
            self.arrays_dir / "spec",
            self.arrays_dir / "features",
            self.blobs_dir,
        ):
            d.mkdir(parents=True, exist_ok=True)
        if not self.manifest.exists():
            self.manifest.write_text(
                json.dumps(
                    {
                        "format_version": PROJECT_FORMAT_VERSION,
                        "engine_version": ENGINE_VERSION,
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
