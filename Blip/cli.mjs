#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, readFile, readdir, realpath, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline/promises';

export const ROOT = path.dirname(fileURLToPath(import.meta.url));
export const RUNTIME = path.resolve(process.env.MYDRIVE_BLIP_RUNTIME ?? path.join(ROOT, '.runtime'));
const PREFIX = 'MYDRIVE_JSON ';
const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const PEER = new RegExp(`^${UUID}:${UUID}$`, 'i');
const TRANSFER = new RegExp(`^${UUID}$`, 'i');
const output = value => process.stdout.write(JSON.stringify(value, null, process.env.MYDRIVE_BLIP_JSONL === '1' ? 0 : 2) + '\n');

export function peerId(text) {
  if (!PEER.test(text ?? '')) throw new Error('Expected explicit --peer USER_UUID:DEVICE_UUID');
  return text;
}
export function transferId(text) {
  if (!TRANSFER.test(text ?? '')) throw new Error('Expected --id TRANSFER_UUID');
  // Blip keys transfers by the original UUID text; Apple senders can use uppercase.
  return text;
}
export function validateSocketPath(profile) {
  if (Buffer.byteLength(path.join(profile, 'cache', 'sock'), 'utf8') >= 108)
    throw new Error('Blip requires its socket path to be under 108 UTF-8 bytes. Choose a shorter --profile path');
}
export function parseArgs(args) {
  const command = args.shift() ?? 'help';
  const options = {}, files = [];
  const flags = new Set(['--execute', '--help']);
  const values = new Set(['--profile', '--java', '--app', '--peer', '--email', '--name', '--id', '--socket']);
  let literal = false;
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (literal) files.push(arg);
    else if (arg === '--') literal = true;
    else if (flags.has(arg)) options[arg.slice(2)] = true;
    else if (values.has(arg)) {
      if (args[index + 1] === undefined || args[index + 1].startsWith('--')) throw new Error(`Missing value for ${arg}`);
      if (Object.hasOwn(options, arg.slice(2))) throw new Error(`Duplicate option ${arg}`);
      options[arg.slice(2)] = args[++index];
    } else if (arg.startsWith('--')) throw new Error(`Unknown option ${arg}`);
    else files.push(arg);
  }
  return { command, options, files };
}
export function encodeInput(values) {
  return values.map(value => Buffer.from(value, 'utf8').toString('base64') + '\n').join('');
}
export function parseBridgeOutput(stdout) {
  const records = stdout.split(/\r?\n/).filter(line => line.startsWith(PREFIX));
  if (records.length !== 1) throw new Error('Expected exactly one bridge response; outcome unconfirmed');
  return JSON.parse(records[0].slice(PREFIX.length));
}

export async function runBounded(executable, args, { input = '', timeoutMs = 15_000, cwd = ROOT, env = process.env } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { cwd, env, shell: false, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '', stderr = '', timedOut = false, overflow = false;
    const timer = setTimeout(() => { timedOut = true; child.kill(); }, timeoutMs);
    const capture = stream => chunk => {
      if (stdout.length + stderr.length + chunk.length > 1_048_576) { overflow = true; child.kill(); return; }
      if (stream === 'stdout') stdout += chunk; else stderr += chunk;
    };
    child.stdout.on('data', capture('stdout')); child.stderr.on('data', capture('stderr'));
    child.on('error', error => { clearTimeout(timer); reject(error); });
    child.stdin.on('error', () => {});
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal, stdout, stderr, timedOut, overflow });
    });
    child.stdin.end(input);
  });
}

