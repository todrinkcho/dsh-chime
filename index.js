/**
 * dsh-task-chime-badge — Host half.
 *
 * Turns the DeepSeek Harness taskbar button into a notification surface for the
 * Windows desktop shell:
 *
 *  - a turn that finishes while nothing else runs   -> "ding" + green badge
 *  - a question / approval that waits for the user  -> soft two-note chime + amber badge
 *
 * The badge lives on the taskbar button of the Harness window. Windows 11 draws
 * an overlay badge on the upper-right corner of that button, which matches the
 * "green dot in the corner" feel; the exact position belongs to Explorer.
 *
 * Everything that touches Win32 lives in `helper/taskbar-helper.ps1`, which this
 * half spawns as one long-lived hidden process. The two sides talk through a
 * small JSON command file, so the helper keeps working across Host reloads and
 * never needs a socket. The helper also exits on its own when this process goes
 * away, and a focused window counts as "read": the badge is dismissed.
 */
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync, renameSync, appendFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

export const name = 'dsh-task-chime-badge';

const PACKAGE_ROOT = fileURLToPath(new URL('.', import.meta.url));
const HELPER_SCRIPT = join(PACKAGE_ROOT, 'helper', 'taskbar-helper.ps1');
const DONE_WAV = join(PACKAGE_ROOT, 'assets', 'done.wav');
const ASK_WAV = join(PACKAGE_ROOT, 'assets', 'ask.wav');

const LOG_LIMIT_BYTES = 256 * 1024;

const DEFAULTS = {
  enabled: true,
  chimeOnDone: true,
  chimeOnAsk: true,
  watchApprovals: true,
  /**
   * Skip the "done" chime/badge when the finished turn was started from an IM
   * bot (dsh-im) instead of the desktop window. A bot replying in WeChat/Feishu
   * keeps ringing the desktop, and nobody is waiting on that notification.
   */
  ignoreImTurns: true,
  /** RPC id prefixes dsh-im uses for its prompts, one per channel. */
  imRpcIdPrefixes: [
    'feishu',
    'weixin',
    'dingtalk',
    'wecomapp',
    'wecom',
    'qq',
    'slack',
    'telegram',
    'discord',
    'whatsapp',
    'imessage',
    'matrix',
    'email',
    'office',
    'im',
  ],
  /** Wait this long after the last agent goes idle before announcing "done". */
  quietMs: 900,
  /** Window process name to badge; the desktop shell ships as "DeepSeek Harness". */
  processName: 'DeepSeek Harness',
  helperPollMs: 350,
  debug: true,
};

function readConfig(raw) {
  const supplied = raw && typeof raw === 'object' ? raw : {};
  const config = { ...DEFAULTS };
  for (const key of Object.keys(DEFAULTS)) {
    if (supplied[key] === undefined) continue;
    const fallback = DEFAULTS[key];
    if (typeof fallback === 'number') {
      const value = Number(supplied[key]);
      if (Number.isFinite(value) && value >= 0) config[key] = value;
    } else if (typeof fallback === 'boolean') {
      if (typeof supplied[key] === 'boolean') config[key] = supplied[key];
    } else if (Array.isArray(fallback)) {
      const values = Array.isArray(supplied[key])
        ? supplied[key]
        : typeof supplied[key] === 'string'
          ? supplied[key].split(',')
          : [];
      const items = values
        .filter((value) => typeof value === 'string' && value.trim().length > 0)
        .map((value) => value.trim());
      if (items.length > 0) config[key] = items;
    } else if (typeof supplied[key] === 'string' && supplied[key].trim().length > 0) {
      config[key] = supplied[key].trim();
    }
  }
  config.quietMs = Math.max(0, Math.min(10_000, config.quietMs));
  config.helperPollMs = Math.min(2000, Math.max(150, config.helperPollMs));
  return config;
}

function resolveRuntimeDir() {
  const home = process.env.DSH_HOME && process.env.DSH_HOME.trim().length > 0 ? process.env.DSH_HOME : join(homedir(), '.dsh');
  return join(home, 'cache', 'task-chime-badge');
}

