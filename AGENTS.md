# SCHEME-DESKTOP

A GTK4 Wayland desktop shell written in Guile Scheme, built on
[Astal](https://github.com/aylur/astal) via `SCHEME-TOOLKIT`.

**Companion document:** [`SCHEME-TOOLKIT.md`](./SCHEME-TOOLKIT.md) — the reusable
library this shell consumes, and this shell's reason to exist. SCHEME-DESKTOP is
the toolkit's integration test: if a feature cannot be built here without
patching the toolkit, that is a toolkit bug.

**Target:** GTK4, Astal (GTK4 namespaces), Wayland/Hyprland. GTK3 out of scope.

**Parity target:** the union of **ags2-shell** and **colorshell**
(`~/GITE/ags-shells/{ags2-shell,colorshell}`), which between them cover the
most ground of any AGS v3 shells surveyed. Where they disagree on approach, the
choice is called out per feature.

---

## 0. Revision notes (second review, 2026-10-26)

Changes relative to the first draft, all driven by findings recorded in
`SCHEME-TOOLKIT.md` § 0 and § 3:

1. **The compositor abstraction is no longer built — it is `AstalWorkspace`**
   (ext-workspace-v1). `AstalHyprland` is used only for Hyprland-specific extras
   (clients, special workspaces, `dispatch`, binds, monitor DPMS/VRR). D3 is
   rewritten accordingly.
2. **Brightness uses `AstalBrightness`** for backlight/keyboard/LEDs; only DDC/CI
   via `ddcutil` is still ported from ags2-shell.
3. **Monitor identity uses `AstalWl4.find_output_by_gdk_monitor`**, not the
   `hyprctl monitors -j` connector hack in ags2-shell `lib/hyprland.ts`.
4. **The shell is controlled through a Guile REPL, not a request protocol.**
   `scheme-toolkit eval '(toggle-window "launcher")'` is the keybinding; the
   shell exports ordinary procedures instead of a `requestHandler` string
   switch (TOOLKIT § M0.5, modelled on `~/GIT/schemacs`). The REPL is available
   from **D0** and every later milestone's acceptance check uses it. The
   `io.Astal.Application` D-Bus interface is an optional shim so existing
   `ags toggle …` keybindings keep working during migration. No Quarrel CLI.
5. **D1's acceptance test is now concrete:** the AGS starter bar
   (`~/GITE/ags/cli/data/gtk4/Bar.tsx`) reproduced line for line in Scheme.
6. **Ordering adjusted:** toolkit M9 (process/time wrappers) and M4 (Astal
   wrappers) are now cheap and land *before* D2, so the clock uses `create-poll`
   from day one.
7. New optional features surfaced by the Astal build on this machine: idle
   auto-dim/lock via `AstalIdleNotify`, and a possible greetd greeter via
   `AstalGreet` as a third toolkit consumer.
8. **Which widget trees to copy is now decided** (§ 3.1): colorshell's
   *structure* (30-line bar, `PopupWindow` as a GObject subclass, window
   registry, control-centre tiles + pages, flat per-window directories) filled
   with ags2-shell's *content* (network/audio/bluetooth pages, notification
   lifecycle, brightness/capture services, Dock/Desktop/Overview). ags2-shell's
   "feature module exports its bar button and its window" convention is kept.
   `PopupWindow` and `PanelButton` move into TOOLKIT M5.

---

## 1. The split rule: what goes where

> **Put it in TOOLKIT if a *different* shell could plausibly want it unchanged.
> Put it in DESKTOP if it embodies a decision this shell made.**

| Belongs in TOOLKIT | Belongs in DESKTOP |
|---|---|
| Accessor/state/computed/effect/scope | Which accessors a *clock widget* binds to |
| Element runtime, `add-child!`, `For`/`With`/`This` | The bar layout and CSS classes |
| GObject service *machinery* (`define-service`) | The `NightLight`, `ScreenCapture`, `Clipboard` services |
| Astal wrappers + feature detection | Which Astal properties are surfaced in the UI |
| App shell, layer windows, per-monitor roots, `<popup-window>`, `panel-button` | Window names, anchor choices, which windows exist per monitor, what each popup contains |
| D-Bus serve/proxy helpers | The logind `Inhibit` call, `GetNameOwner` takeover policy |
| Config *engine* (schema, persist, reload) | The option schema contents |
| CSS *generation* + provider management | The stylesheet and palette rules |
| Launcher framework (plugins, frecency) | The 7 concrete plugins |
| Notification *daemon* + popup machinery | Popup placement, notification UI |
| Process/file/time/Result utilities | Which subprocesses get called |
| i18n runtime | The translation catalogue |

**Deliberate grey areas, decided:**

- **Compositor abstraction → neither; it's Astal.** `AstalWorkspace` gives
  workspaces/groups/outputs compositor-agnostically. The toolkit wraps it (M4);
  DESKTOP decides to *also* import `AstalHyprland` for clients and dispatch.
  colorshell's `src/compositor/` (1,220 lines) and matshell's
  `utils/compositor/{hyprland,river}.ts` remain useful as the reference for the
  *API shape widgets want* (`focusedWorkspace`, `focusWorkspace`, add/remove
  signals), not as code to port.
