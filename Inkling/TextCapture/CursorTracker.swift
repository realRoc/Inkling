import AppKit

enum CursorTracker {
    /// 当前鼠标的全局坐标（屏幕坐标系，左下角原点）。
    static func location() -> NSPoint {
        NSEvent.mouseLocation
    }
}
