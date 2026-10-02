# Bow Guide resource packs

These example packs restyle only the Vivecraft bow guide. They never change
trajectory physics, collisions, damage, or the maximum sampled points.

- `bow-guide-arcane`: violet/gold ribbon with a star impact marker.
- `bow-guide-frost`: broad ice ribbon with a ring impact marker.
- `bow-guide-emerald`: compact dashed green ribbon.

Zip the contents of one pack directory so `pack.mcmeta` is at the archive
root, copy it to Minecraft's `resourcepacks` directory, then enable exactly
one bow-guide pack above the built-in Vivecraft resources. Resource reload is
enough; restarting QuestCraft is not required.

Pack authors can replace `assets/vivecraft/textures/misc/bow_guide_atlas.png`
as well as the JSON style. The JSON loader rejects invalid or oversized files
and safely falls back to the built-in style.
