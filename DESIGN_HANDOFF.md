# Rehearse — macOS interview practice app

## Product direction

**Working name:** Rehearse
**One-line promise:** Keep prepared interview answers organized, then practice recalling them without seeing the answer first.

The product should feel like a focused native notes app, not an interview-management dashboard. The core loop is deliberately small:

1. Capture a question and an answer.
2. Select any question to edit or review its answer.
3. Enter Practice mode to recall the answer before revealing notes.
4. Rate confidence so weak answers naturally return to the top.

All content is local-first and continuously saved. There is no manual Save button and no separate edit mode.

## Recommended information architecture

Use a native three-pane `NavigationSplitView`.

### 1. Library sidebar

- **All questions**
- **Starred**
- **Needs practice**
- A user-created list of interviews, named `Company — Role`
- A small local-save status at the bottom

The sidebar organizes questions without forcing folders or tags onto a first-time user. Tags remain optional metadata inside a question.

### 2. Question list

- Interview name and role/date
- Search scoped to the current collection
- Count of questions due for practice plus a `Practice due` action
- Question rows with prompt, category, last-practiced date, favorite state, and a restrained confidence dot
- `New question` is available from the unified toolbar and via `⌘N`

Selecting a row immediately opens the answer. Avoid a separate preview screen.

### 3. Answer editor

- Editable question as the document title
- Category, last-practiced date, favorite, and overflow actions in a quiet local toolbar
- **Talking points:** three to five short recall cues
- **Full answer:** a structured editor, defaulting to STAR for behavioral questions
- A small optional coaching note at the bottom

The editor is always live. Field chrome should appear on hover/focus and recede otherwise, so reading feels like a clean document.

## Practice mode

Practice is a focused state within the same window, not a separate window.

1. Show the question, its category, and session progress. Hide all answer content.
2. `Space` or the primary button reveals talking points.
3. A second `Space` reveals the full answer.
4. If answer auto-scroll is enabled, a short countdown begins and the full answer moves upward in a dedicated teleprompter stage.
5. The user rates recall as **Again**, **Good**, or **Confident** using `1`, `2`, or `3`.
6. Continue to the next question. `Esc` exits back to the exact selected note.

The copy should say “Rate the recall, not the performance.” This keeps the feature supportive rather than evaluative. Shuffle and “due only” can live in a small pre-session menu; they should not crowd the main editor.

### Confidence behavior for v1

- **Again:** mark `Needs practice`; surface it next session.
- **Good:** keep in normal rotation.
- **Confident:** place later in the rotation.

Do not build a complicated spaced-repetition algorithm in v1. Store practice attempts so one can be added later without a migration problem.

## Window and adaptive behavior

- **Default first-launch size:** `1120 × 720 pt`
- **Minimum useful size:** `620 × 480 pt`
- **980 pt and wider:** sidebar + question list + answer editor
- **720–979 pt:** collapsible sidebar + question list + answer editor
- **Below 720 pt:** one pane at a time with native back navigation
- Keep the answer column readable at a maximum text width of roughly `710 pt`.

Remember and restore:

- Window size and position
- Split-view column widths
- Sidebar visibility
- Last selected interview and question
- Whether the main window is snapped below the camera, and the display it was snapped to
- Last active mode (restore the editor, not an unfinished practice reveal)
- Editor scroll position when practical

Use normal SwiftUI scene restoration with a stable bundle identifier. `.defaultSize(width:height:)` is only the first-launch default. Keep the window resizable; do not apply `.windowResizability(.contentSize)`. If restoration proves unreliable for the deployment target, bridge to `NSWindow.setFrameAutosaveName` with a unique name for the main window.

### Snap below camera

Add a persistent **Snap below camera** button to the leading side of the unified title bar, beside the sidebar control. Use an SF Symbol that reads as a camera/center anchor, a tooltip, and an accessibility label; do not rely on the icon alone. The command should also be available from the **Window** menu for keyboard and VoiceOver users.

When activated:

- Use the screen containing most of the current window, not always the Mac’s primary screen.
- Move the window so its horizontal center aligns with that screen’s camera/notch centerline.
- Place its top edge at the screen’s usable top edge with an `8 pt` breathing gap below the menu bar/camera safe area.
- Preserve the current window size unless it must be clamped to the display’s visible frame.
- Show a selected state on the title-bar button and change its tooltip to **Unsnap from camera**.
- Animate the move with a restrained ease-out transition; move instantly when Reduce Motion is enabled.

