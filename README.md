# scheme-desktop

A GTK4 Wayland desktop shell in Guile Scheme, built on
[Astal](https://github.com/aylur/astal) via scheme-toolkit.

**Status: D1.** The bar renders on every monitor, with a live clock.
See `AGENTS.md` for the full plan.

[Screen Shot](images/screenshot-1.jpg)

## Run it

    bin/scheme-desktop run

That is the whole thing so far: a bar with a Welcome button on the left, a live
clock in the centre, and a Calendar button on the right that opens a calendar
popover. Ctrl-C to stop.

`bin/scheme-desktop` delegates to scheme-toolkit for the environment (the
layer-shell preload and library paths are load-bearing) and adds this checkout
to the load path. Everything else -- `check-env`, `eval`, `repl` -- is
scheme-toolkit's.

## Layout

    bin/scheme-desktop          run; delegates the rest to scheme-toolkit
    scheme-desktop/shell.scm    entry point: which windows this shell has
    scheme-desktop/widgets/     one file per window, starting with the bar
    tests/                      live-shell tests

## Why the bar lives here

scheme-toolkit is the reusable layer; this repository is one shell built on it,
and doubles as its integration test. A bar whose layout is Welcome|clock|Calendar
is *this* shell's decision, so it belongs here, not in the toolkit's examples.
The toolkit keeps a minimal example that demonstrates each layer instead.
