"""Install a user-level Send with myDrive action for Files and Dolphin."""

import os
import shlex
import tempfile
from pathlib import Path


def install_actions(appimage, data_home):
    executable = Path(appimage)
    if not executable.is_absolute() or not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError("Launch myDrive from its AppImage to install file manager actions.")
    command = str(executable)
    if any(character in command for character in "\n\r="):
        raise ValueError("Move the AppImage to a path without line breaks or an equals sign, then try again.")
    # Desktop entries decode value escaping first and Exec quoting second.
    quoted = "".join(f"\\{character}" if character in '"$\\\x60' else character for character in command)
    quoted = quoted.replace("\\", "\\\\").replace("%", "%%")
    nautilus = f"""#!/bin/sh
case "${NAUTILUS_SCRIPT_CURRENT_URI:-}" in
    file://*) exec {shlex.quote(command)} --send-files "$@" ;;
esac
"""
    dolphin = f"""[Desktop Entry]
Type=Service
MimeType=application/octet-stream;inode/directory;
Actions=SendWithMyDrive;

[Desktop Action SendWithMyDrive]
Name=Send with myDrive
Exec="{quoted}" --send-files %F
"""
    actions = {
        data_home / "nautilus" / "scripts" / "Send with myDrive": nautilus,
        data_home / "kio" / "servicemenus" / "net.oseanstudio.myDrive.Send.desktop": dolphin,
    }
    for target, content in actions.items():
        target.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=target.parent, delete=False) as temp:
            path = Path(temp.name)
            try:
                temp.write(content)
                temp.close()
                path.chmod(0o700)
                path.replace(target)
            finally:
                path.unlink(missing_ok=True)
