# The Omarchy menu format

A description of `omarchy-menu.jsonc`, read from
`/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc` (installed) and
`~/GITE/omarchy/default/omarchy/omarchy-menu.jsonc` (source, identical).

Written by reading the file itself, `docs/menu.md` in the Omarchy repo, and the
code that consumes it — `shell/plugins/menu/MenuModel.js` (724 lines, pure
logic) and `shell/plugins/menu/Menu.qml` (1,707 lines, rendering + providers).
Every claim below is taken from one of those three; where they disagree, the
disagreement is called out.

This is the **menu** (SUPER+SPACE), which is a different thing from the
**launcher**. Omarchy has both, and the menu is the one that is "more than an
app launcher": 333 entries of which 275 are actions, arranged as a tree four
levels deep, driving theme changes, installs, hardware toggles, system power
and configuration — with a plugin system, a guard system, and search.

---

## 1. Encoding

JSON, with two relaxations applied by `stripJsonc` — a regex, not a JSONC
grammar:

```js
.replace(/^\s*\/\/[^\n]*(\n|$)/gm, "")   // whole-line // comments
.replace(/,(\s*[}\]])/g, "$1")           // trailing commas
```

**Whole-line comments only.** The regex is anchored with `^` under the `m`
flag, so a comment that trails a value on the same line breaks the parse. This
is worth knowing before writing a generator: emit comments on their own lines.

A file that fails to parse contributes **no** entries, and the failure is
silent — a broken user extension drops every user entry while the shipped menu
keeps working. `readMenuJsonc` returns `null` (as distinct from `[]` for a file
of nothing but comments) so that a file caught mid-write by an editor or an
update is *ignored* rather than replacing good rows with none.

The top level is either a bare map of id → entry, or `{"items": {...}}`. The
shipped file uses the bare form.

---

## 2. The tree: dotted ids

```jsonc
"trigger":                 { ... },   // root row
"trigger.share":           { ... },   // child of trigger
"trigger.share.file":      { ... },   // grandchild
```

**The id is the position.** There is no parent field to keep in sync:
`normalizeItem` derives the parent by dropping the last dot segment, and an id
with no dot gets `parent: "root"`. A `parent` field is accepted and overrides
this, but the shipped file contains zero of them (`grep -c '"parent"'` → 0), as
does the code path that would use it.

`root` is synthesised if neither source declares one, with the label "Go". It
is not in the file.

Depth in the shipped file: 10 root rows, 79 at depth 2, 174 at depth 3, 70 at
depth 4. Nothing deeper.

The ten root rows are:

| id | label | kind |
|---|---|---|
| `apps` | Apps | submenu, **provider-backed** |
| `learn` | Learn | submenu |
| `trigger` | Trigger | submenu |
| `style` | Style | submenu |
| `setup` | Setup | submenu |
| `install` | Install | submenu |
| `remove` | Remove | submenu |
| `update` | Update | submenu |
| `about` | About | **action** |
| `system` | System | submenu |

---

## 3. Kind is inferred, never declared

```js
var kind = value.action ? "action" : (value.target ? "link" : "menu")
```

- **action** — has `action`, a shell command string. 275 in the shipped file.
- **link** — has `target`, the id of another submenu to open instead. **Zero in
  the shipped file**; the code fully supports it and it is the mechanism for a
  row that appears in two places.
- **menu** — neither, so it is a submenu. 58 in the shipped file.

`action` wins over `target` if both are present.

There is no way to declare an action *and* have children. A row that both runs
something and opens something is not expressible.

---

## 4. Fields

