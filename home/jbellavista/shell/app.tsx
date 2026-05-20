import { App, Gdk, Gtk } from 'astal/gtk3';
import Astal from 'gi://Astal?version=3.0';
import AstalBattery from 'gi://AstalBattery?version=0.1';
import AstalBluetooth from 'gi://AstalBluetooth?version=0.1';
import AstalHyprland from 'gi://AstalHyprland?version=0.1';
import AstalMpris from 'gi://AstalMpris?version=0.1';
import AstalNetwork from 'gi://AstalNetwork?version=0.1';
import AstalTray from 'gi://AstalTray?version=0.1';
import AstalWp from 'gi://AstalWp?version=0.1';
import NM from 'gi://NM?version=1.0';
import { Gio, GLib, Variable, bind } from 'astal';
import style from './style.css';
import { RollnrollButton, RollnrollDropdown, closeRollnroll, openRollnrollMonitor, rollnrollCss } from './external/rollnroll';

const battery = AstalBattery.get_default();
const bluetooth = AstalBluetooth.get_default() as AstalBluetooth.Bluetooth;
const hyprland = AstalHyprland.get_default() as AstalHyprland.Hyprland;
const mpris = AstalMpris.get_default() as AstalMpris.Mpris;
const network = AstalNetwork.get_default() as AstalNetwork.Network;
const tray = AstalTray.get_default() as AstalTray.Tray;
const wireplumber = AstalWp.get_default() as AstalWp.Wp;
const audio = wireplumber.audio;
type DropdownPosition = {
  monitor: number;
  marginRight: number;
};

const openAudioPosition = Variable<DropdownPosition | null>(null);
const openBluetoothPosition = Variable<DropdownPosition | null>(null);
const openMediaPosition = Variable<DropdownPosition | null>(null);
const openNetworkPosition = Variable<DropdownPosition | null>(null);
const activeMediaPlayer = Variable<AstalMpris.Player | null>(null);
const mediaButtonLabel = Variable('󰎇 media');
const mediaButtonCoverCss = Variable('');
const mediaButtonHasCover = Variable(false);
const networkScanActive = Variable(false);
const stagedWifiBssid = Variable<string | null>(null);
const stagedWifiPassword = Variable('');
const wifiConnectingBssid = Variable<string | null>(null);
const wifiConnectionError = Variable('');
const savedWifiConnections = Variable<Map<string, string>>(new Map());
const dropdownMarginTop = 72;
let networkManagerClient: NM.Client;
const watchedMediaPlayers = new Set<string>();

const clock = Variable(GLib.DateTime.new_now_local()).poll(
  1000,
  () => GLib.DateTime.new_now_local(),
);

const ssidFromBytes = (bytes: GLib.Bytes) => new TextDecoder().decode(Uint8Array.from(bytes.get_data())).replace(/\0+$/, '');

const mediaIcon = (player: AstalMpris.Player | null) => {
  if (!player) {
    return '󰎇';
  }

  if (player.playbackStatus === AstalMpris.PlaybackStatus.PLAYING) {
    return '󰏤';
  }

  if (player.playbackStatus === AstalMpris.PlaybackStatus.PAUSED) {
    return '󰐊';
  }

  return '󰓛';
};

const mediaLabel = (player: AstalMpris.Player | null) => {
  if (!player) {
    return '󰎇 media';
  }

  return `${mediaIcon(player)} ${player.title || player.identity || 'media'}`;
};

const selectActiveMediaPlayer = () => {
  const players = mpris.get_players();
  const current = activeMediaPlayer.get();
  const playing = players.find((player) => player.playbackStatus === AstalMpris.PlaybackStatus.PLAYING) ?? null;
  const currentStillPaused = current && players.some((player) => player.busName === current.busName) && current.playbackStatus === AstalMpris.PlaybackStatus.PAUSED ? current : null;
  const paused = players.find((player) => player.playbackStatus === AstalMpris.PlaybackStatus.PAUSED) ?? null;
  const next = playing ?? currentStillPaused ?? paused;

  if (activeMediaPlayer.get()?.busName !== next?.busName) {
    activeMediaPlayer.set(next);
  }

  mediaButtonLabel.set(mediaLabel(next));
  mediaButtonCoverCss.set(next?.coverArt ? `background-image: url("${next.coverArt}");` : '');
  mediaButtonHasCover.set(!!next?.coverArt);
};

const watchMediaPlayer = (player: AstalMpris.Player) => {
  if (watchedMediaPlayers.has(player.busName)) {
    return;
  }

  watchedMediaPlayers.add(player.busName);
  player.connect('notify::playback-status', selectActiveMediaPlayer);
  player.connect('notify::title', selectActiveMediaPlayer);
  player.connect('notify::artist', selectActiveMediaPlayer);
  player.connect('notify::cover-art', selectActiveMediaPlayer);
  player.connect('notify::identity', selectActiveMediaPlayer);
};

const refreshKnownWifiSsids = (client: NM.Client) => {
  const connections = new Map<string, string>();

  for (const connection of client.get_connections()) {
    const wireless = connection.get_setting_wireless();

    if (wireless !== null) {
      connections.set(ssidFromBytes(wireless.get_ssid()), connection.get_uuid());
    }
  }

  savedWifiConnections.set(connections);
};

NM.Client.new_async(null, (_, result) => {
  networkManagerClient = NM.Client.new_finish(result);
  refreshKnownWifiSsids(networkManagerClient);
  networkManagerClient.connect('connection-added', () => refreshKnownWifiSsids(networkManagerClient));
  networkManagerClient.connect('connection-removed', () => refreshKnownWifiSsids(networkManagerClient));
});

mpris.get_players().forEach(watchMediaPlayer);
selectActiveMediaPlayer();

mpris.connect('player-added', (_, player) => {
  watchMediaPlayer(player);
  selectActiveMediaPlayer();
});

mpris.connect('player-closed', (_, closedPlayer) => {
  watchedMediaPlayers.delete(closedPlayer.busName);
  selectActiveMediaPlayer();
});

const ram = Variable('').poll(2000, 'cat /proc/meminfo', (output: string) => {
  const values = new Map<string, number>();

  for (const line of output.split('\n')) {
    const match = line.match(/^(MemTotal|MemAvailable):\s+(\d+)/);
    if (match) {
      values.set(match[1], Number.parseInt(match[2], 10));
    }
  }

  const total = values.get('MemTotal') ?? 0;
  const available = values.get('MemAvailable') ?? 0;
  return `${(available / 1048576).toFixed(1)} GB`;
});

type CpuSample = {
  idle: number;
  total: number;
};

let previousCpu: CpuSample | undefined;