export function apply(ctx, rawConfig) {
  const config = readConfig(rawConfig);
  if (!config.enabled) return;
  if (process.platform !== 'win32') return;

  const runtimeDir = resolveRuntimeDir();
  const commandFile = join(runtimeDir, 'command.json');
  const logFile = join(runtimeDir, 'plugin.log');

  try {
    mkdirSync(runtimeDir, { recursive: true });
  } catch {
    return;
  }

  const log = (message) => {
    if (!config.debug) return;
    const line = `${new Date().toISOString()} ${message}\n`;
    try {
      if (statSync(logFile, { throwIfNoEntry: false })?.size > LOG_LIMIT_BYTES) writeFileSync(logFile, '');
      appendFileSync(logFile, line);
    } catch {
      /* logging must never break the feature */
    }
  };

  let seq = Date.now();
  let mode = 'none';
  let helper = null;
  let helperStartedAt = 0;
  let disposed = false;

  const writeCommand = (nextMode, tone, force = false) => {
    if (!force && nextMode === mode && tone === null) return;
    mode = nextMode;
    // Timestamp-based so a Host restart never rewinds the sequence and leaves a
    // surviving helper ignoring fresh commands.
    seq = Math.max(seq + 1, Date.now());
    const payload = JSON.stringify({ seq, mode, tone: tone ?? '' });
    const tmp = `${commandFile}.tmp`;
    try {
      writeFileSync(tmp, payload);
      renameSync(tmp, commandFile);
    } catch (error) {
      log(`command write failed: ${error?.message ?? error}`);
    }
    log(`state -> ${mode}${tone ? ` (tone ${tone})` : ''} seq=${seq}`);
  };

  const announceDone = () => writeCommand('done', config.chimeOnDone ? 'done' : '');
  const announceAsk = () => writeCommand('ask', config.chimeOnAsk ? 'ask' : '');

  const startHelper = () => {
    if (disposed || helper) return;
    const args = [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      HELPER_SCRIPT,
      '-ParentPid',
      String(process.pid),
      '-CommandFile',
      commandFile,
      '-DoneWav',
      DONE_WAV,
      '-AskWav',
      ASK_WAV,
      '-ProcessName',
      config.processName,
      '-PollMs',
      String(Math.round(config.helperPollMs)),
    ];
    try {
      const child = spawn('powershell.exe', args, { windowsHide: true, stdio: 'ignore' });
      helper = child;
      helperStartedAt = Date.now();
      log(`helper started pid=${child.pid ?? '?'}`);
      child.on('exit', (code) => {
        log(`helper exited code=${code}`);
        helper = null;
        if (!disposed && Date.now() - helperStartedAt > 3000) {
          setTimeout(() => {
            if (!disposed && !helper) startHelper();
          }, 2000);
        }
      });
      child.on('error', (error) => {
        log(`helper spawn error: ${error?.message ?? error}`);
        helper = null;
      });
    } catch (error) {
      log(`helper spawn threw: ${error?.message ?? error}`);
    }
  };

  /* ---------------------------------------------------------------------- */
  /* Where a turn came from (desktop window vs an IM bot)                     */
  /* ---------------------------------------------------------------------- */

  const imPrefixes = new Set(config.imRpcIdPrefixes.map((prefix) => prefix.toLowerCase()));

  /** `feishu-<uuid>` from dsh-im vs a bare uuid from the desktop client. */
  const isImRpcId = (rpcId) => {
    if (typeof rpcId !== 'string' || rpcId.length === 0) return false;
    const separator = rpcId.indexOf('-');
    if (separator <= 0) return false;
    return imPrefixes.has(rpcId.slice(0, separator).toLowerCase());
  };

  /** sessionId -> rpc ids of the real user prompts seen in the open turn. */
  const turnPromptIds = new Map();
  /** sessionId -> whether that session's last finished turn came only from IM. */
  const lastTurnFromIm = new Map();

  const onSessionEvent = (session, event) => {
    const sessionId = String(session?.id ?? '');
    const type = event?.type;
    if (!sessionId || typeof type !== 'string') return;
    if (type === 'turn/start') {
      turnPromptIds.set(sessionId, []);
      lastTurnFromIm.delete(sessionId);
      return;
    }
    if (type === 'user/message') {
      // Instructions, runtime-context snapshots and dsh-im notices are also
      // user/message events; only an actual prompt has source.kind "user".
      if (event?.data?.source?.kind !== 'user') return;
      const prompts = turnPromptIds.get(sessionId);
      if (!prompts) return;
      prompts.push(event.data.source.rpcId);
      return;
    }
    if (type !== 'turn/end') return;
    const prompts = turnPromptIds.get(sessionId);
    turnPromptIds.delete(sessionId);
    if (!prompts) return;
    // A turn woken by a goal round, a teammate message or a background job has
    // no prompt of its own; it is not IM just because an earlier one was.
    lastTurnFromIm.set(sessionId, prompts.length > 0 && prompts.every(isImRpcId));
  };

  /* ---------------------------------------------------------------------- */
  /* Turn lifecycle                                                          */
  /* ---------------------------------------------------------------------- */

  const running = new Set();
  /** Agents whose last turn finished since the last announcement. */
  const finished = new Set();
  let quietTimer = null;

  const cancelQuiet = () => {
    if (quietTimer) {
      clearTimeout(quietTimer);
      quietTimer = null;
    }
  };

  const onStatus = (payload) => {
    const id = String(payload?.agent?.id ?? '');
    const status = payload?.status;
    if (!id) return;
    if (status === 'running') {
      running.add(id);
      finished.delete(id);
      cancelQuiet();
      log(`agent ${id} running (${running.size} running)`);
      return;
    }
    if (status !== 'idle') return;
    running.delete(id);
    finished.add(id);
    log(`agent ${id} idle (${running.size} running)`);
    cancelQuiet();
    if (running.size > 0) return;
    quietTimer = setTimeout(() => {
      quietTimer = null;
      if (disposed || running.size > 0) return;
      const agents = [...finished];
      finished.clear();
      if (config.ignoreImTurns
        && agents.length > 0
        && agents.every((agentId) => lastTurnFromIm.get(agentId) === true)) {
        log(`done skipped (IM turn): ${agents.join(', ')}`);
        return;
      }
      announceDone();
    }, config.quietMs);
    if (typeof quietTimer.unref === 'function') quietTimer.unref();
  };

  /* ---------------------------------------------------------------------- */
  /* Blocking questions and approvals                                        */
  /* ---------------------------------------------------------------------- */

  let pendingAsks = 0;

  const beginAsk = (label) => {
    pendingAsks += 1;
    log(`ask pending (${label}) depth=${pendingAsks}`);
    announceAsk();
  };

  const endAsk = () => {
    pendingAsks = Math.max(0, pendingAsks - 1);
    log(`ask settled depth=${pendingAsks}`);
    if (pendingAsks === 0) writeCommand('none', null);
  };

  const wrapAskEvent = (label) => async (request, next) => {
    // Never break the question chain: if this is not the waterfall shape we
    // expect, stay out of the way entirely.
    if (typeof next !== 'function') return undefined;
    try {
      beginAsk(label);
    } catch {
      /* a failed state write must not block the question */
    }
    try {
      return await next();
    } finally {
      try {
        endAsk();
      } catch {
        /* ignore */
      }
    }
  };

  startHelper();
  writeCommand('none', null, true);

  ctx.on('agent/status', onStatus);
  ctx.on('session/event', onSessionEvent);
  ctx.on('user-questions/request', wrapAskEvent('question'));
  if (config.watchApprovals) ctx.on('approval/request', wrapAskEvent('approval'));

  ctx.effect(() => {
    return () => {
      disposed = true;
      cancelQuiet();
      helper?.kill();
      helper = null;
    };
  }, 'task-chime-badge: helper lifetime');

  log('plugin applied');
}
