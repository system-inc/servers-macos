# Servers

A macOS menu bar app for managing local development servers.

## Features

- Start, stop, and restart servers from the menu bar
- Health checks with status indicators
- View server logs
- Auto-start servers on launch
- REST API for programmatic control

## Installation

```bash
./Build.sh
```

This builds the app and installs it to `/Applications/Servers.app`.

## Configuration

Settings are stored in `~/.servers/settings.json`:

```json
{
    "servers": [
        {
            "id": "my-server",
            "name": "My Server",
            "path": "~/Projects/my-app",
            "command": "npm run dev",
            "port": 3000,
            "healthCheckPath": "/",
            "https": false,
            "autoStart": true
        }
    ]
}
```

### Server Options

| Option            | Required | Description                                      |
| ----------------- | -------- | ------------------------------------------------ |
| `id`              | Yes      | Unique identifier                                |
| `name`            | Yes      | Display name in menu                             |
| `path`            | Yes      | Working directory (supports `~`)                 |
| `command`         | Yes      | Command to run                                   |
| `port`            | No       | Port for health checks and "Open in Browser"     |
| `healthCheckPath` | No       | Path for health checks (default: `/`)            |
| `https`           | No       | Use HTTPS for health checks (default: `false`)   |
| `autoStart`       | No       | Start automatically on launch (default: `false`) |

## API

The app runs a REST API on port 7378 (configurable via `apiPort` in settings).

```bash
# List all servers
curl http://localhost:7378/servers

# Get server status
curl http://localhost:7378/servers/my-server

# Start a server
curl -X POST http://localhost:7378/servers/my-server/start

# Stop a server
curl -X POST http://localhost:7378/servers/my-server/stop

# Restart a server
curl -X POST http://localhost:7378/servers/my-server/restart

# Get server logs
curl http://localhost:7378/servers/my-server/logs

# Reload settings
curl -X POST http://localhost:7378/reload-settings
```

## Icon Generation

To regenerate the app icon:

```bash
cd Icon
./GenerateIcons.sh
```

Uses `SfServerRack-Ultralight.png` as the source icon.
