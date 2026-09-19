import CPlaydate

/// The entry point. The firmware calls this once at `kEventInit` with the API
/// pointer, and from then on the application is driven entirely by callbacks.
///
/// The `App` is retained here and handed to each callback as its `userdata`,
/// which is how this program gets by without mutable global state.
@_cdecl("w4_eventHandler")
public func w4_eventHandler(
    pointer: UnsafeMutablePointer<PlaydateAPI>,
    event: PDSystemEvent,
    arg: UInt32
) -> Int32 {
    if event == kEventInit {
        let app = App(playdate: Playdate(api: pointer))
        app.start(userdata: Unmanaged.passRetained(app).toOpaque())
    }
    return 0
}
