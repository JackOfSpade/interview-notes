import AppKit
import SwiftUI

/// A readable scrolling surface that exposes intents, not pixel offsets.
public struct TeleprompterStageView: View {
    public var text: String
    public var wordCount: Int
    @Binding var isPlaying: Bool
    public var wpm: Int
    public var onReachedEnd: () -> Void

    /// Increment to page down; decrement to page up.
    @Binding var pageCommand: Int
    /// Increment to return to the first readable line.
    public var restartToken: Int
    /// Non-zero while a manual up/down control is held. A hold temporarily
    /// takes ownership of the scroll position without changing the user's
    /// intended play state.
    @Binding var manualScrollDirection: Int

    @State private var scrollOffset: CGFloat = 0
    @State private var dragStartOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var contentHeight: CGFloat = 0
    @State private var stageHeight: CGFloat = 0
    @State private var timer: Timer?
    @State private var lastTickDate: Date?
    @State private var lastPageCommand = 0
    @State private var didNotifyEnd = false
    @State private var isManualScrollActive = false
    @State private var manualScrollTimer: Timer?
    @State private var isWheelScrollActive = false
    @State private var wheelScrollTimer: Timer?
    /// Both arrow holds and a wheel/trackpad gesture are transient manual
    /// navigation. Keeping one intent lets either input hand off to the other
    /// without unexpectedly starting, stopping, or double-resuming playback.
    @State private var shouldResumeAfterTransientNavigation = false