- **Colour engines (pywal16/matugen)** → **TOOLKIT**, as a pluggable interface
  (colorshell `color/engine/` has 4 implementations). The palette → CSS mapping is
  DESKTOP.
- **Desktop icons** → **DESKTOP**, firmly (~2,100 lines of shell-specific UX).
  Only file operations and grid geometry are extraction candidates.
- **Screenshot/recording orchestration** → **DESKTOP** (thin over
  `grim`/`slurp`/`wf-recorder`), using TOOLKIT's `process` and `result`.
- **Remote control** → the *mechanism* (REPL server + `eval` client) is
  TOOLKIT; the *vocabulary* (`api.scm`: `toggle-window`, `screenshot`, …) is
  DESKTOP. A per-shell `bin/scheme-desktop` is sugar over `scheme-toolkit eval`.

---

## 2. Feature inventory and parity checklist

`[A]` = ags2-shell, `[C]` = colorshell, `[M]` = matshell, `[H]` = HyprYou.
**Backend** column names what actually provides the data.

### Windows and surfaces
| Feature | Source | Milestone |
|---|---|---|
| Per-monitor bar | [A][C] | D1/D4 |
| OSD (volume/brightness) | [A][C] | D9 |
| Notification popups | [A][C] | D8 |
| Control centre / quick settings | [A][C] | D9 |
| Launcher / runner | [A][C] | D7 |
| Dock (static + autohide) | [A] | D11 |
| Desktop icons (per-monitor, DnD) | [A] | D11 |
| Overview / workspace switcher | [A] | D11 |
| Power / session menu | [A][C] | D12 |
| Apps drawer | [C] | D7 |
| Centre window | [C] | D9 |
| Lock screen | [H] | D12 |

### Services and integration
| Feature | Source | Backend | Milestone |
|---|---|---|---|
| Workspaces / outputs | [A][C][M] | **`AstalWorkspace`** | D3 |
| Clients, special workspaces, dispatch, binds | [A][C] | `AstalHyprland` | D3 |
| Volume (WirePlumber) | [A][C] | `AstalWp` | D3 |
| Network (NetworkManager) | [A][C] | `AstalNetwork` | D3 |
| Bluetooth | [A][C] | `AstalBluetooth` | D3 |
| Battery | [A][C] | `AstalBattery` | D2 |
| Media / MPRIS | [A][C] | `AstalMpris` | D3 |
| System tray (StatusNotifier) | [A][C] | `AstalTray` | D10 |
| Notification daemon + history + DND | [A][C] | `AstalNotifd` + TOOLKIT `notify` | D8 |
| Brightness: backlight, keyboard, LEDs | [A] | **`AstalBrightness`** | D10 |
| Brightness: external displays (DDC/CI) | [A] | `ddcutil` via `process` | D10 |
| Power profiles | [A] | `AstalPowerProfiles` | D10 |
| Screenshots + recording | [A][C] | `grim`/`slurp`/`wf-recorder` | D10 |
| Clipboard (`cliphist`) | [A][C] | subprocess | D10 |
| Wallpaper (per-monitor) | [A][C] | `swww`/`hyprpaper` | D4 |
| Night light | [C] | `hyprctl hyprsunset` | D10 |
| Weather | [M] | `(web client)` | D12 |
| Idle *inhibit* | [A][H] | logind D-Bus `Inhibit` (TOOLKIT `dbus` proxy) | D10 |
| Idle *detection* (auto-dim/lock) | new | **`AstalIdleNotify`** | D12 |
| Polkit auth agent | [C] | `AstalAuth` + `PolkitAgent` | D12 |
| Cava audio visualiser | [A][M] | `AstalCava` | D12 |
| Monitor identity (GdkMonitor ↔ output name) | [A][C] | **`AstalWl4`** | D4 |

### Tooling
| Feature | Source | Milestone |
|---|---|---|
| Remote control + live introspection (`scheme-toolkit eval` / `repl`) | new (TOOLKIT M0.5) | **D0** |
| `(scheme-desktop api)` — the exported procedure vocabulary keybindings call | [A] request verbs, [C] CLI commands | D4 |
| `ags quit/toggle/request/inspect/list` compatibility shim | AGS | D4 (optional) |
| Options/config with schema | [A][C][M] | D5 |
| Theming from wallpaper | [A][C][M][H] | D6 |
| i18n | [C] | D12 |
| Settings UI | [A][C][M] | D9 |
| App search / frecency | [A][C][M] | D7 |
| Geiser/Emacs attach, hot reload | new (TOOLKIT M11) | D12 |

---

## 3. Architecture

