# ErgoDox EZ firmware

This is an offline snapshot of the **Default minimalist Starcraft II** Oryx layout.

- Oryx layout ID: `7mKlb`
- Oryx revision: `XbpYby`
- Oryx/QMK firmware version: `25.0`
- Keyboard target: `zsa/ergodox_ez/m32u4/base`
- Debounce delay: `5 ms`
- Archived: 2026-09-19
- [Latest layout](https://configure.zsa.io/ergodox-ez/layouts/7mKlb/latest/0)
- [Archived Oryx revision](https://configure.zsa.io/ergodox-ez/layouts/7mKlb/XbpYby/0)
- [Debounce settings](https://configure.zsa.io/ergodox-ez/layouts/7mKlb/latest/config/debounce)

`firmware.hex` is the compiled artifact downloaded from Oryx. The `source/`
directory contains the generated QMK keymap used to build it.

## Flash the archived firmware

The NixOS keyboard module installs ZSA's `zapp` utility and the required udev
rules. From the repository root, verify and flash the artifact with:

```sh
(cd firmware/ergodox-ez/default-minimalist-starcraft-ii && sha256sum --check firmware.hex.sha256)
zapp flash firmware/ergodox-ez/default-minimalist-starcraft-ii/firmware.hex
```

Follow `zapp`'s prompt to put the keyboard into bootloader mode.

## Rebuild from source

Use the `firmware25` branch of [ZSA's QMK fork](https://github.com/zsa/qmk_firmware):

```sh
qmk setup zsa/qmk_firmware -b firmware25
cp -R firmware/ergodox-ez/default-minimalist-starcraft-ii/source \
  "$HOME/qmk_firmware/keyboards/zsa/ergodox_ez/m32u4/keymaps/starcraft"
cd "$HOME/qmk_firmware"
qmk compile -kb zsa/ergodox_ez/m32u4/base -km starcraft
```

The archived `firmware.hex` remains the canonical artifact because the upstream
`firmware25` branch may change over time.

## StarCraft layer summary

- Enter layer 2 by holding the base-layer `MO(1)` key and tapping the physical
  Caps Lock position.
- Return to layer 0 with the inner-top key on the right half.
- Camera locations are `F1` through `F5`; `F6` is reserved for Idle Worker.
- The normal left Super key remains available.
- The large left Enter key becomes a second Shift; the right-thumb Escape key
  becomes Enter.
