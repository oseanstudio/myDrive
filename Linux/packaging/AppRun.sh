#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
export MYDRIVE_CORE="$root/usr/bin/mydrive-core"
export MYDRIVE_BLIP_CLASSES="$root/usr/lib/mydrive/blip-classes"
if [ "${1:-}" = "--core" ]; then
    shift
    exec "$MYDRIVE_CORE" "$@"
fi
if ! /usr/bin/python3 -c 'import gi; gi.require_version("Gtk", "4.0")' 2>/dev/null; then
    printf '%s\n' 'myDrive needs Python 3, PyGObject and GTK 4. Install python3-gi and gir1.2-gtk-4.0 on Debian or Ubuntu.' >&2
    exit 1
fi
exec /usr/bin/python3 -B "$root/usr/lib/mydrive/mydrive.py" "$@"
