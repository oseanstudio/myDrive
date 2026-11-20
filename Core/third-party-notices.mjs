import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const [manifest, output, cargo = 'cargo'] = process.argv.slice(2);
if (!manifest || !output) throw new Error('Usage: node third-party-notices.mjs MANIFEST OUTPUT [CARGO]');
const {packages} = JSON.parse(execFileSync(cargo, [
    'metadata', '--locked', '--format-version', '1', '--manifest-path', manifest,
], {maxBuffer: 32 * 1024 * 1024, stdio: ['ignore', 'pipe', 'inherit']}));

const heading = 'myDrive Rust dependency notices\n';
const noticeName = /^(?:licen[sc]e|copying|notice|copyright)(?:[.-].*)?$/i;
const sections = [];

for (const entry of packages.filter(p => p.source?.startsWith('registry+')).sort((a, b) => a.name.localeCompare(b.name))) {
    const root = fs.realpathSync(path.dirname(entry.manifest_path));
    const files = new Set();
    function collect(folder, depth) {
        for (const child of fs.readdirSync(folder, {withFileTypes: true})) {
            if (child.name.startsWith('.')) continue;
            const file = path.join(folder, child.name);
            if (child.isDirectory() && depth < 4) collect(file, depth + 1);
            if (child.isFile() && noticeName.test(child.name)) files.add(file);
        }
    }
    collect(root, 1);
    if (entry.license_file) {
        const declared = fs.realpathSync(path.resolve(root, entry.license_file));
        const relative = path.relative(root, declared);
        if (relative && !relative.startsWith('..') && !path.isAbsolute(relative)) files.add(declared);
    }
    const texts = [...files].sort().map(file => {
        const name = path.relative(root, file).replaceAll(path.sep, '/');
        return `--- ${name} ---\n${fs.readFileSync(file, 'utf8')}\n`;
    });
    sections.push(`=== ${entry.name} ${entry.version} ===\nLicense: ${entry.license || 'See included notice'}\n\n${texts.join('\n')}`);
}

for (const dependency of ['openssl-src', 'libssh2-sys']) {
    if (!sections.some(section => section.startsWith(`=== ${dependency} `))) throw new Error(`Missing native dependency notices for ${dependency}`);
}
fs.writeFileSync(output, heading + '\n' + sections.join('\n'), 'utf8');