```
scheme-desktop/
  scheme-desktop/
    shell.scm              ; entry: (scheme-toolkit app) start; starts the REPL first
    api.scm                ; the procedures keybindings/tests call over the REPL
    windows.scm            ; window registry (mirrors colorshell src/windows.ts)
    monitors.scm           ; per-monitor roots (mirrors ags2-shell shell/main.tsx)
    services/
      nightlight.scm  clipboard.scm  screenshot.scm  recording.scm
      wallpaper.scm   power.scm      idle.scm        ddc.scm   auth.scm
    widgets/               ; one directory per window; see § 3.1 for the layout
      bar/  osd/  notifications/  control-center/  launcher/  apps-drawer/
      date-menu/  power-menu/  center-window/  dock/  desktop/  overview/  settings/
    style/
      palette.scm          ; wallpaper → CSS variables
      rules.scm            ; CSS generated in Scheme (TOOLKIT M7)
    config/
      schema.scm           ; option definitions + defaults
    i18n/
  tests/                   ; srfi-64; live-shell tests drive the REPL
  bin/scheme-desktop       ; `run` → scheme-toolkit run; `eval EXPR` → scheme-toolkit eval;
                           ; convenience verbs (`toggle NAME`, `screenshot area`) are eval sugar
  flake.nix  guix.scm  PKGBUILD
```

**Consumption from TOOLKIT** (the only imports DESKTOP should need):

```scheme
(use-modules (scheme-toolkit reactive))   ; create-state create-binding create-computed create-effect create-root on-cleanup
(use-modules (scheme-toolkit widget))     ; element, box label button … for-each-item with this!
(use-modules (scheme-toolkit service))    ; define-service
(use-modules (scheme-toolkit astal))      ; singletons, astal-supported?
(use-modules (scheme-toolkit app))        ; start, define-layer-window, for-each-monitor, toggle-window, quit, inspect
(use-modules (scheme-toolkit repl))       ; start-repl! (called by start), the test client
(use-modules (scheme-toolkit dbus))       ; proxy (logind), serve-interface (notifications, optional ags shim)
(use-modules (scheme-toolkit config))     ; option-schema, option
(use-modules (scheme-toolkit style))      ; apply-css, css rules
(use-modules (scheme-toolkit launcher))   ; plugin registry
(use-modules (scheme-toolkit notify))     ; daemon
(use-modules (scheme-toolkit process))    ; exec exec-async subprocess create-subprocess
(use-modules (scheme-toolkit time))       ; interval timeout idle create-poll
(use-modules (scheme-toolkit file))       ; read-file write-file monitor-file
(use-modules (scheme-toolkit result))     ; ok err attempt unwrap-or log-error
```

**Rule of thumb:** if DESKTOP needs `(use-modules (g-golf))` directly and
touches a GI class, ask whether a TOOLKIT wrapper should exist. Raw GI in
DESKTOP is a smell, except inside `services/` where wrapping a specific Astal
property is the whole job.

### 3.1 Which GTK trees to mimic

Screenshots show CSS, not structure. Read against the actual widget trees, the
two reference shells are good at different things, and the split is clean:

> **Mimic colorshell's structure and ags2-shell's content.**

**What is identical in both** (and in the AGS starter template), so it is a
settled convention: the bar is `Astal.Window` → `Gtk.CenterBox` → three
`Gtk.Box`es (`$type` start/center/end) holding module widgets; popups are a
fullscreen layer window anchored to all four edges with `exclusivity IGNORE`,
content aligned to a corner, closed by click-outside or Escape.

**Take the structure from colorshell** (`src/window/`):

| Piece | colorshell | Why it wins over ags2-shell |
|---|---|---|
| Bar | `window/bar/index.tsx`: 30 lines, one window, one centerbox, seven widgets in `bar/widgets/` | ags2-shell's bar is ~250 lines of *options-driven variants* (top/bottom, transparent, a triple-nested `ScreenCorner` box for CSS corners, hand-set exclusive zone + cairo input region via raw `Gtk4LayerShell`, hide-on-fullscreen). Good later, none of it is structure. Build colorshell's tree at D1; add ags2-shell's variants behind options at D5 |
| Popup window | `src/widget/PopupWindow.tsx`: an `Astal.Window` **subclass** with properties `closeOnClickOutside`, `closeOnEscape`, `keymode`, anchors | ags2-shell's `widget/shared/PopupWindow.tsx` is a function component with a dozen parameters. A GObject class with declarative properties is the reusable shape — **this moves into TOOLKIT M5 as `<popup-window>`**, with ags2-shell's `create_popup_position` (popup follows bar position) and `Gtk.Revealer` transitions added as properties |
| Window registry | `src/windows.ts` (name → factory) + `src/window/index.ts` (`open`/`toggle`/`isOpen`/`forMonitors`/`forFocusedMonitor`) | ags2-shell mounts windows imperatively in `shell/main.tsx`. Already adopted in D4 |
| Control centre | `window/control-center/widgets/{Tile,Page,tiles/*,pages/*}`: quick-action tiles, each opening a page in a `Gtk.Stack`, plus `Sliders` and `NotifHistory`, inside `Adw.Clamp` | Uniform and extensible — a new feature is one tile and one page. ags2-shell's `QuickSettings/components/*` is a set of bespoke panels |
| Directory layout | `window/<name>/{index.tsx, widgets/*}` per window, flat; matshell uses the same shape (`widgets/<feature>/main.tsx` + `modules/`) | ags2-shell nests Launcher, Notifications, QuickSettings, Overview and DateMenu under `widget/Bar/components/` although they are independent windows. Don't copy that |