On a notched MacBook display, use `NSScreen` safe-area/auxiliary-area information rather than hard-coded notch dimensions. macOS does not expose the physical position of arbitrary external webcams, so on a display without a reported camera/notch area, assume the webcam is centered at the top and align to the screen midpoint. This fallback should still be labeled **Snap below camera** for consistency.

While snapped, maintain these frame invariants:

```text
window.frame.midX == cameraAnchorX
window.frame.maxY == cameraAnchorY
```

Horizontal resizing expands or contracts equally to the left and right, regardless of which side or lower corner the user drags. Vertical resizing keeps the top edge fixed and grows or contracts downward. Do not merely recenter after a normal edge resize, because that lets the resize handle drift away from the pointer. During live resize, calculate width from the fixed centerline (`width = 2 × abs(pointerX − cameraAnchorX)`) or provide equivalent custom symmetric resize tracking so the dragged edge remains under the pointer. The top edge itself remains an anchor while this mode is active.

Clamp the resulting frame to the current screen’s visible width with at least `12 pt` side margins and continue honoring the app’s minimum size. If a requested width cannot fit, stop at the maximum instead of silently unsnapping.

The camera snap releases when the user drags the window away from its anchor, clicks the selected snap button again, enters full screen, or uses a macOS tiling command. Normal resizing does not release it. When displays are attached, removed, rotated, or have their resolution changed, recompute the anchor and keep the window visible. On relaunch, restore the saved width and height first, then recompute the anchor against the saved display if it still exists; otherwise use the screen containing the restored window.

## Settings

Use a standard macOS Settings scene opened from **Rehearse → Settings…** or `⌘,`. A single compact window with **Appearance** and **Practice** sections is preferable to tabs because there are only a few controls. Settings take effect live and persist globally. Keep the Settings window and confirmation dialogs fully opaque.

### Appearance — window transparency

Add a **Window transparency** slider with a numeric percentage:

- Range: `0–40%`
- Default: `0%` beyond the normal macOS material effect
- Left endpoint: **Opaque**
- Right endpoint: **More transparent**
- Persist the chosen value between launches and apply it to both the library and Practice mode.

Transparency should affect window background materials only. Text, icons, controls, focus rings, selection states, popovers, and sheets remain fully opaque and high contrast. Use a blurred/tinted `NSVisualEffectView` or equivalent material behind the SwiftUI content; do **not** implement this by lowering `NSWindow.alphaValue`, because that also fades text and controls. Keep enough tint behind text that the app remains readable over a busy window.

Apply slider changes live so the user can judge the result against whatever is behind the app. When macOS **Reduce Transparency** is enabled, force an effective value of `0%`, disable the slider, and show “Controlled by Reduce Transparency.” With **Increase Contrast**, strengthen surface tint and separators.

### Practice — answer auto-scroll

Add an **Auto-scroll full answers** switch. Keep it **Off by default** so motion never starts unexpectedly. When enabled, reveal these subordinate controls:

- **Reading speed:** `70–200 WPM`, default `120 WPM`, with a live numeric readout
- **Start delay:** `Immediately`, `3 seconds`, or `5 seconds`; default `3 seconds`

Auto-scroll runs only in Practice mode and only after the full answer is revealed. It never moves the editor or the talking-points view.

#### Teleprompter presentation

Once the full answer is revealed, give it a dedicated reading stage:

- Keep the question, category, and session progress fixed above the stage.
- Present the answer left-aligned at approximately `20–22 pt` with generous line height and a maximum readable width around `680 pt`.
- Start the answer after exactly one text-line of top buffer. That buffer scrolls with the document and is not vertical centering; the entire answer, including a short answer, can still scroll upward until it has exited the stage.
- A subtle bottom fade may indicate movement, but it must not obscure the first line at the top of the stage.
- Pin a compact transport below the stage with **Restart**, **Play/Pause**, and the current WPM. Rating controls appear when the end is reached; shortcuts `1`, `2`, and `3` remain available after the full answer is revealed.

After the configured delay, move the text upward at a constant perceived reading speed. Base timing on word count rather than arbitrary pixels: `duration = wordCount ÷ WPM × 60`. Drive movement from elapsed time so it remains stable if frames are dropped. Stop after the final line has exited the stage; never scroll it under the transport.

