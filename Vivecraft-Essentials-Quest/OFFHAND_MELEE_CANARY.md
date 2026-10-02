# Offhand melee canary

This canary gives one fresh left-trigger press an `OFFHAND_ATTACK` meaning only
when all of the following are true:

- the server explicitly negotiated Vivecraft `DUAL_WIELDING`;
- the offhand contains an enabled sword, axe, or Vivecraft sword-tag item;
- the immutable logical-left ray hits an attackable entity in range and inside
  the world border; and
- Minecraft's ordinary attack-charge gate permits the item.

Otherwise LT retains offhand use. If a negotiated melee/entity intent fails a
safety gate, that press is blocked and cannot fall through to entity use. A
one-shot latch prevents a held trigger from replaying or changing meaning after
tracking, ownership, target, or capability changes.

## Protocol boundary

Minecraft 26.2's `ServerboundAttackPacket` carries only an entity id; it has no
hand field. The canary therefore sends Vivecraft's negotiated active body part
before the ordinary attack call and resets it in `finally`. It never swaps
inventory slots or emits a fabricated offhand attack on a Vanilla server.

Minecraft normally exposes one `attackStrengthTicker` per player. The existing
Vivecraft `DUAL_WIELDING` capability negotiates active-item selection, not
separate attack clocks, so peers ending at that protocol version keep the
Vanilla shared clock.

This branch appends `INDEPENDENT_HAND_COOLDOWN` to `NetworkVersion`. When both
client and server negotiate that version and dual wielding is enabled,
`PlayerMixin` selects a second attack/item-swap clock while the active body part
is `OFF_HAND`. The same code runs in the integrated server, so singleplayer has
authoritative independent clocks too. Main hand remains on Minecraft's original
fields. A Vanilla remote server gets no offhand attack packet; an older
Vivecraft server may accept the offhand attack but keeps the shared cooldown.