const cpu = Variable('CPU --%').poll(2000, 'cat /proc/stat', (output: string) => {
  const cpuLine = output.split('\n').find((line) => line.startsWith('cpu '));
  if (!cpuLine) {
    return 'CPU --%';
  }

  const parts = cpuLine.trim().split(/\s+/).slice(1).map(Number);
  const idle = (parts[3] ?? 0) + (parts[4] ?? 0);
  const total = parts.reduce((sum, value) => sum + value, 0);
  const sample = { idle, total };

  if (!previousCpu) {
    previousCpu = sample;
    return 'CPU --%';
  }

  const idleDelta = sample.idle - previousCpu.idle;
  const totalDelta = sample.total - previousCpu.total;
  previousCpu = sample;

  if (totalDelta <= 0) {
    return 'CPU --%';
  }

  return `CPU ${String(Math.round((1 - idleDelta / totalDelta) * 100)).padStart(3, ' ')}%`;
});

const Widget = ({ label, className = '', visible = true }: { label: string | ReturnType<typeof bind>; className?: string; visible?: boolean | ReturnType<typeof bind> }) => (
  <box className={`widget ${className}`} visible={visible}>
    <label label={label} />
  </box>
);

const ButtonWidget = ({
  label,
  onClick,
}: {
  label: string | ReturnType<typeof bind>;
  onClick: (self: Gtk.Widget) => void;
}) => (
  <button className="widget" onClick={(self) => onClick(self)}>
    <label label={label} />
  </button>
);

const GroupGap = () => <box className="group-gap" />;

const trayMenu = (menuModel: Gio.MenuModel, actionGroup: Gio.ActionGroup | null) => {
  const menu = Gtk.Menu.new_from_model(menuModel);
  menu.insert_action_group('dbusmenu', actionGroup);
  return menu;
};

const TrayItem = ({ item }: { item: AstalTray.TrayItem }) => {
  let menu: Gtk.Menu | undefined;
  const menuBinding = Variable.derive(
    [bind(item, 'menuModel'), bind(item, 'actionGroup')],
    (menuModel, actionGroup) => {
      menu?.destroy();
      menu = menuModel ? trayMenu(menuModel, actionGroup) : undefined;
    },
  );

  return (
    <button
      className={bind(item, 'status').as((status) => `tray-item ${status === AstalTray.Status.NEEDS_ATTENTION ? 'attention' : ''}`)}
      tooltipMarkup={bind(item, 'tooltipMarkup')}
      onClick={(self, event) => {
        if (event.button === Gdk.BUTTON_SECONDARY) {
          item.about_to_show();
          menu?.popup_at_widget(self, Gdk.Gravity.NORTH, Gdk.Gravity.SOUTH, null);
          return;
        }

        if (event.button === Gdk.BUTTON_MIDDLE) {
          item.secondary_activate(0, 0);
          return;
        }

        if (item.isMenu && menu) {
          item.about_to_show();
          menu.popup_at_widget(self, Gdk.Gravity.NORTH, Gdk.Gravity.SOUTH, null);
          return;
        }

        item.activate(0, 0);
      }}
      onDestroy={() => {
        menu?.destroy();
        menuBinding.drop();
      }}
    >
      <icon className="tray-icon" gicon={bind(item, 'gicon')} />
    </button>
  );
};

const Tray = () => (
  <box className="tray">
    {bind(tray, 'items').as((items) => items
      .filter((item) => item.id !== null)
      .sort((a, b) => (a.title ?? a.id ?? '').localeCompare(b.title ?? b.id ?? ''))
      .map((item) => <TrayItem item={item} />))}
  </box>
);

const coordsFromTuple = (value: unknown): [number, number] | null => {
  if (!Array.isArray(value)) {
    return null;
  }

  if (typeof value[0] === 'boolean') {
    return value[0] ? [value[1], value[2]] : null;
  }

  return [value[0], value[1]];
};

const dropdownRightForWidget = (widget: Gtk.Widget) => {
  const allocation = widget.get_allocation();
  const toplevel = widget.get_toplevel() as Gtk.Widget;
  const toplevelAllocation = toplevel.get_allocation();
  const translated = coordsFromTuple(widget.translate_coordinates(toplevel, 0, 0));

  if (!translated || !Number.isFinite(translated[0]) || !Number.isFinite(allocation.width) || !Number.isFinite(toplevelAllocation.width) || toplevelAllocation.width <= 0) {
    return 10;
  }

  const buttonRight = translated[0] + allocation.width;
  const marginRight = toplevelAllocation.width - buttonRight;

  if (!Number.isFinite(marginRight)) {
    return 10;
  }

  return Math.min(Math.max(10, marginRight), Math.max(10, toplevelAllocation.width - 10));
};

const toggleAudio = (monitor: number, widget: Gtk.Widget) => {
  closeRollnroll();
  openBluetoothPosition.set(null);
  openMediaPosition.set(null);
  openNetworkPosition.set(null);
  const current = openAudioPosition.get();

  openAudioPosition.set(current?.monitor === monitor ? null : {
    monitor,
    marginRight: dropdownRightForWidget(widget),
  });
};

const toggleBluetooth = (monitor: number, widget: Gtk.Widget) => {
  closeRollnroll();
  openAudioPosition.set(null);
  openMediaPosition.set(null);
  openNetworkPosition.set(null);
  const current = openBluetoothPosition.get();

  openBluetoothPosition.set(current?.monitor === monitor ? null : {
    monitor,
    marginRight: dropdownRightForWidget(widget),
  });
};

const toggleMedia = (monitor: number, widget: Gtk.Widget) => {
  closeRollnroll();
  openAudioPosition.set(null);
  openBluetoothPosition.set(null);
  openNetworkPosition.set(null);
  const current = openMediaPosition.get();

  openMediaPosition.set(current?.monitor === monitor ? null : {
    monitor,
    marginRight: dropdownRightForWidget(widget),
  });
};

const toggleNetwork = (monitor: number, widget: Gtk.Widget) => {
  closeRollnroll();
  openAudioPosition.set(null);
  openBluetoothPosition.set(null);
  openMediaPosition.set(null);
  const current = openNetworkPosition.get();

  openNetworkPosition.set(current?.monitor === monitor ? null : {
    monitor,
    marginRight: dropdownRightForWidget(widget),
  });
};

const closeDropdowns = () => {
  openAudioPosition.set(null);
  openBluetoothPosition.set(null);
  openMediaPosition.set(null);
  openNetworkPosition.set(null);
  closeRollnroll();
};

const closeLocalDropdowns = () => {
  openAudioPosition.set(null);
  openBluetoothPosition.set(null);
  openMediaPosition.set(null);
  openNetworkPosition.set(null);
};

const openRollnrollMonitorValue = () => {
  const value = openRollnrollMonitor.get();
  return typeof value === 'number' ? value : value?.monitor ?? null;
};

