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
  built = "/var/lib/nixos-switch/nixos";
  # The clone is fetched as jbellavista, with its own SSH setup for the personal GitHub account.
  asUser = cmd: ''${pkgs.util-linux}/bin/runuser -u ${user} -- ${pkgs.coreutils}/bin/env HOME=${home} ${cmd}'';
  git = "${pkgs.git}/bin/git";
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
    # Nix refuses a Git repository its user doesn't own, so the build reads root's own copy of what was just fetched.
    if [ ! -d ${built}/.git ]; then ${git} init --quiet ${built}; fi
    ${git} -c safe.directory='*' -C ${built} fetch --quiet ${clone} main
    ${git} -C ${built} reset --quiet --hard FETCH_HEAD
    echo "nixos-switch: evo15 at $(${git} -C ${built} log --oneline -1)"
    exec /run/current-system/sw/bin/nixos-rebuild switch --flake ${built}#evo15 \
      --override-input rollnroll-devtools ${devtools}
  '';
in
{
  systemd.services.nixos-switch = {
    description = "Switch evo15 to origin/main of the nixos repo, with the local devtools (agents start it)";
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "nixos-switch";
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
