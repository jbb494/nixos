local starcraft_workspace_id = nil
local starcraft_window_address = nil

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
  if starcraft_workspace_id then
    configure_workspace(starcraft_workspace_id, false)
  end

  starcraft_workspace_id = nil
  starcraft_window_address = nil
end

local function set_starcraft_workspace(window, workspace)
  local next_id = workspace and workspace.id or nil

  if starcraft_workspace_id and starcraft_workspace_id ~= next_id then
    configure_workspace(starcraft_workspace_id, false)
  end

  starcraft_workspace_id = next_id
  starcraft_window_address = next_id and window.address or nil

  if not next_id then
    return
  end

  configure_workspace(next_id, true)

  -- Let the title/workspace update finish before promoting Gamescope to the
  -- right-hand master pane. Only the outer container is rearranged.
  local address = window.address
  hl.timer(function()
    hl.dispatch(hl.dsp.window.float({
      action = "disable",
      window = "address:" .. address,
    }))
    hl.dispatch(hl.dsp.layout("swapwithmaster master ignoremaster"))
  end, { timeout = 1, type = "oneshot" })
end

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