const volumeIcon = (volume: number, mute: boolean) => {
  if (mute || volume === 0) {
    return '󰝟';
  }

  if (volume < 0.34) {
    return '󰕿';
  }

  if (volume < 0.67) {
    return '󰖀';
  }

  return '󰕾';
};

const endpointName = (node: AstalWp.Node) => node.description ?? node.name ?? 'Unknown device';

const profileDescription = (profile: AstalWp.Profile) => profile.get_description() ?? profile.description ?? String(profile.index);

const workspaceButtonClass = (workspace: AstalHyprland.Workspace, activeId: number | undefined, clientCount: number) => {
  const active = workspace.id === activeId;
  const occupied = clientCount > 0;
  const fullscreen = workspace?.hasFullscreen ?? false;

  return `workspace-button ${active ? 'active' : ''} ${occupied ? 'occupied' : ''} ${fullscreen ? 'fullscreen' : ''}`;
};

const hyprMonitorForGdk = (monitor: number) => {
  const gdkMonitor = Gdk.Display.get_default()?.get_monitor(monitor);
  const geometry = gdkMonitor?.get_geometry();

  if (!geometry) {
    return hyprland.get_monitor(monitor);
  }

  return hyprland.monitors.find((item) => item.x === geometry.x && item.y === geometry.y) ?? hyprland.get_monitor(monitor);
};

const Workspaces = ({ monitor }: { monitor: number }) => {
  const hyprMonitor = hyprMonitorForGdk(monitor);

  return (
    <box className="workspaces">
      {Variable.derive(
        [bind(hyprland, 'workspaces'), bind(hyprland, 'clients'), bind(hyprMonitor, 'activeWorkspace')],
        (workspaces, clients, activeWorkspace) => {
          const monitorWorkspaces = workspaces.filter((workspace) => workspace.id > 0 && workspace.id <= 10 && workspace.monitor?.name === hyprMonitor.name);
          const visibleWorkspaces = activeWorkspace && !monitorWorkspaces.some((workspace) => workspace.id === activeWorkspace.id)
            ? [...monitorWorkspaces, activeWorkspace]
            : monitorWorkspaces;

          return visibleWorkspaces
          .map((workspace) => ({
            workspace,
            clientCount: clients.filter((client) => client.workspace?.id === workspace.id && client.monitor?.name === hyprMonitor.name).length,
          }))
          .filter(({ workspace, clientCount }) => clientCount > 0 || workspace.id === activeWorkspace?.id)
          .sort((a, b) => a.workspace.id - b.workspace.id)
          .map(({ workspace, clientCount }) => (
            <button className={workspaceButtonClass(workspace, activeWorkspace?.id, clientCount)} onClick={() => hyprland.dispatch('workspace', String(workspace.id))}>
              <label label={String(workspace.id)} />
            </button>
          ));
        },
      )()}
    </box>
  );
};

const SliderRow = ({
  node,
  icon,
  max = 1.5,
  title = true,
}: {
  node: AstalWp.Node;
  icon: string | ReturnType<typeof bind>;
  max?: number;
  title?: boolean;
}) => (
  <box className="audio-row" vertical>
    {title ? <label className="audio-row-title" halign={Gtk.Align.START} hexpand truncate label={bind(node, 'description').as(() => endpointName(node))} /> : <box />}
    <box className="audio-slider-line">
      <button
        className={bind(node, 'mute').as((mute) => `audio-icon-button ${mute ? 'muted' : ''}`)}
        onClick={() => node.set_mute(!node.mute)}
      >
        <label label={icon} />
      </button>
      <slider
        className="audio-slider"
        drawValue={false}
        hexpand
        min={0}
        max={max}
        value={bind(node, 'volume')}
        onDragged={({ value, dragging }) => {
          if (dragging) {
            node.set_volume(value);
            node.set_mute(false);
          }
        }}
      />
      <label className="audio-percent" label={bind(node, 'volume').as((volume) => `${Math.round(volume * 100)}%`)} />
    </box>
  </box>
);

const ClickCatcher = (monitor: number) => (
  <window
    application={App}
    name={`dropdown-click-catcher-${monitor}`}
    namespace="jbellavista-shell-click-catcher"
    className="click-catcher"
    monitor={monitor}
    layer={Astal.Layer.TOP}
    anchor={Astal.WindowAnchor.TOP | Astal.WindowAnchor.RIGHT | Astal.WindowAnchor.BOTTOM | Astal.WindowAnchor.LEFT}
    exclusivity={Astal.Exclusivity.IGNORE}
    visible={false}
    onButtonPressEvent={() => {
      closeDropdowns();
      return true;
    }}
    setup={(self) => {
      const update = () => {
        self.visible = openAudioPosition.get()?.monitor === monitor || openBluetoothPosition.get()?.monitor === monitor || openMediaPosition.get()?.monitor === monitor || openNetworkPosition.get()?.monitor === monitor || openRollnrollMonitorValue() === monitor;
      };

      openAudioPosition.subscribe(update);
      openBluetoothPosition.subscribe(update);
      openMediaPosition.subscribe(update);
      openNetworkPosition.subscribe(update);
      openRollnrollMonitor.subscribe(update);
    }}
  >
    <eventbox hexpand vexpand>
      <box hexpand vexpand />
    </eventbox>
  </window>
);

const DeviceButton = ({
  device,
  icon,
}: {
  device: AstalWp.Endpoint;
  icon: string;
}) => (
  <box className={bind(device, 'isDefault').as((isDefault) => `audio-device ${isDefault ? 'active' : ''}`)}>
    <box>
      <label className="audio-device-icon" label={icon} />
      <label className="audio-device-name" halign={Gtk.Align.START} hexpand truncate label={bind(device, 'description').as(() => endpointName(device))} />
      <label className="audio-device-default" label={bind(device, 'isDefault').as((isDefault) => (isDefault ? 'default' : ''))} />
    </box>
  </box>
);

const ProfileRow = ({ device }: { device: AstalWp.Endpoint }) => {
  const cardDevice = device.device;

  if (!cardDevice) {
    return <box />;
  }

  return (
    <box className="audio-profiles" visible={bind(cardDevice, 'profiles').as((profiles) => (profiles?.length ?? 0) > 1)}>
      <label className="audio-profile-label" label="Profile" />
      <scrollable className="audio-profile-scroll" hscroll={Gtk.PolicyType.AUTOMATIC} vscroll={Gtk.PolicyType.NEVER} widthRequest={320} hexpand>
        <box>
          {bind(cardDevice, 'profiles').as((profiles) => {
            if (!profiles || profiles.length <= 1) {
              return <box />;
            }

            return profiles.map((profile) => (
              <button
                className={bind(cardDevice, 'activeProfileId').as((activeId) => `audio-profile ${activeId === profile.index ? 'active' : ''}`)}
                tooltipText={profileDescription(profile)}
                onClick={() => cardDevice.set_active_profile_id(profile.index)}
              >
                <label label={profileDescription(profile)} />
              </button>
            ));
          })}
        </box>
      </scrollable>
    </box>
  );
};

