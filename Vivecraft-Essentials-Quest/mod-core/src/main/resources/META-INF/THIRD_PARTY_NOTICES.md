# Third-party notices

The hotbar artwork under
`assets/vivecraft_essentials_quest/textures/gui/hotbar/` and the adapted
`HotbarGridLayout`, `HotbarRadialSelector`, and `HotbarRadialScreen` source
files derive from Visor commit
`df2b55b3c679e5e9d012d24dc627fbd3b96a96fd`:

<https://github.com/snooped-xl/Visor>

Those files are governed by the Mozilla Public License 2.0. The complete
license is packaged beside this notice at
`META-INF/licenses/Visor-MPL-2.0.txt`.

The QuestCraft adaptation renames the resource namespace, uses Vivecraft's
Vulkan-backed radial surface, and routes release actions through Minecraft's
server-authoritative inventory operations. It includes no Visor renderer,
OpenXR provider, combat system, or AtumVR code.
