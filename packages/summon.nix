{ ghostty
, hyprland
, lib
, makeWrapper
, python3
, stdenvNoCC
, systemd
}:

stdenvNoCC.mkDerivation {
  pname = "summon";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [ ./summon.py ./summon-test.py ];
  };

  nativeBuildInputs = [ makeWrapper python3 ];

  dontBuild = true;
  doCheck = true;

  checkPhase = ''
    runHook preCheck
    ${python3}/bin/python3 $src/summon-test.py
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec $out/bin
    install -m 0555 $src/summon.py $out/libexec/summon.py

    makeWrapper ${python3}/bin/python3 $out/bin/summond \
      --add-flags "$out/libexec/summon.py daemon" \
      --prefix PATH : ${lib.makeBinPath [ ghostty hyprland systemd ]}
    makeWrapper ${python3}/bin/python3 $out/bin/summonctl \
      --add-flags "$out/libexec/summon.py" \
      --prefix PATH : ${lib.makeBinPath [ systemd ]}
    runHook postInstall
  '';

  meta = {
    description = "Generic desktop popup broker";
    platforms = lib.platforms.linux;
    license = lib.licenses.mit;
  };
}
