# 0003. Zarr v3 multi-scale uint8 dB tile pyramids
Date: 2026-07-06
Status: accepted
Context: Unbounded-length audio requires load-what-is-visible tiling for spectrogram and waveform data, with LODs, chunked storage, compression, and cheap partial reads.
Decision: Precompute at ingest: uint8 dB STFT pyramid (max-pooled per LOD, OME-NGFF-inspired multiscale layout) and int16 min/max waveform peak pyramid, stored as Zarr v3 arrays (Blosc+Zstd, bitshuffle) under arrays/ in the .indra bundle. Zarr >= 3.1.6 (3.0.2–3.0.7 yanked for a data-loss bug).
Consequences: Regenerable cache (safe to delete), fast windowed reads for tile serving, one storage format across waveform/spec/embeddings; quantization to uint8 fixes display dynamic range at -100..0 dB.
Alternatives considered: HDF5 (worse concurrent-read story), raw npy tiles (no chunk compression/metadata), BBC audiowaveform .dat (waveform-only; kept as format reference).
