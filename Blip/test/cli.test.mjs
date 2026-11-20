import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rmdir, unlink } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { encodeInput, main, parseArgs, parseBridgeOutput, peerId, transferId, runBounded, validateSocketPath } from '../cli.mjs';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const peer = '11111111-1111-4111-8111-111111111111:22222222-2222-4222-8222-222222222222';

test('receiving preserves uppercase and mixed-case native transfer keys', () => {
  const id='ABCD1234-EF56-4789-ABCD-123456789ABC';
  const nativeTransfers=new Map([[id,{status:'Invited'}]]);
  assert.equal(nativeTransfers.get(transferId(id))?.status,'Invited');
  assert.equal(transferId(id.toLowerCase()),id.toLowerCase());
  for (const invalid of ['', 'phone',id+' --execute']) assert.throws(()=>transferId(invalid));
});

test('a send requires an exact explicit peer identity', () => {
  for (const value of ['', 'phone', '11111111', peer + ' --file secret']) assert.throws(() => peerId(value));
  assert.equal(peerId(peer.toUpperCase()), peer.toUpperCase());
});
test('literal filenames and shell syntax stay in separate arguments', () => {
  const result = parseArgs(['send', '--peer', peer, '--', '--execute', 'a; echo secret.txt']);
  assert.deepEqual(result.files, ['--execute', 'a; echo secret.txt']);
  assert.equal(result.options.execute, undefined);
});
test('missing, duplicate and unknown options fail before execution', () => {
  for (const args of [['send', '--peer'], ['send', '--peer', peer, '--peer', peer], ['send', '--auto-accept']])
    assert.throws(() => parseArgs(args));
});
test('desktop attachment rejects hosting, login and global receiving changes before touching a profile', async () => {
  for (const command of ['serve', 'desktop-serve', 'login', 'verify', 'trust', 'init', 'probe'])
    await assert.rejects(main([command, '--socket', 'unused']), /Desktop sessions support/);
});
test('stdin protocol preserves Unicode, newlines and spaces without shell quoting', () => {
  const values = ['test@example.invalid', 'a\nb\t"c"', '雪 file.txt'];
  const decoded = encodeInput(values).trimEnd().split('\n').map(line => Buffer.from(line, 'base64').toString('utf8'));
  assert.deepEqual(decoded, values);
});
test('native logs cannot masquerade as a successful response', () => {
  assert.throws(() => parseBridgeOutput('INFO success\n{"ok":true}'));
  assert.throws(() => parseBridgeOutput('MYDRIVE_JSON {"ok":true}\nMYDRIVE_JSON {"ok":false}\n'));
  assert.deepEqual(parseBridgeOutput('banner\nMYDRIVE_JSON {"ok":true,"completed":false}\n'), { ok: true, completed: false });
});
test('native socket length limit uses UTF-8 bytes', () => {
  validateSocketPath(path.join(os.tmpdir(), 'bp-short'));
  assert.throws(() => validateSocketPath('x'.repeat(108)), /108/);
  assert.throws(() => validateSocketPath('雪'.repeat(40)), /108/);
});
test('process runner terminates its own stalled child', async () => {
  const result = await runBounded(process.execPath, ['-e', 'setInterval(()=>{},1000)'], { timeoutMs: 200 });
  assert.equal(result.timedOut, true);
});
test('stdin values are data even when they contain shell expressions', async () => {
  const payload = '$(echo private); & exit 99';
  const result = await runBounded(process.execPath, ['-e', 'process.stdin.pipe(process.stdout)'], { input: payload });
  assert.equal(result.code, 0); assert.equal(result.stdout, payload);
});
test('profile init refuses existing state and has no trusted peers by default', async () => {
  const parent = await mkdtemp(path.join(os.tmpdir(), 'bp-'));
  const profile = path.join(parent, 'p');
  try {
    const args = [path.join(ROOT, 'cli.mjs'), 'init', '--profile', profile];
    const first = await runBounded(process.execPath, args);
    assert.equal(first.code, 0);
    assert.equal(await readFile(path.join(profile, 'trusted-peers.txt'), 'utf8'), '');
    const second = await runBounded(process.execPath, args);
    assert.notEqual(second.code, 0);
    const marker = JSON.parse(await readFile(path.join(profile, 'mydrive-profile.json'), 'utf8'));
    assert.equal(marker.version, 1);
  } finally {
    // Remove only files and empty directories created by this test; no recursive deletion.
    for (const file of ['mydrive-profile.json', 'trusted-peers.txt']) await unlink(path.join(profile, file)).catch(() => {});
    for (const dir of ['cache', 'state', 'downloads']) await rmdir(path.join(profile, dir)).catch(() => {});
    await rmdir(profile).catch(() => {}); await rmdir(parent).catch(() => {});
  }
});
