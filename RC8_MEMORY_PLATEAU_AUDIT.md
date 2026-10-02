# RC8 memory plateau audit

## Verdict

The two bounded RC8 memory windows show a high plateau, but they do not prove
a continuing leak. Do not change the JVM, Vulkan path, mod set, or Stable build
from this evidence.

The smallest admissible next experiment is a Lab-only, one-variable cold-launch
Canary:

```text
renderScaleFactor: 1.0 -> 0.8
```

It must begin only after the ordinary RC8 mining candidate is manually accepted
or diagnosed. The live Lab value was read without modification and is `1.0`.

## Evidence

- Final PSS: `2981.08 MiB`.
- Unknown: `1354.01 MiB` (`45.4%`).
- GL, Gfx-device, and EGL combined: `1164.04 MiB` (`39.1%`).
- Those two groups total `2518.06 MiB` (`84.5%`) and already exceed the
  historical `2457.6 MiB` absolute gate.
- The second observation window was flat: total PSS OLS `-0.33 MiB/min` and
  Native Heap OLS `+0.06 MiB/min`.
- Android's local summary reported zero useful Java heap counters, and
  `smaps_rollup` was unavailable. Unknown memory therefore cannot be attributed
  confidently to the HotSpot heap.

Keep the current personal policy at `Xms=512 MiB` and automatic
`Xmx=1536 MiB`. A lower heap ceiling would be an unrelated variable and could
increase GC pauses or cause a false failure.

Vivecraft applies `sqrt(renderScaleFactor)` to each framebuffer dimension, so
`0.8` reduces rendered pixel area by 20 percent while retaining the current
Vulkan/OpenXR pipeline.

## Canary isolation

- Package: `com.qcxr.qcxr.canary262` only.
- Exact RC8 APK, Core, VEQ, signer, JVM flags, mods, world snapshot, render and
  simulation distances, mipmaps, QGO CPU/GPU levels, and resource-pack state
  must remain fixed.
- Preserve the original Lab config byte-for-byte and record its SHA-256 before
  changing the single JSON value.
- Use atomic replacement and verify the resulting JSON and value.
- Do not touch Stable, root, accounts, worlds, mods, resource packs, package
  data, or Android performance hints.
- Run paired cold-launch samples in the order
  `A1-B1-B2-A2-A3-B3`, where A is `1.0` and B is `0.8`.

The server resource pack is explicitly out of scope. Historical measurements
involving it are not a reason to enable, disable, or benchmark it.

## Acceptance gates

The Canary may advance only when all of the following are true:

- Median post-warm PSS and RSS each fall by at least `128 MiB` in at least two
  of three comparable pairs.
- PID, focus, JVM identity, APK/Core/VEQ identities, and CPU4/GPU4 remain fixed.
- Measurement coverage is at least `95%`.
- Initial temperature and compared path differ by no more than `1 C`.
- Refresh-distribution distance is at most `5%`, mean and mode differ by at
  most `0.5 Hz`, and transition-count delta is at most one.
- Mean FPS and P10 lose no more than `1%` in any pair or in aggregate.
- P95 CPU+GPU improves by at least `3%`, or stable-refresh stale frames improve
  by at least `10%`, with wins in at least two of three pairs.
- Both eyes, HUD, Wrist, Grip, and mining have no unacceptable blur, aliasing,
  or interaction regression.

Even a successful short A/B does not clear the historical memory ceiling.
Promotion requires two new 90-minute soaks with max PSS and RSS at or below
`2457.6 MiB`, process swap at or below `512 MiB`, post-15-minute OLS at or below
`2 MiB/min`, last-30-minute growth at or below `128 MiB`, battery at or below
`47 C`, Android thermal status at or below 2, and no crash or LMK.

## Rollback

On any failure, stop Lab only, atomically restore the saved original bytes,
verify their SHA-256, and perform one cold launch that proves `1.0`, exact RC8
identity, Vulkan/OpenXR, and both-eye rendering. Do not use the packaged default
as the rollback source because it is copied only when the user config is absent.
