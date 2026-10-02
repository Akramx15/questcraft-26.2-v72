# Third-party notices

## Visor hotbar artwork and interaction geometry

The files under
`mod-core/src/main/resources/assets/vivecraft_essentials_quest/textures/gui/hotbar/`
are adapted from the Visor hotbar overlay at upstream commit
`df2b55b3c679e5e9d012d24dc627fbd3b96a96fd`:

<https://github.com/snooped-xl/Visor>

The original assets and the adapted `HotbarGridLayout.java`,
`HotbarRadialSelector.java`, and `HotbarRadialScreen.java` files are governed
by the Mozilla Public License 2.0. A full copy is
included in the distributable JAR at
`META-INF/licenses/Visor-MPL-2.0.txt`.

QuestCraft changes rename the resource namespace, connect the selector to
Vivecraft's Vulkan-backed radial surface, and route release actions through
Minecraft's server-authoritative inventory operations. No Visor renderer,
OpenXR provider, combat system, or AtumVR code is included.
