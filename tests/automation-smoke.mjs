import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';

const [binary, ...prefix] = process.argv.slice(2);
assert.ok(binary, 'Pass the installed CLI path');
const run = (args, input) => spawnSync(binary, [...prefix, ...args], {
    input, encoding: 'utf8', timeout: 30000, windowsHide: true,
});
const version = run(['--version']);
assert.equal(version.status, 0, version.stderr);
assert.match(version.stdout.trim(), /^\d+\.\d+\.\d+$/);
if (process.env.MYDRIVE_VERSION) assert.equal(version.stdout.trim(), process.env.MYDRIVE_VERSION);
assert.match(run(['--help']).stdout, /blip serve/);
assert.notEqual(run(['blip', 'send', 'peer only']).status, 0);

const request = (id, method, params) => ({ jsonrpc: '2.0', id, method, params });
const replies = run(['mcp'], [
    request(1, 'initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'myDrive smoke test', version: '1' } }),
    { jsonrpc: '2.0', method: 'notifications/initialized' },
    request(2, 'tools/list'),
    request(3, 'tools/call', { name: 'blip_send', arguments: { peer: 'placeholder', paths: [] } }),
    request(4, 'tools/call', { name: 'smb_browse', arguments: { password: 'fixture' } }),
].map(value => JSON.stringify(value) + '\n').join(''));
assert.equal(replies.status, 0, replies.stderr);
const [init, tools, badSend, badSmb] = replies.stdout.trim().split('\n').map(line => JSON.parse(line));
assert.equal(init.result.serverInfo.version, version.stdout.trim());
assert.equal(init.result.protocolVersion, '2025-11-25');
const names = new Set(tools.result.tools.map(tool => tool.name));
for (const expected of ['blip_send', 'blip_receive', 'sync_share', 'sync_pause', 'smb_devices', 'smb_browse']) assert.ok(names.has(expected));
assert.equal(badSend.result.isError, true);
assert.equal(badSmb.result.isError, true);
assert.match(badSmb.result.content[0].text, /Unknown argument password/);
console.log('Packaged CLI and MCP session passed.');
