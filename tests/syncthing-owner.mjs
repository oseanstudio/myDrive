import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { access, mkdtemp, mkdir, readFile, rm } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { createInterface } from "node:readline";
import { setTimeout as delay } from "node:timers/promises";

const [core, ...prefix] = process.argv.slice(2);
const root = await mkdtemp(path.join(os.tmpdir(), "mydrive-sync-"));
const profile = path.join(root, "profile");
const config = path.join(profile, "config.xml");
const data = path.join(root, "data");
const env = {
    ...process.env, STHOMEDIR: profile, HOME: root, USERPROFILE: root,
    LOCALAPPDATA: root, APPDATA: root, XDG_STATE_HOME: root, XDG_CONFIG_HOME: root,
};
for (const name of ["STCONFDIR", "STDATADIR", "STGUIADDRESS", "STGUIAPIKEY"]) delete env[name];
const children = [];

function launch(executable, args, stdio) {
    const child = spawn(executable, args, { env, stdio, windowsHide: true });
    children.push(child);
    return child;
}

function open() {
    const child = launch(core, [...prefix, "--syncthing-owner"], ["pipe", "pipe", "inherit"]);
    const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
    return {
        async ensure(payload = {}) {
            child.stdin.write(JSON.stringify({ data_dir: data, payload }) + "\n");
            const { value } = await lines.next();
            assert.ok(value, "the myDrive engine owner returned a response");
            const response = JSON.parse(value);
            assert.equal(response.ok, true, response.error);
            return response.data;
        },
        async close() {
            const result = exited(child);
            child.stdin.end();
            assert.equal(await result, 0);
        },
    };
}

async function exited(child) {
    if (child.exitCode === null && child.signalCode === null) {
        return (await once(child, "exit"))[0];
    }
    return child.exitCode;
}

async function api(connection, route, options) {
    const res = await fetch(connection.endpoint + "/rest/" + route, {
        ...options, headers: { "X-API-Key": connection.api_key, ...options?.headers },
        signal: AbortSignal.timeout(2000),
    });
    assert.ok(res.ok, `Syncthing responded to ${route} with ${res.status}`);
    const body = await res.text();
    return body ? JSON.parse(body) : null;
}

async function waitOnline(connection, seconds) {
    const deadline = Date.now() + seconds * 1000;
    while (Date.now() < deadline) {
        try { return await api(connection, "system/ping"); }
        catch { await delay(150); }
    }
    throw new Error("Syncthing did not come online in time.");
}

async function expectOffline(connection) {
    const url = new URL(connection.endpoint);
    const online = await new Promise(resolve => {
        const socket = net.connect({ host: url.hostname, port: Number(url.port) });
        socket.once("connect", () => { socket.destroy(); resolve(true); });
        socket.once("error", () => resolve(false));
        socket.setTimeout(2000, () => { socket.destroy(); resolve(false); });
    });
    assert.equal(online, false, "the owned Syncthing process released its API port");
}

try {
    const first = open();
    // No Syncthing executable or profile was placed in this isolated data directory.
    const fresh = await first.ensure();
    assert.equal(fresh.state, "installed");
    assert.equal(path.resolve(fresh.config_path), config);
    await access(fresh.binary_path);
    let connection = fresh.connection;
    const identity = (await api(connection, "system/status")).myID;
    const folder = await api(connection, "config/defaults/folder");
    folder.id = "mydrive-test";
    folder.path = path.join(root, "files");
    await mkdir(folder.path);
    await api(connection, "config/folders", {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(folder),
    });
    await first.close();
    await expectOffline(connection);

    const external = launch(fresh.binary_path, [
        "serve", "--home", profile, "--no-browser", "--no-restart", "--no-upgrade", "--log-file=-",
    ], "ignore");
    await waitOnline(connection, 15);
    const visitor = open();
    assert.equal((await visitor.ensure()).binary_path, null);
    await visitor.close();
    assert.equal((await api(connection, "system/ping")).ping, "pong", "closing myDrive preserves independently started Syncthing");

    const owner = open();
    assert.equal((await owner.ensure()).state, "running");
    await api(connection, "system/shutdown", { method: "POST" });
    await exited(external);
    // Leave the pipe idle, so this exercises automatic takeover without a UI refresh.
    await waitOnline(connection, 45);
    const running = await owner.ensure();
    assert.equal(running.binary_path, fresh.binary_path);
    connection = running.connection;
    assert.equal((await api(connection, "system/status")).myID, identity);
    assert.equal((await api(connection, "config/folders/" + folder.id)).path, folder.path);
    await owner.close();
    await expectOffline(connection);
    console.log("Syncthing first-run download, app-quit cleanup, external ownership and automatic takeover passed.");
} catch (error) {
    const log = await readFile(path.join(data, "syncthing-engine.log"), "utf8").catch(() => "");
    if (log) console.error(log.trim().split(/\r?\n/).slice(0, 20).join("\n"));
    throw error;
} finally {
    for (const child of children.reverse()) {
        if (child.exitCode !== null || child.signalCode !== null) continue;
        if (child.stdin) child.stdin.end();
        else child.kill();
        await exited(child);
    }
    await rm(root, { recursive: true, force: true, maxRetries: 6, retryDelay: 200 });
}
