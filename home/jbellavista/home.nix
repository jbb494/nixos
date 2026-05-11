{ inputs
, lib
, pkgs
, ...
}:

{
  imports = [
    ./hyprland.nix
  ];

  home = {
    username = "jbellavista";
    homeDirectory = "/home/jbellavista";
    stateVersion = "25.11";
    sessionVariables = {
      EDITOR = "nvim";
      TERMINAL = if pkgs ? ghostty then "ghostty" else "alacritty";
    };
    packages = with pkgs; [
      alacritty
      bat
      brightnessctl
      bun
      cmake
      delta
      docker-compose
      firefox
      gcc
      gettext
      gh
      go
      grim
      jq
      kubectl
      lua-language-server
      nodejs_22
      pavucontrol
      playerctl
      pnpm
      python311
      rofi
      rust-analyzer
      rustup
      slurp
      stylua
      swappy
      typescript-language-server
      uv
      vscode-langservers-extracted
      waybar
      wl-clipboard
    ]
    ++ lib.optional (pkgs ? ghostty) pkgs.ghostty
    ++ lib.optional (pkgs ? mise) pkgs.mise
    ++ lib.optional (pkgs ? opencode) pkgs.opencode
    ++ lib.optional (pkgs ? skaffold) pkgs.skaffold
    ++ lib.optional (pkgs ? tmux-sessionizer) pkgs.tmux-sessionizer;
  };

  programs.home-manager.enable = true;

  programs.alacritty = {
    enable = true;
    settings = {
      window.opacity = 1.0;
      font.normal = {
        family = "JetBrainsMono Nerd Font";
        style = "Regular";
      };
    };
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
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
        default = "simple";
        followTags = true;
      };
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
    matchBlocks."github.com-personal" = {
      hostname = "github.com";
      user = "git";
      identityFile = "~/.ssh/id_ed25519_personal";
      identitiesOnly = true;
    };
  };

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
      set -as terminal-overrides ',alacritty*:Tc,ghostty*:Tc'
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

      set -g status-right ' #(tms sessions)'
      bind -r '(' switch-client -p\; refresh-client -S
      bind -r ')' switch-client -n\; refresh-client -S
      bind -r N display-popup -E 'TMS_CONFIG_FILE=~/.config/tms/config-nvim-repos.toml tms'
      bind -r F display-popup -E 'tms'
      bind -r f display-popup -E 'tms switch'
      bind -r w display-popup -E 'tms windows'
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
    autosuggestion.enable = true;
    enableCompletion = true;
    shellAliases = {
      ta = "tmux attach";
      v = "nvim";
    };
    syntaxHighlighting.enable = true;
    initContent = ''
      bindkey -v

      ${lib.optionalString (pkgs ? mise) ''eval "$(${pkgs.mise}/bin/mise activate zsh)"''}

      if [[ -f "$HOME/.cargo/env" ]]; then
        source "$HOME/.cargo/env"
      fi

      if [[ -f "$HOME/.zsh_local" ]]; then
        source "$HOME/.zsh_local"
      fi
    '';
  };

  services.mako = {
    enable = true;
    settings = {
      default-timeout = 8000;
      font = "JetBrainsMono Nerd Font 10";
      border-size = 2;
      border-radius = 8;
    };
  };

  xdg.configFile = {
    "nvim".source = inputs.nvim-config;
    "opencode/config.json".text = ''
      {
        "$schema": "https://opencode.ai/config.json",
        "keybinds": {
          "leader": "ctrl+x",
          "app_exit": "ctrl+c,<leader>q",
          "editor_open": "<leader>e",
          "theme_list": "<leader>t",
          "session_new": "<leader>n",
          "session_list": "<leader>l",
          "session_share": "<leader>s",
          "session_unshare": "<leader>u",
          "session_interrupt": "esc",
          "session_compact": "<leader>c",
          "messages_page_up": "pgup",
          "messages_page_down": "pgdown",
          "messages_half_page_up": "ctrl+u",
          "messages_half_page_down": "ctrl+d",
          "messages_first": "ctrl+g",
          "messages_last": "ctrl+alt+g",
          "messages_copy": "<leader>y",
          "messages_undo": "<leader>r",
          "model_list": "<leader>m",
          "input_clear": "ctrl+c",
          "input_paste": "ctrl+v",
          "input_submit": "enter",
          "input_newline": "shift+enter,ctrl+j",
          "history_previous": "ctrl+up",
          "history_next": "ctrl+down"
        },
        "share": "disabled"
      }
    '';
    "tms/config.toml".text = ''
      default_session = "default_session"
      search_submodules = true
      recursive_submodules = true
      full_path = true
      session_sort_order = "LastAttached"

      [[search_dirs]]
      path = "~/personal"
      depth = 2

      [[search_dirs]]
      path = "~/.local/src"
      depth = 1
    '';
    "tms/config-nvim-repos.toml".text = ''
      default_session = "default_session"
      search_submodules = true
      recursive_submodules = true
      full_path = true
      session_sort_order = "LastAttached"

      [[search_dirs]]
      path = "~/.local/share/nvim/lazy"
      depth = 1
    '';
  };
}
