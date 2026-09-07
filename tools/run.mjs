// run.mjs -- boot the GameOS disk image inside a Lua 5.4 VM with the CC mock.
// usage: node run.mjs tests/<name>.lua [extra args...]
import { LuaFactory } from 'wasmoon';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const NL = String.fromCharCode(10);
const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const diskRoot = path.join(root, 'disk');
const outDir = path.join(here, 'out');
fs.mkdirSync(outDir, { recursive: true });

function collect(dir, base = '') {
  const map = {};
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const rel = base ? `${base}/${entry.name}` : entry.name;
    const abs = path.join(dir, entry.name);
    if (entry.isDirectory()) Object.assign(map, collect(abs, rel));
    else map[rel] = fs.readFileSync(abs, 'latin1');
  }
  return map;
}

const testFile = process.argv[2];
if (!testFile) {
  console.error('usage: node run.mjs tests/<name>.lua');
  process.exit(2);
}

const diskFiles = collect(diskRoot);

// Static lint: CC:Tweaked is Lua 5.2, and the pipeline is byte-sensitive.
let lintFailed = false;
for (const [name, src] of Object.entries(diskFiles)) {
  if (!name.endsWith('.lua')) continue;
  const lines = src.split(NL);
  lines.forEach((line, i) => {
    for (let k = 0; k < line.length; k++) {
      if (line.charCodeAt(k) > 126) {
        console.error(`NON-ASCII in ${name}:${i + 1} col ${k + 1}`);
        lintFailed = true;
        break;
      }
    }
    const stripped = line
      .replace(/--.*$/, '')
      .replace(/"(\\.|[^"\\])*"/g, '""')
      .replace(/'(\\.|[^'\\])*'/g, "''");
    if (/\/\//.test(stripped) || /<<|>>/.test(stripped)) {
      console.error(`LUA 5.3+ OPERATOR in ${name}:${i + 1}: ${line.trim()}`);
      lintFailed = true;
    }
    // Anything that differs between Lua 5.2 (CC:Tweaked) and 5.4 (test VM).
    const NONPORTABLE = /\bmath\.type\b|\btable\.move\b|\bstring\.pack\b|\butf8\.|\bmath\.atan2?\b|\bmath\.pow\b|\bmath\.ldexp\b|\bloadstring\b|\bsetfenv\b|\bgetfenv\b|\btable\.getn\b|(?<![.:\w])unpack\s*\(/;
    if (NONPORTABLE.test(stripped)) {
      console.error(`NON-PORTABLE in ${name}:${i + 1}: ${line.trim()}`);
      lintFailed = true;
    }
  });
}
if (lintFailed) process.exit(3);

const factory = new LuaFactory();
const lua = await factory.createEngine({ openStandardLibs: true });

const shots = [];
lua.global.set('__shot', (name, payload) => { shots.push({ name, payload }); });
lua.global.set('__log', (msg) => { console.log(msg); });
lua.global.set('__diskList', () => Object.keys(diskFiles).join(NL));
lua.global.set('__diskRead', (n) => diskFiles[n]);
// files at the repository root, so the installer bundle can be tested
lua.global.set('__rootRead', (n) => {
  const p = path.join(root, n);
  return fs.existsSync(p) ? fs.readFileSync(p, 'latin1') : null;
});
lua.global.set('__args', process.argv.slice(3).join(NL));

const prelude = fs.readFileSync(path.join(here, 'ccmock.lua'), 'latin1');
const harness = fs.readFileSync(path.join(here, 'harness.lua'), 'latin1');
const test = fs.readFileSync(path.join(here, testFile), 'latin1');

let code = 0;
try {
  await lua.doString(prelude);
  await lua.doString(harness);
  await lua.doString(test);
} catch (err) {
  console.error(NL + '=== LUA ERROR ===' + NL + (err && err.message ? err.message : String(err)));
  code = 1;
}

const stem = path.basename(testFile, '.lua');
if (shots.length) {
  const file = path.join(outDir, `${stem}.shots`);
  fs.writeFileSync(file, shots.map((s) => `@@${s.name}${NL}${s.payload}`).join(NL));
  console.log(`[${shots.length} screenshot(s) -> tools/out/${stem}.shots]`);
}
try { lua.global.close(); } catch (e) { /* ignore */ }
process.exit(code);
