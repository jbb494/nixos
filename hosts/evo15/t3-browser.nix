{ options, pkgs, lib, ... }:

# T3's browser (html_preview, the agents' page previews) downloads Google's chrome-headless-shell into ~/.t3/tools: a
# generic Linux binary that NixOS runs through nix-ld, which has none of Chromium's libraries by default ("host missing
# Chromium libs": harness feedback #26). `t3 browser setup` would install them FHS-style, which NixOS doesn't do; nix-ld
# gets them instead, added to its defaults. The list is what the binary links (ldd), checked by rendering a page with it.
{
  programs.nix-ld.libraries = options.programs.nix-ld.libraries.default ++ map lib.getLib (with pkgs; [
    glib
    nss
    nspr
    dbus
    expat
    at-spi2-core # libatk-1.0, libatk-bridge-2.0, libatspi
    libgbm
    libdrm
    libxkbcommon
    systemd # libudev
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
  ]);
}
