{ lib
, stdenv
, fetchurl
, autoPatchelfHook
, makeBinaryWrapper
, ripgrep
, wayland
, xorg
, npmMeta
,
}:

let
  meta' = builtins.fromJSON (builtins.readFile npmMeta);
in

stdenv.mkDerivation rec {
  pname = "opencode2";
  # Stable V2 binary from the @opencode npm scope, pinned via the
  # `opencode2-npm` flake input (bump with `nix flake update opencode2-npm`).
  version = meta'.version;

  src = fetchurl {
    url = meta'.dist.tarball;
    hash = meta'.dist.integrity;
  };

  nativeBuildInputs = [
    autoPatchelfHook
    makeBinaryWrapper
  ];

  buildInputs = [ stdenv.cc.cc.lib ];

  # Stripping truncates Bun's appended compiled payload.
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/opencode $out/bin/opencode2
    # LD_LIBRARY_PATH: the TUI's native clipboard (OpenTUI/Zig, since
    # 0.0.0-next-17122) dlopens libwayland-client.so.0 / libxcb.so.1 at
    # runtime and silently reports "unsupported" when they are missing,
    # breaking Ctrl+V image/text paste on NixOS.
    wrapProgram $out/bin/opencode2 \
      --prefix PATH : ${lib.makeBinPath [ ripgrep ]} \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ wayland xorg.libxcb ]}
    runHook postInstall
  '';

  meta = {
    description = "The opencode v2 CLI";
    homepage = "https://opencode.ai";
    license = lib.licenses.mit;
    mainProgram = "opencode2";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
