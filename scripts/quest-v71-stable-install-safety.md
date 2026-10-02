# v71 Stable install and rollback safety contract

This harness is for one package only: `com.qcxr.qcxr.dev262`. It has no
package, profile, component, candidate-APK, or acceptance-manifest override.
`SelfTest` is the default and is Host-only. `Plan` is also Host-only.

## Promotion prerequisites

No device phase can begin until all of these Host gates pass:

1. `V71_STABLE_ACCEPTANCE.lock.json` has status
   `ACCEPTED_FOR_STABLE_BUILD` and the full reviewed evidence validator
   revalidates the locked two soaks, performance campaign, raw reports, and
   manual receipt.
2. A reviewed `V71_STABLE.lock.json` exists. Create it from
   `V71_STABLE.lock.template.json` only after the Stable APK is built and
   independently verified. The install lock binds the exact APK path, SHA-256,
   byte length, package, version code/name, v2 signer, RC3 Core/VEQ pair, LWJGL,
   accepted-evidence manifest hash, exact v69 baseline, reviewer, and policy.
   The template itself is deliberately unusable.
3. `scripts/backup-v71-stable-data.ps1 -Action Backup` has completed against
   exact stopped v69. Supply its `BACKUP_MANIFEST.json` and independently
   computed SHA-256. The install harness rehashes the manifest, every listed
   file, and `SHA256SUMS.sha256`; it rejects reparse points, missing files,
   path collisions, non-allowlisted roots, and account/authentication-like
   names.
4. The installed package is still exact v69: version `69` /
   `6.0.1-26.2-vivecraft-personal.10`, base APK size `126700777`, SHA-256
   `05381EBB9F25ACC4D2ED4C24D83DD2C4C4BF52366D2BCC89A5D85361FC749034`,
   and signer
   `B9BC192248354C7330EAE3781C39A5B569407F0DCCBCAF354C706DEE14D4CA1A`.
   The base APK is pulled read-only and fully inspected on the Host before
   replacement. That exact pulled APK is retained under the ignored receipt
   directory as `v69-rollback.apk`.

## Explicit phases

Use one receipt directory below `artifacts/stable-v71-install/` for the whole
campaign. Re-supply the exact backup manifest path and hash for every phase.
The commands below are examples; replace placeholders with reviewed absolute
or repository-relative paths.

```powershell
pwsh -NoProfile -File scripts/quest-v71-stable-install.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/test-quest-v71-stable-install-host.ps1

pwsh -NoProfile -File scripts/quest-v71-stable-install.ps1 `
  -Action Install `
  -StableLockPath V71_STABLE.lock.json `
  -BackupManifestPath 'C:\path\to\BACKUP_MANIFEST.json' `
  -BackupManifestSha256 'PASTE_SHA256_HERE' `
  -ReceiptDirectory 'artifacts/stable-v71-install/PASTE_CAMPAIGN_NAME_HERE' `
  -AllowDeviceRead -AllowDeviceWrite -AllowForceStop -AllowInstallReplace

pwsh -NoProfile -File scripts/quest-v71-stable-install.ps1 `
  -Action VerifyInstalled `
  -StableLockPath V71_STABLE.lock.json `
  -BackupManifestPath 'C:\path\to\BACKUP_MANIFEST.json' `
  -BackupManifestSha256 'PASTE_SHA256_HERE' `
  -ReceiptDirectory 'artifacts/stable-v71-install/PASTE_CAMPAIGN_NAME_HERE' `
  -AllowDeviceRead -AllowDeviceWrite -AllowForceStop

pwsh -NoProfile -File scripts/quest-v71-stable-install.ps1 `
  -Action ThreeNormalStarts `
  -StableLockPath V71_STABLE.lock.json `
  -BackupManifestPath 'C:\path\to\BACKUP_MANIFEST.json' `
  -BackupManifestSha256 'PASTE_SHA256_HERE' `
  -ReceiptDirectory 'artifacts/stable-v71-install/PASTE_CAMPAIGN_NAME_HERE' `
  -AllowDeviceRead -AllowDeviceWrite -AllowForceStop -AllowLaunch

pwsh -NoProfile -File scripts/quest-v71-stable-install.ps1 `
  -Action Final30MinuteGate `
  -StableLockPath V71_STABLE.lock.json `
  -BackupManifestPath 'C:\path\to\BACKUP_MANIFEST.json' `
  -BackupManifestSha256 'PASTE_SHA256_HERE' `
  -ReceiptDirectory 'artifacts/stable-v71-install/PASTE_CAMPAIGN_NAME_HERE' `
  -AllowDeviceRead -AllowDeviceWrite -AllowForceStop -AllowLaunch
```

The phases emit, respectively:

- `01-install-and-immediate-verify.json`
- `02-post-install-verify.json`
- `03-three-normal-starts.json`
- `04-final-30m.json`

Each phase validates the complete preceding receipt chain by hash and exact
lock/evidence/backup bindings before proceeding. The install phase verifies the newly installed
`base.apk` immediately; the second phase repeats that hash, identity, size,
v2-signature, and signer proof independently. The third phase uses three
separate stopped-to-started launcher cycles and requires fresh log bytes, the
exact RC3 Fabric versions, OpenXR focus/frame submission, the live game JVM,
and exact physical Core/VEQ hashes after every start. The final phase is a
separate 1,800-second survival/persistence gate with at most ten seconds
between health samples. It is not a new performance or manual-interaction
claim.

The harness starts only the normal launcher component. It does not arm
autoplay or send key, touch, controller, or random input. If normal launcher
interaction is needed, the operator performs it in the headset. Every phase
force-stops the app before returning, including handled failures.

## Rollback boundary

Failure rollback is opt-in. Add both `-AllowRollbackOnFailure` and
`-AllowInstallReplace` to a phase only when a conservative rollback attempt is
wanted. The only attempted rollback is the exact, fully verified,
same-signer `v69-rollback.apk` captured before installation, using exactly:

```text
adb -s <selected-serial> install -r <exact-v69-apk>
```

The harness intentionally does not add Android's downgrade override. Android
will normally reject a lower version code after v71 is installed. That
rejection is terminal: the app is stopped and the harness does not uninstall,
clear data, change ownership, copy profile data back, or bypass package-manager
protection. A separately requested `RollbackToV69` action follows the same
rule and additionally requires `-AllowRollbackDowngrade`; that switch grants
intent to attempt the downgrade, not authority to add a downgrade flag.
For later phases, failure rollback is eligible only after that phase has first
re-proven the exact installed v71 APK; connection alone never makes an unknown
installed state eligible.

## Permanent prohibitions

- no uninstall or `pm clear`;
- no downgrade override, split install, test-only install, or package override;
- no account, authentication, credential, or token file access;
- no root, `run-as`, ownership, permission, QGO, Magisk, Tailscale, or profile
  mutation;
- no APK, device serial, raw logcat, account state, or backup content in Git.

Only aggregate receipts belong in the ignored local artifact directory. Do
not call v71 post-install accepted until all four exact receipt hashes have
been reviewed.
