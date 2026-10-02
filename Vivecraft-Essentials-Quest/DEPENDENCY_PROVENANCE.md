# Dependency provenance

## Runtime/build APIs

- Vivecraft Fabric 26.2 is a compile-only/runtime dependency and is not embedded
  in the distributable JAR.
- The reproducible local build used
  `work/device-backups/visor-baseline-20260828-quest3/mods/Vivecraft.jar` with
  SHA-256
  `A7C74ABC182C6607230F79356397F478A47BF2387D4B3AAF8E96E8C00512DB18`.

## Adapted project

This repository retains the LGPL-3.0-or-later history and license notices from
Joulias/VisorEssentialsPlus and PhoenixRa/VisorEssentials. The Quest port adapts
the wrist-inventory, potion-status, and quick-action concepts to Vivecraft APIs.
The isolated port branch was created from the local VEP tree at commit
`89050fd3824f809c95fb9f491dcb4f0b3e70533f`.

No `org.vmstudio.visor` classes, Visor renderer, Visor input engine, or other
MPL-licensed Visor runtime files are compiled or packaged in this artifact.
