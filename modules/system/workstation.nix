{
  hardware = {
    bluetooth = {
      enable = true;
      powerOnBoot = true;
      settings.General.JustWorksRepairing = "always";
    };
    enableAllFirmware = true;
    graphics = {
      enable = true;
      enable32Bit = true;
    };
  };

  services = {
    blueman.enable = true;
    fwupd.enable = true;
    libinput.enable = true;
  };

  programs.steam.enable = true;
}
