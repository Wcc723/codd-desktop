#!/usr/bin/env node
// Regenerates ../hooks/session-insights-activity.golden.json.
//
// Imports the ORIGINAL, unmodified apps/server/src/services/session-insights.js and runs its public
// `enrichOne(record)` against crafted hook files (STATUS_DIR/term/<id>.hook.json) and Claude registry
// files (<claudeHome>/sessions/<pid>.json) written into a fresh temp directory per scenario. Only the
// resulting `activity` object (the hook/registry merge, `_activity`) is recorded.
// Each scenario has at most one matching registry entry, so readdir order cannot affect the result.
//
// Usage: node gen-session-insights.mjs --web-repo <path> [--out <file>]
//   the CODD web repo (read-only) comes from --web-repo or $CODD_WEB_REPO; there is no default
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync, readFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// The constructor consults these; keep the real ~/.claude out of the picture.
delete process.env.CLAUDE_CONFIG_DIR;
delete process.env.CODD_CLAUDE_HOME;
delete process.env.STATUS_DIR_PATH;
delete process.env.STATUS_FILE_PATH;

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const argValue = (flag, fallback) => {
  const i = args.indexOf(flag);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
const webRepoArg = argValue('--web-repo', process.env.CODD_WEB_REPO);
if (!webRepoArg) {
  console.error('gen-session-insights.mjs: pass --web-repo <path to the CODD web repo> or set CODD_WEB_REPO');
  process.exit(2);
}
const webRepo = resolve(webRepoArg);
const outFile = resolve(argValue('--out', join(here, '..', 'hooks', 'session-insights-activity.golden.json')));
const modulePath = join(webRepo, 'apps/server/src/services/session-insights.js');
const { SessionInsights } = await import(pathToFileURL(modulePath).href);

const TID = '7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17';
const OTHER_TID = '9d2f0b15-6c3e-4f9a-8b42-1d7e3f5a9c28';
const SID = '11111111-aaaa-4aaa-8aaa-111111111111';
const PID = 48211;
const T0 = Date.parse('2026-10-15T02:42:00.000Z');
const iso = (dtMs) => new Date(T0 + dtMs).toISOString();

function hook(fields) {
  return {
    v: 2,
    codd_terminal_id: TID,
    config_dir: null,
    session_id: SID,
    transcript_path: null,
    cwd: '/synthetic/project',
    event: 'UserPromptSubmit',
    state: 'busy',
    state_since: iso(0),
    waiting_reason: null,
    last_event_at: iso(0),
    last_tool: 'Bash',
    tool_count: 3,
    last_prompt: null,
    last_prompt_at: null,
    custom_title: null,
    ...fields,
  };
}

function reg(fields) {
  return {
    pid: PID,
    sessionId: SID,
    cwd: '/synthetic/project',
    startedAt: T0 - 60000,
    procStart: 'Thu Oct 15 02:41:00 2026', // ps -o lstart in UTC, as Claude writes it
    version: '2.1.300',
    kind: 'interactive',
    entrypoint: 'cli',
    name: 'synthetic',
    nameSource: 'derived',
    status: 'idle',
    statusUpdatedAt: T0,
    updatedAt: T0,
    ...fields,
  };
}

const running = { status: 'running', pid: PID };

const scenarios = [
  { name: 'exited_record', record: { status: 'exited', pid: PID, exited_at: iso(5000) }, hook: hook({}), registry: [] },
  { name: 'exited_record_no_hook', record: { status: 'exited', pid: PID, exited_at: iso(5000) }, hook: null, registry: [] },
  { name: 'exited_record_bad_time', record: { status: 'exited', pid: PID, exited_at: 'not a date' }, hook: hook({ last_tool: '  Edit  ' }), registry: [] },
  { name: 'hook_busy_no_registry', record: running, hook: hook({}), registry: [] },
  { name: 'hook_ended_alive_is_idle', record: running, hook: hook({ state: 'ended', state_since: iso(1000) }), registry: [] },
  { name: 'hook_ended_ignores_newer_registry', record: running, hook: hook({ state: 'ended' }), registry: [{ file: `${PID}.json`, body: reg({ status: 'busy', statusUpdatedAt: T0 + 10000 }) }] },
  { name: 'hook_waiting_permission', record: running, hook: hook({ state: 'waiting', waiting_reason: 'permission' }), registry: [] },
  { name: 'hook_waiting_plan', record: running, hook: hook({ state: 'waiting', waiting_reason: 'plan' }), registry: [] },
  { name: 'hook_waiting_bogus_reason', record: running, hook: hook({ state: 'waiting', waiting_reason: 'bogus' }), registry: [] },
  { name: 'hook_busy_reason_dropped', record: running, hook: hook({ state: 'busy', waiting_reason: 'permission' }), registry: [] },
  { name: 'registry_idle_newer_overrides_busy', record: running, hook: hook({}), registry: [{ file: `${PID}.json`, body: reg({ status: 'idle', statusUpdatedAt: T0 + 1500 }) }] },
  { name: 'registry_idle_within_margin_keeps_busy', record: running, hook: hook({}), registry: [{ file: `${PID}.json`, body: reg({ status: 'idle', statusUpdatedAt: T0 + 1000 }) }] },
  { name: 'registry_idle_just_over_margin', record: running, hook: hook({}), registry: [{ file: `${PID}.json`, body: reg({ status: 'idle', statusUpdatedAt: T0 + 1001 }) }] },
  { name: 'registry_busy_newer_overrides_waiting', record: running, hook: hook({ state: 'waiting', waiting_reason: 'permission' }), registry: [{ file: `${PID}.json`, body: reg({ status: 'busy', statusUpdatedAt: T0 + 4000 }) }] },
  { name: 'registry_idle_newer_overrides_waiting', record: running, hook: hook({ state: 'waiting', waiting_reason: 'question' }), registry: [{ file: `${PID}.json`, body: reg({ status: 'idle', statusUpdatedAt: T0 + 4000 }) }] },
  { name: 'registry_waiting_never_overrides', record: running, hook: hook({}), registry: [{ file: `${PID}.json`, body: reg({ status: 'waiting', waitingFor: 'permission prompt', statusUpdatedAt: T0 + 9000 }) }] },
  { name: 'registry_same_state_keeps_hook', record: running, hook: hook({ state: 'idle' }), registry: [{ file: `${PID}.json`, body: reg({ status: 'idle', statusUpdatedAt: T0 + 9000 }) }] },
  { name: 'registry_older_keeps_hook', record: running, hook: hook({ state: 'idle', last_event_at: iso(5000) }), registry: [{ file: `${PID}.json`, body: reg({ status: 'busy', statusUpdatedAt: T0 }) }] },
  { name: 'registry_seconds_timestamp', record: running, hook: hook({}), registry: [{ file: `${PID}.json`, body: reg({ status: 'idle', statusUpdatedAt: (T0 + 3000) / 1000 }) }] },
  { name: 'registry_fractional_seconds_timestamp', record: running, hook: hook({}), registry: [{ file: `${PID}.json`, body: reg({ status: 'idle', statusUpdatedAt: (T0 + 3456.7) / 1000 }) }] },
  { name: 'registry_iso_timestamp', record: running, hook: hook({}), registry: [{ file: `${PID}.json`, body: reg({ status: 'idle', statusUpdatedAt: iso(2500) }) }] },
  { name: 'registry_updatedAt_fallback', record: running, hook: hook({}), registry: [{ file: `${PID}.json`, body: reg({ status: 'idle', statusUpdatedAt: null, updatedAt: T0 + 7000 }) }] },
  { name: 'registry_no_timestamp', record: running, hook: hook({}), registry: [{ file: `${PID}.json`, body: reg({ status: 'idle', statusUpdatedAt: undefined, updatedAt: undefined }) }] },
  { name: 'registry_status_trimmed', record: running, hook: hook({}), registry: [{ file: `${PID}.json`, body: reg({ status: '  idle ', statusUpdatedAt: T0 + 5000 }) }] },
  { name: 'hook_bad_last_event_at', record: running, hook: hook({ last_event_at: 'garbage' }), registry: [{ file: `${PID}.json`, body: reg({ status: 'idle', statusUpdatedAt: T0 + 5000 }) }] },
  { name: 'hook_bad_state_since', record: running, hook: hook({ state_since: 'garbage' }), registry: [] },
  { name: 'hook_state_null_uses_registry', record: running, hook: hook({ state: null, event: 'Notification' }), registry: [{ file: `${PID}.json`, body: reg({ status: 'busy', statusUpdatedAt: T0 + 1 }) }] },
  { name: 'hook_state_unknown_string_uses_registry', record: running, hook: hook({ state: 'error' }), registry: [{ file: `${PID}.json`, body: reg({ status: 'idle' }) }] },
  { name: 'hook_state_compacting_no_registry', record: running, hook: hook({ state: 'compacting' }), registry: [] },
  { name: 'no_hook_registry_waiting', record: running, hook: null, registry: [{ file: `${PID}.json`, body: reg({ status: 'waiting', waitingFor: 'input needed', statusUpdatedAt: T0 + 2000 }) }] },
  { name: 'no_hook_registry_busy', record: running, hook: null, registry: [{ file: `${PID}.json`, body: reg({ status: 'busy', statusUpdatedAt: T0 + 2000 }) }] },
  { name: 'no_hook_registry_unknown_status', record: running, hook: null, registry: [{ file: `${PID}.json`, body: reg({ status: 'parked', statusUpdatedAt: T0 + 2000 }) }] },
  { name: 'no_hook_registry_missing_status', record: running, hook: null, registry: [{ file: `${PID}.json`, body: reg({ status: undefined }) }] },
  { name: 'no_hook_no_registry', record: running, hook: null, registry: [] },
  { name: 'registry_match_by_session_id', record: { status: 'running', pid: 777 }, hook: hook({}), registry: [{ file: '90001.json', body: reg({ pid: 90001, status: 'idle', statusUpdatedAt: T0 + 5000 }) }] },
  { name: 'registry_no_match', record: { status: 'running', pid: 777 }, hook: hook({ session_id: 'ffffffff-0000-4000-8000-ffffffffffff' }), registry: [{ file: '90001.json', body: reg({ pid: 90001, status: 'idle', statusUpdatedAt: T0 + 5000 }) }] },
  { name: 'registry_match_by_record_claude_session_id', record: { status: 'running', pid: 777, claude_session_id: SID }, hook: null, registry: [{ file: '90001.json', body: reg({ pid: 90001, status: 'busy' }) }] },
  { name: 'registry_pid_string_not_matched', record: running, hook: null, registry: [{ file: `${PID}.json`, body: reg({ pid: String(PID), sessionId: 'other', status: 'busy' }) }] },
  { name: 'registry_non_numeric_filename_ignored', record: running, hook: null, registry: [{ file: `${PID}.backup.json`, body: reg({ status: 'busy' }) }] },
  { name: 'registry_corrupt_file_ignored', record: running, hook: null, registry: [{ file: `${PID}.json`, raw: '{oops' }] },
  { name: 'hook_from_other_terminal_ignored', record: running, hook: hook({ codd_terminal_id: OTHER_TID }), registry: [{ file: `${PID}.json`, body: reg({ status: 'idle', statusUpdatedAt: T0 + 3000 }) }] },
  { name: 'hook_without_terminal_id_belongs', record: running, hook: hook({ codd_terminal_id: null }), registry: [] },
  { name: 'hook_tool_count_invalid', record: running, hook: hook({ tool_count: -2, last_tool: '   ' }), registry: [] },
  { name: 'hook_tool_count_fraction', record: running, hook: hook({ tool_count: 1.5 }), registry: [] },
];

async function runScenario(sc) {
  const dir = mkdtempSync(join(tmpdir(), 'codd-insights-'));
  try {
    const statusDir = join(dir, 'status');
    const claudeHome = join(dir, 'claude');
    mkdirSync(join(statusDir, 'term'), { recursive: true });
    mkdirSync(join(claudeHome, 'sessions'), { recursive: true });
    if (sc.hook) writeFileSync(join(statusDir, 'term', `${TID}.hook.json`), JSON.stringify(sc.hook, null, 2));
    for (const r of sc.registry) {
      writeFileSync(join(claudeHome, 'sessions', r.file), r.raw ?? JSON.stringify(r.body));
    }
    const insights = new SessionInsights({ statusDir, claudeHome });
    const record = { id: TID, cwd: '/synthetic/project', ...sc.record };
    const out = await insights.enrichOne(record);
    return {
      name: sc.name,
      record: sc.record,
      hook: sc.hook,
      registry: sc.registry.map(r => (r.raw !== undefined ? { file: r.file, raw: r.raw } : { file: r.file, body: JSON.parse(JSON.stringify(r.body)) })),
      expected: out.activity,
    };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function gitCommit(repo) {
  try { return execFileSync('git', ['-C', repo, 'rev-parse', '--short', 'HEAD'], { encoding: 'utf8' }).trim(); } catch { return null; }
}

const results = [];
for (const sc of scenarios) results.push(await runScenario(sc));

const golden = {
  comment: 'GENERATED by gen/gen-session-insights.mjs from the original session-insights.js. Do not edit by hand.',
  source: {
    file: 'apps/server/src/services/session-insights.js',
    commit: gitCommit(webRepo),
    sha256: createHash('sha256').update(readFileSync(modulePath)).digest('hex'),
  },
  node: process.version,
  terminalId: TID,
  scenarios: results,
};
mkdirSync(dirname(outFile), { recursive: true });
writeFileSync(outFile, JSON.stringify(golden, null, 2) + '\n');
console.log(`wrote ${outFile}: ${results.length} scenarios (source ${golden.source.commit} ${golden.source.sha256.slice(0, 12)})`);
