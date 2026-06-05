> **Provenance.** Findings from a multi-agent web-research pass (5 lanes — IMK
> mechanics, IMK pass-through/activation, Wispr Flow & peers, Chromium AXTextMarker,
> open-source landscape — each with an independent verification sub-pass), 2026-06.
> Every load-bearing claim is tagged **[verified]** / **[inference]** / **[speculation]**
> with the source URL; **⚠ VERIFY-PASS** marks where verification nuanced or
> contradicted the first-pass claim. Pair with [`ax-injection.md`](ax-injection.md)
> (what we do today).

# macOS text capture/insert/edit — research findings

> **Scope:** macOS-only (target macOS 26 "Tahoe"), Swift 6. Focus: detecting the focused text box, reading it, and inserting/**editing** text — especially in Chromium/Electron (Slack, Claude desktop, VS Code, Discord, Notion).

---

## 1. Input Method Kit: the real blockers (and the pass-through question)

### Does an IM solve Chromium insertion? Can it READ/REPLACE existing text?

**Insertion: yes, this is the architecturally correct path.** An IMK input method commits text by calling `insertText:replacementRange:` on the `IMKTextInput` client proxy; composition/preview uses `setMarkedText:selectionRange:replacementRange:`. **[verified]** — IMKTextInput protocol header at https://github.com/w0lfschild/macOS_headers/blob/master/macOS/Frameworks/InputMethodKit/365.16.13/IMKTextInput-Protocol.h ; corroborated by Apple's `IMKInputSession.h` (10.6 SDK).

That committed text flows through the same TSM → `NSTextInputContext` → `NSTextInputClient` channel the OS uses for CJK and dead-key input. **[verified]** TSM is the only IMKServer client — Apple IMK Release Note: "The only client in OS X v10.5 is the Text Services Manager" (https://developer.apple.com/library/archive/releasenotes/Cocoa/RN-InputMethodKit/index.html). **[verified]** Chromium implements the full `NSTextInputClient` protocol in `RenderWidgetHostViewCocoa` and its `insertText:replacementRange:` performs a **real** commit (`ImeCommitText()` → mojo `WidgetInputHandler` → Blink `InputMethodController::CommitText` → `Editor::InsertText`, dispatching `beforeinput`/`compositionend`) — https://chromium.googlesource.com/chromium/src/+/7b4466da9d211e0e73a0b5d4dcc0dd76929f43a3/content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm

**The last hop is [inference], not [verified].** No single primary doc states "IMK `insertText` reaches Chromium's contenteditable DOM" end-to-end; it is assembled from (a) TSM-is-the-IMK-client and (b) Chromium's verified `NSTextInputClient` implementation. **Empirical corroboration is strong but indirect:** Rime/Squirrel (the macOS Rime IME) is used daily for CJK input into VS Code, Slack, Discord, Notion — all Electron. **Treat "IMK lands text in Chromium" as a high-confidence inference to prototype, not a quoted fact.**

**Replacement: supported in principle, two Chromium caveats.**
- `insertText:replacementRange:` takes an **absolute document range** (`NSNotFound` = insert at caret) — *not* relative to the string arg. **[verified].**
- **⚠ VERIFY-PASS caveat:** a non-`NSNotFound` `replacementRange` is only honored if the client implements **TSMDocumentAccess**; otherwise it's *silently ignored* and text goes to the current selection. Chromium/Electron have incomplete TSM support, so a document-relative **edit** may be dropped even when plain insert-at-caret works. **Implication:** rely on IMK for *insert-at-caret* and *replace-current-selection* only.

**Reading existing text: the IMK path's hard limit in Chromium. [verified].** Chromium's `NSTextInputClient` only caches the **current selection** and **marked/composition text**, returning `nil` for ranges outside that cache — "never the full document content" (`render_widget_host_view_mac.mm`). **An IMK Relay could insert/replace-around-caret in Chromium but could not read the whole field through IMK.**

### The pass-through question, answered

**Yes, you can forward keystrokes. [verified].** Returning `NO` from an `IMKInputController` event method passes the event through to the client app. Verbatim from IMKInputController.h: `didCommandBySelector:client:` — "It is necessary for this method to return YES or NO so the event can be passed through to the client if it is not handled." Corroborated by a real IME (XIME). https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX10.5.sdk/System/Library/Frameworks/InputMethodKit.framework/Versions/A/Headers/IMKInputController.h

**The keyboard-LAYOUT catch — and why it largely does NOT bite Relay. [inference].** The classic "custom IM forces US-QWERTY" problem is about translating *physical key positions* to characters. Relay commits a **finished ASR string** via `insertText:`, which does *no* physical-key translation, so committed text is layout-independent. The layout problem only bites if Relay lets the user *type through* the IM (rare during a speak-only dictation window). If ever needed, the lever is `overrideKeyboardWithKeyboardNamed:`. **Karabiner-style virtual-HID is NOT a fix** — its keycodes are ANSI-layout-dependent, same fragility as our CGEvent fallback.

### Programmatic enable/select without manual System Settings — possible or not?

**Partly. The API is legitimate; the consent is not silent.** `TISEnableInputSource` is "mainly intended for input methods … makes the specified input source available in UI for selection"; `TISSelectInputSource` requires the source be enabled first. **[verified]** against the 10.6/10.8 TextInputSources.h. But on modern macOS:
- **[verified]** a **"X wants to activate the third-party input method…"** consent prompt recurs on boot/refocus even when already enabled+selected — withfig/fig #2405/#2406/#2426.
- **[verified]** system-level Monterey-era gate (Keyboard Maestro forum; Apple thread) — affects any app using `TISEnableInputSource`/`TISSelectInputSource`.
- **⚠ VERIFY-PASS:** fresh install into `~/Library/Input Methods` often needs logout/login before TIS picks it up; System Settings won't live-update; even a stock layout must already be *enabled* before `TISSelectInputSource` can switch to it (Quicksilver PR #987).
- **[verified] `TISSelectInputSource` alone is unreliable** — the menu icon changes but the source may not actually switch until re-activation/keypress; `macism` works around it with a TemporaryWindow + ~**150 ms** settle on macOS 26. https://github.com/laishulu/macism

### Verdict on "switch to our IM only during dictation, then switch back"

**Viable in principle, unproven by any shipping product, operationally heavy. [inference].** `macism`/Quicksilver switch among the user's *existing* sources, not to a *self-installed transient* IME, so the exact pattern is inferred-viable, not demonstrated. Expect: a consent prompt on first activation, possible logout/login on install, ~150 ms switch latency each way (acceptable behind the ASR finalize window), and an unresolved **HUD/flag** question (the near-cursor input-source popup can be suppressed via `defaults write … TSMLanguageIndicatorEnabled 0`, but whether a *programmatic* switch even raises it on macOS 26 is **untested**).

### Actual blockers beyond "writing more code"

1. **Separate signed/notarized bundle in `~/Library/Input Methods`** with required Info.plist keys (`InputMethodConnectionName`, `InputMethodServerControllerClass`, `ComponentInputModeDict`, `LSUIElement`). **[verified]** — Squirrel's Info.plist + ensan-hcl IMKitSample.
2. **Sandbox/NSConnection:** under App Sandbox, `InputMethodConnectionName` **must** equal `$(PRODUCT_BUNDLE_IDENTIFIER)_Connection` + entitlement `com.apple.security.temporary-exception.mach-register.global-name`. **[verified].**
3. **User-consent prompt on programmatic activation**, flaky/recurring. **[verified].**
4. **Possible logout/login on first install**; System Settings won't live-update. **[verified].**
5. **Secure Input suspends third-party IMEs** → password fields are a hard no. **[inference]** (TN2150 doesn't mention IMEs).
6. **Full-field READS in Chromium remain unsolved by IMK** (selection/marked text only). **[verified].**
7. **~150 ms switch latency each way; switch-back latency unquantified.** **[verified]** forward case.

**Permission upside [inference]:** keys arrive via TSM (not a CGEventTap/HID seize), so the IM path needs **no Accessibility and no Input Monitoring** — the consent is "enable a third-party input source" instead. **⚠ Counter-nuance:** one MacSKK report says an IME got *no* key events without Input Monitoring + Accessibility; for Relay's *insert-only* use likely moot, but verify.

---

## 2. Doing Chromium/Electron right (what Wispr Flow likely does)

### AXTextMarker: the correct AX path — read & set-selection work; replace does not (today)

**Chromium and WebKit expose web text through the `AXTextMarker`/`AXTextMarkerRange` family — node-anchored opaque DOM positions — NOT the offset-based `kAXValue`/`AXSelectedTextRange` Relay currently uses.** This is the API VoiceOver drives for contenteditable.

- **Markers are node-anchored serialized DOM positions**, so they follow DOM edits better than flat offsets. **[verified]** — `ui/accessibility/platform/browser_accessibility_cocoa.mm`; WebKit `AXTextMarker.h`.
- **⚠ VERIFY-PASS upgrade:** `AXTextMarker`/`AXTextMarkerRange` became **public in macOS 12** with official docs (`AXTextMarkerRangeCopyStartMarker`, etc.). On macOS 26 they are documented public APIs. https://developer.apple.com/documentation/applicationservices/axtextmarker

**Reading — works, with a correction. [verified] / ⚠ mixed.** Implemented in current Chromium: `AXStartTextMarker`, `AXEndTextMarker`, `AXSelectedTextMarkerRange` (getter), `AXStringForTextMarkerRange`, `AXBoundsForTextMarkerRange` (returns on-screen `NSRect` — directly usable to anchor Relay's caret overlay), `AXTextMarkerForIndex`, `AXIndexForTextMarker`, plus word/line navigation.
  - **⚠ VERIFY-PASS CONTRADICTION:** `AXStartTextMarkerForBounds`, `AXEndTextMarkerForBounds`, `AXTextMarkerForPosition` are **advertised but inert** in Chromium (in the names array with no handler). **Do NOT rely on screen-point→marker hit-testing.**

**Set-selection / caret placement — works, and replaces the ⌘A→→ hack. [verified].** Chromium **implements the `AXSelectedTextMarkerRange` *setter*** (the 2017 snapshot most blogs cite did NOT — stale). Current `main` (~lines 3090-3103):

```objc
if ([attribute isEqualToString:NSAccessibilitySelectedTextMarkerRangeAttribute] &&
    _owner->HasState(ax::mojom::State::kEditable)) {
  AXRange range = AXTextMarkerRangeToAXRange(value);
  if (range.IsNull()) return;
  manager->SetSelection(AXRange(range.anchor()->AsDomSelectionPosition(),
                                range.focus()->AsDomSelectionPosition()));
}
```

It dispatches a **real `ax::mojom::Action::kSetSelection`** using DOM positions — **not** `kSetValue`, **no** DOM rebuild. **WebKit mirrors this** (the setter sits *before* the `isTextControl()` branch, so it applies to arbitrary contenteditable, whereas plain `SelectedTextRange` setters are *inside* `isTextControl()` and inert for contenteditable — exactly Relay's pain). https://raw.githubusercontent.com/chromium/chromium/main/ui/accessibility/platform/browser_accessibility_cocoa.mm

**Recipe to place a caret at index N (replacing ⌘A→→):** `AXTextMarkerForIndex(N)` → degenerate range via `AXTextMarkerRangeForUnorderedTextMarkers([m,m])` → SET `AXSelectedTextMarkerRange`. Read selection: GET `AXSelectedTextMarkerRange` → `AXStringForTextMarkerRange`/`AXBoundsForTextMarkerRange`. **[verified]** primitives; **[inference]** that it survives a later mutation better than an offset write — **validate empirically.**

**Replacing text via AX — do NOT rely on it in Chromium. [verified].** The `AXTextOperation` Replace path → `ReplaceRanges` is gated on `kMacAccessibilityTextOperation`, which is `FEATURE_DISABLED_BY_DEFAULT`. There is **no** classic `kAXReplaceRangeWithTextAction` in either engine. WebKit's `accessibilityReplaceRange:withText:` works (Safari/WKWebView) but **Chromium's `BrowserAccessibilityCocoa` does NOT implement it.** **Conclusion: in Chromium, SET the selection via marker range, then INSERT via keystroke/paste — you cannot AX-replace a range.**

**Why offset writes fail (root-caused). [verified].** `setAccessibilityValue:` → `kSetValue` (rebuilds field, caret→0; only for atomic `<input>`/`<textarea>`); `setAccessibilitySelectedTextRange:` → `kSetSelection` (offset, `kEditable`-gated); `setAccessibilitySelectedText:` → `kReplaceSelectedText` (atomic only). The marker path avoids `kSetValue`.

**Two durability caveats:**
- **Caret-survival is [inference], not benchmarked** — validate on Slack/Notion/VS Code/Discord. Two relevant Chromium bugs (370009398, 379186294) are **sign-in-walled and unread** — risk areas.
- **Migration risk [verified]:** the setter is reachable today only because `SelectedTextMarkerRange` is not yet in `newAccessibilityAPIMethodToAttributeMap` (gated by `kMacAccessibilityAPIMigration`, also disabled-by-default). **Pin behavior to a Chrome version.**

**Tree is lazy/async. [verified].** Built only after `AXEnhancedUserInterface`/`AXManualAccessibility`; **first walk can return empty** → set **both** flags and retry after ~200 ms. Electron historically didn't *advertise* `AXManualAccessibility` (fixed in PR #38102, version-dependent) → don't treat the setter's return value as fatal.

### What Wispr Flow / peers actually use — and the Slack "edit then send" behavior

**Wispr Flow's primary insertion is clipboard paste (⌘V) with save/restore — NOT a fancier AX write and NOT an IME. [verified].** "On Mac and Windows, Flow temporarily uses your clipboard to paste text and restores your previous contents afterward." Permissions: **Accessibility + Microphone only** (no Input Monitoring, Apple Events, or Automation). https://docs.wisprflow.ai/articles/3152211871-setup-guide

**Slack "edit then send" is mundane. [verified].** Text is pasted into the **real focused contenteditable**, so normal editing works; "press enter" makes Flow **synthesize a Return after pasting** — no Slack API.

**The single most actionable Wispr finding. [verified].** Wispr's v2.0.0 Slack/Electron fix was **exactly Relay's problem**: these apps "often don't report back the text currently in the input field, which previously caused Wispr Flow to treat successful dictations as failures." They "now use a more reliable method to confirm whether text was inserted" + double-insertion safeguards. → **Stop using `kAXValue`/`kAXNumberOfCharacters` read-back as the success oracle. Paste, assume success, guard double-insert, fall back only on a *real* failure signal.** **⚠ The exact new confirmation signal is NOT disclosed.**

**Command Mode (voice editing) reads the user's HIGHLIGHTED selection and replaces via paste — it does NOT read the whole field via `kAXValue`. [verified].** **Guidance for Relay's EDIT goal: drive a selection, then paste the replacement.**

**Peers converge on the same stack.** superwhisper (paste default + experimental keypress fallback + clipboard restore), Aqua Voice (paste), MacWhisper (paste; dictation only in the **non-MAS** build — sandbox can't ship global insertion). **No surveyed third-party tool ships an IME; Apple's built-in Dictation is the one true system input method** — which is *why* it works flawlessly in Chromium. **So an IME would let Relay *exceed* Wispr in exactly the fields where Wispr shows a manual Copy button.**

---

## 3. Technique catalog

Permission note: Accessibility covers AX reads/writes **and** CGEvent posting **and** paste; Input Monitoring is listen-only and does **not** satisfy `AXIsProcessTrusted`; the IME path needs neither.

| Technique | Works in Chromium? | Read + edit existing text? | Permission | Caret correctness | Notes / source |
|---|---|---|---|---|---|
| **AX `kAXSelectedText` write** | Often **inert** (atomic fields only) | Edit-selection only | Accessibility | OK native | `ax_platform_node_cocoa.mm` |
| **AX `kAXValue` whole-write** | atomic yes; **contenteditable rebuilds, caret→0** | Replace-all only | Accessibility | **Bad** | `HasAction(kSetValue)` |
| **AX `AXSelectedTextRange` (offset)** | **Inert** in contenteditable | No | Accessibility | N/A | `kEditable`-gated |
| **AX `AXSelectedTextMarkerRange` SET** | **YES** — real `kSetSelection` via DOM positions | Sets selection (then keystroke/paste) | Accessibility | **Good** (DOM-anchored) | the ⌘A→→ replacement |
| **AX `AXTextMarker` READ** | **YES** (after async tree + retry) | Read yes; replace **no** | Accessibility | bounds usable for overlay | `*ForBounds` inert in Chromium |
| **AX `AXTextOperation` Replace** | **NO** — flag disabled-by-default | would, if enabled | Accessibility | n/a | `accessibility_features.cc` |
| **WebKit `accessibilityReplaceRange:withText:`** | Safari/WKWebView only | Yes (WebKit) | Accessibility | good | Chromium doesn't implement |
| **Clipboard paste (⌘V) + restore** | **YES** (de-facto escape hatch) | Replace-selection (paste over highlight) | Accessibility | inherits app paste | Wispr/superwhisper default |
| **CGEvent keystrokes** | YES (fallback) | No (blind) | Accessibility/Input Monitoring | app-native | layout-fragile for vkeys |
| **IMK `insertText:replacementRange:`** | **YES** (inference; CJK IMEs prove the channel) | Insert + replace-selection; **read = selection/marked only** | **None** (IM consent) | **Good** (Blink editor) | needs installed IME bundle + consent |

Landscape sources: Espanso native.mm https://raw.githubusercontent.com/espanso/espanso/master/espanso-inject/src/mac/native.mm ; Talon axkit https://raw.githubusercontent.com/phillco/talon-axkit/main/dictation/dictation_context.py .

---

## 4. Recommendations for Relay, ranked by impact ÷ effort

### Tier 1 — high impact, low effort

1. **Stop trusting AX value read-back as the insertion success oracle in Chromium.** Paste/write, assume success, guard double-insert, fall back to a visible affordance only on a *real* failure (the AX/IMK call errored), not "value didn't change." This is Wispr's v2.0.0 fix.
2. **Set BOTH `AXManualAccessibility` and `AXEnhancedUserInterface`, retry reads after ~200 ms; don't treat the setter return as fatal.** Cures the frozen/empty read.
3. **Adopt `AXSelectedTextMarkerRange` set-selection to replace the ⌘A→→ caret hack**, gated on `State::kEditable`. **Validate caret-survival on Slack/Notion/VS Code/Discord; pin to a Chrome version.**
4. **Anchor the caret overlay with `AXBoundsForTextMarkerRange`** (not `kAXBoundsForRange`, part of the frozen offset path). Do NOT use `*TextMarkerForBounds` (inert in Chromium).
5. **Adopt Espanso's paste timings + self-event sentinel** (post-copy 100 ms, restore 300 ms, mark synthetic events so our own tap ignores them; restore text only).

### Tier 2 — high impact, medium effort

6. **Per-bundle-id Electron/app handling, modeled on talon-axkit** (descend the tree for a real `AXTextArea`/contenteditable when `kAXFocusedUIElement` lies; `None`-vs-empty `AXValue` coercion; left/right-of-caret context).
7. **Command-Mode-style editing via selection+paste, not value-rewrite.**
8. **Secure-input safety** — `IsSecureEventInputEnabled()` + a "secure field — paste manually" affordance.

### Tier 3 — high impact, high effort / high risk (prototype first)

9. **Prototype a switch-on-dictation IMK input method** as the *premium* Chromium path (and the only route to a marked-text live-preview + guaranteed contenteditable insertion that *beats* Wispr). **First experiment:** confirm the *unverified inference* that an IMK commit actually lands in Slack/VS Code/Discord. **Risks:** end-to-end landing is inference; consent prompt flaky; possible logout/login; full-field reads unsolved; secure fields excluded; switch-back latency unquantified; HUD-on-programmatic-switch untested. Refs: ensan-hcl IMKitSample, 2026 IME guidelines (shikisuen.medium.com), macism.

### Explicitly do NOT do

- **Karabiner-style virtual HID** for insertion (same layout fragility, no Chromium benefit). **[verified]**
- **Rely on AX to *replace* a range in Chromium** (`kMacAccessibilityTextOperation` off; WebKit-only). **[verified]**
- **Ship global insertion in a Mac App Store build** (sandbox forbids it). **[verified]**

---

## 5. Open questions / what could not be confirmed

1. **Does an IMK `insertText:` commit actually land in Chromium contenteditable end-to-end?** Assembled inference (strong corroboration: Rime/Squirrel into Electron). **Prototype.**
2. **Does an `AXSelectedTextMarkerRange`-set caret survive a later contenteditable mutation better than an offset write?** No benchmark — **[inference]**. Chromium bugs 370009398 / 379186294 are sign-in-walled and unread.
3. **What is Wispr's "more reliable confirmation" signal (v2.0.0)?** Not disclosed.
4. **Does a *programmatic* `TISSelectInputSource` raise the input-source HUD on macOS 26?** Untested.
5. **Switch-back latency from a custom Latin IME?** Unquantified (macism's 150 ms is CJK takeover).
6. **Does `TISEnableInputSource` on a freshly-registered own bundle ever need a manual System-Settings "add" on macOS 26?** Unconfirmed.
7. **Does the IMK *receive* path need Input Monitoring/Accessibility?** **[inference]** no; one MacSKK report disagrees. Likely moot for insert-only.
8. **`AXTextMarkerRange` *construction* from Swift** (opaque-handle create API for the SET direction) — not located in a primary source; research before implementing.
9. **No vendor discloses the exact insert call**; no binary teardown of Wispr Flow found.
