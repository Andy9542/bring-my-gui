# bring-my-gui

**English** | [Русский](README.ru.md)

Forward a GUI from a headless Linux sandbox (Docker container or Docker Sandbox) to the host screen over VNC.

The sandbox has no display. The agent starts a virtual screen and gives you a connect string for your OS. Pixels stay on `localhost` → host.

## How to use

1. Install the skill or give your agent this link: https://github.com/Andy9542/bring-my-gui
2. Ask it to set everything up. For example: “open the app from the sandbox on my host”.

When the agent says it is ready, connect:

- macOS: Finder → ⌘K → `vnc://localhost:5900`
- Windows: TightVNC or TigerVNC Viewer → `localhost:5900`
- Linux: Remmina or `vncviewer localhost:5900`

Paste inside the session with **Ctrl+V**. Cmd+V from a Mac does not reach the sandbox.

## Security

The VNC password is a convenience lock. Publish the port only on localhost of your machine.