| Field | Type | Meaning | Shipped uses |
|---|---|---|---|
| `icon` | string | Glyph in the icon column, usually Nerd Font | 333 (every row) |
| `label` | string | Row title; defaults to the id | 333 |
| `action` | string | Shell command, run detached on select | 275 |
| `target` | string | Submenu id to open; makes the row a link | 0 |
| `provider` | string | Runtime row source (see §6) | 2 |
| `when` | string | Bash condition; **hides** the row when it fails | 152 |
| `checked` | string | Bash condition; appends ` ✓` when it succeeds | 43 |
| `disabled` | string | Bash condition; dims, ticks and disables the row | 0 |
| `title` | string | Header text when the submenu is open; defaults to `label` | 16 |
| `iconFont` | string | Font family for the glyph, when it differs from the menu font | 23 |
| `aliases` | string or array | Alternate `summon` routes, also searchable | 20 |
| `description` | string | Subtitle while searching; extra search text | 0 |
| `parent` | string | Override the dotted-id parent | 0 |
| `searchTerms` | string or array | Search-only terms; never routable | 0 |

`title` vs `label` is a real distinction: `setup.default.browser` has
`"label":"Browser"` and `"title":"Default Browser"`, so the row reads *Browser*
in the Defaults list and the open submenu is headed *Default Browser*.

`iconFont` exists because Omarchy ships a private `omarchy` font with brand
glyphs; 23 rows use it, all of them brand marks (Codex, Grok, Cursor, omp,
OpenClaw…). The glyph alone is not enough — you need the font too.

`aliases` is documented as **frozen**: `docs/menu.md` says "Do not add aliases
to new entries. They are reserved for established alternate names users already
type (`power-menu`, `settings`), kept for compatibility." Search does not need
them — labels, the last id segment and descriptions are all searchable already.
Our format does not need to carry this field at all, except to accept Omarchy
files.

**A documented-but-unshipped convention worth noting.** `docs/menu.md` says
Install rows should use `disabled:` and Remove rows `when:`, so that installed
software still appears in the catalog of what can be installed. The shipped
file does the opposite: **zero `disabled` fields**, and Install rows use
`when: "! omarchy-pkg-present <pkg>"`, which *hides* software you already have.
The code implements `disabled` fully (`isDisabled`, and `labelFor` gives it the
same ✓ as `checked`). So the doc describes an intention the file has not been
migrated to. For us: don't infer the convention from the shipped file.

---

## 5. Load and merge

Two sources, defaults then the user's
`~/.config/omarchy/extensions/omarchy-menu.jsonc`:

```js
sources = [defaultItems, userItems]
```

Merged **per key, per field**: an entry with the same id has its *declared*
fields overlaid on the shipped entry, so an extension can retitle or re-icon a
row without restating its action. `merged.id = entry.id` is forced. An
overridden entry **keeps its original position**; new ids append. `order` is
then stamped onto every entry from the final list order — this is what
tie-breaks search results (§8).

Both files are read at startup and **watched**, so an edit takes effect without
restarting the shell — the menu is re-parsed, not re-shelled-out-to.

`~/.config/omarchy/extensions/omarchy-menu.jsonc` ships as a comments-only
file, so the default state adds nothing.

**Merge hygiene worth copying.** `mergeAppRows` and `swapProviderRows` return
*fresh* maps rather than mutating the ones they are handed, because the caller
holds them in QML `var` properties and an in-place write into one is
occasionally dropped by the engine — the key lands with an `undefined` value
and the row duplicates on every later rescan. In Scheme this hazard doesn't
exist; the equivalent warning is about *who owns the tree* when a provider
refreshes.

---

## 6. Providers

A submenu with `provider: "name"` gets its rows at runtime. **The names are
defined by the shell, not by the file** — an extension can point a submenu at an
existing provider but cannot declare a new one.

Shipped usage: `apps` (root) and `fonts` (`style.font`). The full set available
in the shell is `apps`, `fonts`, `power-profiles`, `kernels`, `languages`.

`apps` is native (rows from the desktop-entry library, with image icons and
uninstall support). The other four are bash one-liners in the `providers` map in
`Menu.qml`, e.g.

```js
"fonts": {
  script: "current=$(omarchy-font-current 2>/dev/null); omarchy-font-list 2>/dev/null | while read -r f; do [[ -z $f ]] && continue; printf '%s\\t%s\\t%s\\n' \"$f\" \"$f\" \"$current\"; done",
  icon: "",
  volatile: true,
  actionFor: function(value) { return "omarchy-font-set " + Util.shellQuote(value) }
}
```

