{ pkgs, ... }:

{
  boot = {
    kernelPackages = pkgs.linuxPackages_latest;
    kernelParams = [ "amd_pstate=active" ];
  };

  hardware = {
    bluetooth = {
      enable = true;
      powerOnBoot = true;
    };
    cpu.amd.updateMicrocode = true;
    enableAllFirmware = true;
    graphics = {
      enable = true;
      enable32Bit = true;
    };
  };

  powerManagement.enable = true;

  services = {
    blueman.enable = true;
    fwupd.enable = true;
    libinput.enable = true;
    logind.settings.Login = {
      HandleLidSwitch = "ignore";
      HandleLidSwitchExternalPower = "ignore";
      HandleLidSwitchDocked = "ignore";
    };
    power-profiles-daemon.enable = true;
    upower.enable = true;
    xserver.videoDrivers = [ "amdgpu" ];
  };
}
