{ lib
, runCommand
, xkeyboard_config
}:

runCommand "xkeyboard-config-ergodox-${xkeyboard_config.version or "custom"}" { } ''
  mkdir -p "$out/share/X11"
  cp -RL "${xkeyboard_config}/share/X11/xkb" "$out/share/X11/xkb"
  chmod -R u+w "$out/share/X11/xkb"

  install -m 0644 "${../modules/keyboard/xkb/symbols/ergodox-dvorak}" "$out/share/X11/xkb/symbols/ergodox-dvorak"
  install -m 0644 "${../modules/keyboard/xkb/types/capsnumber}" "$out/share/X11/xkb/types/capsnumber"

  for file in "$out/share/X11/xkb/types/complete"; do
    if ! grep -q 'include "capsnumber"' "$file"; then
      sed -i '/^};/i\    include "capsnumber"' "$file"
    fi
  done

  layout_xml='        <layout>
          <configItem>
            <name>ergodox-dvorak</name>
            <shortDescription>edv</shortDescription>
            <description>English (Ergodox Dvorak)</description>
            <languageList><iso639Id>eng</iso639Id></languageList>
          </configItem>
          <variantList/>
        </layout>'

  for file in "$out/share/X11/xkb/rules/base.xml" "$out/share/X11/xkb/rules/evdev.xml"; do
    if [ -f "$file" ] && ! grep -q '<name>ergodox-dvorak</name>' "$file"; then
      awk -v layout="$layout_xml" '
        /<\/layoutList>/ && ! inserted { print layout; inserted = 1 }
        { print }
      ' "$file" > "$file.tmp"
      mv "$file.tmp" "$file"
    fi
  done

  for file in "$out/share/X11/xkb/rules/base.lst" "$out/share/X11/xkb/rules/evdev.lst"; do
    if [ -f "$file" ] && ! grep -q '^  ergodox-dvorak' "$file"; then
      awk '
        /^! layout$/ { print; in_layout = 1; next }
        in_layout && /^! / { print "  ergodox-dvorak English (Ergodox Dvorak)"; in_layout = 0 }
        { print }
      ' "$file" > "$file.tmp"
      mv "$file.tmp" "$file"
    fi
  done
''
