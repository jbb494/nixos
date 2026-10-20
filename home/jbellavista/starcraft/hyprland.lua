local starcraft_workspace_id = nil
local starcraft_window_address = nil
local starcraft_pane_mode = false

local function is_starcraft_gamescope(window)
  return window.class == "gamescope" and window.title == "StarCraft II"
end

local function is_battlenet_gamescope(window)
  return window.class == "gamescope" and string.match(window.title, "^Battle%.net")
end

local function configure_workspace(workspace_id, gaming)
  if gaming then
    hl.workspace_rule({
      workspace = tostring(workspace_id),
      layout = "master",
      gaps_in = 0,
      gaps_out = 0,
      layout_opts = { orientation = "right" },
    })
  else
    hl.workspace_rule({
      workspace = tostring(workspace_id),
      layout = "dwindle",
      gaps_in = 4,
      gaps_out = 8,
    })
  end
end

local function configure_battlenet_window(window)
  local address = window.address
  hl.timer(function()
    hl.dispatch(hl.dsp.window.float({
      action = "enable",
      window = "address:" .. address,
    }))
    hl.dispatch(hl.dsp.window.resize({
      x = 1600,
      y = 900,
      relative = false,
      window = "address:" .. address,
    }))
    hl.dispatch(hl.dsp.window.center({
      window = "address:" .. address,
    }))
  end, { timeout = 1, type = "oneshot" })
end

local function clear_starcraft_workspace()
  if starcraft_window_address then
    hl.dispatch(hl.dsp.window.fullscreen({
      action = "unset",
      mode = "fullscreen",
      window = "address:" .. starcraft_window_address,
    }))
  end
  if starcraft_workspace_id then
    configure_workspace(starcraft_workspace_id, false)
  end

  starcraft_workspace_id = nil
  starcraft_window_address = nil
  starcraft_pane_mode = false
end

local function set_starcraft_workspace(window, workspace)
  local next_id = workspace and workspace.id or nil

  if starcraft_workspace_id and starcraft_workspace_id ~= next_id then
    configure_workspace(starcraft_workspace_id, false)
  end

  if starcraft_window_address ~= window.address then
    starcraft_pane_mode = false
  end

  starcraft_workspace_id = next_id
  starcraft_window_address = next_id and window.address or nil

  if not next_id then
    return
  end

  configure_workspace(next_id, true)

  -- Apply after title/workspace rules, without focusing or switching workspaces.
  local address = window.address
  hl.timer(function()
    local current = nil
    for _, candidate in ipairs(hl.get_windows({ class = "gamescope" })) do
      if candidate.address == address and is_starcraft_gamescope(candidate) then
        current = candidate
        break
      end
    end
    if not current or starcraft_window_address ~= address then
      return
    end

    hl.dispatch(hl.dsp.window.fullscreen({
      action = starcraft_pane_mode and "unset" or "set",
      mode = "fullscreen",
      window = "address:" .. address,
    }))
    hl.dispatch(hl.dsp.window.float({
      action = "disable",
      window = "address:" .. address,
    }))
    local active = hl.get_active_window()
    if starcraft_pane_mode and active and active.address == address then
      hl.dispatch(hl.dsp.layout("swapwithmaster master ignoremaster"))
    end
  end, { timeout = 1, type = "oneshot" })
end

-- Only intercept this shortcut when the game is focused. The game stays
-- running at 2560x1440; Gamescope fits it into either outer-window layout.
hl.bind("SUPER + SHIFT + F", function()
  local window = hl.get_active_window()
  if window and is_starcraft_gamescope(window) then
    starcraft_pane_mode = not starcraft_pane_mode
    set_starcraft_workspace(window, window.workspace)
  end
end)

for _, window in ipairs(hl.get_windows({ class = "gamescope" })) do
  if is_starcraft_gamescope(window) then
    set_starcraft_workspace(window, window.workspace)
    break
  elseif is_battlenet_gamescope(window) then
    configure_battlenet_window(window)
    break
  end
end

hl.on("window.open", function(window)
  if is_starcraft_gamescope(window) then
    set_starcraft_workspace(window, window.workspace)
  elseif is_battlenet_gamescope(window) then
    configure_battlenet_window(window)
  end
end)

hl.on("window.title", function(window)
  if is_starcraft_gamescope(window) then
    set_starcraft_workspace(window, window.workspace)
  else
    if window.address == starcraft_window_address then
      clear_starcraft_workspace()
    end

    if is_battlenet_gamescope(window) then
      configure_battlenet_window(window)
    end
  end
end)

hl.on("window.move_to_workspace", function(window, workspace)
  if window.address == starcraft_window_address or is_starcraft_gamescope(window) then
    set_starcraft_workspace(window, workspace)
  end
end)

hl.on("window.close", function(window)
  if window.address == starcraft_window_address then
    clear_starcraft_workspace()
  end
end)
