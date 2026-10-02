# Grip v67 Host Report

- Source base: `44f37995`
- Corrective parent: `665a3930`
- Branch: `agent/v67-grip`
- VEQ version: `0.7.0+mc26.2`
- Build JDK: Eclipse Adoptium Java 25
- Vivecraft compile dependency SHA-256:
  `917B75DA63D7EBBCB7CE5A415DCBCB723159E53264A2C4CB8994A8D377C85C85`
- Candidate JAR:
  `mod-fabric/build/libs/VivecraftEssentialsQuest-0.7.0+mc26.2-fabric.jar`
- Candidate JAR size: `343899` bytes
- Candidate JAR SHA-256:
  `AC909393A567F9637A4246C74CF8FE3E2B4D14CB7634B04A7F76DB8775BB243E`

## Implemented contract

- One independent external-overlay surface, logically `98x98` and rendered at
  `196x196`.
- Default physical width approximately `0.22m`, distance `0.35m`.
- Center deadzone `8%`; radial hysteresis `4%`.
- Independent RIGHT/main and LEFT/offhand logical selection state.
- A held second Grip is queued and receives the surface after the first Grip
  releases, including the deferred server-confirmed offhand-swap path.
- LEFT uses one vanilla `ContainerInput.SWAP`, rejects the active main slot,
  and records its marker only after state-id and contents confirmation.
- Pending SWAP keeps the released LEFT surface visible and read-only with a
  yellow syncing indicator. Rejection uses a red slot overlay for four client
  ticks; neither feedback phase can dispatch a second transaction.
- A queued hand is rechecked for held Grip, runtime identity, and current
  ownership immediately before promotion; failed arbitration stays pending or
  closes without a surface selection.
- The offhand marker renders only for LEFT, follows logical item type across
  count/durability changes, and is scoped to the exact level, player,
  inventory, menu, and monotonic session state-id lineage. Cancel, disconnect,
  respawn, or inventory-session replacement clears it.
- Per-hand scale, distance, and sensitivity are persisted atomically in
  `config/vivecraft_essentials_quest/grip_hotbar.json`.
- `RadialHotbarController.owns(controller)` is the small shared ownership seam;
  world-action routing integration is intentionally excluded from this commit.

## Verification

The following clean command completed successfully with 60 actionable tasks:

```text
gradlew clean check :mod-fabric:build --no-daemon -Plocal_vivecraft_fabric_jar=<pinned-current-vivecraft>
```

This includes the full pre-existing VEQ host suite and new tests for session
transfer, offhand marker validity, per-hand config persistence/sanitization,
surface dimensions, and selector ratios. No Quest runtime or FPS claim is made.
No device, APK, profile, Pojlib source, or user data was changed.