const DeviceCard = ({
  device,
  icon,
  sliderIcon,
  max = 1.5,
}: {
  device: AstalWp.Endpoint;
  icon: string;
  sliderIcon: string | ReturnType<typeof bind>;
  max?: number;
}) => (
  <eventbox
    className={bind(device, 'isDefault').as((isDefault) => `audio-card ${isDefault ? 'active' : ''}`)}
    onButtonPressEvent={() => {
      device.set_is_default(true);
      return false;
    }}
  >
  <box className="audio-card-content" vertical>
    <DeviceButton device={device} icon={icon} />
    <SliderRow node={device} icon={sliderIcon} max={max} title={false} />
    <ProfileRow device={device} />
  </box>
  </eventbox>
);

const networkStateLabel = (state: AstalNetwork.State) => {
  switch (state) {
    case AstalNetwork.State.CONNECTED_GLOBAL:
      return 'online';
    case AstalNetwork.State.CONNECTING:
      return 'connecting';
    case AstalNetwork.State.DISCONNECTING:
      return 'disconnecting';
    case AstalNetwork.State.DISCONNECTED:
      return 'offline';
    default:
      return 'limited';
  }
};

const deviceStateLabel = (state: AstalNetwork.DeviceState | undefined) => {
  switch (state) {
    case AstalNetwork.DeviceState.ACTIVATED:
      return 'Activated';
    case AstalNetwork.DeviceState.DISCONNECTED:
      return 'Disconnected';
    case AstalNetwork.DeviceState.UNAVAILABLE:
      return 'Unavailable';
    case AstalNetwork.DeviceState.DEACTIVATING:
      return 'Disconnecting';
    case AstalNetwork.DeviceState.PREPARE:
    case AstalNetwork.DeviceState.CONFIG:
    case AstalNetwork.DeviceState.IP_CONFIG:
    case AstalNetwork.DeviceState.IP_CHECK:
      return 'Connecting';
    case AstalNetwork.DeviceState.NEED_AUTH:
      return 'Needs password';
    case AstalNetwork.DeviceState.FAILED:
      return 'Failed';
    default:
      return 'Unknown';
  }
};

const networkLabel = () => {
  if (network.primary === AstalNetwork.Primary.WIRED && network.wired) {
    return network.wired.state === AstalNetwork.DeviceState.ACTIVATED ? '󰈀' : '󰈂';
  }

  if (network.wifi) {
    if (!network.wifi.enabled) {
      return '󰤮';
    }

    if (network.state === AstalNetwork.State.CONNECTED_GLOBAL) {
      return '󰤨';
    }

    if (network.state === AstalNetwork.State.CONNECTING || network.state === AstalNetwork.State.DISCONNECTING) {
      return '󰤩';
    }

    return '󰤭';
  }

  return '󰤭';
};

const accessPointSsid = (accessPoint: AstalNetwork.AccessPoint) => accessPoint.ssid?.trim() || accessPoint.bssid;

const isActiveAccessPoint = (accessPoint: AstalNetwork.AccessPoint, activeAccessPoint: AstalNetwork.AccessPoint | null | undefined) => (
  accessPoint.bssid === activeAccessPoint?.bssid || (!!accessPoint.ssid && accessPoint.ssid === activeAccessPoint?.ssid)
);

const sortedAccessPoints = (accessPoints: AstalNetwork.AccessPoint[] | null | undefined, activeAccessPoint: AstalNetwork.AccessPoint | null | undefined, savedConnections: Map<string, string>) => {
  const bySsid = new Map<string, AstalNetwork.AccessPoint>();

  for (const accessPoint of accessPoints ?? []) {
    const ssid = accessPointSsid(accessPoint);
    const existing = bySsid.get(ssid);

    if (!existing || isActiveAccessPoint(accessPoint, activeAccessPoint) || (!isActiveAccessPoint(existing, activeAccessPoint) && accessPoint.strength > existing.strength)) {
      bySsid.set(ssid, accessPoint);
    }
  }

  return [...bySsid.values()].sort((left, right) => {
    if (isActiveAccessPoint(left, activeAccessPoint) !== isActiveAccessPoint(right, activeAccessPoint)) {
      return isActiveAccessPoint(left, activeAccessPoint) ? -1 : 1;
    }

    if (savedConnections.has(accessPointSsid(left)) !== savedConnections.has(accessPointSsid(right))) {
      return savedConnections.has(accessPointSsid(left)) ? -1 : 1;
    }

    return right.strength - left.strength;
  });
};

const activateAccessPoint = (accessPoint: AstalNetwork.AccessPoint, savedConnections: Map<string, string>) => {
  if (isActiveAccessPoint(accessPoint, network.wifi.activeAccessPoint)) {
    network.wifi.deactivate_connection((_, result) => {
      try {
        network.wifi.deactivate_connection_finish(result);
      } catch (error) {
        console.error(`Failed to disconnect Wi-Fi network ${accessPoint.ssid ?? accessPoint.bssid}: ${error}`);
      }
    });
    return;
  }

  if (accessPoint.requiresPassword && !savedConnections.has(accessPointSsid(accessPoint))) {
    stagedWifiBssid.set(accessPoint.bssid);
    stagedWifiPassword.set('');
    wifiConnectionError.set('');
    return;
  }

  wifiConnectingBssid.set(accessPoint.bssid);
  accessPoint.activate(null, (_, result) => {
    try {
      accessPoint.activate_finish(result);
      wifiConnectingBssid.set(null);
    } catch (error) {
      wifiConnectingBssid.set(null);
      console.error(`Failed to activate network ${accessPoint.ssid ?? accessPoint.bssid}: ${error}`);
    }
  });
};

const forgetSavedWifi = (ssid: string, uuid: string) => {
  const connection = networkManagerClient.get_connection_by_uuid(uuid);

  if (connection === null) {
    const connections = new Map(savedWifiConnections.get());
    connections.delete(ssid);
    savedWifiConnections.set(connections);
    return;
  }

  connection.delete_async(null, (_, result) => {
    try {
      connection.delete_finish(result);
      const connections = new Map(savedWifiConnections.get());
      connections.delete(ssid);
      savedWifiConnections.set(connections);
    } catch (error) {
      console.error(`Failed to forget Wi-Fi network ${ssid}: ${error}`);
    }
  });
};

