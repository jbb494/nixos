{ callPackage, diskoPackage, nixosInstallTools }:

callPackage ./install-system.nix {
  inherit diskoPackage nixosInstallTools;
  installName = "install-evo15";
  defaultDisk = "/dev/nvme0n1";
  defaultFlakeRef = "github:jbb494/nixos#evo15-bootstrap";
  flakeRefExample = "github:jbb494/nixos#evo15-bootstrap";
  diskModelPattern = "SSDPR-PX600L-512-80";
  diskDescription = "the EVO15 512GB SSD";
  requireUefi = false;
  postInstallInstructions = ''
    if [[ "''${flake_attr}" == "evo15-bootstrap" ]]; then
      echo
      echo "After reboot, switch to the full desktop configuration:"
      echo "  sudo nixos-rebuild switch --flake ''${flake_base}#evo15"
    fi
  '';
}