### The provider contract

**One tab-delimited line per row:**

```
label \t value \t current [\t search-only term]
```

- The row whose `value` equals `current` gets the ✓.
- Selection runs the provider's `actionFor(value)`.
- The optional fourth field is search-only — the languages provider passes each
  language's English name so searching "danish" finds the row labelled "Dansk",
  without making "danish" a routable command.
- Row ids are `<menuId>.<slugify(value)>`, with `-` appended on collision, so
  two values that slugify alike cannot silently drop a row.

`volatile: true` re-runs the enumeration **every time the submenu is entered**,
so a font installed since startup appears without a restart — but *not* on
search keystrokes, which would re-enumerate per key.

`swapProviderRows` merges results by the owning submenu id, so a re-run drops
its previous batch without touching static JSONC children of the same submenu.

### What this is, structurally

A provider is a **stream of rows with a current-value marker**, i.e. a
selector. Three of the four are "pick one of N, mark the current one". That is
the same shape as the `fzf`-style pickers and as the menu's own
`select` mode. Our version can treat "provider" as *any accessor of rows*, which
in Scheme is cheaper than a bash contract.

---

## 7. Guards: `when`, `checked`, `disabled`

Bash conditions. The important thing is **when** they run, which is not on the
open path:

> "The shell never evaluates them on the open path: all guards in the menu are
> batched into a single bash process per (re)load and per open, reporting
> `<id>:<w|c|d>:<0|1>` lines. The menu opens immediately on the previous
> evaluation's answers."

So: the menu opens instantly showing slightly stale ticks, and the batch lands a
moment later. 152 + 43 = 195 guard expressions go into **one** bash process.

Failure semantics differ:

| Guard | On failure |
|---|---|
| `when` | Row is **hidden** |
| `checked` | Row is shown **without** the ✓ |
| `disabled` | Row is shown **dimmed, ticked, and unselectable** — cursor, pointer, Enter and search all step over it |

**A submenu whose visible descendants are all hidden disappears with them** —
computed recursively by `isVisible`, with a depth guard of 32 and a hard
`false` at the limit. Note the rule is about *descendants*, not children, and
that a **provider-backed submenu is exempt** and stays, because its rows load on
demand: `style.font` keeps its place in the Style menu whatever is installed.

So `install.development.javascript` — which has no `when` of its own — is
present only because at least one of `node`/`bun`/`deno` is visible, and each of
those hides itself when its own mise install directory exists. Installing all
three removes the parent row. That is the intended behaviour, and it is the
first place a naive port goes wrong.

### The batch is engineered hard

Worth reading as a statement of what the guards cost:

- `omarchy-pkg-present` is answered **in-process from one `pacman -Q` snapshot**
  rather than one fork per row. The snapshot resolves `Provides`, so `gvim`
  answers for `vim`. It is cached in
  `$XDG_RUNTIME_DIR/omarchy-menu-packages`, stamped with the pacman database
  directory's `stat`, and rebuilt when an install/removal/upgrade moves the
  stamp.
- Commands several rows read a value from — every Defaults > Browser row
  compares against `$(omarchy-default-browser)` — **run once**, with the answer
  substituted into each expression. `GUARD_READERS` in `MenuModel.js` lists
  them, and a test fails the build if a row uses an unlisted reader.
- The guards are dealt into **eight background subshells** so the batch takes as
  long as its slowest probe, not the sum. Result lines therefore arrive in any
  order, and **a guard must not depend on anything another guard set.**

That last sentence is a real constraint on the format, and it is the kind of
thing a Scheme port gets to delete: if guards are Guile procedures rather than
bash strings, they can share state and there is one scheduler, not eight
subshells.

---

## 8. Routing

`bin/omarchy-menu` is a wrapper over the plugin IPC:

```bash
omarchy menu                      # toggle the root menu
omarchy menu toggle system        # open at a route, or close if already open
omarchy menu summon appearance.theme   # always open
omarchy menu close
omarchy menu refresh              # re-parse the JSONC
omarchy menu ping
```