**Take the content and lifecycle from ags2-shell** (`widget/`, `shell/`):

| Piece | ags2-shell | Use |
|---|---|---|
| Network / audio / bluetooth / power-profiles UI | `QuickSettings/components/Network.tsx` (982 lines — the most complete Wi-Fi UI in the set), `Audio.tsx`, `Bluetooth.tsx`, `PowerProfiles.tsx`, `MediaPlayer.tsx`, `DisplayMirroring.tsx` | Port the *content* of each into a colorshell-style page at D9 |
| Notifications | `Notifications/` + `EntryLifecycle.ts`, pinned by ~1,400 lines of tests | D8's behaviour spec |
| Brightness/DDC, screen capture, sleep inhibitor | `service/{brightness,screenCapture,sleepInhibitor}.ts` | D10 |
| Lifecycle | `shell/main.tsx`: deferred mounting, wallpaper child supervision, request guards | D4 (already) |
| The windows nobody else has | `Dock/`, `Desktop/`, `Overview/`, `Settings/` | D11; colorshell's extras (`apps-drawer`, `center-window`, `logout-menu`) are small and come along at D7/D9/D12 |
| Feature = button + window | each feature module exports `.Button` and `.Window` (`QuickSettings.Button` / `QuickSettings.Window`); `PanelButton` tracks its target window's visibility to toggle an `active` class | **Keep this convention**, combined with colorshell's flat layout: `widgets/quick-settings/{window.scm, button.scm, tiles/, pages/}`, registered in `windows.scm`. **`PanelButton` moves into TOOLKIT M5** alongside `<popup-window>` |
| Shared primitives | `widget/shared/{PopupWindow, AnimatedPopover, ApplicationIcon, Placeholder}` | The list of things that are toolkit-level, not shell-level |

**Concretely, per milestone:** D1–D4 build colorshell's trees exactly (bar,
popup window, registry). D7–D9 use colorshell's launcher and tiles/pages
structure filled with ags2-shell's network/audio/bluetooth/notification
content. D11 takes ags2-shell's Dock/Desktop/Overview as they are, since
nothing else exists.

The resulting `widgets/` layout:

```
widgets/
  bar/            window.scm  modules/{workspaces,focused-client,clock,media,tray,status,battery}.scm
  launcher/       window.scm  button.scm  results-list.scm  plugins/…      ; colorshell runner
  apps-drawer/    window.scm                                                 ; colorshell
  control-center/ window.scm  button.scm  tile.scm  page.scm  tiles/  pages/ ; colorshell structure, ags2 content
  notifications/  window.scm  button.scm  entry.scm  lifecycle.scm           ; ags2 behaviour, colorshell data model
  osd/            window.scm
  date-menu/      window.scm  button.scm                                     ; ags2
  power-menu/     window.scm  button.scm  verification.scm                   ; ags2 + colorshell logout-menu
  center-window/  window.scm                                                 ; colorshell
  dock/  desktop/  overview/  settings/                                       ; ags2 only
```

---

## 4. Milestones

### D0 — Prove the stack, and open the back door  *(~1 day; pairs with TOOLKIT M0 + M0.5)*

**Goal:** one `Astal.Window`, one label, correct teardown; `check-env.scm`
green; **and a REPL into that window's process**, because from here on every
acceptance check is "evaluate this and look at the answer", not "look at the
screen".

**Build:** a throwaway script that calls `start-repl!` before showing the
window. Deliberately not a project yet.

**Watch out:** the three traps in `SCHEME-TOOLKIT.md` § 3 — library path,
**uncompiled GSettings schema** (still live on this machine), typelib path.
Assert *binding counts*, not just load success. Record the cold-start time.

**Done when:** window renders and exits cleanly 10× in a row;
`scheme-toolkit eval '(set! (!label lbl) "hello")'` changes the on-screen
label; `(current-thread)` from the REPL is the GTK thread; idle CPU is 0 % with
the REPL open; `(astal-workspace-is-supported)` result is known for this
Hyprland.

---

### D1 — Static bar: the AGS starter template in Scheme  *(~2–3 days; needs M1)*  ⭐ first visible win

**Goal:** reproduce `~/GITE/ags/cli/data/gtk4/Bar.tsx` exactly — `window` with
`name`/`class`/`gdkmonitor`/`exclusivity`/`anchor`, a `centerbox` with
`$type` start/center/end children, a `button` with `on-clicked` → `exec-async`,
a `menubutton` → `popover` → `Gtk.Calendar`. Clock label static for now.