const activateAccessPointWithPassword = (accessPoint: AstalNetwork.AccessPoint, password: string) => {
  if (password.length === 0) {
    wifiConnectionError.set('Password required');
    return;
  }

  wifiConnectingBssid.set(accessPoint.bssid);
  wifiConnectionError.set('');

  accessPoint.activate(password, (_, result) => {
    try {
      accessPoint.activate_finish(result);
      stagedWifiBssid.set(null);
      stagedWifiPassword.set('');
      wifiConnectionError.set('');
    } catch (error) {
      wifiConnectionError.set('Connection failed');
      console.error(`Failed to activate secure network ${accessPoint.ssid ?? accessPoint.bssid}: ${error}`);
    } finally {
      wifiConnectingBssid.set(null);
    }
  });
};

const scanWifi = (wifi: AstalNetwork.Wifi) => {
  networkScanActive.set(true);
  wifi.scan();

  GLib.timeout_add(GLib.PRIORITY_DEFAULT, 1800, () => {
    networkScanActive.set(false);
    return GLib.SOURCE_REMOVE;
  });
};

const AccessPointRow = ({ accessPoint, activeAccessPoint, stagedBssid, connectingBssid, savedConnections }: {
  accessPoint: AstalNetwork.AccessPoint;
  activeAccessPoint: AstalNetwork.AccessPoint | null;
  stagedBssid: string | null;
  connectingBssid: string | null;
  savedConnections: Map<string, string>;
}) => {
  const ssid = accessPointSsid(accessPoint);
  const active = isActiveAccessPoint(accessPoint, activeAccessPoint);
  const savedConnectionUuid = savedConnections.get(ssid);
  const known = savedConnectionUuid !== undefined;
  const staged = stagedBssid === accessPoint.bssid;
  const connecting = connectingBssid === accessPoint.bssid;

  if (staged) {
    return (
      <box className="network-ap staged" vertical>
        <box>
          <label className="network-ap-icon" label="󰌾" />
          <box vertical hexpand>
            <label className="network-ap-name" halign={Gtk.Align.START} truncate label={accessPoint.ssid ?? 'Hidden network'} />
            <label className="network-ap-meta" halign={Gtk.Align.START} label={connecting ? 'Connecting...' : 'Password required'} />
          </box>
        </box>
        <box className="network-password-row">
          <entry
            className="network-password-entry"
            hexpand
            visibility={false}
            placeholderText="Password"
            sensitive={!connecting}
            setup={(self) => setTimeout(() => self.grab_focus(), 80)}
            onChanged={(self) => stagedWifiPassword.set(self.text)}
            onKeyPressEvent={(self, event) => {
              if (event.get_keyval()[1] === Gdk.KEY_Return) {
                activateAccessPointWithPassword(accessPoint, self.text);
                return true;
              }

              return false;
            }}
          />
          <button className="network-password-action" sensitive={!connecting} onClick={() => activateAccessPointWithPassword(accessPoint, stagedWifiPassword.get())}>
            <label label="Connect" />
          </button>
          <button className="network-password-cancel" sensitive={!connecting} onClick={() => {
            stagedWifiBssid.set(null);
            stagedWifiPassword.set('');
            wifiConnectionError.set('');
          }}>
            <label label="Cancel" />
          </button>
        </box>
        <label className="network-error" halign={Gtk.Align.START} visible={bind(wifiConnectionError).as((error) => error.length > 0)} label={bind(wifiConnectionError)} />
      </box>
    );
  }

  return (
    <box className="network-ap-row">
      <button className={`network-ap ${active ? 'active' : ''} ${known ? 'known' : ''}`} tooltipText={accessPoint.bssid} hexpand onClick={() => activateAccessPoint(accessPoint, savedConnections)}>
        <box>
          <label className="network-ap-icon" label={accessPoint.requiresPassword && !active ? '󰌾' : '󰤨'} />
          <box vertical hexpand>
            <label className="network-ap-name" halign={Gtk.Align.START} truncate label={accessPoint.ssid ?? 'Hidden network'} />
            <label className="network-ap-meta" halign={Gtk.Align.START} label={`${accessPoint.strength}%${active ? ' · click to disconnect' : connecting ? ' · connecting' : known ? ' · saved' : accessPoint.requiresPassword ? ' · password required' : ''}`} />
          </box>
        </box>
      </button>
      {known ? (
        <button className="network-forget" tooltipText="Forget network" onClick={() => forgetSavedWifi(ssid, savedConnectionUuid)}>
          <label label="Forget" />
        </button>
      ) : <box />}
    </box>
  );
};

const bluetoothLabel = (isPowered: boolean, devices: AstalBluetooth.Device[]) => {
  if (!bluetooth.adapter) {
    return '󰂲 unavailable';
  }

  if (!isPowered) {
    return '󰂲 off';
  }

  const connected = devices.filter((device) => device.connected);
  return connected.length > 0 ? `󰂱 ${connected.length}` : '󰂯 on';
};

const bluetoothDevices = (devices: AstalBluetooth.Device[] | null | undefined) => (devices ?? [])
  .filter((device) => device.name !== null || device.alias !== null)
  .sort((left, right) => {
    if (left.connected !== right.connected) {
      return left.connected ? -1 : 1;
    }

    if (left.paired !== right.paired) {
      return left.paired ? -1 : 1;
    }

  return (left.alias ?? left.name ?? '').localeCompare(right.alias ?? right.name ?? '');
  });

const MediaControlButton = ({ label, sensitive = true, onClick }: { label: string | ReturnType<typeof bind>; sensitive?: boolean | ReturnType<typeof bind>; onClick: () => void }) => (
  <button className="media-control" sensitive={sensitive} onClick={onClick}>
    <label label={label} />
  </button>
);

const MediaButton = ({ monitor }: { monitor: number }) => (
  <button className="widget media-bar-button" onClick={(self) => toggleMedia(monitor, self)}>
    <box>
      <box
        className="media-bar-cover"
        visible={bind(mediaButtonHasCover)}
        css={bind(mediaButtonCoverCss)}
      />
      <label className="media-bar-label" widthRequest={160} truncate label={bind(mediaButtonLabel)} />
    </box>
  </button>
);

