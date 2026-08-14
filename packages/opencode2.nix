{ lib
, stdenv
, fetchurl
, autoPatchelfHook
, makeBinaryWrapper
, ripgrep
, wayland
, xorg
,
}:

stdenv.mkDerivation rec {
  pname = "opencode2";
  # Fast-moving beta: query @opencode-ai/cli-linux-x64@next, then update version and hash together.
  version = "0.0.0-next-17403";

  src = fetchurl {
    url = "https://registry.npmjs.org/@opencode-ai/cli-linux-x64/-/cli-linux-x64-${version}.tgz";
    hash = "sha512-XGeaXNrEo4DRGNedk21wiQScNMGS1xxZ9c8WfoqeTEneYvQG8W2sItTxb4wXx0kMIpYbzalcLvKy+6Yz19xNjA==";
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
    install -Dm755 bin/opencode2 $out/bin/opencode2
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