    private static let teleprompterTextRowHeight =
        NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: 21)) + 8

    private var isReduceMotionActive: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public init(
        text: String,
        wordCount: Int,
        isPlaying: Binding<Bool>,
        wpm: Int,
        onReachedEnd: @escaping () -> Void,
        pageCommand: Binding<Int> = .constant(0),
        restartToken: Int = 0,
        manualScrollDirection: Binding<Int> = .constant(0)
    ) {
        self.text = text
        self.wordCount = wordCount
        self._isPlaying = isPlaying
        self.wpm = wpm
        self.onReachedEnd = onReachedEnd
        self._pageCommand = pageCommand
        self.restartToken = restartToken
        self._manualScrollDirection = manualScrollDirection
    }

    private var maxScrollOffset: CGFloat {
        TeleprompterScrollMath.maximumOffset(contentHeight: contentHeight)
    }

    public var body: some View {
        GeometryReader { stageGeo in
            // The stage remains a fixed viewport; only its internal document
            // is allowed to grow. This prevents SwiftUI from collapsing a
            // wrapped answer to one truncated line to satisfy the viewport.
            let readingWidth = min(680, max(1, stageGeo.size.width - 40))

            ZStack(alignment: .top) {
                Text(text)
                    .font(.system(size: 21, weight: .regular))
                    .lineSpacing(8)
                    .foregroundStyle(.primary)
                    .frame(width: readingWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    // Keep one readable line above the answer at its initial
                    // position. This padding belongs to the scrolling document
                    // (rather than the stage), so it is measured and exits with
                    // the answer instead of behaving like vertical centering.
                    .padding(.top, Self.teleprompterTextRowHeight)
                    .background(
                        GeometryReader { contentGeo in
                            Color.clear.preference(
                                key: ContentHeightKey.self,
                                value: contentGeo.size.height
                            )
                        }
                    )
                    .offset(y: -scrollOffset)
                    // Keep the answer's document at the top while giving drag
                    // navigation a full-stage hit target, even for a short answer.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                cancelTransientNavigation(resumePlayback: false)
                                pauseForManualNavigation()
                                if !isDragging {
                                    dragStartOffset = scrollOffset
                                    isDragging = true
                                }
                                scrollOffset = TeleprompterScrollMath.dragOffset(
                                    startOffset: dragStartOffset,
                                    translationHeight: value.translation.height,
                                    maximumOffset: maxScrollOffset
                                )
                            }
                            .onEnded { _ in
                                dragStartOffset = scrollOffset
                                isDragging = false
                                notifyEndIfNeeded()
                            }
                    )

                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [
                            Color(nsColor: .windowBackgroundColor).opacity(0),
                            Color(nsColor: .windowBackgroundColor)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 70)
                    .allowsHitTesting(false)
                }
            }
            .clipped()
            .background(
                TeleprompterScrollWheelMonitor { event in
                    handleScrollWheel(event)
                }
                // The monitor observes AppKit events locally; it must not become
                // the hit-tested view or cover the drag gesture above.
                .allowsHitTesting(false)
            )
            .onAppear {
                stageHeight = stageGeo.size.height
                lastPageCommand = pageCommand
                startTimerIfPossible()
            }
            .onChange(of: stageGeo.size) { _, newSize in
                stageHeight = newSize.height
                cancelTransientNavigation(resumePlayback: false)
                pauseForManualNavigation()
                clampScrollOffsetToBounds()
            }
        }
        .onPreferenceChange(ContentHeightKey.self) { height in
            contentHeight = height
            clampScrollOffsetToBounds()
            startTimerIfPossible()
        }
        .onChange(of: text) { _, _ in
            // A newly selected answer is never allowed to begin moving just
            // because the previous answer was playing.
            cancelTransientNavigation(resumePlayback: false)
            isPlaying = false
            restart()
            didNotifyEnd = false
        }
        .onChange(of: wordCount) { _, _ in resetElapsedTimeIfPlaying() }
        .onChange(of: wpm) { _, _ in resetElapsedTimeIfPlaying() }
        .onChange(of: pageCommand) { _, command in
            let direction = command - lastPageCommand
            lastPageCommand = command
            guard direction != 0 else { return }
            page(direction > 0 ? .down : .up)
        }
        .onChange(of: restartToken) { _, _ in restart() }
        .onChange(of: manualScrollDirection) { _, direction in
            if direction == 0 {
                endManualScroll()
            } else {
                beginManualScroll(direction: direction)
            }
        }
        .onChange(of: isPlaying) { _, playing in
            playing ? startTimerIfPossible() : stopTimer()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            cancelTransientNavigation(resumePlayback: false)
            pauseForManualNavigation()
        }
        .onDisappear {
            cancelTransientNavigation(resumePlayback: false)
            stopTimer()
        }
    }

    private enum PageDirection { case up, down }

    private func page(_ direction: PageDirection) {
        let shouldResume = isPlaying || shouldResumeAfterTransientNavigation
        cancelTransientNavigation(resumePlayback: false)
        pauseForManualNavigation()
        let pageSize = max(1, stageHeight * 0.65)
        switch direction {
        case .up:
            scrollOffset = max(0, scrollOffset - pageSize)
        case .down:
            scrollOffset = min(maxScrollOffset, scrollOffset + pageSize)
        }
        notifyEndIfNeeded()
        if shouldResume, maxScrollOffset > 0, scrollOffset < maxScrollOffset, !isReduceMotionActive {
            isPlaying = true
        }
    }

    /// Starts only after layout has measured both the document and stage. A
    /// Start action can arrive before those measurements; leave its binding
    /// intact so the timer begins as soon as the measurements are available.
    private func startTimerIfPossible() {
        guard isPlaying else { return }
        guard !isReduceMotionActive else {
            isPlaying = false
            return
        }
        guard contentHeight > 0, stageHeight > 0, maxScrollOffset > 0 else { return }
        guard timer == nil else { return }
        lastTickDate = Date()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
            MainActor.assumeIsolated { advanceScroll(now: Date()) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        lastTickDate = nil
    }

    private func beginManualScroll(direction: Int) {
        guard direction != 0 else { return }
        beginTransientNavigation()
        stopWheelScrollForHandoff()
        if !isManualScrollActive {
            isManualScrollActive = true
            // Begin repeating on the next 30 Hz timer tick. A quick click can
            // move only a negligible step, while a hold responds immediately.
            startManualRepeat()
        }
    }

    private func startManualRepeat() {
        manualScrollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard isManualScrollActive, manualScrollDirection != 0 else { return }
                moveManually(direction: manualScrollDirection)
            }
        }
        manualScrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func moveManually(direction: Int) {
        scrollOffset = TeleprompterScrollMath.manualOffset(
            from: scrollOffset,
            direction: direction,
            stageHeight: stageHeight,
            maximumOffset: maxScrollOffset,
            repeatTicks: 1
        )
        notifyEndIfNeeded()
    }

    private func endManualScroll() {
        guard isManualScrollActive else { return }
        stopManualScrollForHandoff()
        finishTransientNavigationIfPossible()
    }

    /// Returns whether this event belongs to the stage's wheel lifecycle and
    /// should therefore be consumed by the viewport-local monitor.
    private func handleScrollWheel(_ event: NSEvent) -> Bool {
        let hasVerticalDelta = event.scrollingDeltaY != 0
        let wasCancelled = event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.cancelled)
        let momentumEnded = event.momentumPhase.contains(.ended)
        let regularPhaseEnded = event.phase.contains(.ended)

        // Zero-delta terminal events matter only when they close an active
        // wheel gesture. Horizontal-only and unrelated zero-delta events keep
        // their normal AppKit routing.
        guard hasVerticalDelta || (isWheelScrollActive && (wasCancelled || momentumEnded || regularPhaseEnded)) else {
            return false
        }

        if hasVerticalDelta {
            beginTransientNavigation()
            stopManualScrollForHandoff()
            isWheelScrollActive = true

            scrollOffset = TeleprompterScrollMath.wheelOffset(
                from: scrollOffset,
                scrollingDeltaY: event.scrollingDeltaY,
                hasPreciseDeltas: event.hasPreciseScrollingDeltas,
                coarseRowHeight: Self.teleprompterTextRowHeight,
                maximumOffset: maxScrollOffset
            )
            notifyEndIfNeeded()
        }

        if wasCancelled {
            cancelWheelScrollWithoutResuming()
        } else if momentumEnded {
            // Momentum's final event may carry a useful final delta. Apply it
            // above, then resume immediately rather than waiting to debounce.
            endWheelScroll()
        } else {
            // A regular `.ended` may be followed by momentum, so leave the
            // short debounce in place for that gap and for phase-less mice.
            scheduleWheelScrollEnd()
        }
        return true
    }

    private func beginTransientNavigation() {
        if !isManualScrollActive && !isWheelScrollActive {
            shouldResumeAfterTransientNavigation = isPlaying
        }
        pauseForManualNavigation()
    }

    private func scheduleWheelScrollEnd() {
        wheelScrollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated { endWheelScroll() }
        }
        wheelScrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func endWheelScroll() {
        guard isWheelScrollActive else { return }
        wheelScrollTimer?.invalidate()
        wheelScrollTimer = nil
        isWheelScrollActive = false
        finishTransientNavigationIfPossible()
    }

    private func cancelWheelScrollWithoutResuming() {
        guard isWheelScrollActive else { return }
        stopWheelScrollForHandoff()
        // A cancelled trackpad gesture is not an arrow-button release; it
        // deliberately discards the shared resume intent.
        if !isManualScrollActive {
            shouldResumeAfterTransientNavigation = false
        }
    }

    private func stopManualScrollForHandoff() {
        manualScrollTimer?.invalidate()
        manualScrollTimer = nil
        isManualScrollActive = false
    }

    private func stopWheelScrollForHandoff() {
        wheelScrollTimer?.invalidate()
        wheelScrollTimer = nil
        isWheelScrollActive = false
    }

    private func finishTransientNavigationIfPossible() {
        guard !isManualScrollActive, !isWheelScrollActive else { return }
        let shouldResume = shouldResumeAfterTransientNavigation
        shouldResumeAfterTransientNavigation = false
        if shouldResume,
           maxScrollOffset > 0,
           scrollOffset < maxScrollOffset,
           !isReduceMotionActive {
            isPlaying = true
        }
    }

    private func cancelTransientNavigation(resumePlayback: Bool) {
        let shouldResume = resumePlayback && shouldResumeAfterTransientNavigation
        stopManualScrollForHandoff()
        stopWheelScrollForHandoff()
        shouldResumeAfterTransientNavigation = false
        if shouldResume,
           maxScrollOffset > 0,
           scrollOffset < maxScrollOffset,
           !isReduceMotionActive {
            isPlaying = true
        }
    }

    private func advanceScroll(now: Date) {
        guard let lastTickDate else { return }
        self.lastTickDate = now
        let elapsed = max(0, now.timeIntervalSince(lastTickDate))
        let distance = TeleprompterScrollMath.scrollStep(
            maximumOffset: maxScrollOffset,
            wordCount: wordCount,
            wpm: wpm,
            interval: CGFloat(elapsed)
        )
        scrollOffset = min(maxScrollOffset, scrollOffset + distance)
        notifyEndIfNeeded()
    }

    private func notifyEndIfNeeded() {
        guard contentHeight > 0, stageHeight > 0,
              scrollOffset >= maxScrollOffset else { return }
        scrollOffset = maxScrollOffset
        isPlaying = false
        stopTimer()
        guard !didNotifyEnd else { return }
        didNotifyEnd = true
        onReachedEnd()
    }

    private func pauseForManualNavigation() {
        isPlaying = false
        stopTimer()
    }

    private func resetElapsedTimeIfPlaying() {
        if isPlaying { lastTickDate = Date() }
    }

    private func clampScrollOffsetToBounds() {
        scrollOffset = TeleprompterScrollMath.clamp(scrollOffset, maximumOffset: maxScrollOffset)
    }

    private func restart() {
        cancelTransientNavigation(resumePlayback: false)
        stopTimer()
        scrollOffset = 0
        didNotifyEnd = false
        if isPlaying { startTimerIfPossible() }
    }
}

