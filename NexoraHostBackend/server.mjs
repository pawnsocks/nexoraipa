import http from 'node:http';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { URL } from 'node:url';

const execFileAsync = promisify(execFile);
const VERSION = '0.1.0';
const HOST = process.env.HOST || '0.0.0.0';
const PORT = Number(process.env.PORT || 8787);
const OWNER_TOKEN = process.env.NEXORA_OWNER_TOKEN || '';
const DATA_DIR = path.resolve(process.env.NEXORA_DATA_DIR || './data');
const PROJECTS_DIR = path.join(DATA_DIR, 'projects');
const STATE_FILE = path.join(DATA_DIR, 'state.json');
const PUBLIC_HOST = process.env.NEXORA_PUBLIC_HOST || '';
const PUBLIC_SCHEME = process.env.NEXORA_PUBLIC_SCHEME || 'http';
const GITHUB_TOKEN = process.env.GITHUB_TOKEN || '';
const ALLOW_ROOT = process.env.NEXORA_ALLOW_ROOT === '1';

if (!OWNER_TOKEN || OWNER_TOKEN === 'replace-me') {
  console.error('NEXORA_OWNER_TOKEN must be configured before starting Nexora Host.');
  process.exit(1);
}

await fs.mkdir(PROJECTS_DIR, { recursive: true });

let state = await loadState();
const tasks = new Map();
const taskChildren = new Map();
const processes = new Map();
const logs = new Map();

function nowISO() { return new Date().toISOString(); }
function id(prefix) { return `${prefix}_${crypto.randomUUID()}`; }

async function loadState() {
  try {
    const raw = await fs.readFile(STATE_FILE, 'utf8');
    const parsed = JSON.parse(raw);
    return { projects: parsed.projects || [] };
  } catch {
    return { projects: [] };
  }
}

async function persistState() {
  await fs.mkdir(DATA_DIR, { recursive: true });
  await fs.writeFile(STATE_FILE, JSON.stringify(state, null, 2));
}

function projectRoot(project) { return path.join(PROJECTS_DIR, project.id, 'repo'); }
function projectById(projectId) { return state.projects.find(p => p.id === projectId); }
function safeRelative(raw = '') {
  const decoded = decodeURIComponent(raw || '').replaceAll('\\', '/');
  const normalized = path.posix.normalize('/' + decoded).slice(1);
  if (normalized === '..' || normalized.startsWith('../') || normalized.includes('\0')) throw new Error('Invalid path');
  return normalized === '.' ? '' : normalized;
}
function resolveInside(root, relative = '') {
  const target = path.resolve(root, safeRelative(relative));
  if (target !== root && !target.startsWith(root + path.sep)) throw new Error('Path escapes project workspace');
  return target;
}
function stripCredentials(url) {
  try {
    const u = new URL(url);
    u.username = '';
    u.password = '';
    return u.toString().replace(/\/$/, '');
  } catch { return url; }
}
function projectLog(projectId, level, message) {
  const line = { id: id('log'), timestamp: nowISO(), level, message: String(message) };
  const list = logs.get(projectId) || [];
  list.push(line);
  if (list.length > 2000) list.splice(0, list.length - 2000);
  logs.set(projectId, list);
}

function send(res, status, body = null) {
  const data = body === null ? '' : JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(data),
    'cache-control': 'no-store'
  });
  res.end(data);
}
function ok(res, body = { ok: true }) { send(res, 200, body); }
function fail(res, status, message) { send(res, status, { error: true, message }); }

function authorized(req) {
  const value = req.headers.authorization || '';
  return value === `Bearer ${OWNER_TOKEN}`;
}

async function bodyJSON(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 10 * 1024 * 1024) throw new Error('Request body too large');
    chunks.push(chunk);
  }
  if (!chunks.length) return {};
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function publicPreviewURL(port) {
  if (!port || !PUBLIC_HOST) return null;
  const defaultPort = (PUBLIC_SCHEME === 'https' && port === 443) || (PUBLIC_SCHEME === 'http' && port === 80);
  return `${PUBLIC_SCHEME}://${PUBLIC_HOST}${defaultPort ? '' : ':' + port}`;
}

