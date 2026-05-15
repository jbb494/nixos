{
  powerManagement.enable = true;

  services = {
    logind.settings.Login = {
      HandleLidSwitch = "ignore";
      HandleLidSwitchExternalPower = "ignore";
      HandleLidSwitchDocked = "ignore";
    };
    power-profiles-daemon.enable = true;
    upower.enable = true;
  };
}