const MediaDropdown = (monitor: number) => (
  <window
    application={App}
    name={`media-dropdown-${monitor}`}
    namespace="jbellavista-shell-media"
    className="media-dropdown"
    monitor={monitor}
    layer={Astal.Layer.TOP}
    anchor={Astal.WindowAnchor.TOP | Astal.WindowAnchor.RIGHT}
    exclusivity={Astal.Exclusivity.IGNORE}
    keymode={Astal.Keymode.ON_DEMAND}
    marginTop={dropdownMarginTop}
    marginRight={10}
    onKeyPressEvent={(_, event) => {
      if (event.get_keyval()[1] === Gdk.KEY_Escape) {
        openMediaPosition.set(null);
      }
    }}
    visible={false}
    setup={(self) => {
      openMediaPosition.subscribe((position) => {
        self.marginRight = position?.marginRight ?? 10;
        self.visible = position?.monitor === monitor;
        if (self.visible) {
          self.grab_focus();
        }
      });
    }}
  >
    <box className="dropdown-shell media-menu" vertical>
      <box className="media-menu-header">
        <label className="media-menu-title" halign={Gtk.Align.START} hexpand label="Media" />
        <label className="media-menu-summary" label={bind(activeMediaPlayer).as((player) => player?.identity ?? 'none')} />
      </box>

      {bind(activeMediaPlayer).as((player) => {
        if (!player) {
          return <label className="media-empty" halign={Gtk.Align.START} label="No active media players" />;
        }

        return (
          <box className="media-now">
            <box className="media-cover" css={bind(player, 'coverArt').as((coverArt) => coverArt ? `background-image: url("${coverArt}");` : '')} />
            <box className="media-now-content" vertical hexpand>
              <label className="media-now-title" halign={Gtk.Align.START} truncate label={bind(player, 'title').as((title) => title || 'Unknown title')} />
              <label className="media-now-subtitle" halign={Gtk.Align.START} truncate label={bind(player, 'artist').as((artist) => artist || player.identity || player.busName)} />
              <box className="media-controls">
                <MediaControlButton label="󰒮" sensitive={bind(player, 'canGoPrevious')} onClick={() => player.previous()} />
                <MediaControlButton label={bind(player, 'playbackStatus').as((status) => status === AstalMpris.PlaybackStatus.PLAYING ? '󰏤' : '󰐊')} sensitive={bind(player, 'canControl')} onClick={() => player.play_pause()} />
                <MediaControlButton label="󰒭" sensitive={bind(player, 'canGoNext')} onClick={() => player.next()} />
              </box>
            </box>
          </box>
        );
      })}
    </box>
  </window>
);

const toggleBluetoothDiscovery = () => {
  if (!bluetooth.adapter) {
    return;
  }

  try {
    if (bluetooth.adapter.discovering) {
      bluetooth.adapter.stop_discovery();
    } else {
      bluetooth.adapter.start_discovery();
    }
  } catch (error) {
    console.error(`Failed to toggle Bluetooth discovery: ${error}`);
  }
};

const toggleBluetoothDevice = (device: AstalBluetooth.Device) => {
  if (device.connected) {
    device.disconnect_device((_, result) => {
      try {
        device.disconnect_device_finish(result);
      } catch (error) {
        console.error(`Failed to disconnect Bluetooth device ${device.alias ?? device.name}: ${error}`);
      }
    });
    return;
  }

  device.connect_device((_, result) => {
    try {
      device.connect_device_finish(result);
    } catch (error) {
      console.error(`Failed to connect Bluetooth device ${device.alias ?? device.name}: ${error}`);
    }
  });
};

const BluetoothDeviceRow = ({ device }: { device: AstalBluetooth.Device }) => (
  <button className={bind(device, 'connected').as((connected) => `bluetooth-device ${connected ? 'active' : ''}`)} onClick={() => toggleBluetoothDevice(device)}>
    <box>
      <label className="bluetooth-device-icon" label={bind(device, 'connected').as((connected) => (connected ? '󰂱' : '󰂯'))} />
      <box vertical hexpand>
        <label className="bluetooth-device-name" halign={Gtk.Align.START} truncate label={bind(device, 'alias').as((alias) => alias ?? device.name ?? device.address)} />
        <label
          className="bluetooth-device-meta"
          halign={Gtk.Align.START}
          label={Variable.derive(
            [bind(device, 'connected'), bind(device, 'paired'), bind(device, 'batteryPercentage')],
            (connected, paired, batteryPercentage) => `${connected ? 'Connected' : paired ? 'Paired' : 'Available'}${batteryPercentage >= 0 ? ` · ${Math.round(batteryPercentage * 100)}%` : ''}`,
          )()}
        />
      </box>
    </box>
  </button>
);

const BluetoothDropdown = (monitor: number) => (
  <window
    application={App}
    name={`bluetooth-dropdown-${monitor}`}
    namespace="jbellavista-shell-bluetooth"
    className="bluetooth-dropdown"
    monitor={monitor}
    layer={Astal.Layer.TOP}
    anchor={Astal.WindowAnchor.TOP | Astal.WindowAnchor.RIGHT}
    exclusivity={Astal.Exclusivity.IGNORE}
    keymode={Astal.Keymode.ON_DEMAND}
    marginTop={dropdownMarginTop}
    marginRight={10}
    onKeyPressEvent={(_, event) => {
      if (event.get_keyval()[1] === Gdk.KEY_Escape) {
        openBluetoothPosition.set(null);
      }
    }}
    visible={false}
    setup={(self) => {
      openBluetoothPosition.subscribe((position) => {
        self.marginRight = position?.marginRight ?? 10;
        self.visible = position?.monitor === monitor;
        if (self.visible) {
          self.grab_focus();
        }
      });
    }}
  >
    <box className="dropdown-shell bluetooth-menu" vertical>
      <box className="bluetooth-menu-header">
        <label className="bluetooth-menu-title" halign={Gtk.Align.START} hexpand label="Bluetooth" />
        <label className="bluetooth-menu-summary" label={bind(bluetooth, 'isPowered').as((isPowered) => (isPowered ? 'on' : 'off'))} />
      </box>

      {bind(bluetooth, 'adapter').as((adapter) => {
        if (!adapter) {
          return <label className="bluetooth-empty" halign={Gtk.Align.START} label="No Bluetooth adapter" />;
        }

        return (
          <box className="bluetooth-section" vertical>
            <box className="bluetooth-section-heading">
              <label className="bluetooth-section-title" halign={Gtk.Align.START} hexpand label={adapter.alias ?? adapter.name ?? 'Adapter'} />
              <switch
                className="bluetooth-switch"
                active={bind(adapter, 'powered')}
                setup={(self) => {
                  self.connect('notify::active', () => adapter.set_powered(self.active));
                }}
              />
              <button className="bluetooth-refresh" tooltipText="Discovery" onClick={toggleBluetoothDiscovery}>
                <label label={bind(adapter, 'discovering').as((discovering) => (discovering ? '󰑓' : '󰑐'))} />
              </button>
            </box>

            <scrollable className="bluetooth-device-scroll" hscroll={Gtk.PolicyType.NEVER} vscroll={Gtk.PolicyType.AUTOMATIC} heightRequest={260}>
              <box vertical>
                {bind(bluetooth, 'devices').as((devices) => {
                  const sorted = bluetoothDevices(devices);

                  if (!adapter.powered) {
                    return <label className="bluetooth-empty" halign={Gtk.Align.START} label="Bluetooth is off" />;
                  }

                  if (sorted.length === 0) {
                    return <label className="bluetooth-empty" halign={Gtk.Align.START} label="No devices found" />;
                  }

                  return sorted.map((device) => <BluetoothDeviceRow device={device} />);
                })}
              </box>
            </scrollable>
          </box>
        );
      })}
    </box>
  </window>
);

