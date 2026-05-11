{ modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "nvme"
    "sd_mod"
    "sdhci_pci"
    "thunderbolt"
    "usb_storage"
    "xhci_pci"
  ];

  boot.kernelModules = [
    "amdgpu"
    "kvm-amd"
  ];

  boot.extraModulePackages = [ ];
}
