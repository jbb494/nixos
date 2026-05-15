{ inputs
, config
, lib
, pkgs
, ...
}:

let
  tmuxProjectsBin = "/etc/profiles/per-user/jbellavista/bin/tmux-projects";

  screenshot-full = pkgs.writeShellApplication {
    name = "screenshot-full";
    runtimeInputs = with pkgs; [
      grim
      swappy
    ];
    text = ''
      grim - | swappy -f -
    '';
  };

  screenshot-region = pkgs.writeShellApplication {
    name = "screenshot-region";
    runtimeInputs = with pkgs; [
      grim
      slurp
      swappy
    ];
    text = ''
      geometry="$(slurp)"
      grim -g "$geometry" - | swappy -f -
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
      findutils
      fzf
      ghostty
      hyprland
      jq
      tmux
    ];
    text = ''
      set -euo pipefail

      tmux_command=(tmux)
      tmux_socket="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/tmux-$(id -u)/default"
      if [[ -S "$tmux_socket" ]]; then
        tmux_command=(tmux -S "$tmux_socket")
      fi

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

        exec ghostty -e "$0" select "$@"
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

        if ! "''${tmux_command[@]}" has-session -t "$session_name" 2>/dev/null; then
          "''${tmux_command[@]}" new-session -d -s "$session_name" -c "$path"
        fi

        if [[ -n "''${TMUX:-}" ]]; then
          "''${tmux_command[@]}" switch-client -t "$session_name"
          exit 0
        fi

        exec "''${tmux_command[@]}" attach-session -t "$session_name"
      }

      switch_session() {
        current="$("''${tmux_command[@]}" display-message -p '#S' 2>/dev/null || true)"
        selection="$("''${tmux_command[@]}" list-sessions -F '#{session_last_attached} #{session_name}' 2>/dev/null \
          | sort -rn \
          | cut -d ' ' -f2- \
          | grep -Fxv "$current" \
          | fzf --no-sort --prompt='Sessions> ')"

        [[ -n "$selection" ]] || exit 0
        "''${tmux_command[@]}" switch-client -t "$selection"
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

      case "$command" in
        open) open_picker "$@" ;;
        select) select_project "$@" ;;
        switch) switch_session ;;
        windows) switch_window ;;
        sessions) print_sessions ;;
        *)
          printf 'usage: tmux-projects [open|select|switch|windows|sessions]\n' >&2
          exit 2
          ;;
      esac
    '';
  };
in