Teleprompter interaction rules:

- Before the full answer appears, `Space` keeps its reveal behavior. After it appears, `Space` toggles Play/Pause.
- Trackpad, mouse-wheel, scrollbar, or keyboard scrolling pauses immediately and resumes from the user’s new position.
- **Restart** returns to the top and reruns the chosen delay.
- A new question always starts at the top.
- Short answers remain manually and automatically scrollable until they exit the stage.
- Losing window focus, minimizing the app, display sleep, or resizing pauses playback.
- On resize or text-size changes, preserve the nearest visible paragraph rather than a raw pixel offset.
- Reaching the end stops playback; it never loops.

Changing WPM from the in-session transport updates the same saved preference as the Settings slider, so the next session uses the user’s latest comfortable pace.

## Visual language

The visual direction is calm, editorial, and distinctly macOS:

- System SF typefaces and SF Symbols
- Unified title bar/toolbar with standard traffic-light placement
- Translucent system sidebar and legibility-preserving window materials; user-adjustable background transparency
- System selection/accent color, with indigo as the recommended default
- Neutral surfaces, 1 px separators, and no decorative gradients
- `7–9 pt` control radii, `10–12 pt` content radii
- Comfortable row heights; avoid dense table styling
- Use semantic system red/amber/green only for confidence, always paired with text
- Full light and dark mode support through semantic colors, not duplicated hard-coded palettes

Recommended type scale:

- Question/document title: `25 pt`, medium
- Collection title: `19 pt`, medium
- Body/editor: `13–14 pt`, regular
- Sidebar/list row: `13 pt`
- Metadata: `11–12 pt`

## First launch and empty states

Do not force a tutorial. The empty library should show:

- Title: **Prepare your first interview**
- Body: “Keep questions, talking points, and polished answers together—then practice recalling them.”
- Primary action: **Create interview**
- Secondary action: **Explore a sample**

Creating an interview asks only for company, role, and an optional date. Never reinsert sample data merely because the user deleted every record; record sample/onboarding completion separately.

An interview with no questions should show one inline action: **Add your first question**.

## Core interactions and shortcuts

| Action | Shortcut |
| --- | --- |
| New question | `⌘N` |
| Search current interview | `⌘F` |
| Start practice | `⌘Return` |
| Navigate questions | `↑` / `↓` |
| Reveal in practice; then pause/resume auto-scroll | `Space` |
| Rate Again / Good / Confident | `1` / `2` / `3` |
| Exit practice | `Esc` |
| Toggle sidebar | `⌃⌘S` or standard macOS sidebar command |
| Snap/unsnap below camera | Title-bar button or Window menu |
| Open Settings | `⌘,` |

Support context menus for duplicate, move, favorite, and delete. Deletion requires confirmation only when the answer is non-empty; after deletion, select the nearest remaining row.

## Suggested data model

### Interview

- `id: UUID`
- `company: String`
- `role: String`
- `interviewDate: Date?`
- `sortIndex: Int`
- `createdAt: Date`
- `updatedAt: Date`
- relationship: ordered `[Question]`

### Question

- `id: UUID`
- `prompt: String`
- `category: QuestionCategory`
- `talkingPoints: [String]`
- `answerFormat: AnswerFormat` (`star`, `outline`, `plain`)
- `situation`, `task`, `action`, `result`: optional strings
- `plainAnswer: String?`
- `tags: [String]`
- `isFavorite: Bool`
- `confidence: Confidence` (`again`, `good`, `confident`, `unrated`)
- `sortIndex: Int`
- `createdAt: Date`
- `updatedAt: Date`
- relationship: `[PracticeAttempt]`

### PracticeAttempt

- `id: UUID`
- `rating: Confidence`
- `practicedAt: Date`

### App preferences

Store lightweight global preferences with `@AppStorage` / UserDefaults rather than SwiftData:

- `windowTransparency: Double` — default `0.0`, clamped to `0.0...0.4`
- `autoScrollAnswers: Bool` — default `false`
- `teleprompterWPM: Int` — default `120`, clamped to `70...200`
- `teleprompterStartDelay: Int` — default `3`, allowed values `0`, `3`, or `5`