/// Observes wheel input without participating in hit testing, so the SwiftUI
/// drag gesture remains the responder for pointer drags. The AppKit monitor is
/// local to this process and further limited to this viewport's bounds.
@MainActor
private struct TeleprompterScrollWheelMonitor: NSViewRepresentable {
    /// `true` means the stage accepted this event and the local monitor should
    /// consume it; `false` preserves the event's ordinary AppKit routing.
    let onScrollWheel: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onScrollWheel: onScrollWheel)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScrollWheel = onScrollWheel
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        private final class MonitorToken: @unchecked Sendable {
            let value: Any

            init(_ value: Any) {
                self.value = value
            }
        }

        weak var view: NSView?
        var onScrollWheel: (NSEvent) -> Bool
        private var monitor: MonitorToken?

        init(onScrollWheel: @escaping (NSEvent) -> Bool) {
            self.onScrollWheel = onScrollWheel
        }

        func install(on view: NSView) {
            self.view = view
            guard monitor == nil else { return }

            let token = NSEvent.addLocalMonitorForEvents(
                matching: [.scrollWheel],
                handler: { [weak self] event in
                    guard let self, self.contains(event) else { return event }
                    return self.onScrollWheel(event) ? nil : event
                }
            )
            if let token {
                monitor = MonitorToken(token)
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor.value)
            self.monitor = nil
        }

        private func contains(_ event: NSEvent) -> Bool {
            guard let view,
                  let window = view.window,
                  event.window === window else { return false }
            let point = view.convert(event.locationInWindow, from: nil)
            return view.bounds.contains(point)
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor.value)
            }
        }
    }
}

