/**
 * Inkling bridge: Node sidecar that wraps @anthropic-ai/claude-agent-sdk.
 *
 * Protocol: line-delimited JSON over stdin/stdout. See docs/PROTOCOL.md.
 *
 * 当前工作目录 (cwd) 由 Inkling.app 设置为
 *   ~/Library/Application Support/Inkling/
 * Claude Agent SDK 会自动加载该目录下的 CLAUDE.md 作为系统指令。
 */

import * as readline from 'node:readline';
import { query, type Options, type SDKMessage } from '@anthropic-ai/claude-agent-sdk';

type Outbound =
  | { type: 'session_created'; id: string }
  | { type: 'delta'; id: string; text: string }
  | { type: 'done'; id: string; usage?: unknown }
  | { type: 'error'; id: string; message: string };

type Inbound =
  | { type: 'create_session'; id: string; model?: string; system_prompt?: string }
  | { type: 'send'; id: string; text: string }
  | { type: 'end_session'; id: string };

interface Session {
  model: string;
  systemPrompt?: string;
  /** 用 Claude Agent SDK 的 resumable session id 复用对话上下文 */
  resumeId?: string;
}

const sessions = new Map<string, Session>();

function emit(msg: Outbound): void {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function logErr(...args: unknown[]): void {
  process.stderr.write(args.map(String).join(' ') + '\n');
}

async function handleCreateSession(msg: Extract<Inbound, { type: 'create_session' }>) {
  sessions.set(msg.id, {
    model: msg.model ?? 'claude-haiku-4-5',
    systemPrompt: msg.system_prompt,
  });
  emit({ type: 'session_created', id: msg.id });
}

async function handleSend(msg: Extract<Inbound, { type: 'send' }>) {
  const session = sessions.get(msg.id);
  if (!session) {
    emit({ type: 'error', id: msg.id, message: 'session not found' });
    return;
  }

  const options: Options = {
    model: session.model,
    // 复用之前会话（如有）。第一次为 undefined，SDK 会建立新 session。
    resume: session.resumeId,
    // bridge 启动时 cwd 已是 Application Support/Inkling/，
    // SDK 会自动加载该目录的 CLAUDE.md，故无需重复传 systemPrompt。
    appendSystemPrompt: session.systemPrompt,
  };

  try {
    const iter = query({ prompt: msg.text, options });
    for await (const event of iter as AsyncIterable<SDKMessage>) {
      handleSDKEvent(msg.id, session, event);
    }
    emit({ type: 'done', id: msg.id });
  } catch (err) {
    emit({ type: 'error', id: msg.id, message: (err as Error).message });
  }
}

function handleSDKEvent(id: string, session: Session, event: SDKMessage) {
  // SDK 的事件结构请按当前版本细化。这里只截关键路径：
  // - assistant 文本增量 -> delta
  // - system init 携带 sessionId -> 存到 session.resumeId 以便下一轮 resume
  const anyEvent = event as any;
  if (anyEvent.type === 'system' && anyEvent.subtype === 'init' && anyEvent.session_id) {
    session.resumeId = anyEvent.session_id;
    return;
  }
  if (anyEvent.type === 'assistant' && anyEvent.message?.content) {
    for (const block of anyEvent.message.content) {
      if (block.type === 'text' && block.text) {
        emit({ type: 'delta', id, text: block.text });
      }
    }
  }
}

function handleEnd(msg: Extract<Inbound, { type: 'end_session' }>) {
  sessions.delete(msg.id);
}

async function main() {
  const rl = readline.createInterface({ input: process.stdin });
  for await (const line of rl) {
    if (!line.trim()) continue;
    let msg: Inbound;
    try {
      msg = JSON.parse(line);
    } catch (e) {
      logErr('parse error', e);
      continue;
    }
    try {
      switch (msg.type) {
        case 'create_session': await handleCreateSession(msg); break;
        case 'send':           await handleSend(msg); break;
        case 'end_session':    handleEnd(msg); break;
        default:
          logErr('unknown type', (msg as any).type);
      }
    } catch (e) {
      logErr('handler error', e);
    }
  }
}

main().catch((e) => {
  logErr('fatal', e);
  process.exit(1);
});
