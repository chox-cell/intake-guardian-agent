# SSOT (Single Source of Truth)

## Master Hash
MASTER_HASH: cad27d3d77eb97ef77da33f4b34bec4fb7f5ba6e7b3e73e90fb986bee78808f3

## Scope
- This repository is governed by SSOT + Manifest integrity checks.
- Agents must NOT add features beyond explicitly requested tasks.
- Any change that modifies runtime behavior MUST be deliberate and reviewed.

## Rules
1) Do not edit `.env*`, `data/`, secrets.
2) Only edit files required for the requested task.
3) After changes: run `pnpm typecheck` and `pnpm integrity:verify`.
4) Only the owner updates MASTER_HASH when a milestone is accepted.

## Notes
- MASTER_HASH is computed from `governance/manifest.json` (sha256).
