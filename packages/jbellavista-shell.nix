{ ags
, astal
, networkmanager
, runCommand
, writeText
, eveRuntimePackages ? [ ]
, eveShellModule ? null
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
  eveFallback = writeText "eve.tsx" ''
    import { Variable } from "astal";

    export const eveCss = "";
    export const openEvePosition = Variable<null>(null);
    export const closeEve = () => {};
    export const EveButton = () => <box />;
    export const EveDropdown = () => <box />;
  '';
  shellSrc = runCommand "jbellavista-shell-src" { } ''
    cp -R ${../home/jbellavista/shell} $out
    chmod -R u+w $out
    mkdir -p $out/external
    cp ${if rollnrollShellModule == null then rollnrollFallback else rollnrollShellModule} $out/external/rollnroll.tsx
    cp ${if eveShellModule == null then eveFallback else eveShellModule} $out/external/eve.tsx
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
  ] ++ rollnrollRuntimePackages ++ eveRuntimePackages;
}).overrideAttrs (oldAttrs: {
  postInstall = (oldAttrs.postInstall or "") + ''
    rm -rf $out/share
  '';
})
