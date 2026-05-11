{ libxkbcommon
, runCommand
, xkeyboardConfigErgodox
}:

runCommand "check-xkb-ergodox" { nativeBuildInputs = [ libxkbcommon ]; } ''
  export XKB_CONFIG_ROOT="${xkeyboardConfigErgodox}/share/X11/xkb"

  xkbcli compile-keymap \
    --include "$XKB_CONFIG_ROOT" \
    --rules evdev \
    --model pc105 \
    --layout ergodox-dvorak \
    > compiled-keymap.xkb

  grep -q CAPS_NUMBERS compiled-keymap.xkb
  touch "$out"
''
