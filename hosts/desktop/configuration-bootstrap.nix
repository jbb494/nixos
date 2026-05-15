{ pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
  ];

  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      trusted-users = [ "root" "jbellavista" ];
      auto-optimise-store = true;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };

  nixpkgs.config.allowUnfree = true;

  time.timeZone = "Europe/Madrid";
  i18n.defaultLocale = "en_US.UTF-8";

  console = {
    keyMap = "es";
    earlySetup = true;
  };

  boot = {
    blacklistedKernelModules = [ "nouveau" ];
    kernelParams = [ "nomodeset" ];
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };
    initrd.systemd.enable = true;
    tmp.cleanOnBoot = true;
  };

  networking.hostName = "desktop";
  networking.networkmanager.enable = true;

  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

  security = {
    polkit.enable = true;
    sudo.wheelNeedsPassword = true;
  };

  services.openssh.enable = true;
  services.fstrim.enable = true;

  hardware = {
    cpu.intel.updateMicrocode = true;
    enableRedistributableFirmware = true;
  };

  zramSwap.enable = true;

  environment.systemPackages = with pkgs; [
    btrfs-progs
    curl
    git
    htop
    nano
    pciutils
    usbutils
    vim
    wget
  ];

  users.mutableUsers = true;
  users.users.jbellavista = {
    isNormalUser = true;
    description = "Joan Bellavista";
    shell = pkgs.zsh;
    extraGroups = [
      "audio"
      "input"
      "networkmanager"
      "video"
      "wheel"
    ];
  };

  system.stateVersion = "25.11";
}