async function detectProject(project) {
  const root = projectRoot(project);
  const exists = async f => { try { await fs.access(path.join(root, f)); return true; } catch { return false; } };
  const readJSON = async f => { try { return JSON.parse(await fs.readFile(path.join(root, f), 'utf8')); } catch { return null; } };

  let runtime = 'Unknown';
  let framework = null;
  let packageManager = null;
  let startCommand = null;
  let entrypoint = null;

  const pkg = await readJSON('package.json');
  if (pkg) {
    runtime = (await exists('bun.lockb')) || (await exists('bun.lock')) ? 'Bun' : 'Node.js';
    packageManager = runtime === 'Bun' ? 'bun' : (await exists('pnpm-lock.yaml')) ? 'pnpm' : (await exists('yarn.lock')) ? 'yarn' : 'npm';
    const deps = { ...(pkg.dependencies || {}), ...(pkg.devDependencies || {}) };
    if (deps.next) framework = 'Next.js';
    else if (deps.vite) framework = 'Vite';
    else if (deps.react) framework = 'React';
    else if (deps['discord.js'] || deps.eris) framework = 'Discord Bot';
    else if (deps.express || deps.fastify || deps.koa) framework = 'Node API';
    const scripts = pkg.scripts || {};
    if (scripts.dev) startCommand = packageManager === 'npm' ? 'npm run dev' : `${packageManager} run dev`;
    else if (scripts.start) startCommand = packageManager === 'npm' ? 'npm start' : `${packageManager} run start`;
    entrypoint = pkg.main || (await exists('src/index.ts') ? 'src/index.ts' : await exists('index.ts') ? 'index.ts' : await exists('index.js') ? 'index.js' : null);
  } else if (await exists('pyproject.toml') || await exists('requirements.txt') || await exists('main.py') || await exists('app.py')) {
    runtime = 'Python';
    packageManager = await exists('uv.lock') ? 'uv' : 'pip';
    entrypoint = await exists('main.py') ? 'main.py' : await exists('app.py') ? 'app.py' : null;
    let py = '';
    try { py = await fs.readFile(path.join(root, entrypoint || 'main.py'), 'utf8'); } catch {}
    if (/FastAPI\s*\(/.test(py)) { framework = 'FastAPI'; startCommand = '.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000'; }
    else if (/Flask\s*\(/.test(py)) { framework = 'Flask'; startCommand = '.venv/bin/python ' + (entrypoint || 'app.py'); }
    else startCommand = `.venv/bin/python ${entrypoint || 'main.py'}`;
  } else if (await exists('Cargo.toml')) {
    runtime = 'Rust'; packageManager = 'cargo'; startCommand = 'cargo run'; entrypoint = 'src/main.rs';
  } else if (await exists('go.mod')) {
    runtime = 'Go'; packageManager = 'go'; startCommand = 'go run .'; entrypoint = await exists('main.go') ? 'main.go' : null;
  } else if (await exists('pom.xml') || await exists('build.gradle') || await exists('build.gradle.kts')) {
    runtime = 'Java'; packageManager = await exists('pom.xml') ? 'maven' : 'gradle';
    startCommand = packageManager === 'maven' ? 'mvn spring-boot:run' : './gradlew run';
  } else {
    const names = await fs.readdir(root).catch(() => []);
    const csproj = names.find(n => n.endsWith('.csproj'));
    if (csproj) { runtime = '.NET'; packageManager = 'dotnet'; startCommand = 'dotnet run'; entrypoint = 'Program.cs'; }
    else if (await exists('main.lua')) { runtime = 'Lua'; startCommand = 'lua main.lua'; entrypoint = 'main.lua'; }
    else if (await exists('compose.yaml') || await exists('docker-compose.yml')) { runtime = 'Docker'; startCommand = 'docker compose up'; entrypoint = await exists('compose.yaml') ? 'compose.yaml' : 'docker-compose.yml'; }
    else if (await exists('index.html')) { runtime = 'Static'; framework = 'Static Website'; startCommand = 'python3 -m http.server 8080 --bind 0.0.0.0'; entrypoint = 'index.html'; }
  }

  Object.assign(project, { runtime, framework, packageManager, startCommand, entrypoint, updatedAt: nowISO() });
  await refreshGitMetadata(project);
  await persistState();
  return project;
}

async function refreshGitMetadata(project) {
  const root = projectRoot(project);
  try {
    const { stdout: branch } = await execFileAsync('git', ['-C', root, 'branch', '--show-current']);
    project.branch = branch.trim() || project.branch || 'main';
    const { stdout: commit } = await execFileAsync('git', ['-C', root, 'log', '-1', '--pretty=%h %s']);
    project.latestCommit = commit.trim();
  } catch {}
}

function templateFiles(template) {
  const key = String(template || '').toLowerCase();
  if (key.includes('python') || key.includes('fastapi') || key.includes('flask')) {
    const fast = key.includes('fastapi');
    const flask = key.includes('flask');
    return {
      'main.py': fast ? 'from fastapi import FastAPI\n\napp = FastAPI()\n\n@app.get("/")\ndef root():\n    return {"ok": True}\n' : flask ? 'from flask import Flask\n\napp = Flask(__name__)\n\n@app.get("/")\ndef root():\n    return {"ok": True}\n\napp.run(host="0.0.0.0", port=8000)\n' : 'print("Hello from Nexora Host")\n',
      'requirements.txt': fast ? 'fastapi\nuvicorn\n' : flask ? 'flask\n' : '',
      '.gitignore': '.venv/\n__pycache__/\n.env\n'
    };
  }
  if (key.includes('rust')) return { 'Cargo.toml': '[package]\nname = "nexora-app"\nversion = "0.1.0"\nedition = "2024"\n\n[dependencies]\n', 'src/main.rs': 'fn main() { println!("Hello from Nexora Host"); }\n' };
  if (key === 'go') return { 'go.mod': 'module nexora/app\n\ngo 1.23\n', 'main.go': 'package main\nimport "fmt"\nfunc main(){ fmt.Println("Hello from Nexora Host") }\n' };
  if (key.includes('lua')) return { 'main.lua': 'print("Hello from Nexora Host")\n' };
  if (key.includes('static')) return { 'index.html': '<!doctype html><meta name="viewport" content="width=device-width"><h1>Hello from Nexora Host</h1>\n' };
  if (key.includes('bun')) return { 'package.json': JSON.stringify({ scripts: { dev: 'bun run index.ts' } }, null, 2) + '\n', 'index.ts': 'console.log("Hello from Nexora Host Bun")\n' };
  if (key.includes('discord')) return { 'package.json': JSON.stringify({ scripts: { start: 'node index.js' }, dependencies: { 'discord.js': '^14.0.0' } }, null, 2) + '\n', 'index.js': 'console.log("Configure DISCORD_TOKEN in the Nexora Host secret vault before starting.")\n' };
  return { 'package.json': JSON.stringify({ scripts: { start: 'node index.js' } }, null, 2) + '\n', 'index.js': 'console.log("Hello from Nexora Host Node.js")\n', '.gitignore': 'node_modules/\n.env\n' };
}

async function writeTemplate(root, template) {
  for (const [rel, content] of Object.entries(templateFiles(template))) {
    const target = resolveInside(root, rel);
    await fs.mkdir(path.dirname(target), { recursive: true });
    await fs.writeFile(target, content);
  }
}

function setupCommand(project) {
  switch (project.packageManager) {
    case 'bun': return 'bun install';
    case 'pnpm': return 'pnpm install';
    case 'yarn': return 'yarn install';
    case 'npm': return 'npm install';
    case 'uv': return 'uv sync';
    case 'pip': return 'python3 -m venv .venv && .venv/bin/pip install -r requirements.txt';
    case 'cargo': return 'cargo fetch';
    case 'go': return 'go mod download';
    case 'maven': return 'mvn dependency:go-offline';
    case 'gradle': return './gradlew dependencies';
    case 'dotnet': return 'dotnet restore';
    default: return null;
  }
}

function dangerousCommand(command) {
  return /(^|\s)(sudo|su)(\s|$)|rm\s+-rf\s+\/|mkfs|:\(\)\s*\{|dd\s+if=|shutdown|reboot|git\s+reset\s+--hard|git\s+clean\s+-fdx/i.test(command);
}

function rootExecutionBlocked() {
  return typeof process.getuid === 'function' && process.getuid() === 0 && !ALLOW_ROOT;
}

function newTask(projectId, kind, command, currentStep = 'Queued') {
  const task = {
    id: id('task'), projectID: projectId || null, kind, status: 'queued', command: command || null,
    output: '', exitCode: null, currentStep, startedAt: nowISO(), finishedAt: null
  };
  tasks.set(task.id, task);
  return task;
}

function appendTask(task, chunk, projectId, level = 'info') {
  const text = String(chunk);
  task.output += text;
  if (task.output.length > 500_000) task.output = task.output.slice(-500_000);
  if (projectId) {
    for (const line of text.split(/\r?\n/)) if (line) projectLog(projectId, level, line);
  }
}

function runTask(project, kind, command, { confirmed = false, env = {} } = {}) {
  if (rootExecutionBlocked()) throw new Error("Backend is running as root. Install/run the service as the restricted 'nexora' user or explicitly set NEXORA_ALLOW_ROOT=1.");
  if (dangerousCommand(command) && !confirmed) throw new Error('Destructive command requires explicit confirmation.');

  const task = newTask(project?.id, kind, command, 'Starting');
  const cwd = project ? projectRoot(project) : DATA_DIR;
  const child = spawn('/bin/bash', ['-lc', command], {
    cwd,
    env: { ...process.env, ...env, FORCE_COLOR: '0' },
    detached: false,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  taskChildren.set(task.id, child);
  task.status = 'running';
  task.currentStep = 'Running';
  child.stdout.on('data', chunk => appendTask(task, chunk, project?.id, 'info'));
  child.stderr.on('data', chunk => appendTask(task, chunk, project?.id, 'error'));
  child.on('close', code => {
    task.exitCode = code ?? -1;
    task.status = code === 0 ? 'completed' : 'failed';
    task.currentStep = task.status === 'completed' ? 'Finished' : 'Failed';
    task.finishedAt = nowISO();
    taskChildren.delete(task.id);
  });
  child.on('error', error => {
    appendTask(task, `\n${error.message}\n`, project?.id, 'error');
    task.exitCode = -1;
    task.status = 'failed';
    task.currentStep = 'Failed to launch';
    task.finishedAt = nowISO();
    taskChildren.delete(task.id);
  });
  return task;
}

async function startProject(project, restart = false) {
  if (!project.startCommand) await detectProject(project);
  if (!project.startCommand) throw new Error('Nexora Host could not detect a start command. Use Terminal or configure the project first.');
  if (restart) await stopProject(project.id);
  if (processes.has(project.id)) throw new Error('Project is already running.');
  if (rootExecutionBlocked()) throw new Error("Backend is running as root. Run Nexora under the restricted 'nexora' user.");

  const task = newTask(project.id, restart ? 'restart' : 'start', project.startCommand, 'Launching process');
  const child = spawn('/bin/bash', ['-lc', project.startCommand], {
    cwd: projectRoot(project), env: { ...process.env, FORCE_COLOR: '0' }, stdio: ['ignore', 'pipe', 'pipe']
  });
  taskChildren.set(task.id, child);
  task.status = 'running';
  const proc = {
    id: `process_${project.id}`, projectID: project.id, projectName: project.name,
    pid: child.pid || null, command: project.startCommand, status: 'running', port: null,
    uptimeSeconds: 0, cpuPercent: null, memoryMB: null, previewURL: null,
    startedAtMs: Date.now(), child
  };
  processes.set(project.id, proc);
  project.status = 'running';
  project.updatedAt = nowISO();
  await persistState();
  projectLog(project.id, 'info', `Started: ${project.startCommand}`);

  const observe = (chunk, level) => {
    appendTask(task, chunk, project.id, level);
    const text = String(chunk);
    const match = text.match(/(?:localhost|127\.0\.0\.1|0\.0\.0\.0|:\s*)(?::)?(\d{2,5})\b|https?:\/\/[^\s:]+:(\d{2,5})/i);
    const port = Number(match?.[1] || match?.[2] || 0);
    if (port > 0 && port < 65536) {
      proc.port = port;
      proc.previewURL = publicPreviewURL(port);
      project.port = port;
      project.previewURL = proc.previewURL;
      persistState().catch(() => {});
    }
  };
  child.stdout.on('data', chunk => observe(chunk, 'info'));
  child.stderr.on('data', chunk => observe(chunk, 'error'));
  child.on('close', code => {
    proc.status = code === 0 ? 'stopped' : 'failed';
    task.exitCode = code ?? -1;
    task.status = code === 0 ? 'completed' : 'failed';
    task.currentStep = 'Process exited';
    task.finishedAt = nowISO();
    taskChildren.delete(task.id);
    processes.delete(project.id);
    project.status = proc.status;
    project.updatedAt = nowISO();
    projectLog(project.id, code === 0 ? 'info' : 'error', `Process exited with code ${code}`);
    persistState().catch(() => {});
  });
  child.on('error', error => {
    appendTask(task, error.message, project.id, 'error');
    task.status = 'failed'; task.currentStep = 'Launch failed'; task.finishedAt = nowISO();
    processes.delete(project.id); project.status = 'error'; persistState().catch(() => {});
  });

  setTimeout(() => detectListeningPort(proc, project).catch(() => {}), 1500);
  return task;
}

async function detectListeningPort(proc, project) {
  if (!proc.pid || proc.port) return;
  try {
    const { stdout } = await execFileAsync('ss', ['-ltnp']);
    const lines = stdout.split('\n').filter(line => line.includes(`pid=${proc.pid},`));
    for (const line of lines) {
      const match = line.match(/:(\d+)\s+/);
      if (match) {
        const port = Number(match[1]);
        proc.port = port;
        proc.previewURL = publicPreviewURL(port);
        project.port = port;
        project.previewURL = proc.previewURL;
        await persistState();
        return;
      }
    }
  } catch {}
}

async function stopProject(projectId) {
  const proc = processes.get(projectId);
  const project = projectById(projectId);
  if (!proc) {
    if (project) { project.status = 'stopped'; project.updatedAt = nowISO(); await persistState(); }
    return;
  }
  try { proc.child.kill('SIGTERM'); } catch {}
  setTimeout(() => { try { if (!proc.child.killed) proc.child.kill('SIGKILL'); } catch {} }, 5000);
  processes.delete(projectId);
  if (project) { project.status = 'stopped'; project.updatedAt = nowISO(); await persistState(); }
  projectLog(projectId, 'info', 'Stop requested');
}

function serializeProcess(proc) {
  return {
    id: proc.id, projectID: proc.projectID, projectName: proc.projectName,
    pid: proc.pid, command: proc.command, status: proc.status, port: proc.port,
    uptimeSeconds: Math.max(0, (Date.now() - proc.startedAtMs) / 1000),
    cpuPercent: proc.cpuPercent, memoryMB: proc.memoryMB, previewURL: proc.previewURL
  };
}

async function listFiles(project, relative) {
  const root = projectRoot(project);
  const dir = resolveInside(root, relative || '');
  const entries = await fs.readdir(dir, { withFileTypes: true });
  const result = [];
  for (const item of entries) {
    if (item.name === '.git') continue;
    const target = path.join(dir, item.name);
    const stat = await fs.stat(target);
    const rel = path.relative(root, target).split(path.sep).join('/');
    result.push({ path: rel, name: item.name, isDirectory: item.isDirectory(), size: stat.size, modifiedAt: stat.mtime.toISOString() });
  }
  return result.sort((a, b) => Number(b.isDirectory) - Number(a.isDirectory) || a.name.localeCompare(b.name));
}

async function readFile(project, relative) {
  const target = resolveInside(projectRoot(project), relative);
  const data = await fs.readFile(target);
  if (data.includes(0)) return { path: safeRelative(relative), content: data.toString('base64'), encoding: 'base64' };
  return { path: safeRelative(relative), content: data.toString('utf8'), encoding: 'utf8' };
}

async function writeFile(project, relative, content, encoding = 'utf8') {
  const rel = safeRelative(relative);
  if (!rel) throw new Error('File path is required');
  const target = resolveInside(projectRoot(project), rel);
  await fs.mkdir(path.dirname(target), { recursive: true });
  const data = encoding === 'base64' ? Buffer.from(content, 'base64') : Buffer.from(content, 'utf8');
  if (data.length > 8 * 1024 * 1024) throw new Error('File is larger than 8 MB');
  await fs.writeFile(target, data);
  project.updatedAt = nowISO(); await persistState();
  projectLog(project.id, 'info', `Updated file ${rel}`);
  return readFile(project, rel);
}

async function gitStatus(project) {
  const root = projectRoot(project);
  const run = async args => (await execFileAsync('git', ['-C', root, ...args])).stdout.trim();
  const branch = await run(['branch', '--show-current']).catch(() => project.branch || 'main');
  const porcelain = await run(['status', '--porcelain']).catch(() => '');
  const changed = porcelain ? porcelain.split('\n').filter(Boolean).map(line => line.slice(3)) : [];
  const latestCommit = await run(['log', '-1', '--pretty=%h %s']).catch(() => null);
  let ahead = null, behind = null;
  try {
    const counts = await run(['rev-list', '--left-right', '--count', `origin/${branch}...${branch}`]);
    const [behindRaw, aheadRaw] = counts.split(/\s+/).map(Number);
    ahead = aheadRaw; behind = behindRaw;
  } catch {}
  return { branch, clean: changed.length === 0, changed, ahead, behind, latestCommit };
}

async function cloneRepository({ url, branch, name }) {
  const parsed = new URL(url);
  if (!['https:', 'http:'].includes(parsed.protocol) || parsed.hostname !== 'github.com') throw new Error('Only GitHub HTTPS repository URLs are accepted in Phase 1.');
  const repoName = (name || path.basename(parsed.pathname, '.git')).replace(/[^a-zA-Z0-9._-]/g, '-').slice(0, 80);
  if (!repoName) throw new Error('Invalid project name');
  const project = {
    id: id('project'), name: repoName, repoURL: stripCredentials(url), branch: branch || 'main',
    runtime: 'Detecting', framework: null, packageManager: null, status: 'stopped',
    startCommand: null, entrypoint: null, port: null, previewURL: null, latestCommit: null,
    createdAt: nowISO(), updatedAt: nowISO()
  };
  const root = projectRoot(project);
  await fs.mkdir(path.dirname(root), { recursive: true });
  const args = [];
  if (GITHUB_TOKEN) args.push('-c', `http.extraHeader=Authorization: Bearer ${GITHUB_TOKEN}`);
  args.push('clone', '--depth', '1');
  if (branch) args.push('--branch', branch);
  args.push(url, root);
  await execFileAsync('git', args, { maxBuffer: 10 * 1024 * 1024 });
  state.projects.unshift(project);
  await detectProject(project);
  projectLog(project.id, 'info', `Cloned ${project.repoURL}`);
  return project;
}

async function createEmptyProject({ name, template }) {
  const clean = String(name || '').trim().replace(/[^a-zA-Z0-9._ -]/g, '').slice(0, 80);
  if (!clean) throw new Error('Project name is required');
  const project = {
    id: id('project'), name: clean, repoURL: null, branch: 'main', runtime: 'Detecting', framework: null,
    packageManager: null, status: 'stopped', startCommand: null, entrypoint: null, port: null,
    previewURL: null, latestCommit: null, createdAt: nowISO(), updatedAt: nowISO()
  };
  const root = projectRoot(project);
  await fs.mkdir(root, { recursive: true });
  await writeTemplate(root, template);
  await execFileAsync('git', ['-C', root, 'init', '-b', 'main']).catch(() => {});
  await execFileAsync('git', ['-C', root, 'add', '.']).catch(() => {});
  await execFileAsync('git', ['-C', root, '-c', 'user.name=Nexora Host', '-c', 'user.email=nexora@localhost', 'commit', '-m', 'Initial project']).catch(() => {});
  state.projects.unshift(project);
  await detectProject(project);
  projectLog(project.id, 'info', `Created ${template || 'empty'} project`);
  return project;
}

async function runtimeInventory() {
  const commands = [
    ['Node.js', 'node', ['--version']], ['Bun', 'bun', ['--version']], ['Python', 'python3', ['--version']],
    ['Lua', 'lua', ['-v']], ['Go', 'go', ['version']], ['Rust', 'rustc', ['--version']], ['Java', 'java', ['-version']],
    ['.NET', 'dotnet', ['--version']], ['Ruby', 'ruby', ['--version']], ['PHP', 'php', ['--version']],
    ['Git', 'git', ['--version']], ['Docker', 'docker', ['--version']], ['C', 'gcc', ['--version']], ['C++', 'g++', ['--version']]
  ];
  const result = [];
  for (const [name, command, args] of commands) {
    try {
      const { stdout, stderr } = await execFileAsync(command, args, { timeout: 3000 });
      result.push({ name, installed: true, version: (stdout || stderr).trim().split('\n')[0], command });
    } catch {
      result.push({ name, installed: false, version: null, command });
    }
  }
  return result;
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const pathname = url.pathname;

    if (pathname === '/api/v1/health' && req.method === 'GET') {
      return ok(res, { ok: true, hostname: os.hostname(), version: VERSION, uptimeSeconds: process.uptime() });
    }
    if (!authorized(req)) return fail(res, 401, 'Unauthorized');

    if (pathname === '/api/v1/projects' && req.method === 'GET') {
      return ok(res, state.projects);
    }
    if (pathname === '/api/v1/projects/clone' && req.method === 'POST') {
      const input = await bodyJSON(req);
      const project = await cloneRepository(input);
      return send(res, 201, project);
    }
    if (pathname === '/api/v1/projects/create' && req.method === 'POST') {
      const input = await bodyJSON(req);
      const project = await createEmptyProject(input);
      return send(res, 201, project);
    }
    if (pathname === '/api/v1/tasks' && req.method === 'GET') {
      return ok(res, Array.from(tasks.values()).sort((a, b) => b.startedAt.localeCompare(a.startedAt)).slice(0, 200));
    }
    if (pathname === '/api/v1/processes' && req.method === 'GET') {
      return ok(res, Array.from(processes.values()).map(serializeProcess));
    }
    if (pathname === '/api/v1/runtimes' && req.method === 'GET') {
      return ok(res, await runtimeInventory());
    }

    let match = pathname.match(/^\/api\/v1\/tasks\/([^/]+)(?:\/(cancel))?$/);
    if (match) {
      const task = tasks.get(decodeURIComponent(match[1]));
      if (!task) return fail(res, 404, 'Task not found');
      if (match[2] === 'cancel' && req.method === 'POST') {
        const child = taskChildren.get(task.id);
        if (child) { try { child.kill('SIGTERM'); } catch {} }
        task.status = 'cancelled'; task.currentStep = 'Cancelled'; task.finishedAt = nowISO();
        return ok(res);
      }
      if (!match[2] && req.method === 'GET') return ok(res, task);
    }

    match = pathname.match(/^\/api\/v1\/projects\/([^/]+)(?:\/(.*))?$/);
    if (!match) return fail(res, 404, 'Endpoint not found');
    const projectId = decodeURIComponent(match[1]);
    const action = match[2] || '';
    const project = projectById(projectId);
    if (!project) return fail(res, 404, 'Project not found');

    if (!action && req.method === 'GET') {
      await refreshGitMetadata(project);
      const proc = processes.get(project.id);
      if (proc) {
        project.status = proc.status;
        project.port = proc.port;
        project.previewURL = proc.previewURL;
      }
      return ok(res, project);
    }

    if (action === 'files' && req.method === 'GET') {
      return ok(res, await listFiles(project, url.searchParams.get('path') || ''));
    }
    if (action === 'file') {
      const rel = url.searchParams.get('path') || '';
      if (req.method === 'GET') return ok(res, await readFile(project, rel));
      if (req.method === 'PUT' || req.method === 'POST') {
        const input = await bodyJSON(req);
        return ok(res, await writeFile(project, rel, input.content ?? '', input.encoding || 'utf8'));
      }
      if (req.method === 'DELETE') {
        const target = resolveInside(projectRoot(project), rel);
        const base = path.basename(target);
        if (base === '.git' || base === '.env') return fail(res, 403, 'Protected path');
        await fs.rm(target, { recursive: true, force: false });
        projectLog(project.id, 'warning', `Deleted ${safeRelative(rel)}`);
        return ok(res);
      }
    }
    if (action === 'folder' && req.method === 'POST') {
      const input = await bodyJSON(req);
      const target = resolveInside(projectRoot(project), input.path || '');
      await fs.mkdir(target, { recursive: true });
      return ok(res);
    }
    if (action === 'commands' && req.method === 'POST') {
      const input = await bodyJSON(req);
      if (!input.command || String(input.command).length > 20_000) return fail(res, 400, 'Command is required');
      const task = runTask(project, 'command', String(input.command), { confirmed: input.confirmed === true });
      return send(res, 202, task);
    }
    if (action === 'setup' && req.method === 'POST') {
      await detectProject(project);
      const command = setupCommand(project);
      if (!command) return fail(res, 422, 'No dependency install command detected for this project.');
      return send(res, 202, runTask(project, 'setup', command));
    }
    if (action === 'start' && req.method === 'POST') {
      return send(res, 202, await startProject(project, false));
    }
    if (action === 'stop' && req.method === 'POST') {
      await stopProject(project.id); return ok(res);
    }
    if (action === 'restart' && req.method === 'POST') {
      return send(res, 202, await startProject(project, true));
    }
    if (action === 'logs' && req.method === 'GET') {
      const limit = Math.min(1000, Math.max(1, Number(url.searchParams.get('limit') || 250)));
      return ok(res, (logs.get(project.id) || []).slice(-limit));
    }
    if (action === 'git/status' && req.method === 'GET') {
      return ok(res, await gitStatus(project));
    }
    if (action === 'git/pull' && req.method === 'POST') {
      return send(res, 202, runTask(project, 'git-pull', 'git pull --ff-only'));
    }
    if (action === 'git/commit' && req.method === 'POST') {
      const input = await bodyJSON(req);
      const message = String(input.message || '').trim();
      if (!message || message.length > 500) return fail(res, 400, 'Commit message is required');
      const safeMessage = `'${message.replaceAll("'", "'\\''")}'`;
      let command = `git add -A && git commit -m ${safeMessage}`;
      if (input.push === true) command += ' && git push';
      return send(res, 202, runTask(project, 'git-commit', command));
    }

    return fail(res, 404, 'Project endpoint not found');
  } catch (error) {
    console.error(error);
    return fail(res, 500, error?.message || String(error));
  }
});

server.listen(PORT, HOST, () => {
  console.log(`Nexora Host backend ${VERSION} listening on http://${HOST}:${PORT}`);
  console.log(`Data directory: ${DATA_DIR}`);
  if (rootExecutionBlocked()) console.warn("Command execution is disabled because Nexora Host is running as root. Install the systemd service as the 'nexora' user.");
});
