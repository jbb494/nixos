{ config, pkgs, ... }:

# Agents may apply what is merged on GitHub (Joan, 2026-11-25): `sudo systemctl start nixos-switch` (the only command
# the sudo rule below lets jbellavista run without a password) switches evo15 to origin/main of this repo, with the
# local devtools checkout as rollnroll-devtools, exactly as Joan runs it by hand. It builds from its own clone, never from
# ~/personal/nixos, so unfinished edits there are never switched in. Watch it: `systemctl status nixos-switch`,
# `journalctl -u nixos-switch`. Rollback: `sudo nixos-rebuild switch --rollback`.
let
  user = "jbellavista";
  home = "/home/${user}";
  clone = "${home}/.local/state/nixos-switch/nixos";
  devtools = "${home}/rollnroll/devtools";
  git = "${pkgs.git}/bin/git";
  nix = "${config.nix.package}/bin/nix";
  # Fetching and building run as jbellavista, as `sudo nixos-rebuild` does: Nix refuses Git repositories another user
  # owns (the clone and the devtools checkout are Joan's), and the fetch uses Joan's SSH setup for the personal account.
  asUser = cmd: ''${pkgs.util-linux}/bin/runuser -u ${user} -- ${pkgs.coreutils}/bin/env HOME=${home} ${cmd}'';
  script = pkgs.writeShellScript "nixos-switch" ''
    set -euo pipefail
    export PATH=${pkgs.openssh}/bin:${pkgs.git}/bin:$PATH
    if [ ! -d ${clone}/.git ]; then
      remote=$(${asUser "${git} -C ${home}/personal/nixos remote get-url origin"})
      ${asUser "${pkgs.coreutils}/bin/mkdir -p ${home}/.local/state/nixos-switch"}
      ${asUser ''${git} clone --quiet "$remote" ${clone}''}
    fi
    ${asUser "${git} -C ${clone} fetch --quiet origin main"}
    ${asUser "${git} -C ${clone} reset --quiet --hard origin/main"}
    echo "nixos-switch: evo15 at $(${asUser "${git} -C ${clone} log --oneline -1"})"
    system=$(${asUser "${nix} --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths ${clone}#nixosConfigurations.evo15.config.system.build.toplevel --override-input rollnroll-devtools ${devtools}"})
    # Only the activation runs as root.
    ${config.nix.package}/bin/nix-env -p /nix/var/nix/profiles/system --set "$system"
    exec "$system/bin/switch-to-configuration" switch
  '';
in
{
  systemd.services.nixos-switch = {
    description = "Switch evo15 to origin/main of the nixos repo, with the local devtools (agents start it)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = script;
    };
    # The switch reloads units; this one must not be stopped or restarted by the switch it is running.
    restartIfChanged = false;
    stopIfChanged = false;
  };

  security.sudo.extraRules = [
    {
      users = [ user ];
      commands = [
        {
          command = "/run/current-system/sw/bin/systemctl start nixos-switch";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/systemctl start nixos-switch.service";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
