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
- Camera locations are `F1` through `F5`; `F6` is reserved for Idle Worker.
- The normal left Super key remains available.
- The large left Enter key becomes a second Shift; the right-thumb Escape key
  becomes Enter.