This is the right first target because it exercises every M1 feature
(`$type` slots, signal props, nested children, a non-intrinsic GI class) in 30
lines, and because "the AGS hello-world runs in Scheme" is a clear milestone.

**Reference:** `~/GITE/ags/cli/data/gtk4/Bar.tsx`; then grow it into
colorshell `src/window/bar/index.tsx` (the tree to mimic, § 3.1) with its
`bar/widgets/` as the module list. ags2-shell `widget/Bar/index.tsx` is *not*
the D1 target — its position/transparency/corner variants arrive with options
at D5.

**Done when:** the bar occupies the top edge, reserves space, and the calendar
popover opens — the last two asserted over the REPL (`(get-exclusive-zone …)`,
`(!visible popover)` after `(popup popover)`), which becomes the first
live-shell test in `tests/`.

---

### D2 — First live widgets  *(~3–5 days; needs M2, M9, M4)*  ⭐ feels real

**Goal:** prove the reactive core with the easiest real widgets.

**Build:** clock via `(create-poll "" 1000 "date")` (exactly the template's
`createPoll`), then a formatted variant via `(time (lambda (t) …))`; battery via
`(create-binding (battery) 'percentage)` with icon derived by `as`; workspaces
via `For` over `(create-binding (workspace-manager) 'workspaces)` as the first
`For` consumer; volume as a stretch.

**Reference:** colorshell `src/window/bar/widgets/Clock.tsx`; ags2-shell
`widget/Bar/components/Buttons/Battery.tsx` (multi-source `createComputed`
for `remaining_time`); matshell `widgets/bar/modules/Workspaces.tsx` for the
widget-side API shape.

**Done when:** time, battery and workspace pills update without restart; a
disposed bar leaves no handlers (TOOLKIT M2 test).

---

### D3 — Core services  *(~1–2 weeks; needs M3 M4)*

**Goal:** the services every shell needs, on Astal, with the right seam.

**Build:**
- **Workspaces/outputs from `AstalWorkspace`**: `WorkspaceManager.get_default()`
  → `workspaces`, `groups`, `for_output`; `Workspace.activate`, `name`,
  `coordinates`, `state`. Fallback to `AstalHyprland.Workspace` when
  `is_supported` is false (keep both paths behind one `services/workspaces.scm`).
- **Hyprland extras from `AstalHyprland`**: `clients`, `focused-client`,
  `special-workspace`, `dispatch`, `binds`, monitor `dpms-status`/`vrr`.
- `services/` for volume (`AstalWp` `default_speaker`/`default_microphone`),
  network (`AstalNetwork` `wifi`/`wired`, `primary`), bluetooth, media
  (`AstalMpris` players).
- Bar widgets: workspace pills, volume, network, bluetooth, media, tray stub.
- First `define-service` consumers: `NightLight` (`hyprctl hyprsunset`),
  `Clipboard` (`cliphist` via `subprocess`), both wrapped in `result`.

**Reference:**
- Workspace *widget API shape*: matshell `widgets/bar/modules/Workspaces.tsx`
  (never touches Astal directly) vs Ateon's fork (inlines `Hyprland.get_default()`
  — don't copy). colorshell `src/compositor/` for the full interface surface a
  shell ends up wanting.
- Service layer: colorshell `src/modules/{volume,bluetooth,media}.ts`;
  ags2-shell `service/*.ts`.
- Night light: colorshell `src/modules/nightlight.ts` (191). Clipboard:
  colorshell `src/modules/clipboard.ts` (274), ags2-shell `lib/clipboard.ts`.

**Done when:** workspace pills track focus across monitors through
`AstalWorkspace`; volume/network/bluetooth reflect live state; `ddcutil`-free
machines don't log errors.

---

### D4 — Real shell: multi-monitor, control, wallpaper  *(~1–2 weeks; needs M5)*

**Goal:** the shell becomes a *shell*.

**Build:**
- `shell.scm`: `(start #:instance-name "scheme-desktop" #:main …)`; the
  toolkit starts the REPL before `main`. Window names (`bar`, `launcher`,
  `osd`, `control-center`, `notifications`, `power-menu`, `overview`, `dock`,
  `desktop`).
- **`api.scm`** — the procedures keybindings and tests call, replacing
  ags2-shell's `requestHandler` switch and colorshell's CLI modules:
  `(toggle-window name)`, `(launcher-search query)`, `(screenshot #:area? #t)`,
  `(toggle-recording #:scope 'focused)`, `(confirm-power-action 'shutdown)`,
  `(volume-up!)`, `(media-next!)`, `(quit)`, `(inspect)`. Each guarded by the
  `ready`/`quitting`/`stopping` state ags2-shell uses. Because they are plain
  procedures, anything not anticipated is one expression away
  (`scheme-toolkit eval '(set! (!visible (window "bar")) #f)'`).
