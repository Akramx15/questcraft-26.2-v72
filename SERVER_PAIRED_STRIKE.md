# Paired Strike server setup for v71 Lab RC1

Paired Strike is optional server support. Singleplayer already uses the
integrated server. A remote or Tailscale server falls back safely to ordinary
Vivecraft combat until it runs the exact matching Vivecraft JAR.

## Artifact

- Minecraft: `26.2`
- Java: `25` or newer
- Loader: Fabric `0.16.1` or newer; tested with `0.19.4`
- File: `exports/v71-lab-rc1-f33647e5/vivecraft-26.2-v71-lab-universal-client-server.jar`
- Size: `8,440,058` bytes
- SHA-256: `0661CB8877BD55B21C2A6D9F3759A66C74910F816934D4B8E72341C7946398D9`
- Fabric mod id: `vivecraft`
- Fabric version: `26.2-1.3.15`
- Source: `f33647e5f5288b76c4fa50737bf08d207e3a1b59`, tag `v71-lab-rc1`
- Source bundle SHA-256:
  `3FA3C8F732323B678924899F0DA38921BA4FBD628DFDF59AC8574B00866E5780`

The same archive is used on the Quest client and server. VEQ is client-only and
must not be placed on the server.
The internal version still reads `26.2-1.3.15`, so the full SHA-256—not the
filename or version string—is the authoritative v71 identity.

## Install

1. Stop the Fabric 26.2 server cleanly.
2. Back up its current Vivecraft JAR and `config/vivecraft-server-config.toml`.
3. Remove only the older Vivecraft JAR from `mods` so two copies cannot load.
4. Copy the exact universal JAR above into `mods` and verify its SHA-256.
5. Start the server and confirm Vivecraft loads without Mixin or linkage errors.
6. Join from v71 Lab and verify that the client receives Paired Strike support.

Defaults are generated automatically. The relevant values are equivalent to:

```toml
[vrChanges]
dualWielding = true

[vrChanges.pairedStrike]
enabled = true
windowTicks = 4
minimumCharge = 0.9
allowPvp = false
```

Keep PvP disabled unless every player explicitly agrees to the mechanic.

## Acceptance test

Remote-server support has not yet been validated. Before accepting it:

1. Record the damage and durability baseline with one axe.
2. Hit the same non-player mob with opposite hands within four ticks.
3. Confirm two damage events and one durability event from each used item.
4. Confirm same-hand, different-target, and expired-window strikes do not pair.
5. Confirm death, teleport, disconnect, and reconnect clear pending state.
6. Keep PvP disabled and run a 20-minute Tailscale session without a crash or
   inventory/combat desynchronization.

## Rollback

Stop the server, restore the backed-up Vivecraft JAR and config, and restart.
Clients without matching support automatically use ordinary Vivecraft combat;
there is no need to clear worlds or player data.
