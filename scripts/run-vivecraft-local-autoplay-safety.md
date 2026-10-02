# Local autoplay launch preflight

`run-vivecraft-local-autoplay.ps1 -Action ArmAndRun` now performs a read-only,
fail-closed headset-state check immediately before the one-shot Lab arm intent.
It reads only:

- `dumpsys CompanionService`, for explicit PIN/keyguard lock evidence;
- `dumpsys activity activities`, for the active PIN activity and Meta
  Guardian/`LaunchCheckRequires6dof` or “Finding position in room” UI.

Either dump failing, returning empty output, lacking an explicit unlocked PIN
state, or lacking an identifiable active activity stops the run. A detected PIN
or Guardian gate gives an operator-facing error and sends no arm or execute
intent. Resolve the prompt manually in the headset and rerun the helper.

The helper never enters a PIN, sends input, changes Guardian/boundary settings,
or targets Personal Stable. `Cancel` retains its existing authenticated Lab-only
cancel behavior and does not arm a run.

Host verification is device-free:

```powershell
pwsh -NoProfile -File scripts/run-vivecraft-local-autoplay.ps1 -Action SelfTest
pwsh -NoProfile -File scripts/test-run-vivecraft-local-autoplay-host.ps1
```
