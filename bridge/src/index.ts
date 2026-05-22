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
    // SDK 会自动加载该目录的 CLAUDE.md。这里用 preset+append 形式追加可选的额外指令。
    systemPrompt: session.systemPrompt
      ? { type: 'preset', preset: 'claude_code', append: session.systemPrompt }
      : undefined,
    // 开启增量事件，否则只能等整段 assistant 消息回来才有文本。
    includePartialMessages: true,
  };

  const ctx: TurnContext = { id: msg.id, streamed: false };
  try {
    const iter = query({ prompt: msg.text, options });
    for await (const event of iter as AsyncIterable<SDKMessage>) {
      handleSDKEvent(ctx, session, event);
    }
    emit({ type: 'done', id: msg.id });
  } catch (err) {
    emit({ type: 'error', id: msg.id, message: (err as Error).message });
  }
}

interface TurnContext {
  id: string;
  /** 本轮是否已经通过 stream_event 推过 delta，避免最终 assistant 消息重复发文本。 */
  streamed: boolean;
}

function handleSDKEvent(ctx: TurnContext, session: Session, event: SDKMessage) {
  switch (event.type) {
    case 'system':
      // 只关心 init，其他 subtype（compact_boundary / permission_denied / ...）忽略。
      if ('subtype' in event && event.subtype === 'init') {
        session.resumeId = event.session_id;
      }
      return;

    case 'stream_event': {
      const inner = event.event;
      if (
        inner.type === 'content_block_delta' &&
        inner.delta.type === 'text_delta' &&
        inner.delta.text
      ) {
        ctx.streamed = true;
        emit({ type: 'delta', id: ctx.id, text: inner.delta.text });
      }
      return;
    }

    case 'assistant': {
      // 没有走流式（兜底）时，把整段 assistant text 当作一次 delta 发出。
      if (ctx.streamed) return;
      if (event.error) {
        emit({ type: 'error', id: ctx.id, message: event.error });
        return;
      }
      for (const block of event.message.content) {
        if (block.type === 'text' && block.text) {
          emit({ type: 'delta', id: ctx.id, text: block.text });
        }
      }
      return;
    }

    case 'result': {
      // result 是 SDK 这一轮的总结；只在出错时上报，正常完成由 handleSend 末尾的 done 处理。
      if (event.subtype !== 'success') {
        const message = event.errors?.join('; ') || event.subtype;
        emit({ type: 'error', id: ctx.id, message });
      }
      return;
    }

    default:
      // user / hook / permission / plugin 等事件目前不上报到 Swift 侧。
      return;
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