- Hyprland bindings call `scheme-toolkit eval -i scheme-desktop '(toggle-window "launcher")'`;
  `bin/scheme-desktop toggle launcher` is sugar for the same.
- **Optional `ags` shim**: `(serve-astal-dbus-shim)` so `ags toggle launcher`
  keeps working for anyone migrating keybindings; `Request(argv)` evaluates
  `argv` as an expression in the user module.
- `monitors.scm`: per-monitor roots from `for-each-monitor`; monitor identity
  via `AstalWl4.find_output_by_gdk_monitor` → output `name`; deferred mounting
  of non-per-monitor windows in nested `idle`s (ags2-shell).
- `windows.scm`: colorshell-style registry (`name → factory`) with `open`,
  `toggle`, `is-open`, `for-focused-monitor`.
- Wallpaper per monitor (`swww` or `hyprpaper`) with ags2-shell's child
  supervision (exponential backoff restart); colour extraction deferred to D6.

**Reference:** ags2-shell `shell/main.tsx` (309) **best lifecycle reference**
(its `requestHandler` cases are the first entries in `api.scm`); colorshell
`src/windows.ts` (45) + `src/window/index.ts` (356) for the registry;
colorshell `src/cli/modules/{main,volume,media,screenshot}.ts` for the
*inventory* of operations users want scriptable (the parser is gone, the list
is still right); `~/GIT/schemacs/schemacs/main.scm` for how `--remote FILE`
maps a shell-level verb to one evaluated expression; `~/GITE/ags/cli/lib/astal.go`
for the shim's contract; colorshell `src/modules/wallpaper.ts`, matshell
`utils/wallpaper/WallpaperSetter.ts`.

**Done when:** two monitors with independent bars; a Hyprland keybinding
toggles the launcher via `scheme-toolkit eval`; a `tests/` live-shell test
adds and removes a headless output and asserts root creation/disposal and
handler counts over the REPL; with the shim on, `ags toggle bar` also works.

---

### D5 — Configuration  *(~1 week; needs M6)*

**Build:** `config/schema.scm` — bar layout, widget visibility, clock format,
notification behaviour, OSD, theme, launcher — on the TOOLKIT config engine.
This is also where the bar grows ags2-shell's option-driven variants
(`widget/Bar/index.tsx`: top/bottom position via `anchor` accessor,
transparent mode, screen-corner decorations, hide-on-fullscreen) on top of
the colorshell tree built at D1.

**Format decision:** s-expressions (TOOLKIT § 4.1). If GNOME-style tooling is
wanted, the alternative is a compiled GSettings schema via `create-settings`;
decide here, the engine supports both. A one-off importer for an existing
`options.json` is optional.

**Reference:** ags2-shell `shell/options.ts` (609; corrupt-store recovery);
colorshell `src/config.ts` (152; the schema inventory); matshell `options.ts`.

**Done when:** editing the config live-updates the bar; a truncated file is
recovered.

---

### D6 — Theming  *(~1 week; needs M7)*

**Build:** colour engine integration via TOOLKIT (pywal16 / matugen / static /
Material); `style/palette.scm` → CSS variables; `style/rules.scm` generated in
Scheme; provider at the priority TOOLKIT chose; live reload on wallpaper
change; light/dark.

**Reference:** colorshell `src/modules/stylemanager.ts` (189) **best**;
colorshell `src/modules/color/` (engine interface + 4 impls; read pywal's
`colors.css`, not `colors.json`); ags2-shell `style/` + `style/runtime-css.ts`
(314); HyprYou `hypryou/utils/colors`; matshell `matugen/templates/`.

**Adwaita note:** Adwaita *widgets* only (`Clamp`, `Spinner`, `Bin`,
`Carousel`, `ButtonContent`, `ToggleGroup`); `(adw-init)` is required; never
`Adw.Application`. Own the CSS above the theme priority or Adwaita will clash
with the palette.

**Done when:** wallpaper change recolours the whole shell live, Adw widgets
included.

---

### D7 — Launcher and apps drawer  *(~1–2 weeks; needs M8)*

