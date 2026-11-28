import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { access, mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
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

function launch(executable, args, stdio, environment = env) {
    const child = spawn(executable, args, { env: environment, stdio, windowsHide: true });
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

function change(method, body) {
    return { method, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) };
}

async function freePort() {
    const server = net.createServer();
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const { port } = server.address();
    await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    return port;
}

async function request(connection, action, payload) {
    const child = launch(core, prefix, ["pipe", "pipe", "inherit"]);
    const output = [];
    child.stdout.on("data", piece => output.push(piece));
    const done = once(child, "close");
    child.stdin.end(JSON.stringify({ action: "syncthing." + action, data_dir: data, syncthing: connection, payload }));
    const [status] = await done;
    assert.equal(status, 0);
    return JSON.parse(Buffer.concat(output).toString("utf8"));
}

async function waitContent(file, content, seconds = 35) {
    const deadline = Date.now() + seconds * 1000;
    while (Date.now() < deadline) {
        if (await readFile(file, "utf8").catch(() => null) === content) return;
        await delay(150);
    }
    assert.fail("The expected synced copy did not arrive: " + path.basename(file));
}

async function selectedShare(connection, binary, identity) {
    const secondPath = path.join(root, "recipient-profile");
    await mkdir(secondPath);
    const secondEnv = { ...env, STNODEFAULTFOLDER: "1" };
    delete secondEnv.STHOMEDIR;
    const generation = launch(binary, ["generate", "--home", secondPath], ["ignore", "ignore", "inherit"], secondEnv);
    assert.equal(await exited(generation), 0);
    const generatedConfig = await readFile(path.join(secondPath, "config.xml"), "utf8");
    const key = generatedConfig.match(/<apikey>([^<]+)<\/apikey>/)?.[1];
    assert.ok(key, "the isolated second engine has an API key");
    const gui = await freePort();
    const second = { endpoint: "http://127.0.0.1:" + gui, api_key: key };
    const other = launch(binary, [
        "serve", "--home", secondPath, "--gui-address=127.0.0.1:" + gui,
        "--no-browser", "--no-restart", "--no-upgrade", "--log-file=-",
    ], ["ignore", "ignore", "inherit"], secondEnv);
    await waitOnline(second, 15);
    const remote = (await api(second, "system/status")).myID;
    const port1 = await freePort();
    const port2 = await freePort();
    const address = port => "tcp://127.0.0.1:" + port;
    const localOptions = port => ({ listenAddresses: [address(port)], globalAnnounceEnabled: false,
        localAnnounceEnabled: false, relaysEnabled: false, natEnabled: false });
    await api(connection, "config/options", change("PATCH", localOptions(port1)));
    await api(second, "config/options", change("PATCH", localOptions(port2)));
    await api(connection, "config/devices", change("POST", { deviceID: remote, name: "Fixture recipient", addresses: [address(port2)] }));
    await api(second, "config/devices", change("POST", { deviceID: identity, name: "Fixture sender", addresses: [address(port1)] }));

    const source = path.join(root, "selected-source");
    const destination = path.join(root, "selected-destination");
    await mkdir(path.join(source, "project"), { recursive: true });
    await mkdir(destination);
    const explicit = "keep [draft].txt";
    await writeFile(path.join(source, explicit), "original");
    await writeFile(path.join(source, "private.txt"), "excluded");
    await writeFile(path.join(source, "project", "notes.txt"), "folder contents");
    const settings = { local_paths: [path.join(source, explicit), path.join(source, "project")], device_id: remote };
    const share = await request(connection, "share.drop", settings);
    assert.equal(share.ok, true, share.error);
    assert.equal(share.data.selected_only, true);
    const id = share.data.folder_id;
    const saved = await api(connection, "config/folders/" + id);
    assert.equal(saved.type, "sendreceive");
    assert.equal(saved.paused, false);
    assert.ok(saved.devices.some(device => device.deviceID === remote));
    const receive = await api(second, "config/defaults/folder");
    await api(second, "config/folders", change("POST", { ...receive, id, path: destination,
        rescanIntervalS: 1, fsWatcherDelayS: 1, devices: [{ deviceID: remote }, { deviceID: identity }] }));
    await waitContent(path.join(destination, explicit), "original");
    await waitContent(path.join(destination, "project", "notes.txt"), "folder contents");
    await assert.rejects(access(path.join(destination, "private.txt")), { code: "ENOENT" });
    await writeFile(path.join(destination, explicit), "changed by recipient");
    await waitContent(path.join(source, explicit), "changed by recipient");
    const widened = await request(connection, "share.drop.preview", { local_paths: [source], device_id: remote });
    assert.equal(widened.ok, false);
    assert.match(widened.error, /selected items only/);
    await api(second, "system/shutdown", { method: "POST" });
    await exited(other);
    console.log("Syncthing applied a mixed file and folder selection, kept its sibling private, and synced a recipient edit back.");
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
    await selectedShare(connection, fresh.binary_path, identity);
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
