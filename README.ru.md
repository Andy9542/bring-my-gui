# bring-my-gui

[English](README.md) | **Русский**

Проброс GUI из headless Linux-песочницы (Docker container или Docker Sandbox) на экран хоста через VNC.

В песочнице нет дисплея. Агент поднимает виртуальный экран и отдаёт строку подключения под вашу ОС. Картинка идёт только `localhost` → хост.

## Как пользоваться

1. Поставьте skill или дайте агенту ссылку: https://github.com/Andy9542/bring-my-gui
2. Попросите всё настроить — например: «открой приложение из песочницы на хосте».

Когда агент скажет, что готово, подключитесь:

- macOS: Finder → ⌘K → `vnc://localhost:5900`
- Windows: TightVNC или TigerVNC Viewer → `localhost:5900`
- Linux: Remmina или `vncviewer localhost:5900`

В сессии вставка — **Ctrl+V**. С Mac Cmd+V до песочницы не доходит.

## Безопасность

Пароль VNC — удобный замок. Порт только на localhost своей машины.
