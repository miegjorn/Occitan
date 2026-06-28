# Occitan meta-repo

Cross-repo epics, GitHub scaffold scripts, component docs, and deploy manifests for the Occitan stack.

Stack: Gardian (7400) → Fondament → Farga (7500) → Amassada (7700) → Charradissa (8448) + Cor + Caissa (CLI + Helm charts). Guilhem org agent runs via `caissa listen` on port 8080.

Production dispatch path: Matrix event → Charradissa → Amassada POST /sessions/{room_id}/message → agent POST /turn → reply stripped of block markers → Matrix room.

docs/components/ — one doc per stack component, keep current with architecture changes.
deploy/manifests/ — raw Kubernetes manifests (reference only; Helm charts in Caissa are canonical).
scripts/github-scaffold/ — org setup scripts.