`resolveRoute` semantics:

1. Lowercase, `_` → `-`.
2. Empty, `go`, or `menu` → `root`.
3. An **exact id** wins.
4. Otherwise scan `itemOrder` for a non-app entry whose `aliases` contain it
   (same normalisation).
5. Otherwise **fall through with the literal input**, so a misspelling still
   attempts to open that id.

**App rows are never routable** — their aliases carry `.desktop` `Keywords` and
`GenericName` for search only. Without that, an installed app could shadow a
menu route: `htop` ships `Keywords=system;…`, and SUPER+ESCAPE must still open
the system menu.

Summoning a route that resolves to an **action** runs it directly rather than
opening an empty submenu; a **link** is followed to its target.

---

## 9. Search

Every row is searchable, and the scoring is a tier table
(`searchScore`, lower is better):

| Match | Score |
|---|---|
| label equals the query, row is a **root** row | 2 |
| label equals the query, row is **not** a root row | 0 |
| an **app** whose label contains the query as a whole word | 0 |
| label starts with the query | 10 |
| label contains the query | 30 |
| name text (`label` + last id segment + aliases + searchTerms) contains it | 40 |
| description matches the query word-for-word | 60 |
| otherwise | 80 |

Then: `-2` for a submenu or link, `-5` for an app row. Final key is
`score * 1000 + depth * 25 + order`.

Read the first three rows carefully: an exact label match scores **0** for a
non-root row and **2** for a root row — so a deep exact match *outranks* a root
one, and an app whose label contains the query as a whole word ties with a deep
exact match, then loses 5 to the `-5` app penalty and drops behind it. The
ordering is deliberate: typing `zen` should offer the app before Install > Zen.
But it means the tier table cannot be reconstructed by intuition. Copy it.

Two details that are easy to miss and easy to get wrong:

- **Name matching is substring**; **description matching is whole-word**
  (`termInSearchWords`). So "dan" finds a label containing "dan", but only the
  word "danish" matches a description.
- **Multi-term queries must all match**, each term against either the name text
  or the description words.

`nameSearchText` folds `._-` to spaces, so `setup.default.browser` is searchable
as the words "setup default browser" as well as by its label.

---

## 10. Select and input modes

The same plugin doubles as the system's dmenu:
`omarchy-menu-select` and `omarchy-menu-input` summon it with
`mode: select` / `mode: input`, then block on a tempfile handshake (the shell
writes the selection to `selectionFile` and touches `doneFile`; cancellation
exits 1).

A select option is `label`, `glyph\tlabel`, or `glyph\tlabel\tsubtext` — the
glyph shows but never returns; the subtext renders under the label, filters with
it, and comes back as `label\tsubtext` so callers with same-named rows get a
stable key.

There is also `--multiple`, with `--selected`, `--on-change <JSON command
array>` and `--change-key`. Adjacent to the menu, not part of its format, but it
is how the menu's own picker actions present lists.

---

## 11. i18n

`applyTranslations(items, catalog)` overlays a catalogue keyed by **entry id**,
replacing `label`, `title` and `description`. Crucially, when a label is
translated it **pushes the original label into `searchTerms`**, so English
search keeps working after the UI is translated — without making English words
routable. That is the whole reason `searchTerms` exists.

---

## 12. Our format

**The menu IS the root entry.**

```scheme
(define omarchy-menu
  '(label "Go" submenu
    ((key apps icon "" label "Apps" aliases ("app" "applications") provider applisting)
     (key learn icon "" label "Learn" submenu
      ((key keybindings icon "" label "Keybindings" action "omarchy-launch-webapp '…'")
       (key omarchy    icon "" label "Omarchy"    action "…"))))))
```

Not a list containing the root: that would be a singleton wrapper, always exactly
one element, carrying nothing. `submenu` holds a **list** of entries because a
submenu may have any number of rows; the top level has exactly one holder, and
that holder is the menu.

