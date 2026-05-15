{ callPackage, diskoPackage, nixosInstallTools }:

callPackage ./install-system.nix {
  inherit diskoPackage nixosInstallTools;
  installName = "install-desktop";
  defaultDisk = "/dev/nvme0n1";
  defaultFlakeRef = "github:jbb494/nixos#desktop";
  diskModelPattern = "Samsung SSD 980 PRO 2TB";
  diskDescription = "the desktop Samsung 980 PRO 2TB NVMe";
}
