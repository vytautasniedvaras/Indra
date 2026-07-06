# 0010. Permissive-only dependency policy with named exclusions
Date: 2026-07-06
Status: accepted
Context: Indra is a distributable native app; copyleft or non-commercial licenses in the engine would infect or encumber it.
Decision: Only permissive licenses (MIT/BSD/Apache-2/CC0) may be added, verified per-dep in docs/licenses.md and enforced by a CI license gate. Named exclusions (do not add, even transitively): Essentia (AGPL-3.0), madmom (CC-BY-NC weights, abandoned), aubio (GPL-3.0), LarsNet (CC-BY-NC), CLAPSep family (CC-BY-NC-ND). Vendored code keeps upstream LICENSE + source URL + commit SHA under _vendor/.
Consequences: Some best-in-class MIR tools are off the table (reimplement or substitute); AudioSep ships only after weight-license clarification; every dependency addition carries a small verification cost.
Alternatives considered: case-by-case licensing (risk of accidental AGPL contamination), GPL-and-release-source (conflicts with product intent).
