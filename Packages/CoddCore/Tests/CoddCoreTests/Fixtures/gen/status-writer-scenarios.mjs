// Crafted hook event sequences fed to the ORIGINAL configs/hooks/status-writer.js.
// All paths and ids are synthetic. Each step is { dt, payload } (an object sent as JSON on stdin)
// or { dt, stdin } (raw stdin text, for malformed input). `dt` = milliseconds after the previous step.
// `seed` (optional) is raw JSON text written as the hook file before the first step.

export const TERMINAL_ID = '7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17';
export const START = '2026-10-15T02:42:00.000Z';

const SID_A = '11111111-aaaa-4aaa-8aaa-111111111111';
const SID_B = '22222222-bbbb-4bbb-8bbb-222222222222';
const SID_C = '33333333-cccc-4ccc-8ccc-333333333333';
const CWD = '/synthetic/Project/orb-toolkit-backend';

const transcript = (sid) => `/synthetic/.claude/projects/-synthetic-Project-orb-toolkit-backend/${sid}.jsonl`;

function ev(name, extra = {}, sid = SID_A) {
  return {
    hook_event_name: name,
    session_id: sid,
    transcript_path: transcript(sid),
    cwd: CWD,
    permission_mode: 'default',
    ...extra,
  };
}

const step = (payload, dt = 1500) => ({ dt, payload });
const raw = (stdin, dt = 1500) => ({ dt, stdin });

const LONG_PROMPT = '請幫我把登入 API 的 401 修好。'.repeat(30) + 'end'; // > 500 code points
const EMOJI_PROMPT = '\u{1F600}'.repeat(499) + '\u{1F44D}\u{1F3FD}tail'; // surrogate pairs at the cut
const LONG_TITLE = '標題'.repeat(150); // 300 code points > 200