Keep camera-snap state with the main window’s scene/restoration state rather than treating it as a global appearance preference:

- `isCameraSnapped: Bool`
- `cameraSnapDisplayID: CGDirectDisplayID?`

Persist selection by UUID, never by holding a stale model reference across launches.

## Persistence requirements

- Use SwiftData in the app scene’s shared `ModelContainer`.
- Save edits after a short `400–600 ms` debounce and immediately when focus changes or the app resigns active.
- Surface save failures; a green “Saved locally” indicator should only appear after a successful save.
- Keep the stable bundle identifier and storage schema across builds.
- Do not sort the visible question list directly by `updatedAt`; otherwise a row can jump while the user types. Use explicit `sortIndex` plus user-selected sort modes.
- On launch, restore saved interview/question IDs if they still exist. Otherwise choose the nearest sensible fallback or show the empty state.
- Save Settings changes immediately. Restore transparency, auto-scroll enablement, WPM, and delay before presenting the main window so it does not visibly jump between defaults and saved values.

## Accessibility

- Every icon-only button needs an accessibility label and tooltip.
- All actions must be keyboard reachable; preserve visible system focus rings.
- Confidence never relies on color alone.
- Respect Reduce Motion and Increase Contrast.
- Support Dynamic Type-equivalent macOS accessibility text sizing without clipping.
- Practice reveal, auto-scroll countdown, paused/resumed, and end states should be announced through VoiceOver without repeatedly announcing moving lines.
- Keep teleprompter text as one stable accessible document; do not recreate individual lines during movement or move keyboard focus as it scrolls.
- Pause auto-scroll whenever VoiceOver focus enters the answer. Under **Reduce Motion**, disable automatic movement and offer manual scrolling/page movement with a brief explanation.
- Under **Reduce Transparency**, keep all surfaces opaque regardless of the saved transparency preference.
- Maintain at least a `44 × 44 pt` effective target where touch/alternative pointing input is plausible; compact toolbar icons may use standard native macOS sizing.

## Acceptance criteria

1. A user can create, edit, reorder, search, favorite, and delete questions.
2. Clicking a question shows its answer with no mode switch.
3. Edits survive force quit and relaunch.
4. Relaunch restores the last valid interview and question.
5. Resizing, moving, quitting, and reopening restores the previous window frame.
6. The layout remains usable at `620 × 480`, the default size, and full screen.
7. Practice hides the answer until reveal and records one rating per completed prompt.
8. Deleting the selected question never leaves a stale or blank-bound editor.
9. Deleting all content does not recreate demo data.
10. The title-bar snap button centers the window below the camera area on the current display and clearly indicates its active state.
11. While snapped, width changes remain exactly centered, the top edge remains fixed, and the resize handle tracks the pointer without jumping.
12. Manual window movement, full screen, and macOS tiling release the snap; ordinary resizing does not.
13. Camera snapping survives relaunch and handles display removal, resolution changes, safe areas, and non-notched external displays without placing the window off-screen.
14. Window transparency can be adjusted from `0–40%`, affects backgrounds without fading content, persists across relaunch, and yields to macOS Reduce Transparency.
15. Optional auto-scroll begins only after the full answer is revealed, uses the saved WPM/delay, and never moves editor content or talking points.
16. Space, manual scrolling, window deactivation, and resizing pause auto-scroll correctly; Restart and resume preserve predictable positions.
17. Answers of every length start at the top, scroll fully out of the stage, and never loop.
18. Light mode, dark mode, keyboard-only use, VoiceOver labels, Reduce Motion, Reduce Transparency, and Increase Contrast are verified.

## Recommended implementation prompt for the next AI

> Build the native macOS SwiftUI app described in `DESIGN_HANDOFF.md`. Use `NavigationSplitView`, SwiftData, `@AppStorage`, semantic system colors, SF Symbols, and native toolbar/sidebar conventions. Implement local autosave, scene/window restoration, adaptive three/two/one-pane behavior, keyboard shortcuts, empty states, background-only window transparency, the camera-centered snap mode with true symmetric live resizing, and the progressive-reveal Practice mode with optional WPM-based teleprompter scrolling. Respect macOS safe areas, display changes, and accessibility display settings, and treat every acceptance criterion as a required test. Do not substitute a browser-only app because browser security cannot reliably restore the enclosing window frame.
