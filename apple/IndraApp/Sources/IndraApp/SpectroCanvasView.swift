// MTKView subclass + NSViewRepresentable for the spectrogram canvas
// (BUILD_SPEC §5.2: the canvas subclasses MTKView and owns gestures via
// NSResponder overrides — scroll pans, magnify zooms at the cursor, drag
// selects; SwiftUI gestures do not deliver scroll-wheel events). All
// interpretation of the events lives in SpectroCanvasModel; this view only
// translates NSEvents into flipped-coordinate callbacks.
// USER-SMOKE-TESTED ONLY — see docs/plan/SMOKE_TESTS.md (Phase 4).

#if os(macOS) && canImport(SwiftUI) && canImport(MetalKit)

    import AppKit
    import MetalKit
    import SwiftUI

    final class SpectroMTKView: MTKView {
        var onPan: ((_ deltaX: Double, _ deltaY: Double) -> Void)?
        var onZoomTime: ((_ factor: Double, _ x: Double) -> Void)?
        var onZoomFrequency: ((_ factor: Double, _ y: Double) -> Void)?
        var onDragBegin: ((_ x: Double, _ y: Double) -> Void)?
        var onDragUpdate: ((_ x: Double, _ y: Double) -> Void)?
        var onDragEnd: (() -> Void)?
        var onClick: ((_ x: Double, _ y: Double, _ optionDown: Bool) -> Void)?

        private var dragStart: CGPoint?
        private var dragging = false
        /// Movement below this (squared px) stays a click, not a drag.
        private let dragSlopSquared: CGFloat = 9

        /// y = 0 at the TOP, matching Viewport screen conventions.
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        override func scrollWheel(with event: NSEvent) {
            // Line-based (non-trackpad) deltas are in lines; scale to pixels.
            let scale = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
            onPan?(
                Double(event.scrollingDeltaX) * scale,
                Double(event.scrollingDeltaY) * scale)
        }

        override func magnify(with event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
            let factor = max(1 + Double(event.magnification), 0.05)
            if event.modifierFlags.contains(.option) {
                onZoomFrequency?(factor, Double(location.y))
            } else {
                onZoomTime?(factor, Double(location.x))
            }
        }

        override func mouseDown(with event: NSEvent) {
            dragStart = convert(event.locationInWindow, from: nil)
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart else { return }
            let location = convert(event.locationInWindow, from: nil)
            if !dragging {
                let dx = location.x - start.x
                let dy = location.y - start.y
                guard dx * dx + dy * dy >= dragSlopSquared else { return }
                dragging = true
                onDragBegin?(Double(start.x), Double(start.y))
            }
            onDragUpdate?(Double(location.x), Double(location.y))
        }

        override func mouseUp(with event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
            if dragging {
                onDragUpdate?(Double(location.x), Double(location.y))
                onDragEnd?()
            } else if dragStart != nil {
                onClick?(
                    Double(location.x), Double(location.y),
                    event.modifierFlags.contains(.option))
            }
            dragStart = nil
            dragging = false
        }
    }

    /// Hosts the MTKView, draw-on-demand (§5.3: isPaused +
    /// enableSetNeedsDisplay; redraw pokes come from the canvas model).
    struct SpectroMetalView: NSViewRepresentable {
        let canvas: SpectroCanvasModel

        func makeNSView(context: Context) -> SpectroMTKView {
            let view = SpectroMTKView(frame: .zero, device: canvas.renderer.device)
            view.delegate = canvas.renderer
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.colorPixelFormat = .bgra8Unorm
            view.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1)
            view.framebufferOnly = true

            canvas.requestRedraw = { [weak view] in
                view?.needsDisplay = true
            }
            view.onPan = { [weak canvas] dx, dy in
                canvas?.panBy(deltaX: dx, deltaY: dy)
            }
            view.onZoomTime = { [weak canvas] factor, x in
                canvas?.zoomTime(by: factor, atX: x)
            }
            view.onZoomFrequency = { [weak canvas] factor, y in
                canvas?.zoomFrequency(by: factor, atY: y)
            }
            view.onDragBegin = { [weak canvas] x, y in
                canvas?.selectionDragBegan(atX: x, y: y)
            }
            view.onDragUpdate = { [weak canvas] x, y in
                canvas?.selectionDragMoved(toX: x, y: y)
            }
            view.onDragEnd = { [weak canvas] in
                canvas?.selectionDragEnded()
            }
            view.onClick = { [weak canvas] x, y, optionDown in
                canvas?.clicked(atX: x, y: y, optionDown: optionDown)
            }
            return view
        }

        func updateNSView(_ view: SpectroMTKView, context: Context) {
            view.needsDisplay = true
        }
    }

#endif