`trigger.share.file` becomes `(key file …)` inside `(key share …)` inside
`(key trigger …)`.

### Keys are symbols, and one of them has to be renamed

`key` is a **symbol**: it names a row and is what a lookup is keyed by, so
`(assq 'apps rows)` is the natural question to ask of a menu.

Every one of the 333 keys in the shipped menu is a valid identifier except one:
`1password`, which starts with a digit. **The obvious fix does not work.** Bar
quoting it as `|1password|` was measured and rejected:

```scheme
(symbol->string (read (open-input-string "|1password|")))
;; => "|1password|"   -- eleven characters, the bars are IN the name
```

Guile reads a bare `1password` happily, but writes it back as `#{1password}#`,
which is Guile's own notation and nothing else's.

So a key that is not an identifier is **renamed** by putting an underscore in
front: `1password` becomes `_1password`. `key-symbol` is a **pure function of the
Omarchy segment**, which is what makes it safe — every path, index lookup and
route that names a row mangles identically, so the tree and the names in it
cannot disagree. Anything else that has to name a row (a keybinding, a future
`target`, a translation catalogue) must go through the same function.

**The root is an entry, and it is the only one without a `key`.** Everything
else has one because it is a row and has to be told apart from its siblings; the
root has no siblings and is not a row -- it is what holds the top-level rows and
what is left when the user navigates back up out of a submenu. Upstream injects
one too (`{"id":"root","parent":"","label":"Go"}`) for the same reasons.
`omarchy-menu-count` counts entries *with* a key for exactly this reason: 333,
not 334.

**An entry is a real property list.** Every element after `key` pairs with the
one before it, so `assq`, a plist reader, a merge and a formatter that assumes
key/value alternation all work on it. In particular `submenu`'s value is
**one list of entries**:

```scheme
(key "learn" … submenu ((key "a" …) (key "b" …)))     ; a plist
(key "learn" … submenu (key "a" …) (key "b" …))       ; NOT -- `submenu' has no
                                                      ; value and the entry ends
                                                      ; in a variadic tail
```

**The kind is the tail of the plist**, so the last token says what an entry is:

```scheme
(key "x" … action "cmd")            ; a shell command
(key "x" … action some-procedure)   ; a Scheme procedure
(key "x" … provider applisting)     ; rows from a Scheme procedure
(key "x" … submenu ((entry …) …))   ; static children, as one list
```

| Field | Value | Notes |
|---|---|---|
| `key` | symbol | last id segment, as an identifier (see below) |
| `icon` | string | glyph |
| `icon-font` | string | font family for the glyph |
| `label` | string | row title; defaults to `key` |
| `title` | string | header text when open; defaults to `label` |
| `action` | string **or symbol** | shell command, or a Scheme procedure to call |
| `provider` | symbol | a Scheme procedure returning rows |
| `aliases` | list of strings | alternate routes; also searchable |
| `description` | string | subtitle while searching; extra search text |
| `search-terms` | list of strings | search-only; never routable |
| `when` | string **or symbol** | hides the row when it fails |
| `checked` | string **or symbol** | appends ` ✓` when it succeeds |
| `disabled` | string **or symbol** | dims, ticks and disables |
| `submenu` | list of entries | the row's children |

**Everything is data, under one quote.** So a bare symbol IS the symbol: write
`provider applisting`, never `provider 'applisting`, which is the two-element
list `(quote applisting)` and would have the runtime looking up a provider whose
name is a list. Resolving a symbol to a procedure happens where the value is
*used*, not when the file loads.

**A string guard is the compatibility form.** `when`/`checked`/`disabled` are
strings when they came from Omarchy, because the source is bash; a symbol means
a Scheme procedure. The string form should be recognised and routed through one
batched shell rather than forked per row -- see §7 for what that batching costs
upstream. Anything written by hand should use a procedure.

### What is deliberately NOT carried over

| Dropped | Why |
|---|---|
| `target` | links to another submenu by **absolute id**. Upstream supports it and ships **zero**. Keeping it would reintroduce dotted paths, which is the thing nesting exists to remove |
| `parent` | redundant when the tree is the nesting. Upstream ships zero |
| dotted ids | the nesting is the tree |
| `description`/`searchTerms` from JSON | kept, as `description`/`search-terms` |

