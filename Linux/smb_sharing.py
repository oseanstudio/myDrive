"""Create read-only usershares on a verified Tailscale-bound Samba host."""

import ipaddress
import json
import re
import subprocess
from pathlib import Path


def query(*arguments):
    try:
        return subprocess.run(arguments, check=True, capture_output=True,
                              text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError) as error:
        raise RuntimeError(f"Could not verify secure SMB sharing with {arguments[0]}.") from error


def verify_listener():
    state = json.loads(query("tailscale", "status", "--json"))
    if state.get("BackendState") != "Running":
        raise RuntimeError("Connect this computer to Tailscale before sharing a folder.")
    assigned = set(state.get("TailscaleIPs") or [])
    interfaces = json.loads(query("ip", "-j", "address", "show", "dev", "tailscale0"))
    addresses = {info["local"] for interface in interfaces for info in interface.get("addr_info", [])}
    allowed = {ipaddress.ip_address(address) for address in assigned & addresses}
    listeners = set()
    for row in query("ss", "-H", "-lnt").splitlines():
        address, _, port = row.split()[3].rpartition(":")
        if port not in {"139", "445"}:
            continue
        try:
            ip = ipaddress.ip_address(address.strip("[]").split("%")[0])
        except ValueError:
            raise RuntimeError("Samba is listening on a wildcard address.") from None
        if ip in allowed and port == "445":
            listeners.add(ip)
        elif not ip.is_loopback:
            raise RuntimeError("Samba is reachable through another interface. Bind it to tailscale0 first.")
    if not listeners:
        raise RuntimeError("Start Samba on the Tailscale interface before sharing a folder.")
    serve = json.loads(query("tailscale", "serve", "status", "--json"))
    configurations = [serve, *(serve.get("Foreground") or {}).values()]
    if any(any((config.get("AllowFunnel") or {}).values()) for config in configurations):
        raise RuntimeError("Turn off public Tailscale Funnel on this computer before creating the share.")


def add_private_share(name, folder, account):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_ -]{0,63}", name):
        raise ValueError("Enter a share name of up to 64 letters, numbers, spaces, underscores or hyphens.")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+(?:\\[A-Za-z0-9_.-]+)?", account):
        raise ValueError("Enter an existing Samba account, optionally as DOMAIN\\user.")
    if account.casefold().split("\\")[-1] in {"guest", "nobody", "everyone"}:
        raise ValueError("Choose a personal Samba account for this share.")

    def parameter(name):
        return query("testparm", "-s", "--parameter-name=" + name).casefold()

    interfaces = set(parameter("interfaces").replace(",", " ").split())
    if "tailscale0" not in interfaces or interfaces - {"tailscale0", "lo", "127.0.0.1", "::1"} or (
        parameter("bind interfaces only") != "yes" or parameter("smb ports") != "445"
    ):
        raise RuntimeError("Samba must bind TCP 445 to tailscale0 and may also bind loopback.")
    if parameter("server smb encrypt") != "required" or parameter("server min protocol") not in {
        "smb3", "smb3_00", "smb3_02", "smb3_11"
    }:
        raise RuntimeError("Samba must require SMB 3 and SMB encryption before sharing.")
    if (parameter("map to guest") != "never" or parameter("usershare allow guests") != "no"
            or parameter("usershare owner only") != "yes" or parameter("usershare template share")):
        raise RuntimeError("Samba usershares must use owner-only folders, account authentication and the default share template.")

    installed = query("testparm", "-s")
    configured_names = re.findall(r"^\[([^\]]+)\]$", installed, flags=re.MULTILINE)
    user_names = query("net", "usershare", "list", "--long").splitlines()
    if any(existing.strip().casefold() == name.casefold() for existing in configured_names + user_names):
        raise RuntimeError("A Samba share already uses that name.")
    verify_listener()
    directory = Path(folder).resolve(strict=True)
    if not directory.is_dir():
        raise ValueError("Choose a folder to share.")
    query("net", "usershare", "add", name, str(directory), "Shared from myDrive", account + ":R", "guest_ok=n")