enum TeleprompterScrollMath {
    static let dragSensitivity: CGFloat = 0.1

    /// Every non-empty answer can travel completely past the stage's top
    /// edge, including answers that are shorter than the viewport.
    static func maximumOffset(contentHeight: CGFloat) -> CGFloat {
        max(0, contentHeight)
    }

    static func clamp(_ offset: CGFloat, maximumOffset: CGFloat) -> CGFloat {
        max(0, min(max(0, maximumOffset), offset))
    }

    static func dragOffset(
        startOffset: CGFloat,
        translationHeight: CGFloat,
        maximumOffset: CGFloat,
        sensitivity: CGFloat = dragSensitivity
    ) -> CGFloat {
        clamp(startOffset - translationHeight * sensitivity, maximumOffset: maximumOffset)
    }

    static func manualOffset(
        from offset: CGFloat,
        direction: Int,
        stageHeight: CGFloat,
        maximumOffset: CGFloat,
        repeatTicks: Int
    ) -> CGFloat {
        let tickCount = max(0, repeatTicks)
        guard direction != 0, tickCount > 0 else {
            return clamp(offset, maximumOffset: maximumOffset)
        }

        let distance = max(3, stageHeight * 0.009) * CGFloat(tickCount)
        return clamp(
            offset + (direction > 0 ? distance : -distance),
            maximumOffset: maximumOffset
        )
    }

    /// `scrollingDeltaY` already follows the user's Natural Scrolling setting.
    /// A positive document offset moves this stage's text upward, the inverse
    /// of its visual `offset(y:)` transform.
    static func wheelOffset(
        from offset: CGFloat,
        scrollingDeltaY: CGFloat,
        hasPreciseDeltas: Bool,
        coarseRowHeight: CGFloat,
        maximumOffset: CGFloat
    ) -> CGFloat {
        let multiplier = hasPreciseDeltas ? 1 : max(1, coarseRowHeight)
        return clamp(
            offset - (scrollingDeltaY * multiplier),
            maximumOffset: maximumOffset
        )
    }

    static func scrollStep(
        maximumOffset: CGFloat,
        wordCount: Int,
        wpm: Int,
        interval: CGFloat
    ) -> CGFloat {
        let duration = (CGFloat(max(1, wordCount)) / CGFloat(max(1, wpm))) * 60
        return max(0, maximumOffset) / duration * interval
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
