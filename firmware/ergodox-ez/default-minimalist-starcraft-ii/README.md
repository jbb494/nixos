# ErgoDox EZ firmware

This is a locally maintained firmware based on the **Default minimalist
Starcraft II** Oryx layout.

- Oryx layout ID: `7mKlb`
- Oryx revision: `XbpYby`
- Oryx/QMK firmware version: `25.0`
- Keyboard target: `zsa/ergodox_ez/m32u4/base`
- ZSA QMK revision: `93b2b9ec3368f86c5eb5a2e3f934049f8daef885`
- ZSA modules revision: `13890cd7856175de20798689d15ba6a46bf0c5c7`
- Debounce delay: `5 ms`
- Archived: 2026-09-19
- [Latest layout](https://configure.zsa.io/ergodox-ez/layouts/7mKlb/latest/0)
- [Archived Oryx revision](https://configure.zsa.io/ergodox-ez/layouts/7mKlb/XbpYby/0)
- [Debounce settings](https://configure.zsa.io/ergodox-ez/layouts/7mKlb/latest/config/debounce)

The `source/` directory began as Oryx revision `XbpYby` and is now the source of
truth for local changes. In particular, the persistent StarCraft layer does not
illuminate the bright green layer-2 indicator. Oryx does not contain local
changes made after that revision.

`firmware.hex` is compiled from the checked-in source and is ready to flash.

## Flash the archived firmware

The NixOS keyboard module installs ZSA's `zapp` utility and the required udev
rules. From the repository root, verify and flash the artifact with:

```sh
(cd firmware/ergodox-ez/default-minimalist-starcraft-ii && sha256sum --check firmware.hex.sha256)
zapp flash firmware/ergodox-ez/default-minimalist-starcraft-ii/firmware.hex
```

Follow `zapp`'s prompt to put the keyboard into bootloader mode.

## Rebuild from source

Use the recorded revision of [ZSA's QMK fork](https://github.com/zsa/qmk_firmware):

```sh
repo="$PWD"
qmk setup zsa/qmk_firmware -b firmware25
cd "$HOME/qmk_firmware"
git checkout 93b2b9ec3368f86c5eb5a2e3f934049f8daef885
git submodule update --init --recursive
rm -rf keyboards/zsa/ergodox_ez/m32u4/keymaps/starcraft
cp -R "$repo/firmware/ergodox-ez/default-minimalist-starcraft-ii/source" \
  keyboards/zsa/ergodox_ez/m32u4/keymaps/starcraft
qmk compile -kb zsa/ergodox_ez/m32u4/base -km starcraft
cp zsa_ergodox_ez_m32u4_base_starcraft.hex \
  "$repo/firmware/ergodox-ez/default-minimalist-starcraft-ii/firmware.hex"
cd "$repo/firmware/ergodox-ez/default-minimalist-starcraft-ii"
sha256sum firmware.hex > firmware.hex.sha256
```

When running from this NixOS repository, enter a build environment with:

```sh
nix shell nixpkgs#qmk nixpkgs#dos2unix
```

## StarCraft layer summary

- Enter layer 2 by holding the base-layer `MO(1)` key and tapping the physical
  Caps Lock position.
- Return to layer 0 with the inner-top key on the right half.
- The outer-left column is a camera column. From top to bottom it sends `F4`,
  `F2`, `F1`, `F3`, and `F5`.
- The physical Left Arrow position sends `F6` for Idle Worker.
- The physical Volume Down position sends Escape.
- The normal left Super key remains available.
- The normal left Space position sends Shift.
- The normal left Enter position is the Building Select key; there is no Space
  binding on the StarCraft layer.
- The physical Previous Track position—the upper-left small key in the left
  thumb cluster—holds Ctrl+Shift for adding every visible object of the clicked
  type to the current selection.
- The right-thumb Escape position becomes Enter for chat.

### Control groups

Physical `1` through `5` operate unit groups normally:

- `1`–`5`: select unit groups 1–5
- Thumb Ctrl + `1`–`5`: replace unit groups 1–5

Two dedicated keys provide a second group bank without moving the mouse hand
or pressing multiple thumb modifiers:

- Hold the normal left Enter thumb position and press `1`–`5` to select
  groups `6`, `7`, `8`, `9`, and `0`.
- Hold the lower physical Backslash position and press `1`–`5` to replace
  groups `6`, `7`, `8`, `9`, and `0`.

The large thumb key is the frequently used **Building Select** action; the
lower inner key is **Building Set**. The upper physical Right Bracket position
is inert. Both building actions are momentary firmware layers and do not
illuminate the layer indicators. A suggested assignment is:

```text
1–5                  Unit groups
Building Select + 1  Nexuses
Building Select + 2  Robotics Facilities
Building Select + 3  Stargates
Building Select + 4  Forge
Building Select + 5  Other technology building
W                    Warp Gates
```

There is no dedicated add-to-group action. Select the existing group, extend
the selection with Shift, and replace the group using its set action. To add
all visible objects of one type at once, hold the Ctrl+Shift thumb key and click
one of them before replacing the group.
