# T3 Code with one fix in its built client: the Files panel's HTML documents no longer flash white on every change and
# thread switch (Joan, 2026-11-25). Until upstream fixes it; drop this file and its overlay then.
#
# The cause (T3 0.1.8, client/src/components/files/BrowserDocumentFrame.tsx): FileDocument's iframe is keyed per
# revision and has `bg-white`, so each change mounts a fresh white iframe before the page paints. HtmlRenderDocument
# avoids it by matching the page's colour scheme; here the frame is transparent instead, and inherits T3's own colour
# scheme from its parent, which is the same match: a page that declares its scheme (STATE.html: "light dark") paints
# over T3's background, never over white. The PDF iframe is left alone.
#
# The built output is copied with the asset patched and its own store path rewritten in it (the bin wrappers point at
# it): no rebuild from source. The build fails if the version isn't the pinned one or the string isn't found exactly
# once, so a T3 update can't drop the patch silently.
{ lib, runCommand, t3code }:

let
  unwrapped = t3code.unwrapped;
  # Pinned: the bundle's file name and minified text are 0.1.8's. A new T3 fails here: check whether upstream fixed it
  # (then drop this), or find the new file and string.
  pinned = "0.1.8";
  asset = "libexec/t3code/apps/server/dist/client/assets/contextPresentationRegistry-DNANjXLv.js";
  from = "className:`min-h-0 flex-1 border-0 bg-white`,sandbox:`allow-scripts allow-forms allow-popups allow-downloads`";
  to = "className:`min-h-0 flex-1 border-0 bg-transparent`,sandbox:`allow-scripts allow-forms allow-popups allow-downloads`";
in
assert lib.assertMsg (unwrapped.version == pinned)
  "packages/t3code-files-frame.nix is for T3 ${pinned}, not ${unwrapped.version}: check the patch (or drop it if upstream fixed the white flash)";
runCommand unwrapped.name
{
  inherit (unwrapped) version meta;
  passthru = unwrapped.passthru;
} ''
  cp -a ${unwrapped} $out
  chmod -R u+w $out

  file=$out/${asset}
  if [ ! -f "$file" ]; then
    echo "t3code-files-frame: ${asset} isn't in T3 ${unwrapped.version}: the patch needs checking" >&2
    exit 1
  fi
  found=$(grep -oF -- ${lib.escapeShellArg from} "$file" | wc -l)
  if [ "$found" != 1 ]; then
    echo "t3code-files-frame: the FileDocument iframe's class was found $found times (expected 1): the patch needs checking" >&2
    exit 1
  fi
  substituteInPlace "$file" --replace-fail ${lib.escapeShellArg from} ${lib.escapeShellArg to}

  # Its own store path, in the bin wrappers (binaries: same length, so the bytes line up) and anywhere else.
  old=${unwrapped}
  if [ ''${#old} != ''${#out} ]; then echo "t3code-files-frame: store path lengths differ" >&2; exit 1; fi
  grep -rlF -- "$old" $out | while read -r f; do sed -i "s|$old|$out|g" "$f"; done
  if grep -rqF -- "$old" $out; then echo "t3code-files-frame: $old is still referenced" >&2; exit 1; fi
''