const NetworkDropdown = (monitor: number) => (
  <window
    application={App}
    name={`network-dropdown-${monitor}`}
    namespace="jbellavista-shell-network"
    className="network-dropdown"
    monitor={monitor}
    layer={Astal.Layer.TOP}
    anchor={Astal.WindowAnchor.TOP | Astal.WindowAnchor.RIGHT}
    exclusivity={Astal.Exclusivity.IGNORE}
    keymode={Astal.Keymode.ON_DEMAND}
    marginTop={dropdownMarginTop}
    marginRight={10}
    onKeyPressEvent={(_, event) => {
      if (event.get_keyval()[1] === Gdk.KEY_Escape) {
        openNetworkPosition.set(null);
      }
    }}
    visible={false}
    setup={(self) => {
      openNetworkPosition.subscribe((position) => {
        self.marginRight = position?.marginRight ?? 10;
        self.visible = position?.monitor === monitor;
        if (self.visible) {
          self.grab_focus();
        }
      });
    }}
  >
    <box className="dropdown-shell network-menu" vertical>
      <box className="network-menu-header">
        <label className="network-menu-title" halign={Gtk.Align.START} hexpand label="Network" />
        <label className="network-menu-summary" label={bind(network, 'state').as((state) => networkStateLabel(state))} />
      </box>

      {bind(network, 'wired').as((wired) => {
        if (!wired) {
          return <box />;
        }

        return (
          <box className="network-section" vertical>
            <label className="network-section-title" halign={Gtk.Align.START} label="Ethernet" />
            <box className={bind(wired, 'state').as((state) => `network-card ${state === AstalNetwork.DeviceState.ACTIVATED ? 'active' : ''}`)}>
              <label className="network-card-icon" label="󰈀" />
              <box vertical hexpand>
                <label className="network-card-title" halign={Gtk.Align.START} label="Wired" />
                <label className="network-card-subtitle" halign={Gtk.Align.START} label={bind(wired, 'state').as((state) => `${deviceStateLabel(state)} · ${wired.speed} Mbps`)} />
              </box>
            </box>
          </box>
        );
      })}

      {bind(network, 'wifi').as((wifi) => {
        if (!wifi) {
          return <label className="network-empty" halign={Gtk.Align.START} label="No Wi-Fi device" />;
        }

        return (
          <box className="network-section" vertical>
            <box className="network-section-heading">
              <label className="network-section-title" halign={Gtk.Align.START} hexpand label="Wi-Fi" />
              <switch
                className="network-switch"
                active={bind(wifi, 'enabled')}
                setup={(self) => {
                  self.connect('notify::active', () => wifi.set_enabled(self.active));
                }}
              />
              <button
                className={Variable.derive([bind(wifi, 'scanning'), bind(networkScanActive)], (scanning, scanActive) => `network-refresh ${scanning || scanActive ? 'active' : ''}`)()}
                tooltipText="Scan"
                onClick={() => scanWifi(wifi)}
              >
                <label label={Variable.derive([bind(wifi, 'scanning'), bind(networkScanActive)], (scanning, scanActive) => (scanning || scanActive ? '󰑓' : '󰑐'))()} />
              </button>
            </box>

            <box className={bind(wifi, 'state').as((state) => `network-card ${state === AstalNetwork.DeviceState.ACTIVATED ? 'active' : ''}`)}>
              <label className="network-card-icon" label="󰤨" />
              <box vertical hexpand>
                <label className="network-card-title" halign={Gtk.Align.START} truncate label={bind(wifi, 'ssid').as((ssid) => ssid || 'Not connected')} />
                <label className="network-card-subtitle" halign={Gtk.Align.START} label={bind(wifi, 'state').as((state) => `${deviceStateLabel(state)} · ${wifi.strength}%`)} />
              </box>
            </box>

            <scrollable className="network-ap-scroll" hscroll={Gtk.PolicyType.NEVER} vscroll={Gtk.PolicyType.AUTOMATIC} heightRequest={260}>
              <box vertical>
                {Variable.derive([bind(wifi, 'accessPoints'), bind(wifi, 'activeAccessPoint'), bind(stagedWifiBssid), bind(wifiConnectingBssid), bind(savedWifiConnections)], (accessPoints, activeAccessPoint, stagedBssid, connectingBssid, savedConnections) => {
                  const sorted = sortedAccessPoints(accessPoints, activeAccessPoint, savedConnections);

                  if (!wifi.enabled) {
                    return <label className="network-empty" halign={Gtk.Align.START} label="Wi-Fi is off" />;
                  }

                  if (sorted.length === 0) {
                    return <label className="network-empty" halign={Gtk.Align.START} label="No networks found" />;
                  }

                  return sorted.map((accessPoint) => <AccessPointRow accessPoint={accessPoint} activeAccessPoint={activeAccessPoint} stagedBssid={stagedBssid} connectingBssid={connectingBssid} savedConnections={savedConnections} />);
                })()}
              </box>
            </scrollable>
          </box>
        );
      })}
    </box>
  </window>
);

