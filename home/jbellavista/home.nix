{ inputs
, chromeForceEgl
, config
, lib
, opencodeLinearMcp
, opencodePersonalProfile
, pkgs
, ...
}:

let
  # Workaround for upstream Chromium bug on Wayland + NVIDIA: software-decoded
  # 10-bit video (e.g. Netflix AV1, HEVC Main 10) renders black with audio only.
  # https://issuetracker.google.com/issues/548711898
  # Forcing the EGL backend fixes presentation while staying on native Wayland.
  chromeFlags = "--ozone-platform=wayland --enable-features=UseOzonePlatform"
    + lib.optionalString chromeForceEgl " --use-gl=egl";
  rollnrollEnabled = !(inputs.rollnroll-devtools ? isStub);
  tmuxProjectsBin = "/etc/profiles/per-user/jbellavista/bin/tmux-projects";
  opencode2 = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.opencode2;
  raddebugger = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.raddebugger;
  opencode = pkgs.runCommand "opencode" { } ''
    mkdir -p $out/bin
    ln -s ${opencode2}/bin/opencode2 $out/bin/opencode
  '';
  opencodeDefaultProject = "${config.home.homeDirectory}/personal/nixos";
  opencodeProfileDirs = profile: {
    dataHome = "${config.home.homeDirectory}/.local/share/opencode-profiles/${profile}/data";
    stateHome = "${config.home.homeDirectory}/.local/state/opencode-profiles/${profile}";
    cacheHome = "${config.home.homeDirectory}/.cache/opencode-profiles/${profile}";
  };
  opencodeProfileEnv = profile:
    let
      dirs = opencodeProfileDirs profile;
    in
    [
      "XDG_DATA_HOME=${dirs.dataHome}"
      "XDG_STATE_HOME=${dirs.stateHome}"
      "XDG_CACHE_HOME=${dirs.cacheHome}"
    ];
  personalOpencodeProfileDirs = opencodeProfileDirs "personal";

  # Single source of truth for future opencode feature flags. Projected into
  # both login shells and web services, which do not inherit login-shell env.
  opencodeEnv = { };
  opencodeEnvList = lib.mapAttrsToList (name: value: "${name}=${value}") opencodeEnv;

  # Secret env vars (API tokens such as FIGMA_API_KEY) stay out of Git and the
  # Nix store. Env-format file (KEY=value lines, chmod 600), created manually.
  # Projected into both login shells and web services, mirroring opencodeEnv.
  secretsEnvFile = "${config.home.homeDirectory}/.secrets/opencode.env";

  # Wrap bun so prebuilt native addons (sharp, canvas, sqlite3, ...) can dlopen
  # libstdc++.so.6 on NixOS. Scoped to bun only — no global LD_LIBRARY_PATH.
  bun = pkgs.symlinkJoin {
    name = "bun";
    paths = [ pkgs.bun ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/bun \
        --suffix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]}
    '';
  };

  screenshot = pkgs.writeShellApplication {
    name = "screenshot";
    runtimeInputs = with pkgs; [
      grim
      slurp
      wl-clipboard
    ];
    text = ''
      geometry="$(slurp)"
      grim -g "$geometry" - | wl-copy --type image/png
    '';
  };

  secedit = pkgs.writeShellApplication {
    name = "secedit";
    runtimeInputs = with pkgs; [
      coreutils
      gnupg
      neovim
    ];
    text = ''
      set -euo pipefail

      if [[ -z "''${GPG_TTY:-}" ]] && gpg_tty="$(tty 2>/dev/null)"; then
        export GPG_TTY="$gpg_tty"
      fi

      exec nvim --clean \
        --cmd "set runtimepath^=${pkgs.vimPlugins.vim-gnupg}" \
        -u "$HOME/.config/nvim/secedit.lua" \
        "$@"
    '';
  };

  hypr-summon = pkgs.writeShellApplication {
    name = "hypr-summon";
    runtimeInputs = with pkgs; [
      coreutils
      hyprland
      jq
    ];
    text = ''
      set -euo pipefail

      matcher=""
      make_float=0

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --match)
            if [[ $# -lt 2 ]]; then
              printf 'hypr-summon: --match requires a regex\n' >&2
              exit 2
            fi
            matcher="$2"
            shift 2
            ;;
          --float)
            make_float=1
            shift
            ;;
          --)
            shift
            break
            ;;
          *)
            break
            ;;
        esac
      done

      if [[ -z "$matcher" || $# -eq 0 ]]; then
        printf 'usage: hypr-summon --match REGEX [--float] -- command [args...]\n' >&2
        exit 2
      fi

      clients_json="$(hyprctl clients -j 2>/dev/null || printf '[]')"
      address="$(${pkgs.jq}/bin/jq -r --arg re "$matcher" '
        map(select(
          ((.class // "") | test($re; "i")) or
          ((.initialClass // "") | test($re; "i")) or
          ((.title // "") | test($re; "i")) or
          ((.initialTitle // "") | test($re; "i"))
        ))[0].address // empty
      ' <<<"$clients_json")"

      if [[ -n "$address" ]]; then
        workspace="$(hyprctl activeworkspace -j | ${pkgs.jq}/bin/jq -r '.id // empty')"
        if [[ -n "$workspace" ]]; then
          hyprctl dispatch movetoworkspace "$workspace,address:$address" >/dev/null
        fi

        hyprctl dispatch focuswindow "address:$address" >/dev/null

        if [[ "$make_float" == "1" ]]; then
          hyprctl dispatch setfloating "address:$address" >/dev/null || true
          hyprctl dispatch centerwindow >/dev/null || true
        fi

        exit 0
      fi

      exec "$@"
    '';
  };

  tmux-projects = pkgs.writeShellApplication {
    name = "tmux-projects";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      findutils
      fzf
      ghostty
      hyprland
      jq
      tmux
      util-linux
    ];
    text = ''
      set -euo pipefail

      tmux_socket_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/tmux-$(id -u)"
      tmux_socket="$tmux_socket_dir/default"
      mkdir -p "$tmux_socket_dir"
      chmod 700 "$tmux_socket_dir"
      tmux_command=(tmux -S "$tmux_socket")
      oc_queue_file="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/opencode-done-queue.json"

      command="''${1:-open}"
      shift || true

      focus_tmux_terminal() {
        local address=""

        address="$(hyprctl clients -j 2>/dev/null | jq -r '
          map(select(
            (.class // "") == "com.mitchellh.ghostty" or
            (.initialClass // "") == "com.mitchellh.ghostty"
          ))
          | sort_by(.focusHistoryID // 999999)
          | .[0].address // empty
        ')"

        if [[ -n "$address" ]]; then
          hyprctl dispatch focuswindow "address:$address" >/dev/null || true
        fi
      }

      open_picker() {
        client="$("''${tmux_command[@]}" list-clients -F '#{client_activity} #{client_tty}' 2>/dev/null \
          | sort -rn \
          | while read -r _ tty; do printf '%s' "$tty"; break; done || true)"

        if [[ -n "$client" ]]; then
          focus_tmux_terminal
          exec "''${tmux_command[@]}" display-popup -t "$client" -E "$0 select $*"
        fi

        exec ghostty -e env TMUX_PROJECTS_KEEP_SHELL=1 "$0" select "$@"
      }

      collect_entries() {
        local nvim_only=0
        declare -gA seen=()
        entries=()

        if [[ "''${1:-}" == "--nvim" ]]; then
          nvim_only=1
        fi

        add_repo() {
          local path="$1"
          local label=""

          path="$(realpath -m "$path")"
          [[ -d "$path" ]] || return 0
          [[ -n "''${seen[$path]:-}" ]] && return 0
          seen["$path"]=1

          case "$path" in
            "$HOME"/*) label="''${path#"$HOME/"}" ;;
            *) label="$path" ;;
          esac

          entries+=("$label"$'\t'"$path")
        }

        add_search_dir() {
          local root="$1"
          local depth="$2"
          local maxdepth=$((depth + 1))

          [[ -d "$root" ]] || return 0

          while IFS= read -r -d ''' git_file; do
            add_repo "$(dirname "$git_file")"
          done < <(find "$root" -mindepth 2 -maxdepth "$maxdepth" -name .git -print0 2>/dev/null)
        }

        if [[ "$nvim_only" == "1" ]]; then
          add_search_dir "$HOME/.local/share/nvim/lazy" 1
          return
        fi

        add_search_dir "$HOME/personal" 2
        add_search_dir "$HOME/.local/src" 1

        shopt -s nullglob
        for git_file in "$HOME"/*/*-worktrees/*/.git "$HOME"/*/worktrees/*/.git; do
          [[ -f "$git_file" ]] || continue
          home_prefix="$HOME/"
          workspace="''${git_file#"$home_prefix"}"
          workspace="''${workspace%%/*}"
          add_search_dir "$HOME/$workspace" 2
          add_repo "$(dirname "$git_file")"
        done
        shopt -u nullglob
      }

      select_project() {
        collect_entries "$@"

        if [[ ''${#entries[@]} -eq 0 ]]; then
          printf 'tmux-projects: no repositories found\n' >&2
          exit 1
        fi

        selection="$(printf '%s\n' "''${entries[@]}" \
          | sort \
          | cut -f1 \
          | fzf --prompt='Projects> ')"

        [[ -n "$selection" ]] || exit 0

        path=""
        for entry in "''${entries[@]}"; do
          label="''${entry%%$'\t'*}"
          if [[ "$label" == "$selection" ]]; then
            path="''${entry#*$'\t'}"
            break
          fi
        done

        [[ -n "$path" ]] || exit 1

        session_name="$(printf '%s' "$selection" | tr '/.:' '___')"

        if ! "''${tmux_command[@]}" has-session -t "=$session_name" 2>/dev/null; then
          "''${tmux_command[@]}" new-session -d -s "$session_name" -c "$path"
        fi

        if [[ -n "''${TMUX:-}" ]]; then
          "''${tmux_command[@]}" switch-client -t "=$session_name"
          exit 0
        fi

        if [[ "''${TMUX_PROJECTS_KEEP_SHELL:-0}" == "1" ]]; then
          "''${tmux_command[@]}" attach-session -t "=$session_name"
          exec "''${SHELL:-${pkgs.zsh}/bin/zsh}" -l
        fi

        exec "''${tmux_command[@]}" attach-session -t "=$session_name"
      }

      switch_session() {
        current="$("''${tmux_command[@]}" display-message -p '#S' 2>/dev/null || true)"
        selection="$("''${tmux_command[@]}" list-sessions -F '#{session_last_attached} #{session_name}' 2>/dev/null \
          | sort -rn \
          | cut -d ' ' -f2- \
          | grep -Fxv "$current" \
          | fzf --tiebreak=index --prompt='Sessions> ')"

        [[ -n "$selection" ]] || exit 0
        "''${tmux_command[@]}" switch-client -t "=$selection"
      }

      switch_window() {
        selection="$("''${tmux_command[@]}" list-windows -F '#{window_id} #{window_name}' 2>/dev/null \
          | fzf --prompt='Windows> ')"

        [[ -n "$selection" ]] || exit 0
        "''${tmux_command[@]}" select-window -t "''${selection%% *}"
      }

      print_sessions() {
        current="$("''${tmux_command[@]}" display-message -p '#S' 2>/dev/null || true)"
        "''${tmux_command[@]}" list-sessions -F '#{session_name}' 2>/dev/null \
          | while IFS= read -r session; do
              if [[ "$session" == "$current" ]]; then
                printf '*%s ' "$session"
              else
                printf '%s ' "$session"
              fi
            done
      }

      # --- opencode attention queue ---------------------------------------
      # JSON array of {session, title, status, ts} entries describing tmux
      # sessions whose opencode run finished and awaits the user's attention.

      oc_queue_read() {
        if [[ -s "$oc_queue_file" ]]; then
          cat "$oc_queue_file"
        else
          printf '[]'
        fi
      }

      oc_queue_update() {
        local program="$1"
        shift
        exec 9>"$oc_queue_file.lock"
        flock 9
        oc_queue_read | jq -c "$@" "$program" >"$oc_queue_file.tmp"
        mv "$oc_queue_file.tmp" "$oc_queue_file"
        exec 9>&-
      }

      # Prints "client_tty window_id client_session" of the most recently
      # active client (window_id = the client's current window).
      oc_recent_client() {
        "''${tmux_command[@]}" list-clients -F '#{client_activity} #{client_tty} #{window_id} #{client_session}' 2>/dev/null \
          | sort -rn \
          | while read -r _ rest; do
              printf '%s' "$rest"
              break
            done || true
      }

      # The user is "watching" an entry when ghostty is the focused window and
      # the most recently active tmux client shows that session — and, when a
      # window is known, that specific window.
      oc_user_watching() {
        local session="$1"
        local window="''${2:--}"
        local active_class=""
        local client_info=""
        local rest=""
        local client_window=""
        local client_session=""

        active_class="$(hyprctl activewindow -j 2>/dev/null | jq -r '.class // .initialClass // ""' 2>/dev/null || true)"
        if [[ "$active_class" != "com.mitchellh.ghostty" ]]; then
          return 1
        fi

        client_info="$(oc_recent_client)"
        [[ -n "$client_info" ]] || return 1
        rest="''${client_info#* }"
        client_window="''${rest%% *}"
        client_session="''${rest#* }"

        [[ "$client_session" == "$session" ]] || return 1

        if [[ "$window" == "-" ]]; then
          return 0
        fi

        [[ "$client_window" == "$window" ]]
      }

      oc_queue_add() {
        local session="''${1:-}"
        local window="''${2:--}"
        local status="''${3:-done}"
        shift 3 2>/dev/null || true
        local title="$*"

        if [[ -z "$session" ]]; then
          printf 'usage: tmux-projects oc-queue add SESSION [WINDOW] [STATUS] [TITLE...]\n' >&2
          exit 2
        fi

        if oc_user_watching "$session" "$window"; then
          exit 0
        fi

        # shellcheck disable=SC2016 # $session/$window/$title/$status are jq variables
        oc_queue_update \
          'map(select((.session != $session) or ((.window // "-") != $window)))
           + [{session: $session, window: $window, title: $title, status: $status, ts: now}]' \
          --arg session "$session" --arg window "$window" --arg status "$status" --arg title "''${title:-$session}"
      }

      # Removes entries for a session (all of them) or, when a window is
      # given, only that window's entry plus unknown-window entries. Writes
      # only when something matches, since this runs on every client focus-in
      # and pointless writes would churn the file watchers (bar, picker).
      oc_queue_prune() {
        local session="''${1:-}"
        local window="''${2:-}"
        local queue=""
        local matcher=""
        [[ -n "$session" ]] || return 0

        # shellcheck disable=SC2016 # $session/$window are jq variables
        matcher='.session == $session and ($window == "" or (.window // "-") == $window or (.window // "-") == "-")'

        exec 9>"$oc_queue_file.lock"
        flock 9
        queue="$(oc_queue_read)"
        if jq -e --arg session "$session" --arg window "$window" "any(.[]; $matcher)" <<<"$queue" >/dev/null; then
          jq -c --arg session "$session" --arg window "$window" "map(select(($matcher) | not))" <<<"$queue" >"$oc_queue_file.tmp"
          mv "$oc_queue_file.tmp" "$oc_queue_file"
        fi
        exec 9>&-
      }

      oc_goto_session() {
        local session="$1"
        local window="''${2:--}"
        local client_info=""
        local client_tty=""

        oc_queue_prune "$session" "$window"

        if ! "''${tmux_command[@]}" has-session -t "=$session" 2>/dev/null; then
          return 0
        fi

        # Land on the entry's window (window ids are server-global; the id may
        # be stale if the window was moved or closed, hence the || true).
        if [[ "$window" != "-" ]]; then
          "''${tmux_command[@]}" select-window -t "$window" 2>/dev/null || true
        fi

        client_info="$(oc_recent_client)"

        if [[ -n "$client_info" ]]; then
          client_tty="''${client_info%% *}"
          focus_tmux_terminal
          "''${tmux_command[@]}" switch-client -c "$client_tty" -t "=$session"
          return 0
        fi

        exec ghostty -e "''${tmux_command[@]}" attach-session -t "=$session"
      }

      oc_queue_pop() {
        local queue=""
        local live=""
        local next=""
        local next_window=""

        exec 9>"$oc_queue_file.lock"
        flock 9
        queue="$(oc_queue_read)"
        live="$({ "''${tmux_command[@]}" list-sessions -F '#{session_name}' 2>/dev/null || true; } | jq -R . | jq -s -c .)"
        queue="$(jq -c --argjson live "$live" 'map(select(.session as $s | $live | index($s)))' <<<"$queue")"
        next="$(jq -r '.[0].session // empty' <<<"$queue")"
        next_window="$(jq -r '.[0].window // "-"' <<<"$queue")"
        jq -c '.[1:]' <<<"$queue" >"$oc_queue_file.tmp"
        mv "$oc_queue_file.tmp" "$oc_queue_file"
        exec 9>&-

        [[ -n "$next" ]] || return 0
        oc_goto_session "$next" "$next_window"
      }

      # Prints fzf input lines (display<TAB>session<TAB>window) for live sessions.
      oc_queue_lines() {
        local queue=""
        local live=""

        queue="$(oc_queue_read)"
        live="$({ "''${tmux_command[@]}" list-sessions -F '#{session_name}' 2>/dev/null || true; } | jq -R . | jq -s -c .)"
        jq -r --argjson live "$live" \
          'map(select(.session as $s | $live | index($s)))
           | .[]
           | "\(if .status == "error" then "✗" elif .status == "permission" then "?" else "✓" end) \(.title | gsub("[\\n\\t]"; " "))  ·  \(.session)\(if (.window // "-") != "-" then " \(.window)" else "" end)\t\(.session)\t\(.window // "-")"' \
          <<<"$queue"
      }

      # Background helper started by fzf (inherits $FZF_PORT): pushes a reload
      # to the running picker whenever the queue file changes, and exits when
      # the picker is gone.
      oc_queue_watch() {
        [[ -n "''${FZF_PORT:-}" ]] || exit 0

        local last=""
        local current=""

        while :; do
          if ! curl -fsS -o /dev/null "localhost:''${FZF_PORT}" 2>/dev/null; then
            exit 0
          fi

          current="$(stat -c %Y "$oc_queue_file" 2>/dev/null || printf '0')"

          if [[ "$current" != "$last" ]]; then
            curl -fsS -o /dev/null -XPOST "localhost:''${FZF_PORT}" \
              -d "reload($0 oc-queue lines)" 2>/dev/null || exit 0
            last="$current"
          fi

          sleep 1
        done
      }

      # Fuzzy-pick a waiting session (runs inside a tmux popup or a fresh
      # ghostty window, mirroring select_project). Stays open while empty and
      # refreshes in real time as opencode sessions finish.
      oc_queue_select() {
        local selection=""
        local session=""
        local window=""
        local rest=""

        selection="$(fzf </dev/null \
          --listen \
          --delimiter='\t' --with-nth=1 --tiebreak=index \
          --prompt='OpenCode> ' \
          --header='finished opencode sessions · updates live · esc to close' \
          --bind "start:reload($0 oc-queue lines)+execute-silent(nohup $0 oc-queue watch >/dev/null 2>&1 &)" \
          || true)"
        [[ -n "$selection" ]] || exit 0
        window="''${selection##*$'\t'}"
        rest="''${selection%$'\t'*}"
        session="''${rest##*$'\t'}"

        oc_queue_prune "$session" "$window"

        if ! "''${tmux_command[@]}" has-session -t "=$session" 2>/dev/null; then
          exit 0
        fi

        if [[ "$window" != "-" ]]; then
          "''${tmux_command[@]}" select-window -t "$window" 2>/dev/null || true
        fi

        if [[ -n "''${TMUX:-}" ]]; then
          "''${tmux_command[@]}" switch-client -t "=$session"
          exit 0
        fi

        if [[ "''${TMUX_PROJECTS_KEEP_SHELL:-0}" == "1" ]]; then
          "''${tmux_command[@]}" attach-session -t "=$session"
          exec "''${SHELL:-${pkgs.zsh}/bin/zsh}" -l
        fi

        exec "''${tmux_command[@]}" attach-session -t "=$session"
      }

      # App entrypoint: show the picker in a popup on the most recent tmux
      # client (focusing ghostty), or spawn a ghostty window for it.
      oc_queue_open() {
        local client_info=""
        local client_tty=""

        client_info="$(oc_recent_client)"

        if [[ -n "$client_info" ]]; then
          client_tty="''${client_info%% *}"
          focus_tmux_terminal
          exec "''${tmux_command[@]}" display-popup -t "$client_tty" -E "$0 oc-queue select"
        fi

        exec ghostty -e env TMUX_PROJECTS_KEEP_SHELL=1 "$0" oc-queue select
      }

      oc_queue() {
        local subcommand="''${1:-list}"
        shift || true

        case "$subcommand" in
          add) oc_queue_add "$@" ;;
          pop) oc_queue_pop ;;
          prune) oc_queue_prune "$@" ;;
          goto) oc_goto_session "''${1:?tmux-projects oc-queue goto SESSION [WINDOW]}" "''${2:--}" ;;
          select) oc_queue_select ;;
          open) oc_queue_open ;;
          lines) oc_queue_lines ;;
          watch) oc_queue_watch ;;
          list)
            oc_queue_read
            printf '\n'
            ;;
          *)
            printf 'usage: tmux-projects oc-queue [add|pop|prune|goto|select|open|list]\n' >&2
            exit 2
            ;;
        esac
      }

      case "$command" in
        open) open_picker "$@" ;;
        select) select_project "$@" ;;
        switch) switch_session ;;
        windows) switch_window ;;
        sessions) print_sessions ;;
        oc-queue) oc_queue "$@" ;;
        *)
          printf 'usage: tmux-projects [open|select|switch|windows|sessions|oc-queue]\n' >&2
          exit 2
          ;;
      esac
    '';
  };

  opencodeWebService = { port, profile ? null }:
    let
      profileEnv = lib.optionals (profile != null) (opencodeProfileEnv profile);
    in
    {
      Unit = {
        Description = "OpenCode web interface${lib.optionalString (profile != null) " (${profile})"}";
      };

      Service = {
        Type = "simple";
        WorkingDirectory = opencodeDefaultProject;
        ExecStart = "${opencode2}/bin/opencode2 serve --hostname 127.0.0.1 --port ${toString port}";
        Restart = "on-failure";
        RestartSec = 5;
        Environment = [
          "LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]}"
          # Fixed web-auth password: tailscale is the real gate, this is a formality.
          "OPENCODE_SERVER_PASSWORD=rollnroll"
        ] ++ profileEnv ++ opencodeEnvList;
        # Optional (leading "-"): secrets such as FIGMA_API_KEY, kept out of Git.
        EnvironmentFile = "-${secretsEnvFile}";
      };

      Install.WantedBy = [ "default.target" ];
    };

  # Registers a tailnet-only HTTPS endpoint (via `tailscale serve`) that
  # proxies to a local opencode server. Requires tailscaled's operator user
  # to be jbellavista (set on the system side), so no root is needed.
  opencodeTailscaleServe = port: {
    Unit = {
      Description = "Tailscale HTTPS serve for opencode on port ${toString port}";
    };

    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.tailscale}/bin/tailscale serve --bg --https=${toString port} http://127.0.0.1:${toString port}";
      ExecStop = "${pkgs.tailscale}/bin/tailscale serve --https=${toString port} off";
      # Retry until tailscaled is up after login.
      Restart = "on-failure";
      RestartSec = 5;
    };

    Install.WantedBy = [ "default.target" ];
  };
in

{
  imports = [
    ./hyprland.nix
    inputs.rollnroll-devtools.homeManagerModules.default
  ];

  programs.rollnroll-devtools = lib.mkIf rollnrollEnabled {
    enable = true;
    enableZshIntegration = true;
  };

  home = {
    username = "jbellavista";
    homeDirectory = "/home/jbellavista";
    stateVersion = "25.11";
    sessionVariables = {
      EDITOR = "nvim";
      JAVA_HOME = pkgs.jdk21.home;
      TERMINAL = "ghostty";
    } // opencodeEnv;
    pointerCursor = {
      name = "Adwaita";
      package = pkgs.adwaita-icon-theme;
      size = 24;
      gtk.enable = true;
      x11.enable = true;
    };
    packages = with pkgs; [
      awscli2
      bat
      brightnessctl
      bun
      caddy
      claude-code
      clang
      cmake
      delta
      discord
      docker-compose
      ffmpeg
      gdb
      gettext
      ghostty
      gh
      go
      google-chrome
      google-cloud-sdk
      gnupg
      grim
      jdk21
      jq
      kubectl
      lua-language-server
      mariadb
      gnumake
      nautilus
      nodejs_22
      obs-studio
      opencode2
      opencode
      pavucontrol
      pkg-config
      playerctl
      pnpm
      prettier
      prettierd
      python311
      raddebugger
      rofi
      slurp
      spotify
      strace
      stylua
      typescript-language-server
      uv
      vscode-langservers-extracted
      wl-clipboard
    ]
    ++ [
      hypr-summon
      screenshot
      secedit
      tmux-projects
    ]
    ++ lib.optional (pkgs ? mise) pkgs.mise
    ++ lib.optional (pkgs ? skaffold) pkgs.skaffold;
  };

  programs.home-manager.enable = true;

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.gpg.enable = true;

  services.gpg-agent = {
    enable = true;
    enableZshIntegration = true;
    pinentry.package = pkgs.pinentry-qt;
  };

  systemd.user.services = {
    opencode-web = opencodeWebService { port = 4096; };
    opencode-web-personal = opencodeWebService {
      port = 4097;
      profile = "personal";
    };
    opencode-web-tailscale = opencodeTailscaleServe 4096;
    opencode-web-personal-tailscale = opencodeTailscaleServe 4097;

    # Mirrors the unit shipped in the mako package (not enableable
    # declaratively), shadowed via ~/.config/systemd/user so sd-switch manages
    # it. X-Restart-Triggers forces a restart when the settings change.
    mako = {
      Unit = {
        Description = "Mako notification daemon";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        X-Restart-Triggers = [ (builtins.hashString "sha256" (builtins.toJSON config.services.mako.settings)) ];
      };
      Service = {
        Type = "dbus";
        BusName = "org.freedesktop.Notifications";
        ExecCondition = "${pkgs.runtimeShell} -c '[ -n \"$WAYLAND_DISPLAY\" ]'";
        ExecStart = "${pkgs.mako}/bin/mako";
        ExecReload = "${pkgs.mako}/bin/makoctl reload";
        Restart = "on-failure";
        RestartSec = 1;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };

  services.mako = {
    enable = true;
    settings = {
      anchor = "top-right";
      default-timeout = 0;
      ignore-timeout = true;
      layer = "overlay";
      margin = "12,12";
      padding = "10";
      border-radius = 10;
      border-size = 1;
      width = 360;
      font = "JetBrainsMono Nerd Font 10";
      background-color = "#181825f2";
      text-color = "#cdd6f4";
      border-color = "#89b4fa66";
      progress-color = "over #89b4fa";
      icons = true;
      markup = true;
      actions = true;
      on-button-left = "dismiss";
      "app-name=Blueman".invisible = true;
      "app-name=blueman".invisible = true;
      "app-name=Bluetooth".invisible = true;
      "desktop-entry=blueman".invisible = true;
    };
  };

  programs.git = {
    enable = true;
    includes = [
      {
        condition = "gitdir:~/personal/";
        contents = {
          user = {
            name = "Joan Bellavista Bartroli";
            email = "jbb494@gmail.com";
          };
          url = {
            "git@github.com-personal:".insteadOf = "git@github.com:";
            "ssh://git@github.com-personal/".insteadOf = "ssh://git@github.com/";
            "git+ssh://git@github.com-personal/".insteadOf = "git+ssh://git@github.com/";
          };
        };
      }
    ];
    settings = {
      branch.sort = "-committerdate";
      column.ui = "auto";
      alias.lola = "log --graph --decorate --pretty=oneline --abbrev-commit --all";
      user.name = "Joan Bellavista Bartroli";
      diff = {
        algorithm = "histogram";
        colorMoved = "plain";
        mnemonicPrefix = true;
        renames = true;
      };
      fetch = {
        all = true;
        prune = true;
        pruneTags = true;
      };
      init.defaultBranch = "main";
      push = {
        autoSetupRemote = true;
        default = "current";
        followTags = true;
      };
      remote.pushDefault = "origin";
      rerere = {
        autoupdate = true;
        enabled = true;
      };
      tag.sort = "version:refname";
    };
  };

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    includes = [ "config.local" ];
    matchBlocks = {
      "homelab" = {
        hostname = "ubuntu-4gb-hel1-1";
        user = "jbellavista";
      };

      "pokemon-db-public" = {
        hostname = "ubuntu-4gb-hel1-2";
        user = "jbellavista";
        identityFile = "~/.ssh/id_ed25519_ubuntu-4gb-hel1-2";
        identitiesOnly = true;
      };

      "ubuntu-8gb-fsn1-1" = {
        hostname = "ubuntu-8gb-fsn1-1";
        user = "jbellavista";
        identityFile = "~/.ssh/id_ed25519_ubuntu-4gb-hel1-2";
        identitiesOnly = true;
      };

      "github.com-personal" = {
        hostname = "github.com";
        user = "git";
        identityFile = "~/.ssh/id_ed25519_personal";
        identitiesOnly = true;
      };
    } // lib.optionalAttrs rollnrollEnabled {
      "github.com-rollnroll" = {
        hostname = "github.com";
        user = "git";
        identityFile = "~/.ssh/id_ed25519_rollnroll";
        identitiesOnly = true;
      };
    };
  };

  home.file.".ssh/config".force = true;

  programs.rofi = {
    enable = true;
    package = pkgs.rofi;
    extraConfig = {
      "drun-match-fields" = "name,generic,keywords";
    };
  };

  programs.tmux = {
    enable = true;
    baseIndex = 1;
    clock24 = true;
    escapeTime = 0;
    historyLimit = 200000;
    keyMode = "vi";
    prefix = "C-a";
    terminal = "tmux-256color";
    plugins = with pkgs.tmuxPlugins; [
      continuum
      resurrect
      yank
    ];
    extraConfig = ''
      set -as terminal-overrides ',ghostty*:Tc'
      set -g display-time 4000
      set -g status-interval 5
      set -g focus-events on
      set -g detach-on-destroy off
      setw -g aggressive-resize on

      bind r source-file ~/.config/tmux/tmux.conf
      bind -T copy-mode-vi v send-keys -X begin-selection
      bind -T copy-mode-vi y send-keys -X copy-pipe 'wl-copy' \; send -X clear-selection
      bind -T copy-mode-vi ] send-keys -X next-prompt
      bind -T copy-mode-vi [ send-keys -X previous-prompt

      bind ^ last-window
      bind k select-pane -U
      bind j select-pane -D
      bind h select-pane -L
      bind l select-pane -R

      set -g status-right ' #(${tmuxProjectsBin} sessions)'
      unbind-key F
      bind -r '(' switch-client -p\; refresh-client -S
      bind -r ')' switch-client -n\; refresh-client -S
      bind -r N display-popup -E '${tmuxProjectsBin} select --nvim'
      bind -r f display-popup -E '${tmuxProjectsBin} switch'
      bind -r w display-popup -E '${tmuxProjectsBin} windows'
      bind -r O display-popup -E '${tmuxProjectsBin} oc-queue select'
      bind -r o last-window
      bind -r X kill-session

      # Visiting an entry's tmux window clears it from the opencode attention
      # queue: switching sessions, switching windows within a session, and
      # returning focus to the terminal all prune what is now visible.
      set-hook -g client-session-changed 'run-shell "${tmuxProjectsBin} oc-queue prune \"#{client_session}\" \"#{window_id}\""'
      set-hook -g client-focus-in 'run-shell "${tmuxProjectsBin} oc-queue prune \"#{client_session}\" \"#{window_id}\""'
      set-hook -g session-window-changed 'run-shell "${tmuxProjectsBin} oc-queue prune \"#{session_name}\" \"#{window_id}\""'
    '';
  };

  # Apply tmux config changes (hooks, binds) to the running server on switch,
  # so a manual prefix+r is not needed after rebuilds.
  home.activation.reloadTmuxConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    tmux_socket="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/tmux-$(id -u)/default"
    if [ -S "$tmux_socket" ]; then
      run ${pkgs.tmux}/bin/tmux -S "$tmux_socket" source-file "${config.home.homeDirectory}/.config/tmux/tmux.conf" || true
    fi
  '';


  # The personal profile does not override XDG_CONFIG_HOME, so both profiles
  # share this writable CLI preferences file. It must not be a Nix store link.
  home.activation.registerOpencodeAttentionPlugin = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    cli_file="${config.xdg.configHome}/opencode/cli.json"
    plugin_path="${config.xdg.configHome}/opencode/attention-queue-plugin"
    legacy_plugin_path="${config.xdg.configHome}/opencode/attention-tui.js"
    mkdir -p "$(dirname "$cli_file")"

    if [ ! -e "$cli_file" ]; then
      tmp="$(${pkgs.coreutils}/bin/mktemp "$cli_file.tmp.XXXXXX")"
      if ${pkgs.jq}/bin/jq -n \
        --arg package "$plugin_path" \
        --arg tmuxProjects "${tmuxProjectsBin}" \
        '{plugins: [{package: $package, options: {tmuxProjects: $tmuxProjects}}]}' > "$tmp"; then
        mv "$tmp" "$cli_file"
      else
        rm -f "$tmp"
        printf 'warning: could not initialize %s\n' "$cli_file" >&2
      fi
    elif ! ${pkgs.jq}/bin/jq empty "$cli_file" >/dev/null 2>&1; then
      printf 'warning: leaving malformed OpenCode CLI config unchanged: %s\n' "$cli_file" >&2
    else
      tmp="$(${pkgs.coreutils}/bin/mktemp "$cli_file.tmp.XXXXXX")"
      if ${pkgs.jq}/bin/jq \
        --arg package "$plugin_path" \
        --arg legacyPackage "$legacy_plugin_path" \
        --arg tmuxProjects "${tmuxProjectsBin}" \
        '.plugins = ((.plugins // [])
          | map(select(type != "object" or (.package != $package and .package != $legacyPackage)))
          + [{package: $package, options: {tmuxProjects: $tmuxProjects}}])' \
        "$cli_file" > "$tmp"; then
        mv "$tmp" "$cli_file"
      else
        rm -f "$tmp"
        printf 'warning: could not update OpenCode CLI config: %s\n' "$cli_file" >&2
      fi
    fi
  '';

  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.zsh = {
    enable = true;
    dotDir = config.home.homeDirectory;
    autosuggestion.enable = true;
    enableCompletion = true;
    envExtra = ''
      setopt no_global_rcs
      if [[ -r "${secretsEnvFile}" ]]; then
        set -a
        source "${secretsEnvFile}"
        set +a
      fi
    '';
    shellAliases = {
      ta = "tmux attach";
      v = "nvim";
    };
    plugins = [
      {
        name = "zsh-vi-mode";
        src = pkgs.zsh-vi-mode;
        file = "share/zsh-vi-mode/zsh-vi-mode.plugin.zsh";
      }
    ];
    syntaxHighlighting.enable = true;
    initContent = lib.mkMerge [
      (lib.mkOrder 550 ''
        zvm_config() {
          ZVM_LINE_INIT_MODE=$ZVM_MODE_INSERT
        }
      '')
      (lib.mkOrder 1000 ''
        zvm_after_init() {
          bindkey -M viins '^P' history-beginning-search-backward
          bindkey -M viins '^N' history-beginning-search-forward
          bindkey -M viins '^H' backward-delete-char
        }

        PROMPT='λ > '

        ${lib.optionalString (pkgs ? mise) ''eval "$(${pkgs.mise}/bin/mise activate zsh)"''}

        ${lib.optionalString opencodePersonalProfile ''
          opencode() {
            local profile=""

            case "$PWD/" in
              "$HOME/personal/"*)
                local dir="$PWD"
                while [[ "$dir/" == "$HOME/personal/"* ]]; do
                  if [[ -e "$dir/.opencode-default" ]]; then
                    command opencode "$@"
                    return
                  fi

                  [[ "$dir" == "$HOME/personal" ]] && break
                  dir="''${dir:h}"
                done
                profile="personal"
                ;;
            esac

            if [[ -z "$profile" ]]; then
              command opencode "$@"
              return
            fi

            XDG_DATA_HOME="${personalOpencodeProfileDirs.dataHome}" \
              XDG_STATE_HOME="${personalOpencodeProfileDirs.stateHome}" \
              XDG_CACHE_HOME="${personalOpencodeProfileDirs.cacheHome}" \
              command opencode "$@"
          }
        ''}

        if [[ -f "$HOME/.cargo/env" ]]; then
          source "$HOME/.cargo/env"
        fi

        if [[ -f "$HOME/.zsh_local" ]]; then
          source "$HOME/.zsh_local"
        fi
      '')
    ];
  };

  # Dark theming. GTK3 uses the file-based Adwaita-dark theme; GTK4/libadwaita
  # only honours the prefer-dark hint (no gtk4.theme - it has Adwaita built in).
  gtk = {
    enable = true;
    theme = {
      name = "Adwaita-dark";
      package = pkgs.gnome-themes-extra;
    };
    iconTheme = {
      name = "Adwaita";
      package = pkgs.adwaita-icon-theme;
    };
    gtk3.extraConfig.gtk-application-prefer-dark-theme = 1;
    gtk4.extraConfig.gtk-application-prefer-dark-theme = 1;
  };

  qt = {
    enable = true;
    platformTheme.name = "gtk";
    style.name = "adwaita-dark";
  };

  dconf.settings."org/gnome/desktop/interface" = {
    color-scheme = "prefer-dark";
    gtk-theme = "Adwaita-dark";
    cursor-theme = "Adwaita";
    cursor-size = 24;
  };

  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "inode/directory" = "org.gnome.Nautilus.desktop";
      "text/html" = "google-chrome.desktop";
      "x-scheme-handler/about" = "google-chrome.desktop";
      "x-scheme-handler/claude-cli" = "claude-code-url-handler.desktop";
      "x-scheme-handler/http" = "google-chrome.desktop";
      "x-scheme-handler/https" = "google-chrome.desktop";
      "x-scheme-handler/unknown" = "google-chrome.desktop";
    };
  };

  # Shadow system desktop entries so app launchers behave well under Hyprland.
  # Apps that cannot open a second instance are moved to the current workspace.
  xdg.dataFile = {
    "applications/google-chrome.desktop".text = ''
      [Desktop Entry]
      Version=1.0
      Name=Google Chrome
      GenericName=Web Browser
      Comment=Access the Internet
      Exec=${pkgs.google-chrome}/bin/google-chrome-stable ${chromeFlags} --new-window %U
      StartupNotify=true
      StartupWMClass=Google-chrome
      Terminal=false
      Icon=google-chrome
      Type=Application
      Categories=Network;WebBrowser;
      MimeType=application/pdf;application/rdf+xml;application/rss+xml;application/xhtml+xml;application/xhtml_xml;application/xml;image/gif;image/jpeg;image/png;image/webp;text/html;text/xml;x-scheme-handler/http;x-scheme-handler/https;
      Actions=new-window;new-private-window;

      [Desktop Action new-window]
      Name=New Window
      Exec=${pkgs.google-chrome}/bin/google-chrome-stable ${chromeFlags} --new-window

      [Desktop Action new-private-window]
      Name=New Incognito Window
      Exec=${pkgs.google-chrome}/bin/google-chrome-stable ${chromeFlags} --incognito
    '';
    "applications/google-chrome.desktop".force = true;

    "applications/blueman-manager.desktop".text = ''
      [Desktop Entry]
      Name=Bluetooth Manager
      Comment=Blueman Bluetooth Manager
      Exec=${hypr-summon}/bin/hypr-summon --match "blueman-manager|blueman|bluetooth manager" -- ${pkgs.blueman}/bin/blueman-manager
      Icon=blueman
      StartupNotify=true
      Terminal=false
      Type=Application
      Categories=GTK;GNOME;Settings;HardwareSettings;
    '';
    "applications/blueman-manager.desktop".force = true;

    "applications/org.pulseaudio.pavucontrol.desktop".text = ''
      [Desktop Entry]
      Version=1.0
      Name=Volume Control
      GenericName=Volume Control
      Comment=Adjust the volume level
      Exec=${hypr-summon}/bin/hypr-summon --match "pavucontrol|org[.]pulseaudio[.]pavucontrol|volume control" -- ${pkgs.pavucontrol}/bin/pavucontrol
      Icon=org.pulseaudio.pavucontrol
      StartupNotify=true
      Terminal=false
      Type=Application
      Categories=AudioVideo;Audio;Mixer;GTK;Settings;X-XFCE-SettingsDialog;X-XFCE-HardwareSettings;
      Keywords=pavucontrol;PulseAudio;Microphone;Volume;Audio;Mixer;Output;Input;Devices;Playback;Recording;
    '';
    "applications/org.pulseaudio.pavucontrol.desktop".force = true;

    "applications/nm-connection-editor.desktop".text = ''
      [Desktop Entry]
      Name=Network Connections
      Comment=Manage and change your network connection settings
      Exec=${hypr-summon}/bin/hypr-summon --match "nm-connection-editor|network connections" -- ${pkgs.networkmanagerapplet}/bin/nm-connection-editor
      Icon=preferences-system-network
      StartupNotify=true
      Terminal=false
      Type=Application
      Categories=GNOME;GTK;Settings;X-GNOME-NetworkSettings;
      Keywords=Network;Connections;Wi-Fi;Wifi;Ethernet;
    '';
    "applications/nm-connection-editor.desktop".force = true;

    "applications/screenshot.desktop".text = ''
      [Desktop Entry]
      Name=Screenshot
      GenericName=Screenshot Tool
      Comment=Select a screen region and copy it to the clipboard
      Exec=${screenshot}/bin/screenshot
      Icon=camera-photo
      StartupNotify=false
      Terminal=false
      Type=Application
      Categories=Utility;Graphics;
      Keywords=Screenshot;Screen;Capture;Region;Crop;Rectangle;Clipboard;Grim;Slurp;
    '';
    "applications/screenshot.desktop".force = true;

    "applications/tmux-projects.desktop".text = ''
      [Desktop Entry]
      Name=TMS
      GenericName=Tmux Project Switcher
      Comment=Open a project in tmux
      Exec=${tmux-projects}/bin/tmux-projects open
      Icon=utilities-terminal
      StartupNotify=false
      Terminal=false
      Type=Application
      Categories=Development;Utility;TerminalEmulator;
      Keywords=tmux;projects;worktree;terminal;ghostty;
    '';
    "applications/tmux-projects.desktop".force = true;

    "applications/opencode-attention.desktop".text = ''
      [Desktop Entry]
      Name=OCS
      GenericName=OpenCode Session Picker
      Comment=Jump to a tmux session whose opencode run finished
      Exec=${tmux-projects}/bin/tmux-projects oc-queue open
      Icon=utilities-terminal
      StartupNotify=false
      Terminal=false
      Type=Application
      Categories=Development;Utility;TerminalEmulator;
      Keywords=opencode;tmux;sessions;done;attention;
    '';
    "applications/opencode-attention.desktop".force = true;
  };

  xdg.configFile = {
    "ghostty/config".text = ''
      font-family = JetBrainsMonoNL Nerd Font Mono
      font-feature = -calt, -liga, -dlig
      keybind = ctrl+enter=unbind
    '';
    "nvim".source = inputs.nvim-config;
    "opencode/opencode.json".text = builtins.toJSON ({
      "$schema" = "https://opencode.ai/config.json";
      share = "disabled";
      autoupdate = false;
      model = "openai/gpt-5.6-sol";
    } // lib.optionalAttrs opencodeLinearMcp {
      # Linear MCP is host-specific; enabled per host via extraSpecialArgs.
      mcp.servers = {
        "linear-server" = {
          type = "remote";
          url = "https://mcp.linear.app/mcp";
        };
        sentry = {
          type = "remote";
          url = "https://mcp.sentry.dev/mcp";
        };
        # Community Figma MCP (figma-developer-mcp): reads FIGMA_API_KEY from the
        # secrets env file so it works regardless of how the daemon was spawned.
        figma = {
          type = "local";
          command = [
            "/run/current-system/sw/bin/zsh"
            "-c"
            "[ -r \"\${HOME}/.secrets/opencode.env\" ] && { set -a; source \"\${HOME}/.secrets/opencode.env\"; set +a; }; export PATH=\"/etc/profiles/per-user/jbellavista/bin:$PATH\"; exec npx -y figma-developer-mcp@0.13.2 --stdio"
          ];
        };
      };
    });
    # Adds completed/interrupted/failed top-level sessions to the tmux-projects
    # attention queue, surfaced by the bar widget and popped with $mod+O.
    #
    # The v2 shared background service broadcasts every session's events to
    # every connected TUI, so each TUI's plugin instance only reports sessions
    # it owns (open tab or focused route). Background subagents wake the root
    # session each time they report, settling it repeatedly, so "done" waits a
    # grace period and is dropped when the session is running again. Service
    # shutdown interruptions resume on the next boot and are ignored.
    "opencode/attention-queue-plugin/tui.js".text = ''
      import { Plugin } from "@opencode-ai/plugin/tui"
      import { execFile } from "node:child_process"

      const DEFAULT_TMUX_PROJECTS = "${tmuxProjectsBin}"
      const SETTLE_MS = 2000
      const RENAME_WAIT_MS = 3000

      function execute(file, args) {
        return new Promise((resolve, reject) => {
          execFile(file, args, { encoding: "utf8" }, (error, stdout) => {
            if (error) reject(error)
            else resolve(stdout)
          })
        })
      }

      function sleep(ms) {
        return new Promise((resolve) => setTimeout(resolve, ms))
      }

      export default Plugin.define({
        id: "attention-queue",
        setup(context) {
          if (!process.env.TMUX || !process.env.TMUX_PANE) return

          const tmuxPane = process.env.TMUX_PANE
          const tmuxProjects =
            typeof context.options.tmuxProjects === "string" ? context.options.tmuxProjects : DEFAULT_TMUX_PROJECTS
          let disposed = false

          const tmuxContext = async () => {
            try {
              const info = (await execute("tmux", ["display-message", "-p", "-t", tmuxPane, "#{window_id} #S"])).trim()
              const spaceIndex = info.indexOf(" ")
              if (spaceIndex > 0) return { window: info.slice(0, spaceIndex), session: info.slice(spaceIndex + 1) }
            } catch {}
            return undefined
          }

          const rooted = (sessionID) => {
            try {
              return context.data.session.root(sessionID) || sessionID
            } catch {
              return sessionID
            }
          }

          // The shared service's event feed is global; only sessions surfaced
          // in this TUI (an open tab or the focused route) belong to this
          // tmux window's attention queue.
          const owned = (sessionID) => {
            const root = rooted(sessionID)
            try {
              const route = context.ui.router.current()
              if (route.type === "session" && rooted(route.sessionID) === root) return true
            } catch {}
            try {
              return context.ui.tabs.list().some((tab) => tab.sessionID === root)
            } catch {}
            return false
          }

          const resolveSession = async (sessionID) => {
            let session = context.data.session.get(sessionID)
            if (!session) {
              try {
                await context.data.session.sync(sessionID)
                session = context.data.session.get(sessionID)
              } catch {}
            }
            return session
          }

          const enqueue = async (sessionID, status, title) => {
            const session = await resolveSession(sessionID)
            if (session?.parentID) return

            const tmux = await tmuxContext()
            if (!tmux?.session) return

            try {
              await execute(tmuxProjects, [
                "oc-queue",
                "add",
                tmux.session,
                tmux.window,
                status,
                title || session?.title || sessionID,
              ])
            } catch {}
          }

          const pending = new Map()
          const ended = async (sessionID, status) => {
            const session = await resolveSession(sessionID)
            if (session?.parentID) return
            if (!owned(sessionID)) return

            // Orchestrations settle the root session once per subagent
            // report; only the settle that sticks deserves attention.
            if (status === "done") {
              await sleep(SETTLE_MS)
              if (disposed) return
              if (context.data.session.status(sessionID) === "running") return
            }

            const title = context.data.session.get(sessionID)?.title || session?.title
            if (title) {
              await enqueue(sessionID, status, title)
              return
            }

            const previous = pending.get(sessionID)
            if (previous) clearTimeout(previous.timer)
            const timer = setTimeout(() => {
              pending.delete(sessionID)
              void enqueue(sessionID, status)
            }, RENAME_WAIT_MS)
            pending.set(sessionID, { status, timer })
          }

          const dispose = [
            context.data.on("session.execution.succeeded", (event) => {
              void ended(event.data.sessionID, "done")
            }),
            context.data.on("session.execution.interrupted", (event) => {
              // Service shutdown interrupts every running session at once and
              // the turns resume on the next boot; that is not attention.
              if (event.data.reason === "shutdown") return
              void ended(event.data.sessionID, "done")
            }),
            context.data.on("session.execution.failed", (event) => {
              void ended(event.data.sessionID, "error")
            }),
            context.data.on("session.renamed", (event) => {
              const item = pending.get(event.data.sessionID)
              if (!item) return
              clearTimeout(item.timer)
              pending.delete(event.data.sessionID)
              void enqueue(event.data.sessionID, item.status, event.data.title)
            }),
          ]

          return () => {
            disposed = true
            dispose.reverse().forEach((cleanup) => cleanup())
            for (const item of pending.values()) clearTimeout(item.timer)
            pending.clear()
          }
        },
      })
    '';
  };
}