**Plugins for parity** (colorshell's 7): apps, clipboard, websearch, shell,
media, wallpapers, kill — prefixes `?` `#` `!` `>` `:`.

**Reference:** colorshell `src/runner/` (1,526) **best plugin architecture**
(`runner/widgets/ResultsList.tsx` is an `Adw.Bin` subclass — a `define-class`
over `<adw-bin>` test case); matshell `utils/picker/` (frecency); ags2-shell
`widget/Bar/components/Launcher/` (+ `tests/bar/launcher-lifecycle.test.ts`,
731 lines of behavioural spec); colorshell `src/window/apps-drawer/`.

**Done when:** `?query` searches the web, `#wall` finds wallpapers, frecency
ranks by use.

---

### D8 — Notifications  *(~1 week; needs M8)*

**Build:** own `org.freedesktop.Notifications` (TOOLKIT `notify` + `dbus`);
popup windows with placement/timeout; history; DND; hold.

**Reference:** ags2-shell `service/notifications.ts` (146) +
`lib/notifications.ts` (302) **daemon ownership**; colorshell
`src/modules/notifications.ts` (371) **data model**; colorshell
`src/widget/Notification.tsx` (uses `Adw.Clamp`); ags2-shell
`widget/Bar/components/Notifications/` + `EntryLifecycle.ts`, pinned by
`notification-placement.test.ts` / `notificationViewport.test.ts` (876).

**Done when:** `notify-send` pops a styled notification; history survives
restart; DND suppresses popups but keeps history.

---

### D9 — Control centre, quick settings, OSD, settings UI  *(~1–2 weeks; needs M3 M7)*

**Build:** the control centre as **colorshell's tree** — `tile.scm`/`page.scm`
primitives, `tiles/` (network, bluetooth, night-light, DND, recording) each
opening a page in a `Gtk.Stack`, `sliders.scm`, `notif-history.scm`, inside
`Adw.Clamp` in a toolkit `<popup-window>` — with each page's **content ported
from ags2-shell's** `QuickSettings/components/{Network,Audio,Bluetooth,
PowerProfiles,MediaPlayer,DisplayMirroring}.tsx` (§ 3.1). OSD and a settings
window alongside.

**Reference:** colorshell `src/window/control-center/` for the structure —
`widgets/NotifHistory.tsx` (`createBinding` → `For`) and `widgets/Tray.tsx`
(`For` + `With` + multi-source computed) are the two idioms the port must
reproduce; `widgets/{Tile,Page}.tsx` and `pages/index.tsx` for the Stack
plumbing. ags2-shell `widget/Bar/components/QuickSettings/components/` for
the content (`Network.tsx`, 982 lines, is the most complete Wi-Fi UI in the
set). colorshell `src/window/center-window/`, `src/widget/` (Slider);
ags2-shell `widget/OSD/`. HyprYou `hypryou/src/modules/` (18 modules) as a
feature inventory. Settings: ags2-shell `widget/Settings/`;
`Adw.PreferencesPage` is available.

**Done when:** volume/brightness OSDs appear on keypress; control-centre
toggles track real state.

---

### D10 — Peripheral features  *(~1–2 weeks; needs M9)*

**Build:** tray, MPRIS controls, screenshots + recording, clipboard UI,
brightness, power profiles, night light UI, idle inhibit.

- **Brightness:** `AstalBrightness` (`screen`, `keyboard`, `backlights`,
  `leds`) for everything internal; port only ags2-shell's `ddcutil` parsing and
  `brightnessMath.ts` (unit-tested) for external displays, in `services/ddc.scm`.
- **Idle inhibit:** logind `org.freedesktop.login1.Manager.Inhibit` with fd
  passing via TOOLKIT `dbus` proxy (ags2-shell `service/sleepInhibitor.ts`
  handles the `GUnixFDList`; verify G-Golf passes `GUnixFDList` out-params).

**Reference:** colorshell `src/window/bar/widgets/Tray.tsx`
(`Gtk.PopoverMenu` + dbusmenu action group); ags2-shell
`service/screenCapture.ts` (407); colorshell `src/modules/{screenshot,recording}.ts`;
ags2-shell `service/brightness.ts` (591) **for DDC only now**; HyprYou
`src/services/idle_inhibitor.py`.

**Done when:** tray works; screenshots land on the clipboard; brightness keys
work on internal and external displays.

---

### D11 — Desktop icons, dock, overview  *(~2–4 weeks; needs M10)*  ⚠ hardest

**Reference:** ags2-shell `widget/Desktop/` — `Desktop.ts` (857),
`FileOperations.ts` (746), `GridGeometry.ts` (492), `DragAndDrop.tsx` (426),
`components/LauncherCreator.tsx` (1,259). Pure logic sits inside `widget/`; fix
the layering in the port and keep `GridGeometry.test.ts`'s brute-force
invariants. `widget/Dock/`, `widget/Bar/components/Overview/` (`overview.test.ts`).
GTK4 DnD via `Gtk.DragSource`/`Gtk.DropTarget` as children in the element
runtime (colorshell and ags2-shell both use them as JSX children — M1 must
support controllers as children, which it does).

**Done when:** icons drag between monitors; geometry tests pass.

---

### D12 — Polish and soak  *(~1–2 weeks; needs M10 M11)*

**Build:** power/session menu, lock screen, i18n catalogue (colorshell's 6
locales), weather, cava, polkit agent, **idle auto-dim via `AstalIdleNotify`**,
Geiser attach + hot reload polish, packaging, multi-day soak (RSS and handler
counts sampled over the REPL on a timer, so the soak produces data rather than
an impression).

**Reference:** colorshell `src/window/logout-menu/`, ags2-shell
`widget/PowerMenu/`; HyprYou `hypryou/src/modules/lockscreen.py` (+
`gtk4-session-lock`), marble-shell `src/ui/Screenlock.tsx`, or `hyprlock`;
colorshell `src/i18n/`; colorshell `src/modules/auth.ts` (`PolkitAgent.Listener`
+ `AstalAuth.Pam`); matshell `utils/weather/`; matshell/Ateon
`widgets/music/modules/cava/`.

**Soak:** leave it running for a week watching `gtk_widget_unparent`
assertions, handler counts, and RSS. The 25-cycle M0 stress test was clean; a
week is the real test.

**Done when:** a week of uptime with flat memory.

---

## 5. Cross-reference: milestone ordering

**Authoritative interleaving of the two plans.**

| Order | TOOLKIT | DESKTOP | Why this order |
|---|---|---|---|
| 1 | **M0** GI bootstrap, timing, feature detection | **D0** prove stack | De-risks everything; learns whether `AstalWorkspace` is supported here |
| 1b | **M0.5** REPL back door | **D0** gains a REPL | Everything after this is tested through it; schemacs has already solved the GTK pitfalls |
| 2 | **M1** element runtime + `add-child!` + For/With/This | **D1** AGS starter bar | First visible artifact; the DSL is designed against a real consumer; first live-shell test |
| 3 | **M2** reactive core (Gnim `state.ts`/`scope.ts` port) | — | Biggest new-work item |
| 4 | **M9** process/time/file/result (AstalIO wrappers) + **M4** Astal wrappers | **D2** live clock, battery, workspace pills | Both cheap; D2 wants `create-poll` and singletons immediately |
| 5 | **M3** service authoring | **D3** core services | `define-service` before the first custom service |
| 6 | **M5** app + layer + lifecycle (+ optional `ags` shim) | **D4** multi-monitor, `api.scm`, keybindings via `eval`, wallpaper | A keybinding toggling the launcher through the REPL is the milestone's proof |
| 7 | **M6** config | **D5** schema | |
| 8 | **M7** styling | **D6** theming | |
| 9 | **M8** launcher + notify frameworks | **D7** launcher | |
| 10 | — | **D8** notifications | Second half of M8 |
| 11 | — | **D9** control centre + OSD + settings | No new toolkit work |
| 12 | — | **D10** peripherals | |
| 13 | **M10** test harness (tiers 1–3) | — | Tier-2 live-shell tests have accrued since D1; this formalises the runner and adds the headless-compositor CI tier. Pull forward if D11 is next |
| 14 | — | **D11** desktop icons + dock + overview | Hardest; needs M10 |
| 15 | **M11** packaging + REPL polish | **D12** polish + soak | Ship it |

**Notes:**
- **Critical path: M0 → M0.5 → M1 → M2 → M5 → M7.**
- **Four easy wins in the first third:** D0 (a window you can talk to), D1 (the
  AGS template bar), D2 (live widgets), D4 (a Hyprland keybinding drives a
  Guile shell). If the project is going to fail, it fails before D4 — cheaply.
- **Tests accumulate from D1, not from M10.** Each milestone's "done when" is
  an expression evaluated in the live shell; write it into `tests/` as you go.
- `AstalWorkspace` support should be known at D0; if absent, D3's workspace
  service uses `AstalHyprland` and nothing else changes.

---

## 6. Risks specific to DESKTOP

| Risk | Severity | Mitigation |
|---|---|---|
| Desktop icons (D11) balloon | **High** | Schedule last; consider stretch goal |
| Reactive ergonomics wrong once 50 widgets exist | **High** | D1–D3 exercise it against real widgets; Gnim semantics are the spec, so divergence is detectable |
| `add-child!` lacks a container DESKTOP needs | Medium | the error names the classes; add a method in TOOLKIT (that's the integration-test loop working) |
| Multi-monitor lifecycle bugs | Medium | copy ags2-shell `shell/main.tsx`; test hotplug at D4; assert handler counts |
| `AstalWorkspace` unsupported / incomplete on Hyprland | Low–Medium | detect at D0; `AstalHyprland` fallback path kept |
| Startup time annoys (Guile + GI imports) | Medium | selective imports (TOOLKIT M0); measure at D0 and D4 |
| Feature creep from the union parity list | Medium | ship D0–D8 first |
| Weeks-uptime stability | Medium | D12 soak is the gate |

---

## 7. Definition of done for the project

1. `scheme-desktop` and `scheme-toolkit` install from a package manager.
2. Bar, launcher, notifications, control centre, OSD, tray and dock work on a
   fresh Hyprland session.
3. Every user-facing operation is a procedure in `(scheme-desktop api)`,
   callable from a keybinding via `scheme-toolkit eval`, and the test suite
   exercises the live shell through the same REPL.
4. Theming follows the wallpaper live.
5. A week of uptime without leaks or crashes.
6. `scheme-toolkit` is usable by a *different* shell without patching — no
   DESKTOP file imports raw `g-golf` outside `services/`. (A tiny `AstalGreet`
   greeter is the suggested second consumer to prove it.)
