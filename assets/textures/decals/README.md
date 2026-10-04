# Bullet-hole decal texture.
#
# Place your PNG here:
#
#   assets/textures/decals/bullet_hole.png
#
# Specs that work well:
# - 256x256, RGBA with a transparent background.
# - A dark irregular ring / scorch mark with a soft alpha edge
#   (hard edges look like stickers on walls).
# - Mostly near-black; the Decal node multiplies it onto the surface.
#
# Then wire it up: open scenes/player.tscn, select the WeaponManager node,
# and set "Impact Texture" (under the Impacts group) to this PNG.
#
# Until then the game uses a procedural fallback blotch generated at runtime,
# so impacts still show without any texture assigned.
