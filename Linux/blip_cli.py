"""Headless entry point for the same local Blip bridge used by the GTK shell."""

import json
import subprocess
import sys
from uuid import UUID

from services import Blip


def run(arguments):
    bridge = Blip()
    if arguments == ["serve"]:
        try:
            bridge.monitor()
            while sys.stdin.buffer.read(4096):
                pass
        except KeyboardInterrupt:
            pass
        finally:
            bridge.stop()
        return
    if arguments == ["poll"]:
        result = bridge.request("poll")
    elif len(arguments) == 4 and arguments[:2] == ["accept", "--id"] and arguments[3] == "--execute":
        UUID(arguments[2])
        result = bridge.request("accept", arguments[2])
    elif len(arguments) >= 6 and arguments[:2] == ["send", "--peer"] and arguments[3:5] == ["--execute", "--"]:
        result = bridge.send(arguments[2], arguments[5:])
    else:
        raise ValueError("Invalid Blip command.")
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        run(sys.argv[1:])
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
