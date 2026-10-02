# Quest VEQ deployment safety contract

`quest-veq-dev.ps1` selects one write transport before acquiring the mutation
lock. Normal ADB shell remains the first choice; root is used only when
`-AllowRootFallback` was explicitly supplied and the read-only capability probe
selected it. A compound mutation is never replayed through another transport.

Every file transaction runs while the host holds `mutation.lock` and repeats
the app-stopped check, the `instances.json` SHA-256 CAS, and path checks inside
the same remote shell command. The canonical files, game, mods, and transaction
directories must be real directories (not symlinks), and `cd` plus `pwd -P`
must equal the host-verified canonical path. All owned destination leaves are
rejected when they are symlinks, including dangling symlinks. The lock directory
and exact token are also rechecked by each production transaction. Normal and
root use the same checks.

ADB uploads never target a game or mods leaf. They first land in a unique
shell-owned `/data/local/tmp` file. Under the lock, the transaction creates a
new private directory below the verified state directory, copies and hashes the
payload there, and atomically renames the verified regular file to its owned
leaf. This avoids `cp` following a destination symlink.

The lock command cleans a directory it created if token staging or promotion
fails. A tokenless orphan is reclaimed only when the lock directory is a real
directory, has no token, contains at most the expected regular `token.tmp`, and
is at least 60 seconds old. A young or unfamiliar lock fails closed.

Structured failures run their rollback trap before returning. In particular,
the managed-JAR removal restores the exact locked backup if `rm` performed the
deletion and then reported failure. `EnableDev` restores the managed JAR before
it restores `instances.json`, so it never intentionally re-enables the managed
slug while the managed JAR is absent. Atomic commits write a persistent
operation-specific marker before disarming their rollback trap. If ADB reports
an error after the remote commit, the host probes that marker and accepts the
commit without replaying it.

## Exact race guarantee

Android's available shell utilities do not expose an `openat(2)`/directory-fd
transaction API. The script therefore guarantees canonical verification
immediately before mutation, symlink rejection for owned leaves, unique private
staging, CAS, and rollback against cooperative launcher/script concurrency. It
also detects the parent/leaf swap simulations in the committed fault harness.
It cannot mathematically exclude a privileged or same-UID adversary swapping a
verified parent in the small interval between a `pwd -P` check and a later
pathname-based utility call. Such active hostile races remain out of scope; a
detected mismatch fails closed and no automatic transport retry occurs.

Run the offline verification with:

```powershell
pwsh -NoProfile -File scripts/quest-veq-dev.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/test-quest-veq-dev-transactions.ps1
```

The fault harness executes generated production shell commands locally in Git
Bash. It performs no ADB call and reports its exact case and syntax counts.