### What nesting costs, measured

Omarchy's `order` is the index in the **flat** file, and that file is *not* in
pre-order: `trigger.capture.screenrecord.stop` is declared before its own parent
`trigger.capture.screenrecord`. A nested tree cannot represent that.

Checked against the shipped file:

- **333 rows, `0` field mismatches** on `icon`, `label`, `action`, `title`,
  `icon-font`, `when`, `checked`, `disabled`, `provider`, `aliases`.
- **sibling order preserved for every single parent** (0 parents differ).
- **total file order is lost** at the first interleave: the JSONC's flat order
  has `trigger` where the tree has `learn.keybindings`.

`order` is only the last term of the search key
(`score * 1000 + depth * 25 + order`), so the practical effect is the relative
order of equally-scored rows in *different* parents. If that ever matters, an
optional explicit `order` field is the fix; it is not worth it today.

---

## 13. The module, and the converter

**The menu is data, and that is the artifact.** `(scheme-desktop menu omarchy)`
turns an Omarchy file into a list of property lists and stops there:

```scheme
(use-modules (scheme-desktop menu omarchy))

(define menu (omarchy-menu-file->scheme omarchy-menu-default-path))
(omarchy-menu-count menu)                      ; => 333

(call-with-values (lambda () (omarchy-menu-index menu))
  (lambda (by-path order)
    (hash-ref by-path "setup.default.browser") ; => the Browser entry
    (length order)))                           ; => 333, tree order
```

| Export | |
|---|---|
| `omarchy-menu-file->scheme` | path -> menu |
| `omarchy-menu-jsonc->scheme` | text -> menu |
| `omarchy-menu->string` | menu -> Scheme source (the *only* text-producing code) |
| `omarchy-menu-count` | entries at every level, not `(length menu)` |
| `omarchy-menu-index` | `(values by-path order)` -- dotted path -> entry, and tree order |
| `omarchy-menu-warn` | a parameter; the reporting hook |
| `omarchy-menu-warnings` | what the default hook collected |
| `omarchy-menu-default-path` | Omarchy's installed menu file |

It depends on **guile-json and nothing else** -- no scheme-toolkit -- so a shell
can read an Omarchy file whether or not the toolkit is loaded.

**The index is not optional.** Nesting means an id only exists as a *path*:
`key` is the last segment, so `setup.default.browser` is three nested entries and
nowhere in the data does that string appear. Routing (`omarchy menu summon ...`),
search, and a translation catalogue all need it, and walking is the only way to
get it. `omarchy-menu-index` is that walk.

**Reporting is a parameter, not a print.** The same code runs in a build tool and
inside a shell, and a library that writes to stderr uninvited cannot be used
quietly. The default collects; `omarchy-menu-warnings` returns what it got.

### bin/omarchy-menu-to-scheme

```bash
bin/omarchy-menu-to-scheme                     # to stdout
bin/omarchy-menu-to-scheme -o menu.scm         # to a file
bin/omarchy-menu-to-scheme -n my-menu          # different define name
bin/omarchy-menu-to-scheme --stats             # counts; exit 2 on warnings
bin/omarchy-menu-to-scheme FILE
```

It is a **wrapper**: read the file, render the data, write it. It converts
nothing. If it and the module ever disagree about the menu, the module is right.
Kept as a separate program rather than a module function because converting is a
build step with a human in it -- the output is 333 rows of arbitrary shell
commands, and that is not something to hand a running process unseen.

It strips comments with **the same two regexes Omarchy uses**, deliberately: a
reader that accepts a dialect its source rejects, or rejects one it accepts,
disagrees with upstream about what the input is. That includes the limitation --
`//` must start its line, so a trailing comment is not stripped.

Two traps it handles that bite silently:

