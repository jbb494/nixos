{
  lib,
  stdenv,
  clang,
  fetchFromGitHub,
  libxfixes,
  lld,
  llvm,
  makeWrapper,
  pkg-config,
  freetype,
  glibc,
  libGL,
  xorg,
  zenity,
}:

stdenv.mkDerivation rec {
  pname = "raddebugger";
  version = "0.9.29-alpha";

  src = fetchFromGitHub {
    owner = "EpicGames";
    repo = "raddebugger";
    rev = "v${version}";
    hash = "sha256-IQNicRWKdIamDeQU1RRceRR2QgoUlomQYoeCgepO10w=";
  };

  # NixOS glibc omits the optional SystemTap loader probes used by RAD.
  # Fall back to the standard ELF r_debug link map for module discovery.
  patches = [ ./raddebugger-nixos-modules.patch ];

  nativeBuildInputs = [
    clang
    lld
    llvm
    makeWrapper
    pkg-config
  ];
  buildInputs = [
    freetype
    libGL
    libxfixes
    xorg.libX11
    xorg.libXext
  ];

  # build.sh derives build metadata from git; the store checkout has no .git.
  postPatch = ''
    substituteInPlace build.sh \
      --replace-fail 'git_hash=$(git describe --always --dirty)' 'git_hash="${version}"' \
      --replace-fail 'git_hash_full=$(git rev-parse HEAD)' 'git_hash_full="${src.rev}"'
  '';

  # Upstream's supported Linux compiler is clang (build.sh defaults to it);
  # CC is set explicitly because the stdenv wrapper exports CC=gcc.
  buildPhase = ''
    runHook preBuild
    CC=clang bash ./build.sh release raddbg
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 build/raddbg $out/bin/raddbg
    install -Dm644 data/logo.png $out/share/pixmaps/raddbg.png
    install -Dm644 /dev/null $out/share/applications/raddbg.desktop
    cat > $out/share/applications/raddbg.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=RAD Debugger
GenericName=Debugger
Comment=Native, user-mode, multi-process graphical debugger
Exec=raddbg %f
Icon=raddbg
Terminal=false
Categories=Development;Debugger;
Keywords=debugger;c;c++;native;
EOF
    # raddbg shells out to zenity for message boxes and file dialogs.
    wrapProgram $out/bin/raddbg \
      --prefix PATH : ${lib.makeBinPath [ zenity ]} \
      --prefix NIX_DEBUG_INFO_DIRS : ${glibc.debug}/lib/debug
    runHook postInstall
  '';

  meta = with lib; {
    description = "Native, user-mode, multi-process, graphical debugger";
    homepage = "https://github.com/EpicGames/raddebugger";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "raddbg";
  };
}
