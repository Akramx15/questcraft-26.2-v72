# Personal 26.2 default mod seed

`STACK.lock.json` is the machine-readable source of truth. The `26.2` block in
all four Pojlib manifests is equivalent, and every default file is verified
with SHA-256 during initial profile creation or an explicit repair.

## Seed-only ownership

`com.qcxr.qcxr.dev262` uses `seed-only` mod management for Minecraft 26.2.
The launcher installs the compatible defaults once for a new profile. After
that succeeds, ordinary Play never restores a deleted JAR, overwrites a
manually updated JAR, removes an extra mod, or rewrites mod metadata. Existing
Personal profiles migrate by recording ownership metadata only; their files
are not reconciled during migration. Lab and other package IDs retain their
strict canary behavior.

An explicit connected Repair may restore the current pinned default slots, but
it preserves extra/manual entries and missing manual downloads. Repair is a
user-requested recovery operation, not part of normal Play.

## Default set

| Component | Version | SHA-256 |
| --- | --- | --- |
| QuestCraft Vivecraft | `26.2-1.3.15+qc.v71.rc8-mining` | `ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB` |
| [Fabric API](https://modrinth.com/mod/fabric-api/version/UWwhUX3k) | `0.160.0+26.2` | `5F3DFF88E1661166E222213302B25ACE6C36DC3683804CBD4B5ACF93138EA05E` |
| [Sodium](https://modrinth.com/mod/sodium/version/A0IzDzaH) | `0.9.2-beta.1` | `6652B40EE7F0F6D146C668CD288F861D271BC935C12F767D33B6B07BDCB7857A` |
| [Lithium](https://modrinth.com/mod/lithium/version/f7vZ0VWU) | `0.25.3` | `FDDE92E238E8075F89AD7F701F2A3D5854AF88BA9A67657184A4407B104AC563` |
| [FerriteCore](https://modrinth.com/mod/ferrite-core/version/d5ddUdiB) | `9.0.0` | `213966C72ED967ACC7392BEB28A866FBA301FF56B9976C2E7801C2DB7DE6BF22` |
| [BadOptimizations](https://modrinth.com/mod/badoptimizations/version/JmPs4Wie) | `2.4.1` | `06CEE46D81D3A0AFB8E993DFBE4B990A3BE92F52ABDE3590CC396490CB6EB4D2` |
| [Text Placeholder API](https://modrinth.com/mod/placeholder-api/version/NDqH16LT) | `3.1.0-beta.1` | `C2CA2B5C397A0C198A32E7AF68D2D0A011BC2C7BAEAE5CFFD3996EFD65C5069E` |
| [Mod Menu](https://modrinth.com/mod/modmenu/version/njXb639R) | `20.0.1` | `81BFBCA06012C57C74949072F2FFAAD06360BADEE4D00DC59BFAEAC80DD24BD8` |
| [ImmersiveMC](https://modrinth.com/mod/immersivemc/version/EaSE97uU) | `1.6.0-alpha4.1` | `2BCAA1B4A9F2E8CC47B8F0C28866A2C2328B49F0EDE5111AC0BA0B4FD17CD342` |
| [Xaero's Minimap](https://modrinth.com/mod/xaeros-minimap/version/tBIPWIKW) | `26.5.0` | `E12BBDCC149E865F0724F380C4DE3026FC4F11312E6BB2394734C85E568B4343` |
| Vivecraft Essentials Quest | `0.7.0-v71.rc6` | `FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9` |

Sodium `0.9.2-beta.1` is the current Personal seed; use `0.9.1` as a
conservative rollback if it causes a Quest/Vulkan regression.
ImmersiveMC multiplayer features still require compatible server support.
The historical v61 launcher smoke reconciled the physical `26.2` profile to Vivecraft
`574C4592...0FEE` and VEQ `1419CCFA...8A1E`; Fabric Loader 0.19.4 loaded the
stack successfully. This is a combined compatibility smoke, not an isolated
performance acceptance. Sodium alpha 4 has not yet won a normalized one-variable Quest
A/B against `0.9.1`. Lithium, FerriteCore, and BadOptimizations have also only
passed the combined runtime smoke, not an isolated normalized A/B. Their
inclusion remains a personal candidate decision rather than a measured per-mod
performance claim.

The default Quick Action is named “World Map”, but v68 currently stages only
Xaero's Minimap. The baseline fallback can match Xaero's `toggle_map` binding,
so it may toggle the minimap instead of opening a full map; treat that action as
unaccepted until the manual gate or the settings canary replaces it. Add
[Xaero's World Map for 26.2](https://modrinth.com/mod/xaeros-world-map/version/NzjI8AbM)
only as a later one-variable feature canary; do not silently fold a twelfth JAR
into the staged v68 stack.

## Vivecraft Essentials Quest slot

The local wrist/quick-actions add-on is never represented by a fake URL or a
zero hash. The current embedded Personal seed is `0.7.0-v71.rc6`, SHA-256
`FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9`.
The older v68 artifact was release `0.7.0`, SHA-256
`6575A2A436F1FF74898950A9D781B18641707621CAFAE064BB61A9709C1696B9`.
It is gameplay-entry equivalent to the user-accepted `0.7.0-rc.2.7` artifact
(`90D854125ACCBA23802D0FE7788A8C2FFBA24AA0CF90FBEC5A90DDB3DDE866E5`):
240 gameplay entries are byte-identical, while only release metadata and the
generated Architectury injection entry differ.
It registers independent wrist and carried-item surfaces, uses the VEP-style
3x3 hotbar/9x3 inventory with armor, offhand, crafting, creative and status
content, and preserves Quick Actions. A claimed global container remains the
native Minecraft lifecycle owner while only its ordinary GUI-plane draw and
pointer are suppressed; the wrist surface owns click/drag/release without
packets or direct inventory mutation. Grip uses the compact 98x98 center/eight
direction layout with independent right-main and left-offhand sessions.
The core scopes Wrist to `504x270 @2x` and Grip to `98x98 @4x`
through the same projection, scissor, cursor and carried-item metrics. The
accepted `rc.2.7` hot-deploy passed the user's manual functional gate. Release
`0.7.0` passed reproducible Host and Pojlib packaging gates. The full v68 APK
also passed its Host build and artifact checks at SHA-256
`0F218BB5542E90EA19E22E6763AE5A4D10995B6A2494439108385FC8DD2C00E1`;
same-signer installation, profile reconciliation and runtime/performance gates
remain pending and are recorded separately in `TEST_RESULTS.md`. The overlay
contract dispatches left/right/middle
clicks and vertical scroll, but this remains Host-only until a supervised Quest
container/Creative/JEI test. Optional integrations are still key-mapping based:
v68 does not embed Xaero's minimap texture into the wrist and does not contain
mod-specific JEI or Inventory Profiles Next adapters. Those are explicit later
feature tasks, not accepted v68 functionality.

For history only, v61 staged VEQ `0.2.0+mc26.2` at SHA-256
`1419CCFA78FF390EC38E2A448F1051365075D64A96CF94F6A2EA997C2CAA8A1E`.
That older artifact passed an unattended Quest startup/render smoke and
migrated the runtime config to schema 2, but controllers were inactive. Those
facts are not v67 runtime evidence.
Its actual inclusion state is recorded in `STACK.lock.json`; pin it atomically
when bringing that artifact into a wrapper worktree:

```powershell
.\scripts\pin-vivecraft-essentials-quest.ps1 `
  -JarPath 'C:\path\to\vivecraft-essentials-quest.jar' `
  -Version 'PASTE_VERSION_HERE'
```

The script validates `fabric.mod.json`, computes SHA-256, stages the asset, and
updates all four manifests, `CHECKSUMS.sha256`, and `STACK.lock.json` together.
It does not claim Quest/runtime acceptance.

## User-owned changes

After the first seed, every JAR in the Personal profile is user-owned. It may be
added, updated, renamed, disabled, or removed without the launcher undoing that
choice on the next Play. `disabledMods` remains compatible metadata, but normal
Personal Play no longer needs it to protect a removal. Core compatibility is
still the user's responsibility when changing Vivecraft, Fabric Loader, or
rendering mods.

## Excluded from v68

`ImmediatelyFast`, `EntityCulling`, `MoreCulling`, `Krypton`, Distant Horizons,
and ViveMonkeCraft are intentionally absent. They must not be copied into a v68
profile by the installer. This keeps the first Vivecraft Personal measurement
free of known stereo-risk and native-library confounders.

## Runtime acceptance

The managed list is reproducible and Host/build/artifact verified. The v68 APK
has not yet been installed or runtime-smoked on Quest, so it is not a v68
Stable/FPS or runtime claim. The matching gameplay payload was manually accepted
only in the earlier `rc.2.7` hot-deploy.
Test one variable at a time with
`scripts/quest-vrapi-pid-benchmark.ps1`, QGO Dynamic, and CPU/GPU 4/4. Compare
only windows with similar actual refresh distribution. Reject a candidate for
a stereo defect, crash, persistent regression, compositor stale-frame pattern,
or new thermal/GC instability.