- **guile-json reverses object key order.** It builds each object by consing, so
  `{"z":1,"y":2,"x":3}` comes back as `("x" "y" "z")`. Recovery is unambiguous
  because guile-json's types are: an *object* is an alist, an *array* is a
  vector, so every list is an object and can be reversed. Without it the whole
  menu comes out backwards -- valid Scheme, wrong order, no error.
- **`(and action kids)` is true for an empty list.** Only `#f` is false in
  Scheme, so a truth test on a possibly-empty child list warns on every leaf.

And one it walked into: the field map is split into **groups iterated once
each**. As a single list filtered three times, the first pass read every entry
and emitted `when` *twice* -- which parses, looks nearly right, and is invisible
to a field-by-field comparison because `memq` finds the first occurrence.

### Verification

Against the shipped file: **333 rows, 0 field mismatches** on `icon`, `label`,
`action`, `title`, `icon-font`, `when`, `checked`, `disabled`, `provider` and
`aliases`; **0 duplicate fields**; **sibling order preserved for every parent**;
**total file order lost** at the first interleave (§12).

## 14. Summary

Omarchy's format, in five ideas:

1. **A flat map of dotted ids** whose keys imply a tree. Cheap to read, cheap to
   diff, and its order is meaningful (used for tie-breaking).
2. **Kind by inference** from which field is present.
3. **Per-field overlay** of a user file on the shipped one, position preserved.
4. **Bash-string guards**, batched off the open path, with three failure
   meanings (hide / tick / dim-and-disable).
5. **Providers**: a named, shell-defined source of rows for a submenu, with a
   current-value marker.

Ours keeps 1 (as nesting), 2, 3, 4 (as procedures first, strings for
compatibility) and 5, and drops the JSONC encoding, the regex parser, the bash
guard batching with its pacman-snapshot cache, the tab-delimited provider
contract, and the `aliases` field.

The designs worth keeping verbatim, because they are not obvious: guarded rows
with **three** failure meanings, submenu pruning when every visible descendant
is hidden, providers as a tree extension point, route resolution where an exact
id beats an alias, and the tier-table search score.

---

## 15. Editing the menu in place: `menu-splice`

The converted menu is ordinary Scheme data, so a config can edit it rather than
replace it. `(scheme-desktop menu)` exports `menu-splice` for that:

```scheme
(menu-splice main-menu sub-menu location)   ; => the whole menu, with sub-menu in it
```

`location` is a list of keys. **Its last element is the anchor**, and everything
before it is the path to the submenu that will hold the new row:

```scheme
;; after the `file' row of trigger > share
(menu-splice m my-entry '(trigger share file))

;; as the FIRST row of trigger > share -- the `#f' sentinel
(menu-splice m my-entry '(trigger share #f))

;; after `trigger' at the top level
(menu-splice m my-entry '(trigger))

;; before everything at the top level
(menu-splice m my-entry '(#f))
```

A config uses it with `menu-set!`, which installs the result without the Omarchy
file ever being read:

```scheme
(menu-set! (menu-splice (menu) my-entry '(trigger share file)))
```

**`sub-menu` is a whole entry**, so a branch with children of its own can be
added, not only a leaf:

```scheme
(menu-set!
 (menu-splice (menu)
              '(key research icon "" label "Research"
                submenu ((key papers icon "" label "Papers" action "papers")
                         (key notes  icon "" label "Notes"  action "notes")))
              '(trigger share #f)))
```

Behaviour worth knowing:

- **A location that does not name a place returns `#f`**, not the menu
  unchanged. A splice that silently did nothing is the failure this avoids: the
  caller can say which key was missing. Test the result before installing it.
- **An anchor that does not exist appends** instead. The path proved the
  container is there, so a row asked to sit after something that has gone goes
  at the end rather than being dropped.
- **Only static children are spliced into.** An entry whose rows come from a
  `provider` has no children in the tree until the provider is asked, so there
  is nothing to place a row beside -- `(menu-splice m e '(apps provider x))` is
  `#f`, the same restriction `menu-resolve` documents.
- **The input is not modified.** The result shares every unchanged branch with
  the menu you passed in.
