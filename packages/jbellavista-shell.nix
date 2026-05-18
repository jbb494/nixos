{ ags
, astal
, lib
, networkmanager
, runCommand
, writeText
, rollnrollShellModule ? null
, rollnrollRuntimePackages ? [ ]
}:

let
  rollnrollFallback = writeText "rollnroll.tsx" ''
    import { Variable } from "astal";

    export const rollnrollCss = "";
    export const openRollnrollMonitor = Variable<number | null>(null);
    export const closeRollnroll = () => openRollnrollMonitor.set(null);
    export const RollnrollButton = () => <box />;
    export const RollnrollDropdown = () => <box />;
  '';
  shellSrc = runCommand "jbellavista-shell-src" { } ''
    cp -R ${../home/jbellavista/shell} $out
    chmod -R u+w $out
    mkdir -p $out/external
    cp ${if rollnrollShellModule == null then rollnrollFallback else rollnrollShellModule} $out/external/rollnroll.tsx
  '';
in

(ags.passthru.bundle {
  pname = "jbellavista-shell";
  version = "0.1.0";
  src = shellSrc;
  entry = "app.tsx";
  dependencies = [
    astal.battery
    astal.bluetooth
    astal.hyprland
    astal.mpris
    astal.network
    networkmanager
    astal.tray
    astal.wireplumber
  ] ++ rollnrollRuntimePackages;
}).overrideAttrs (oldAttrs: {
  postInstall = (oldAttrs.postInstall or "") + ''
    rm -rf $out/share
  '';
})