async function runtime(options) {
  let java = options.java ?? process.env.MYDRIVE_JAVA;
  if (!java) {
    const entries = await readdir(RUNTIME).catch(() => []);
    const dir = entries.find(name => name.startsWith('jdk-'));
    if (dir) java = path.join(RUNTIME, dir, 'bin', process.platform === 'win32' ? 'java.exe' : 'java');
  }
  const app = path.resolve(options.app ?? process.env.MYDRIVE_BLIP_APP ?? path.join(RUNTIME, 'blip'));
  if (!java || !existsSync(java)) throw new Error('Portable Java 25 required. See README setup; use --java PATH');
  if (!existsSync(path.join(app, 'app', 'libblip-jvm.jar'))) throw new Error('Blip runtime missing. See README setup; use --app DIRECTORY');
  const lock = JSON.parse(await readFile(path.join(ROOT, 'runtime-lock.json'), 'utf8'));
  for (const [file, dependency] of Object.entries(lock.support_files ?? {})) {
    const hash = createHash('sha256').update(await readFile(path.join(RUNTIME, 'support', file)).catch(() => { throw new Error('Blip support runtime missing. Run tests/prepare-blip-support.ps1'); })).digest('hex');
    if (hash !== dependency.sha256) throw new Error(`Unreviewed support dependency: ${file}`);
  }
  for (const [file, expected] of Object.entries(lock.files)) {
    const hash = createHash('sha256').update(await readFile(path.join(app, file))).digest('hex');
    if (hash !== expected) throw new Error(`Unreviewed Blip engine version: ${file}`);
  }
  return { java: path.resolve(java), app };
}
function jvmArgs(app, main, args) {
  const nativeDir = path.join(app, 'bin');
  const nativePath = [nativeDir, ...(process.platform === 'win32' ? [path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32')] : [])].join(path.delimiter);
  return ['-Djava.awt.headless=true', '--enable-native-access=ALL-UNNAMED', `-Djava.library.path=${nativePath}`,
    '-cp', [path.join(RUNTIME, 'classes'), path.join(RUNTIME, 'support', 'jna-5.19.1.jar'), path.join(app, 'app', '*')].join(path.delimiter), main, ...args];
}
function childEnvironment() {
  // Do not inherit JVM injection options from the parent session.
  const env = { ...process.env };
  delete env.JAVA_TOOL_OPTIONS; delete env.JDK_JAVA_OPTIONS; delete env._JAVA_OPTIONS;
  return env;
}
async function profileInfo(options) {
  const profile = await realpath(path.resolve(options.profile ?? path.join(ROOT, '.profiles', 'mydrive-server')));
  validateSocketPath(profile);
  const marker = JSON.parse(await readFile(path.join(profile, 'mydrive-profile.json'), 'utf8'));
  if (marker.version !== 1 || !TRANSFER.test(marker.deviceId) || typeof marker.name !== 'string') throw new Error('Invalid MyDrive profile');
  return { profile, marker };
}
async function request(options, command, values = []) {
  const { profile } = await profileInfo(options), { java, app } = await runtime(options);
  // Windows AF_UNIX endpoints cannot be opened like ordinary files for realpath/stat.
  const address = options.socket ? [path.resolve(options.socket)] : [];
  const result = await runBounded(java, jvmArgs(app, 'BlipBridge', ['request', profile, command, ...address]), {
    input: encodeInput(values), env: childEnvironment(), timeoutMs: 25_000,
  });
  if (result.timedOut || result.overflow) throw new Error('Bridge stopped at its limit; command outcome is unconfirmed. Check status before retrying');
  let response;
  try { response = parseBridgeOutput(result.stdout); }
  catch { throw new Error(`Bridge could not return a safe response (exit ${result.code}). Check that serve is running`); }
  output(response);
  if (result.code !== 0 || !response.ok) process.exitCode = 1;
}

const HELP = `MyDrive Blip headless proof of concept (private Blip 1.2.8 interface)

  node cli.mjs init [--name NAME]                 Create a separate server profile
  node cli.mjs doctor                            Check portable runtime
  node cli.mjs build                             Compile the Java bridge
  node cli.mjs probe                             Bounded fresh-profile engine test
  node cli.mjs serve                             Run headless in foreground; Ctrl+C stops
  node cli.mjs desktop-serve                     Keep existing desktop device available without its UI
  node cli.mjs status | devices | transfers | poll Query real engine state
  node cli.mjs login --email EMAIL               Request a Blip sign-in code
  node cli.mjs verify                            Read sign-in code from stdin/prompt
  node cli.mjs trust --peer USER_UUID:DEVICE_UUID Allow unattended incoming transfers
  node cli.mjs send --peer USER_UUID:DEVICE_UUID FILE... [--execute]
  node cli.mjs accept --id TRANSFER_UUID --execute

Common: --profile PATH, --java JAVA_EXE, --app COPIED_RUNTIME_DIRECTORY
Desktop session: --socket PATH for status/devices/transfers/poll/send/accept only.
Blip desktop must stay running. Its account and receiving preferences are preserved.
Send defaults to a preview; --execute dispatches. Dispatch is not completion.
Receive destination: PROFILE/downloads/TRANSFER_UUID. Receive policy must verify after login.
No public API, no Tailscale, no desktop app entry point. Experimental; see README.
`;

export async function main(argv = process.argv.slice(2)) {
  const { command, options, files } = parseArgs([...argv]);
  if (['help', '--help', '-h'].includes(command) || options.help) { process.stdout.write(HELP); return; }
  if (options.socket && !['status', 'devices', 'transfers', 'poll', 'send', 'accept'].includes(command))
    throw new Error('Desktop sessions support status, devices, transfers, poll, send and accept only; manage sign-in and automatic receiving in Blip desktop');
  if (command === 'init') {
    const profile = path.resolve(options.profile ?? path.join(ROOT, '.profiles', 'mydrive-server'));
    validateSocketPath(profile);
    await mkdir(path.dirname(profile), { recursive: true, mode: 0o700 });
    await mkdir(profile, { mode: 0o700 }); // EEXIST deliberately refuses account/profile reuse.
    for (const dir of ['cache', 'state', 'downloads']) await mkdir(path.join(profile, dir), { mode: 0o700 });
    await writeFile(path.join(profile, 'mydrive-profile.json'), JSON.stringify({ version: 1, name: options.name ?? 'MyDrive headless test', deviceId: randomUUID() }, null, 2), { flag: 'wx', mode: 0o600 });
    await writeFile(path.join(profile, 'trusted-peers.txt'), '', { flag: 'wx', mode: 0o600 });
    output({ ok: true, profile, receiving: 'manual until peer explicitly trusted' }); return;
  }
  if (command === 'doctor') {
    const { java, app } = await runtime(options);
    const result = await runBounded(java, ['-version'], { env: childEnvironment() });
    const version = result.stderr + result.stdout;
    const java25 = /version "25[.\"]/.test(version);
    const bridgeBuilt = existsSync(path.join(RUNTIME, 'classes', 'BlipBridge.class'));
    output({ ok: result.code === 0 && java25 && bridgeBuilt, java25, app, bridgeBuilt });
    if (!java25 || !bridgeBuilt) process.exitCode = 1; return;
  }
  if (command === 'build') {
    const { java, app } = await runtime(options);
    const javac = path.join(path.dirname(java), process.platform === 'win32' ? 'javac.exe' : 'javac');
    await mkdir(path.join(RUNTIME, 'classes'), { recursive: true });
    const result = await runBounded(javac, ['-cp', path.join(app, 'app', '*'), '-d', path.join(RUNTIME, 'classes'), path.join(ROOT, 'java', 'BlipBridge.java'), path.join(ROOT, 'java', 'HeadlessProbe.java')], { env: childEnvironment(), timeoutMs: 30_000 });
    if (result.code !== 0 || result.timedOut) { process.stderr.write(result.stderr); throw new Error('Java compilation failed'); }
    output({ ok: true, compiled: true }); return;
  }
  if (command === 'probe') {
    const { java, app } = await runtime(options);
    await mkdir(path.join(ROOT, '.profiles'), { recursive: true, mode: 0o700 });
    const profile = path.join(ROOT, '.profiles', `p-${randomUUID().slice(0, 8)}`);
    validateSocketPath(profile);
    const result = await runBounded(java, jvmArgs(app, 'HeadlessProbe', [profile]), { env: childEnvironment(), timeoutMs: 15_000 });
    const markers = Object.fromEntries([...result.stdout.matchAll(/MYDRIVE_PROBE ([a-z_]+)=(true|false)/g)].map(m => [m[1], m[2] === 'true']));
    const ok = result.code === 0 && !result.timedOut && ['headless', 'engine_started', 'client_exists', 'state_decoded', 'clean_shutdown'].every(key => markers[key]);
    output({ ok, scope: 'unauthenticated_engine_startup', ...markers, timedOut: result.timedOut, profile });
    if (!ok) process.exitCode = 1; return;
  }
  if (command === 'serve' || command === 'desktop-serve') {
    const { profile } = await profileInfo(options), { java, app } = await runtime(options);
    const child = spawn(java, jvmArgs(app, 'BlipBridge', [command === 'desktop-serve' ? 'desktop-host' : 'host', profile, '-']), { shell: false, windowsHide: true, env: childEnvironment(), stdio: ['pipe', 'pipe', 'pipe'] });
    let lineBuffer = '', stopped = false, deadline;
    const stop = () => { if (stopped) return; stopped = true; child.stdin.end('STOP\n'); deadline = setTimeout(() => child.kill(), 10000); };
    process.once('SIGINT', stop); process.once('SIGTERM', stop);
    const onInput = chunk => { if (String(chunk).trim() === 'STOP') stop(); };
    process.stdin.on('data', onInput);
    process.stdin.once('end', stop);
    child.stdin.on('error', () => {});
    child.stdout.on('data', data => {
      lineBuffer += data;
      if (lineBuffer.length > 1_048_576) { stop(); return; }
      let index;
      while ((index = lineBuffer.indexOf('\n')) !== -1) {
        const line = lineBuffer.slice(0, index).replace(/\r$/, ''); lineBuffer = lineBuffer.slice(index + 1);
        if (line.startsWith(PREFIX)) { try { output(JSON.parse(line.slice(PREFIX.length))); } catch { stop(); } }
      }
    });
    // Raw native logging can contain registration events. Never forward it to the console.
    child.stderr.resume();
    await new Promise((resolve, reject) => { child.on('error', reject); child.on('close', code => { clearTimeout(deadline); if (code !== 0) process.exitCode = 1; resolve(); }); });
    process.removeListener('SIGINT', stop); process.removeListener('SIGTERM', stop);
    process.stdin.removeListener('data', onInput); process.stdin.removeListener('end', stop); process.stdin.pause(); return;
  }
  if (command === 'trust') {
    const peer = peerId(options.peer), { profile } = await profileInfo(options);
    const filename = path.join(profile, 'trusted-peers.txt');
    const peers = new Set((await readFile(filename, 'utf8')).split(/\r?\n/).filter(Boolean)); peers.add(peer);
    await writeFile(filename, [...peers].sort().join('\n') + '\n', { mode: 0o600 });
    output({ ok: true, trusted: peer, scope: 'incoming files from this exact peer', applies: 'on next engine state update' }); return;
  }
  if (['status', 'devices', 'transfers', 'poll'].includes(command)) { await request(options, command); return; }
  if (command === 'login') {
    if (!options.email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(options.email)) throw new Error('Expected --email EMAIL');
    const { marker } = await profileInfo(options); await request(options, 'login', [options.email, marker.name]); return;
  }
  if (command === 'verify') {
    let code;
    if (process.stdin.isTTY) { const prompt = createInterface({ input: process.stdin, output: process.stderr }); try { code = await prompt.question('Blip sign-in code: '); } finally { prompt.close(); } }
    else { let input = ''; for await (const chunk of process.stdin) { input += chunk; if (input.length > 256) throw new Error('Code input too long'); } code = input.trim(); }
    if (!/^[a-z0-9-]{4,16}$/i.test(code ?? '')) throw new Error('Invalid sign-in code');
    const { marker } = await profileInfo(options); await request(options, 'verify', [code, marker.deviceId, marker.name]); return;
  }
  if (command === 'send') {
    const peer = peerId(options.peer); if (!files.length) throw new Error('At least one file or folder required');
    const paths = await Promise.all(files.map(async value => { const p = await realpath(value); const s = await stat(p); if (!s.isFile() && !s.isDirectory()) throw new Error('Unsupported file type'); return p; }));
    if (!options.execute) { output({ ok: true, preview: true, peer, paths, next: 'Add --execute to dispatch these paths' }); return; }
    await request(options, 'send', options.id ? [peer, transferId(options.id), ...paths] : [peer, '', ...paths]); return;
  }
  if (command === 'accept') {
    if (!TRANSFER.test(options.id ?? '')) throw new Error('Expected --id TRANSFER_UUID');
    if (!options.execute) throw new Error('Add --execute to accept the specified transfer');
    await request(options, 'accept', [transferId(options.id)]); return;
  }
  throw new Error(`Unknown command ${command}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { output({ ok: false, error: error.message }); process.exitCode = 1; });
}
