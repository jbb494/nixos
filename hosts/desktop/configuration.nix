{ config
, inputs
, lib
, masterPkgs
, pkgs
, ...
}:

{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ../../modules/system/base.nix
    ../../modules/system/workstation.nix
    ../../modules/desktop/hyprland.nix
    ../../modules/keyboard/ergodox-dvorak.nix
    inputs.eve-protocol-observatory.nixosModules.default
  ];

  networking.hostName = "desktop";

  console.keyMap = pkgs.lib.mkForce "dvorak";

  boot = {
    loader.systemd-boot.enable = lib.mkForce false;
    lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
    };
  };

  hardware = {
    cpu.amd.updateMicrocode = true;
    nvidia = {
      modesetting.enable = true;
      nvidiaSettings = true;
      open = true;
      package = config.boot.kernelPackages.nvidiaPackages.stable;
    };
  };

  services = {
    # Give Hyprland a stable path for the GPU that owns the desktop's display.
    # Otherwise Aquamarine picks the unused AMD iGPU as its primary renderer
    # and copies every frame to NVIDIA, which breaks Chromium's DMA-BUF path.
    udev.extraRules = ''
      KERNEL=="card*", KERNELS=="0000:01:00.0", SUBSYSTEM=="drm", SUBSYSTEMS=="pci", SYMLINK+="dri/nvidia-dgpu"
    '';
    xserver.videoDrivers = [ "nvidia" ];
  } // lib.optionalAttrs (inputs.eve-protocol-observatory.available or false) {
    eve-protocol-observatory = {
      enable = true;
      user = "jbellavista";
    };
  };

  environment.sessionVariables = {
    AQ_DRM_DEVICES = "/dev/dri/nvidia-dgpu";
    GBM_BACKEND = "nvidia-drm";
    LIBVA_DRIVER_NAME = "nvidia";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
  };

  environment.systemPackages = [ pkgs.sbctl ];
  programs.wireshark.enable = true;

  users.mutableUsers = true;
  users.users.jbellavista = {
    isNormalUser = true;
    description = "Joan Bellavista";
    shell = pkgs.zsh;
    extraGroups = [
      "audio"
      "docker"
      "input"
      "networkmanager"
      "video"
      "wheel"
      "wireshark"
    ];
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = {
      inherit inputs masterPkgs;
      # Use default ANGLE: forcing EGL disables WebGL on Chrome 152.
      chromeForceEgl = false;
      opencodeLinearMcp = false;
      opencodePersonalProfile = false;
    };
    users.jbellavista = import ../../home/jbellavista/home.nix;
  };

  system.stateVersion = "25.11";
}