export const scenarios = [
  {
    name: 'startup_permission_tool_cycle',
    steps: [
      step(ev('SessionStart', { source: 'startup', model: 'claude-opus-5-5' })),
      step(ev('UserPromptSubmit', { prompt: '修正登入 API 401' })),
      step(ev('PreToolUse', { tool_name: 'Bash', tool_input: { command: 'npm test -- auth.spec.ts' }, tool_use_id: 'toolu_1' })),
      step(ev('PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'npm test -- auth.spec.ts' } })),
      step(ev('Notification', { notification_type: 'permission_prompt', message: 'Claude needs your permission to use Bash' }), 6000),
      step(ev('PostToolUse', { tool_name: 'Bash', tool_use_id: 'toolu_1', tool_response: { stdout: 'ok' } }), 4000),
      step(ev('PreToolUse', { tool_name: 'Edit', tool_input: { file_path: '/synthetic/a.ts' } })),
      step(ev('PostToolUseFailure', { tool_name: 'Edit', error: 'String not found' })),
      step(ev('PreToolUse', { tool_name: 'Edit' })),
      step(ev('PostToolUse', { tool_name: 'Edit' })),
      step(ev('Stop', { stop_hook_active: false, last_assistant_message: 'Done.' })),
      step(ev('Notification', { notification_type: 'idle_prompt', message: 'Claude is waiting for your input' }), 60000),
    ],
  },
  {
    name: 'ask_user_question_and_plan',
    steps: [
      step(ev('SessionStart', { source: 'startup' })),
      step(ev('UserPromptSubmit', { prompt: '發票匯出 CSV' })),
      step(ev('PreToolUse', { tool_name: 'AskUserQuestion', tool_input: { questions: [] } })),
      step(ev('PreToolUse', { tool_name: 'AskUserQuestion' })),
      step(ev('PostToolUse', { tool_name: 'AskUserQuestion' })),
      step(ev('PreToolUse', { tool_name: 'ExitPlanMode' })),
      step(ev('PermissionRequest', { tool_name: 'ExitPlanMode' })),
      step(ev('PostToolUse', { tool_name: 'ExitPlanMode' })),
      step(ev('PermissionRequest', { tool_name: 'AskUserQuestion' })),
      step(ev('PermissionRequest', {})),
      step(ev('PreToolUse', { tool_name: 'askuserquestion' })),
      step(ev('Stop', {})),
    ],
  },
  {
    name: 'notification_types',
    steps: [
      step(ev('SessionStart', { source: 'startup' })),
      step(ev('Notification', { notification_type: 'elicitation_dialog', message: 'MCP server wants input' })),
      step(ev('Notification', { notification_type: 'idle_prompt' })),
      step(ev('Notification', { notification_type: 'elicitation_url_dialog' })),
      step(ev('Notification', { notification_type: 'auth_success', message: 'permission granted' })),
      step(ev('Notification', { notification_type: 'agent_needs_input' })),
      step(ev('Notification', { notification_type: 'elicitation_complete' })),
      step(ev('Notification', { notification_type: 'quota_auto_resume_fired' })),
      step(ev('Stop', {})),
      step(ev('Notification', { message: 'Claude needs your PERMISSION to use Write' })),
      step(ev('Stop', {})),
      step(ev('Notification', { message: 'Claude is waiting for your input' })),
      step(ev('Notification', { notification_type: '   ', message: 'needs permission' })),
      step(ev('Stop', {})),
      step(ev('Notification', { notification_type: 42, message: 'Permission?' })),
      step(ev('Stop', {})),
      step(ev('Notification', { message: 12345 })),
      step(ev('Notification', { notification_type: 'permission_prompt' })),
      step(ev('Notification', { notification_type: 'permission_prompt' })),
    ],
  },
  {
    name: 'stop_failure_and_session_end',
    steps: [
      step(ev('SessionStart', { source: 'startup' })),
      step(ev('UserPromptSubmit', { prompt: '場景載入優化' })),
      step(ev('StopFailure', { error: 'overloaded', error_details: 'API Error: 529 Overloaded', last_assistant_message: 'API Error: Overloaded' })),
      step(ev('UserPromptSubmit', { prompt: 'retry' })),
      step(ev('StopFailure', { error: 'rate_limit', last_assistant_message: 'API Error: Rate limit reached' })),
      step(ev('Notification', { notification_type: 'idle_prompt' }), 60000),
      step(ev('SessionEnd', { reason: 'prompt_input_exit' })),
      step(ev('SessionEnd', { reason: 'other' })),
    ],
  },
  {
    name: 'clear_flow_session_end_then_new_id',
    steps: [
      step(ev('SessionStart', { source: 'startup', session_title: '修正登入 API 401' })),
      step(ev('UserPromptSubmit', { prompt: 'first prompt' })),
      step(ev('PostToolUse', { tool_name: 'Read' })),
      step(ev('Stop', {})),
      step(ev('SessionEnd', { reason: 'clear' })),
      step(ev('SessionStart', { source: 'clear' }, SID_B)),
      step(ev('UserPromptSubmit', { prompt: 'second prompt' }, SID_B)),
      step(ev('Stop', {}, SID_B)),
    ],
  },
  {
    name: 'clear_takeover_without_session_end',
    steps: [
      step(ev('SessionStart', { source: 'startup' })),
      step(ev('UserPromptSubmit', { prompt: 'p1', session_title: 'Old title' })),
      step(ev('PostToolUse', { tool_name: 'Bash' })),
      step(ev('PostToolUse', { tool_name: 'Bash' })),
      step(ev('SessionStart', { source: 'clear' }, SID_B)),
      step(ev('PreToolUse', { tool_name: 'Grep' }, SID_B)),
      step(ev('UserPromptSubmit', { prompt: 'late event from old id' }, SID_A)),
    ],
  },
  {
    name: 'fork_takeover_keeps_tool_count',
    steps: [
      step(ev('SessionStart', { source: 'startup' })),
      step(ev('UserPromptSubmit', { prompt: 'p1' })),
      step(ev('PostToolUse', { tool_name: 'Edit' })),
      step(ev('PostToolUse', { tool_name: 'Edit' })),
      step(ev('PostToolUse', { tool_name: 'Edit' })),
      step(ev('SessionStart', { source: 'fork', session_title: 'Forked copy' }, SID_B)),
      step(ev('UserPromptSubmit', { prompt: 'after fork' }, SID_B)),
    ],
  },
  {
    name: 'nested_claude_is_rejected',
    steps: [
      step(ev('SessionStart', { source: 'startup' })),
      step(ev('UserPromptSubmit', { prompt: 'run claude -p inside bash' })),
      step(ev('PreToolUse', { tool_name: 'Bash' })),
      step(ev('SessionStart', { source: 'startup' }, SID_C)),
      step(ev('SessionStart', { source: 'resume' }, SID_C)),
      step(ev('UserPromptSubmit', { prompt: 'nested prompt' }, SID_C)),
      step(ev('Stop', {}, SID_C)),
      step(ev('SessionEnd', { reason: 'other' }, SID_C)),
      step(ev('SessionStart', { source: 'compact' }, SID_C)),
      step(ev('PostToolUse', { tool_name: 'Bash' })),
      step(ev('Stop', {})),
    ],
  },
  {
    name: 'resume_after_end_is_accepted',
    steps: [
      step(ev('SessionStart', { source: 'startup' })),
      step(ev('SessionEnd', { reason: 'resume' })),
      step(ev('SessionStart', { source: 'resume', session_title: 'Resumed one' }, SID_C)),
      step(ev('UserPromptSubmit', { prompt: 'hello again' }, SID_C)),
    ],
  },
  {
    name: 'compaction_keeps_state',
    steps: [
      step(ev('SessionStart', { source: 'compact' })),
      step(ev('UserPromptSubmit', { prompt: 'long task' })),
      step(ev('PreCompact', { trigger: 'auto', custom_instructions: null })),
      step(ev('SessionStart', { source: 'compact' })),
      step(ev('PostCompact', { trigger: 'auto', compact_summary: 'Summary...' })),
      step(ev('PreToolUse', { tool_name: 'Edit' })),
      step(ev('Stop', {})),
      step(ev('PreCompact', { trigger: 'manual', custom_instructions: 'keep tests' })),
      step(ev('SessionStart', { source: 'compact' })),
      step(ev('PostCompact', { trigger: 'manual', compact_summary: 'Summary 2' })),
      step(ev('PreToolUse', { tool_name: 'AskUserQuestion' })),
      step(ev('SessionStart', { source: 'compact' })),
    ],
  },
  {
    name: 'subagents_are_noops',
    steps: [
      step(ev('SessionStart', { source: 'startup' })),
      step(ev('UserPromptSubmit', { prompt: 'use subagents' })),
      step(ev('PreToolUse', { tool_name: 'Agent' })),
      step(ev('SubagentStart', { agent_id: 'agent-1', agent_type: 'Explore' })),
      step(ev('SubagentStart', { agent_id: 'agent-2', agent_type: 'general-purpose' })),
      step(ev('PreToolUse', { tool_name: 'Grep', agent_id: 'agent-1', agent_type: 'Explore' })),
      step(ev('SubagentStop', { agent_id: 'agent-1', agent_type: 'Explore', stop_hook_active: false })),
      step(ev('SubagentStop', { agent_id: 'agent-2', agent_type: 'general-purpose' })),
      step(ev('PostToolUse', { tool_name: 'Agent' })),
      step(ev('Stop', {})),
      step(ev('SubagentStop', { agent_id: 'agent-3' })),
    ],
  },
  {
    name: 'text_cleaning_titles_and_prompts',
    steps: [
      step(ev('SessionStart', { source: 'startup', session_title: '  我的\u0007 標題\n\tline2  ' })),
      step(ev('UserPromptSubmit', { prompt: '\u001b[31mred\u001b[0m and \u001b[1;32mbold green\u001b[m\r\nnext line' })),
      step(ev('UserPromptSubmit', { prompt: LONG_PROMPT })),
      step(ev('UserPromptSubmit', { prompt: EMOJI_PROMPT })),
      step(ev('UserPromptSubmit', { prompt: 'nbsp ideo　zwsp​bom﻿ls ps nel\u0085end' })),
      step(ev('UserPromptSubmit', { prompt: '   \n\t  ' })),
      step(ev('UserPromptSubmit', { prompt: '\u001b' })),
      step(ev('UserPromptSubmit', { prompt: 'esc \u001b]0;title\u0007 osc and \u001b[?2004h mode and \u001b[ 5 q' })),
      step(ev('UserPromptSubmit', { prompt: 'c1\u0080\u009fcontrols\u007fdel\u001b[' })),
      step(ev('UserPromptSubmit', { prompt: 12345, session_title: LONG_TITLE })),
      step(ev('UserPromptSubmit', { prompt: '       x᠎y\u000b\u000cz' })),
      step(ev('SessionStart', { source: 'resume', session_title: '   ' })),
      step(ev('SessionStart', { source: 'resume', session_title: { nested: true } })),
    ],
  },
  {
    name: 'malformed_stdin',
    steps: [
      raw(''),
      raw('{oops'),
      raw('[1,2,3]'),
      raw('"just a string"'),
      raw('5'),
      raw('null'),
      step(ev('SessionStart', { source: 'startup' })),
      raw('{}'),
      step({ session_id: SID_A, cwd: '/synthetic/other' }),
      step(ev(' Stop ', {})),
      step(ev('PreModelSwitch', { from_model: 'a', to_model: 'b' })),
      step({ hook_event_name: 'UserPromptSubmit', session_id: 99, prompt: 'numeric session id' }),
      step({ hook_event_name: 'PostToolUse', session_id: '   ', tool_name: '  ' }),
      step({ hook_event_name: 'PreToolUse', tool_name: 7 }),
      step({ hook_event_name: 'Stop', session_id: SID_A, transcript_path: '   ', cwd: '' }),
    ],
  },
  {
    name: 'state_since_and_repeated_events',
    steps: [
      step(ev('UserPromptSubmit', { prompt: 'a' })),
      step(ev('PreToolUse', { tool_name: 'Read' })),
      step(ev('PostToolUse', { tool_name: 'Read' })),
      step(ev('PreToolUse', { tool_name: 'Bash' })),
      step(ev('PermissionRequest', { tool_name: 'Bash' })),
      step(ev('PermissionRequest', { tool_name: 'Bash' })),
      step(ev('PreToolUse', { tool_name: 'AskUserQuestion' })),
      step(ev('PostToolUse', {})),
      step(ev('Stop', {})),
      step(ev('Stop', {})),
      step(ev('SessionStart', { source: 'resume' })),
      step(ev('SessionStart', {})),
      step(ev('SessionStart', { source: 'compact' })),
    ],
  },
  {
    name: 'seed_garbage_tool_count_negative',
    seed: JSON.stringify({ v: 2, session_id: SID_A, state: 'busy', state_since: '', tool_count: -1, last_prompt: 'kept' }),
    steps: [
      step(ev('PostToolUse', { tool_name: 'Bash' })),
      step(ev('PreToolUse', { tool_name: 'Bash' })),
    ],
  },
  {
    name: 'seed_garbage_tool_count_fraction',
    seed: JSON.stringify({ v: 2, session_id: SID_A, state: 'idle', state_since: '2026-10-15T01:00:00.000Z', tool_count: 2.5 }),
    steps: [step(ev('Stop', {})), step(ev('PostToolUse', { tool_name: 'Bash' }))],
  },
  {
    name: 'seed_garbage_tool_count_string',
    seed: '{"v":2,"session_id":"' + SID_A + '","state":"waiting","waiting_reason":"plan","state_since":"2026-10-15T01:00:00.000Z","tool_count":"3"}',
    steps: [step(ev('Notification', { notification_type: 'agent_completed' })), step(ev('PostToolUse', {}))],
  },
  {
    name: 'seed_valid_tool_count_float_literal',
    seed: '{"v":2,"session_id":"' + SID_A + '","state":"idle","state_since":"2026-10-15T01:00:00.000Z","tool_count":7.0,"custom_title":"Seeded"}',
    steps: [step(ev('PostToolUse', { tool_name: 'Read' }))],
  },
  {
    name: 'seed_corrupt_file',
    seed: '{not json',
    steps: [step(ev('Stop', {}))],
  },
  {
    name: 'seed_ended_other_session',
    seed: JSON.stringify({ v: 2, session_id: SID_C, state: 'ended', state_since: '2026-10-15T01:00:00.000Z', tool_count: 4, last_prompt: 'old', last_prompt_at: '2026-10-15T00:59:00.000Z', custom_title: 'old title', transcript_path: transcript(SID_C), cwd: '/synthetic/old' }),
    steps: [
      step(ev('PreToolUse', { tool_name: 'Bash' })),
    ],
  },
  {
    name: 'seed_session_id_whitespace_is_distinct',
    seed: JSON.stringify({ v: 2, session_id: ` ${SID_A} `, state: 'busy', state_since: '2026-10-15T01:00:00.000Z', tool_count: 1 }),
    steps: [
      step(ev('Stop', {})),
      step(ev('SessionStart', { source: 'clear' })),
    ],
  },
  {
    name: 'transcript_and_cwd_updates',
    steps: [
      step(ev('SessionStart', { source: 'startup' })),
      step({ hook_event_name: 'UserPromptSubmit', session_id: SID_A, prompt: 'no transcript or cwd in payload' }),
      step({ hook_event_name: 'PreToolUse', session_id: SID_A, transcript_path: '/synthetic/new.jsonl', cwd: '/synthetic/elsewhere', tool_name: 'Bash' }),
      step({ hook_event_name: 'PostToolUse', tool_name: 'Bash' }),
    ],
  },
];
