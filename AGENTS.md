# Instructions for coding agents

Before changing this repository, read these files in order:

1. `PROJECT_STATUS.md`
2. `STACK.lock.json`
3. `TEST_RESULTS.md`
4. `BUILDING.md`
5. `MODS.md`
6. `CHECKSUMS.sha256`

The public v72 source snapshot is the `main` branch of
`https://github.com/Akramx15/questcraft-26.2-v72`. It starts from one squashed
public root commit and intentionally carries no development remotes, branches,
tags, or earlier commit history. The necat101 QuestCraft experiment and
Vivecraft repositories are references, not push targets. `AI_HANDOFF.md` is a
frozen historical Dev.2 record, not the current source of truth. Earlier
Personal and Lab values elsewhere in the repository are historical baselines
unless `STACK.lock.json` explicitly identifies them as current.

The checked-in v72 identity is `com.qcxr.qcxr.dev262`, version code `72`,
version name `6.0.1-26.2-vivecraft-personal.13`. The separately released APK
`QuestCraft-Vivecraft-26.2-personal.13-perfbase-cd079c65.apk` was built from
private development commit `cd079c65`; the later asset-index self-heal in this
source snapshot is not inside that APK. Always take component and APK hashes
from `STACK.lock.json` and `CHECKSUMS.sha256`; do not carry forward a historical
hash by filename alone.

Keep these constraints:

- Preserve the separate `com.qcxr.qcxr.dev262` package; do not replace, clear,
  or migrate stable QuestCraft automatically.
- Never commit APKs, build/device logs, account state, worlds, device serials,
  Quest backups, keystores, or signing secrets.
- Keep Vulkan and OpenXR enabled for the 26.2 profile unless a new branch and
  explicit test plan intentionally change the platform contract.
- Follow the binary synchronization chain in `BUILDING.md`: Vivecraft source
  to bundled JAR, LWJGL source to merged runtime, Pojlib source/assets to staged
  AAR, then Unity APK and verification.
- Keep all four `26.2` manifest blocks identical and update documented hashes
  when a managed artifact changes.
- Do not change the friend's Minecraft server, Tailscale routing, QGO/Magisk
  settings, or a connected headset unless the current task authorizes it.
- Do not call the managed mod stack accepted until each candidate wins a
  one-variable comparison under QGO Dynamic CPU4/GPU4. Compare only samples
  with matching actual refresh distributions; the application must not request
  a refresh rate or performance hint.

Prefer a focused branch and focused commits. Before every push, run the
relevant component tests, `scripts/verify-dev-apk.ps1` when an APK was built,
`git lfs fsck`, a secret scan, `git diff --check`, and `git status --short`.
