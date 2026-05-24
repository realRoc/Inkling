import os

/// 诊断用 Logger。Release 构建下 NSLog 被 os_log 当成 private 全部脱敏成 `<private>`，
/// 看不到任何上下文。这里显式标 privacy: .public，让选区抓取链路的关键状态能在
/// `log stream --predicate 'subsystem == "com.wuyupeng.inkling"'` 里看到。
/// 用 .notice 级别——不加 --info 也能流出来，方便用户排查。
let diagLog = Logger(subsystem: "com.wuyupeng.inkling", category: "diag")
