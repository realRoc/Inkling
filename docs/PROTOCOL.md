# Bridge Protocol

Swift App ↔ Node bridge 走 line-delimited JSON over stdin/stdout。每条消息一行 JSON，UTF-8。

## 公共字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `type` | string | 消息类型 |
| `id` | string | 会话 ID（Swift 侧生成 UUID） |

## Swift → bridge

### create_session
```json
{
  "type": "create_session",
  "id": "session-uuid",
  "model": "claude-haiku-4-5",
  "system_prompt": "你是一个划词助手……"
}
```

### send
```json
{
  "type": "send",
  "id": "session-uuid",
  "text": "解释这段：「foo bar baz」",
  "selection_context": {
    "app": "Safari",
    "url": "https://example.com",
    "surrounding_text": "...前后 500 字..."
  }
}
```

### end_session
```json
{"type": "end_session", "id": "session-uuid"}
```

## bridge → Swift

### session_created
```json
{"type": "session_created", "id": "session-uuid"}
```

### delta（流式 token）
```json
{"type": "delta", "id": "session-uuid", "text": "这段"}
```

### tool_use（如果未来开启工具调用）
```json
{
  "type": "tool_use",
  "id": "session-uuid",
  "name": "Read",
  "input": {"file_path": "..."}
}
```

### done
```json
{
  "type": "done",
  "id": "session-uuid",
  "usage": {"input_tokens": 120, "output_tokens": 45, "cache_read_input_tokens": 800}
}
```

### error
```json
{"type": "error", "id": "session-uuid", "message": "rate limited", "code": "rate_limit"}
```

## 生命周期

```
Swift                          bridge
  │   create_session              │
  ├─────────────────────────────▶ │
  │                               │ 启动 query()
  │   session_created             │
  │ ◀─────────────────────────────┤
  │                               │
  │   send                        │
  ├─────────────────────────────▶ │
  │                               │ 推 prompt
  │   delta (多条)                │
  │ ◀─────────────────────────────┤
  │   done                        │
  │ ◀─────────────────────────────┤
  │                               │
  │   send (追问)                 │
  ├─────────────────────────────▶ │
  │                               │ 复用 session
  │   delta ... done              │
  │ ◀─────────────────────────────┤
  │                               │
  │   end_session                 │
  ├─────────────────────────────▶ │
  │                               │ 清理
```
