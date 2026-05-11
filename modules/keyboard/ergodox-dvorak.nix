{ xkeyboardConfigErgodox, ... }:

{
  services.xserver.xkb = {
    dir = "${xkeyboardConfigErgodox}/share/X11/xkb";
    layout = "es";
    model = "pc105";
    variant = "cat";
  };

  environment.sessionVariables.XKB_CONFIG_ROOT = "${xkeyboardConfigErgodox}/share/X11/xkb";
}
