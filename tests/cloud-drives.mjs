import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { setTimeout as wait } from 'node:timers/promises';

const binary = resolve(process.argv[2]);
const args = process.argv.slice(3);
const fixture = await mkdtemp(join(tmpdir(), 'mydrive-cloud-'));
const data = join(fixture, 'app');
const source = join(fixture, 'Projects');
const remote = join(fixture, 'Cloud');
const target = join(remote, 'Backups', 'Projects');
const account = 'a'.repeat(32);
const localFile = join(source, 'scene.txt');
const cloudFile = join(target, 'scene.txt');
const restored = join(fixture, 'restored.txt');

function request(action, payload = {}) {
    const result = spawnSync(binary, args, {
        input: JSON.stringify({ action: 'cloud.' + action, data_dir: data, payload }),
        encoding: 'utf8',
        timeout: 210_000,
        windowsHide: true,
    });
    assert.equal(result.status, 0, result.error?.message || result.stderr);
    return JSON.parse(result.stdout);
}

function call(action, payload) {
    const reply = request(action, payload);
    assert.equal(reply.ok, true, reply.error);
    return reply.data;
}

async function backup(id, schedule = false) {
    if (schedule) call('tick');
    else assert.equal(call('run', { job: id }).started, true);
    for (let attempt = 0; attempt < 120; attempt++) {
        const { report } = call('status').jobs.find(item => item.job.id === id);
        if (report.phase === 'complete') return;
        assert.ok(['queued', 'running'].includes(report.phase), report.message || report.phase);
        await wait(200);
    }
    assert.fail('Cloud backup did not finish.');
}

try {
    assert.deepEqual(call('status'), { accounts: [], jobs: [] });
    const { version } = call('setup');
    assert.match(version, /^v\d+\.\d+\.\d+$/);
    const helper = join(data, 'cloud', version, process.platform === 'win32' ? 'rclone.exe' : 'rclone');
    const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.toUpperCase().startsWith('RCLONE_')));
    for (const provider of ['dropbox', 'onedrive', 'drive']) {
        const profile = join(fixture, provider + '.conf');
        const options = provider === 'drive' ? 'client_id = fixture.apps.googleusercontent.com\n' : '';
        await writeFile(profile, '[mydrive]\ntype = ' + provider + '\n' + options);
        const setup = spawnSync(helper, ['--config', profile, 'config', 'update', 'mydrive', '--non-interactive'],
            { encoding: 'utf8', env, timeout: 10_000, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
        assert.equal(setup.status, 0, provider);
        const prompt = JSON.parse(setup.stdout);
        assert.equal(prompt.Option.Name, 'config_is_local', provider);
    }
    const config = join(data, 'cloud', 'accounts', account);
    await Promise.all([config, source, remote].map(path => mkdir(path, { recursive: true })));
    await writeFile(join(config, 'rclone.conf'), '[mydrive]\ntype = alias\nremote = ' + remote.replaceAll('\\', '/') + '\n');
    await writeFile(join(data, 'cloud', 'state.json'), JSON.stringify({
        accounts: [{ id: account, name: 'Fixture', provider: 'drive' }], jobs: [],
    }));
    await writeFile(localFile, 'original project');
    await writeFile(join(source, 'keep.txt'), 'keep this cloud copy');
    await mkdir(join(source, 'Nested'));
    await writeFile(join(source, 'Nested', 'asset.txt'), 'nested asset');

    assert.deepEqual(call('browse', { account, path: '' }).entries, []);
    const options = { account, source, path: 'Backups/Projects', interval: 1440 };
    call('add', options);
    const { job } = call('status').jobs[0];
    assert.equal(request('add', { ...options, path: 'Backups' }).ok, false);
    assert.equal(request('add', { ...options, path: 'Credentials', source: data }).ok, false);
    assert.equal(request('disconnect', { account }).ok, false);
    const versions = 'myDrive Versions/' + job.id;
    assert.deepEqual(call('browse', { account, path: versions }).entries, []);

    await backup(job.id, true);
    assert.equal(await readFile(cloudFile, 'utf8'), 'original project');
    assert.equal(await readFile(join(target, 'Nested', 'asset.txt'), 'utf8'), 'nested asset');
    await writeFile(localFile, 'changed project with a new length');
    await rm(join(source, 'keep.txt'));
    call('pause', { job: job.id, paused: true });
    assert.equal(call('status').jobs[0].job.paused, true);
    await backup(job.id);
    assert.equal(await readFile(cloudFile, 'utf8'), 'changed project with a new length');
    assert.equal(await readFile(join(target, 'keep.txt'), 'utf8'), 'keep this cloud copy');
    const [previous] = call('browse', { account, path: versions }).entries;
    assert.equal(previous.folder, true);
    const payload = { account, path: previous.path + '/scene.txt', destination: restored };
    call('download', payload);
    assert.equal(await readFile(restored, 'utf8'), 'original project');
    assert.equal(request('download', payload).ok, false);

    call('remove', { job: job.id });
    call('disconnect', { account });
    assert.deepEqual(call('status'), { accounts: [], jobs: [] });
    assert.equal(await readFile(cloudFile, 'utf8'), 'changed project with a new length');
    console.log('Cloud Drives: verified helper, browsing, scheduled and manual backup, saved versions, and non-overwriting restore.');
} finally {
    await rm(fixture, { recursive: true, force: true, maxRetries: 5 });
}