{
  imports = [
    ./hyprland.nix
    inputs.rollnroll-devtools.homeManagerModules.default
  ];

  programs.rollnroll-devtools = {
    enable = true;
    enableZshIntegration = false;
  };

  home = {
    username = "jbellavista";
    homeDirectory = "/home/jbellavista";
    stateVersion = "25.11";
    sessionVariables = {
      EDITOR = "nvim";
      TERMINAL = "ghostty";
    };
    pointerCursor = {
      name = "Adwaita";
      package = pkgs.adwaita-icon-theme;
      size = 24;
      gtk.enable = true;
      x11.enable = true;
    };
    packages = with pkgs; [
      bat
      brightnessctl
      bun
      caddy
      claude-code
      cmake
      delta
      discord
      docker-compose
      gcc
      gettext
      ghostty
      gh
      go
      google-chrome
      gnupg
      grim
      jq
      kubectl
      lua-language-server
      nodejs_22
      obs-studio
      opencode
      pavucontrol
      playerctl
      pnpm
      python311
      rofi
      slurp
      spotify
      stylua
      swappy
      typescript-language-server
      uv
      vscode-langservers-extracted
      wl-clipboard
    ]
    ++ [
      hypr-summon
      screenshot-full
      screenshot-region
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
    };
  };

  programs.git = {
    enable = true;
    includes = [
      {
        condition = "gitdir:~/personal/";
        contents.user = {
          name = "Joan Bellavista Bartroli";
          email = "jbb494@gmail.com";
        };
      }
    ];
    settings = {
      branch.sort = "-committerdate";
      column.ui = "auto";
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
    matchBlocks = {
      "github.com-personal" = {
        hostname = "github.com";
        user = "git";
        identityFile = "~/.ssh/id_ed25519_personal";
        identitiesOnly = true;
      };
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
      bind -r o last-window
      bind -r X kill-session
    '';
  };

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
        path=("$HOME/rollnroll/devtools/bin" $path)
        fpath=("$HOME/rollnroll/devtools/completions" $fpath)

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

          XDG_DATA_HOME="$HOME/.local/share/opencode-profiles/$profile/data" \
            XDG_STATE_HOME="$HOME/.local/state/opencode-profiles/$profile" \
            XDG_CACHE_HOME="$HOME/.cache/opencode-profiles/$profile" \
            command opencode "$@"
        }

        if [[ -f "$HOME/.cargo/env" ]]; then
          source "$HOME/.cargo/env"
        fi

        if [[ -f "$HOME/.zsh_local" ]]; then
          source "$HOME/.zsh_local"
        fi
      '')
    ];
  };

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
    gtk4 = {
      theme = {
        name = "Adwaita-dark";
        package = pkgs.gnome-themes-extra;
      };
      extraConfig.gtk-application-prefer-dark-theme = 1;
    };
  };

  qt = {
    enable = true;
    platformTheme.name = "gtk";
    style.name = "adwaita-dark";
  };

  dconf.settings = {
    "org/gnome/desktop/interface" = {
      color-scheme = "prefer-dark";
      gtk-theme = "Adwaita-dark";
      cursor-theme = "Adwaita";
      cursor-size = 24;
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
      Exec=${pkgs.google-chrome}/bin/google-chrome-stable --new-window %U
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
      Exec=${pkgs.google-chrome}/bin/google-chrome-stable --new-window

      [Desktop Action new-private-window]
      Name=New Incognito Window
      Exec=${pkgs.google-chrome}/bin/google-chrome-stable --incognito
    '';

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

    "applications/screenshot-full.desktop".text = ''
      [Desktop Entry]
      Name=Screenshot Full Screen
      GenericName=Screenshot Tool
      Comment=Capture the full screen and edit it in Swappy
      Exec=${screenshot-full}/bin/screenshot-full
      Icon=camera-photo
      StartupNotify=false
      Terminal=false
      Type=Application
      Categories=Utility;Graphics;
      Keywords=Screenshot;Screen;Capture;Swappy;Grim;
    '';

    "applications/screenshot-region.desktop".text = ''
      [Desktop Entry]
      Name=Screenshot Region
      GenericName=Screenshot Tool
      Comment=Select a screen region and edit it in Swappy
      Exec=${screenshot-region}/bin/screenshot-region
      Icon=camera-photo
      StartupNotify=false
      Terminal=false
      Type=Application
      Categories=Utility;Graphics;
      Keywords=Screenshot;Screen;Capture;Region;Swappy;Grim;Slurp;
    '';

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
  };

  xdg.configFile = {
    "ghostty/config".text = ''
      font-family = JetBrainsMonoNL Nerd Font Mono
      font-feature = -calt, -liga, -dlig
    '';
    "nvim".source = inputs.nvim-config;
    "opencode/config.json".text = ''
      {
        "$schema": "https://opencode.ai/config.json",
        "share": "disabled",
        "autoupdate": false
      }
    '';
    "opencode/tui.json".text = ''
      {
        "$schema": "https://opencode.ai/tui.json",
        "keybinds": {
          "leader": "ctrl+x",
          "app_exit": "ctrl+c,<leader>q",
          "editor_open": "<leader>e",
          "theme_list": "<leader>t",
          "session_new": "<leader>n",
          "session_list": "<leader>l",
          "session_share": "<leader>s",
          "session_unshare": "<leader>u",
          "session_interrupt": "escape",
          "session_compact": "<leader>c",
          "messages_page_up": "pageup",
          "messages_page_down": "pagedown",
          "messages_half_page_up": "ctrl+u",
          "messages_half_page_down": "ctrl+d",
          "messages_first": "ctrl+g",
          "messages_last": "ctrl+alt+g",
          "messages_copy": "<leader>y",
          "messages_undo": "<leader>u",
          "messages_redo": "<leader>r",
          "model_list": "<leader>m",
          "input_clear": "ctrl+c",
          "input_paste": "ctrl+v",
          "input_submit": "return",
          "input_newline": "shift+return,ctrl+return,alt+return,ctrl+j",
          "history_previous": "ctrl+up",
          "history_next": "ctrl+down"
        }
      }
    '';
  };
}