const AudioDropdown = (monitor: number) => (
  <window
    application={App}
    name={`audio-dropdown-${monitor}`}
    namespace="jbellavista-shell-audio"
    className="audio-dropdown"
    monitor={monitor}
    layer={Astal.Layer.TOP}
    anchor={Astal.WindowAnchor.TOP | Astal.WindowAnchor.RIGHT}
    exclusivity={Astal.Exclusivity.IGNORE}
    keymode={Astal.Keymode.ON_DEMAND}
    marginTop={dropdownMarginTop}
    marginRight={10}
    onKeyPressEvent={(_, event) => {
      if (event.get_keyval()[1] === Gdk.KEY_Escape) {
        openAudioPosition.set(null);
      }
    }}
    visible={false}
    setup={(self) => {
      openAudioPosition.subscribe((position) => {
        self.marginRight = position?.marginRight ?? 10;
        self.visible = position?.monitor === monitor;
        if (self.visible) {
          self.grab_focus();
        }
      });
    }}
  >
    <box className="dropdown-shell audio-menu" vertical>
      <box className="audio-menu-header">
        <label className="audio-menu-title" halign={Gtk.Align.START} hexpand label="Sound" />
        <label className="audio-menu-summary" label={Variable.derive(
          [bind(audio.defaultSpeaker, 'volume'), bind(audio.defaultSpeaker, 'mute')],
          (volume, mute) => `${volumeIcon(volume, mute)} ${Math.round(volume * 100)}%`,
        )()} />
      </box>

      <box className="audio-section" vertical>
        <label className="audio-section-title" halign={Gtk.Align.START} label={bind(audio, 'speakers').as((devices) => `Outputs (${devices?.length ?? 0})`)} />
        <box vertical>
          {bind(audio, 'speakers').as((devices) => {
            if (!devices || devices.length === 0) {
              return <label className="audio-empty" halign={Gtk.Align.START} label="No output devices" />;
            }

            return devices
              .slice()
              .sort((a, b) => endpointName(a).localeCompare(endpointName(b)))
              .map((device) => <DeviceCard
                device={device}
                icon="󰓃"
                sliderIcon={Variable.derive(
                  [bind(device, 'volume'), bind(device, 'mute')],
                  (volume, mute) => volumeIcon(volume, mute),
                )()}
              />);
          })}
        </box>
      </box>

      <box className="audio-section" vertical>
        <label className="audio-section-title" halign={Gtk.Align.START} label={bind(audio, 'microphones').as((devices) => `Inputs (${devices?.length ?? 0})`)} />
        <box vertical>
          {bind(audio, 'microphones').as((devices) => {
            if (!devices || devices.length === 0) {
              return <label className="audio-empty" halign={Gtk.Align.START} label="No input devices" />;
            }

            return devices.map((device) => <DeviceCard device={device} icon="󰍬" sliderIcon="󰍬" max={1} />);
          })}
        </box>
      </box>

      <box className="audio-section" vertical>
        <label className="audio-section-title" halign={Gtk.Align.START} label={bind(audio, 'streams').as((streams) => `Playback Streams (${streams?.length ?? 0})`)} />
        <box vertical>
          {bind(audio, 'streams').as((streams) => {
            if (!streams || streams.length === 0) {
              return <label className="audio-empty" halign={Gtk.Align.START} label="No active playback streams" />;
            }

            return streams.map((stream) => <SliderRow node={stream} icon="󰎆" />);
          })}
        </box>
      </box>
    </box>
  </window>
);

const Bar = (monitor: number) => (
  <window
    application={App}
    name={`jbellavista-shell-bar-${monitor}`}
    namespace="jbellavista-shell"
    className="shell-bar"
    monitor={monitor}
    layer={Astal.Layer.TOP}
    anchor={Astal.WindowAnchor.TOP | Astal.WindowAnchor.LEFT | Astal.WindowAnchor.RIGHT}
    exclusivity={Astal.Exclusivity.EXCLUSIVE}
    visible
  >
    <box className="bar-shell" hexpand>
      <centerbox
        hexpand
        startWidget={
          <box className="section left" halign={Gtk.Align.START} hexpand>
            <Workspaces monitor={monitor} />
          </box>
        }
        centerWidget={<box className="section center" />}
        endWidget={
          <box className="section right" halign={Gtk.Align.END}>
            <RollnrollButton monitor={monitor} getMarginRight={dropdownRightForWidget} closeOthers={closeLocalDropdowns} />
            <GroupGap />
            <MediaButton monitor={monitor} />
            <GroupGap />
            <ButtonWidget
              label={Variable.derive(
                [bind(audio.defaultSpeaker, 'volume'), bind(audio.defaultSpeaker, 'mute')],
                (volume, mute) => volumeIcon(volume, mute),
              )()}
              onClick={(self) => toggleAudio(monitor, self)}
            />
            <ButtonWidget
              label={Variable.derive(
                [bind(network, 'primary'), bind(network, 'state'), bind(network, 'connectivity')],
                networkLabel,
              )()}
              onClick={(self) => toggleNetwork(monitor, self)}
            />
            <ButtonWidget
              label={Variable.derive(
                [bind(bluetooth, 'isPowered'), bind(bluetooth, 'devices'), bind(bluetooth, 'isConnected')],
                bluetoothLabel,
              )()}
              onClick={(self) => toggleBluetooth(monitor, self)}
            />
            <GroupGap />
            <Widget label={bind(cpu)} />
            <Widget label={bind(ram).as((value) => `RAM ${value}`)} />
            <Widget
              visible={Variable.derive(
                [bind(battery, 'isBattery'), bind(battery, 'isPresent')],
                (isBattery, isPresent) => isBattery && isPresent,
              )()}
              label={Variable.derive(
                [bind(battery, 'percentage'), bind(battery, 'charging')],
                (percentage, charging) => `${charging ? '󰂄' : percentage < 0.18 ? '󰁺' : '󰁹'} ${Math.round(percentage * 100)}%`,
              )()}
            />
            <GroupGap />
            <Tray />
            <GroupGap />
            <Widget label={bind(clock).as((value) => value.format('%Y-%m-%d %H:%M') ?? '')} />
          </box>
        }
      />
    </box>
  </window>
);

let monitorCount = 0;

const monitorWindowNames = (monitor: number) => [
  `jbellavista-shell-bar-${monitor}`,
  `dropdown-click-catcher-${monitor}`,
  `rollnroll-dropdown-${monitor}`,
  `bluetooth-dropdown-${monitor}`,
  `media-dropdown-${monitor}`,
  `network-dropdown-${monitor}`,
  `audio-dropdown-${monitor}`,
];

const destroyMonitorWindows = (monitor: number) => {
  monitorWindowNames(monitor).forEach((name) => App.get_window(name)?.destroy());
};

const createMonitorWindows = (monitor: number) => {
  Bar(monitor);
  ClickCatcher(monitor);
  RollnrollDropdown(monitor, dropdownMarginTop);
  BluetoothDropdown(monitor);
  MediaDropdown(monitor);
  NetworkDropdown(monitor);
  AudioDropdown(monitor);
};

const syncMonitorWindows = () => {
  const display = Gdk.Display.get_default();
  const nextMonitorCount = display?.get_n_monitors() ?? 1;

  if (nextMonitorCount === monitorCount) {
    return;
  }

  if (nextMonitorCount < monitorCount) {
    closeDropdowns();

    for (let monitor = nextMonitorCount; monitor < monitorCount; monitor += 1) {
      destroyMonitorWindows(monitor);
    }
  }

  for (let monitor = monitorCount; monitor < nextMonitorCount; monitor += 1) {
    createMonitorWindows(monitor);
  }

  monitorCount = nextMonitorCount;
};

App.start({
  instanceName: 'jbellavista-shell',
  main: () => {
    App.apply_css(`${style}\n${rollnrollCss}`, true);

    const display = Gdk.Display.get_default();

    syncMonitorWindows();
    display?.connect('monitor-added', syncMonitorWindows);
    display?.connect('monitor-removed', syncMonitorWindows);
  },
});
