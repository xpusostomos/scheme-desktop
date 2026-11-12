#!/usr/bin/env bash
# install-arch-packages.sh -- install what scheme-desktop needs, from the right
# repository.
#
#   ./install-arch-packages.sh              required packages only
#   ./install-arch-packages.sh --optional   also the feature-dependent ones
#   ./install-arch-packages.sh --dry-run    print the commands, change nothing
#   ./install-arch-packages.sh --help
#
# THE LIST IS docs/packages.txt, and that file says where each name came from:
# the GI namespaces are every `gi-import' in the two trees, the programs are
# every string handed to `exec-async'.  This script is the same list in the form
# a machine can run.
#
# WHY IT CHECKS BEFORE IT INSTALLS.  A package manager given a list installs
# what it can and fails on the rest, which leaves a half-installed system and a
# message about the LAST name rather than the wrong one.  So every name is
# resolved first, all of them, and nothing is installed unless all of them
# resolve.  `--dry-run' stops after that check.
#
# WHAT IT DOES NOT DO: scheme-utils, scheme-toolkit and scheme-desktop are not
# Arch packages.  scheme-utils is REQUIRED (the REPL back door lives there) and
# is installed with `make install PREFIX=/usr' from its own checkout; the other
# two are this project.  The script says so at the end rather than guessing
# where your checkouts are.

set -euo pipefail

# ---------------------------------------------------------------------------
# The lists
# ---------------------------------------------------------------------------

# Official repositories.  `pacman -S'.
REPO_REQUIRED=(
    guile                 # the interpreter
    glib2                 # GLib; owns libgirepository-2.0.so
    gobject-introspection # loads the typelibs (also a guile-g-golf dependency)
    gtk4
    libadwaita
    gtk4-layer-shell      # MANDATORY: LD_PRELOAD, or anchors silently no-op
    hyprland              # the compositor; hyprctl is called
    cliphist              # clipboard history
    wl-clipboard          # wl-copy / wl-paste
    grim                  # screenshots
    slurp                 # screenshot region
    playerctl             # media control
    jq                    # inspecting hyprctl -j by hand
    gdb                   # `bin/scheme-desktop gdb'
)

# Official repositories, only if the matching feature is wanted.
REPO_OPTIONAL=(
    ddcutil               # external-display brightness
    cava                  # audio visualiser (AstalCava)
    hyprpaper             # wallpaper (alternative to awww)
    wf-recorder           # screen recording
    brightnessctl         # named in process.scm's example; not called today
)

# AUR.  `yay -S'.  guile-lib and gobject-introspection arrive as guile-g-golf's
# dependencies, so they are not named here.
AUR_REQUIRED=(
    guile-g-golf          # the GI binding everything is written against
    libastal-meta         # every libastal service the code imports
    guile-json3           # (json), imported by (scheme-desktop menu omarchy)
)

AUR_OPTIONAL=(
    guile-cairo           # not imported yet; needed the day a cairo widget lands
)

# `swww' was renamed: extra/awww Provides: swww.  Named here so the reason is
# written down rather than rediscovered.
REPO_OPTIONAL+=(
    awww                  # wallpaper daemon (provides swww)
)

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

say()  { printf '%s\n' "$*"; }
warn() { printf 'install-arch-packages: %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

OPTIONAL=0
DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --optional) OPTIONAL=1 ;;
        --dry-run)  DRY_RUN=1 ;;
        -h|--help)  usage ;;
        *)          die "unknown argument: $arg (try --help)" ;;
    esac
done

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

command -v pacman >/dev/null 2>&1 || die "pacman not found -- this is not an Arch system"

# yay is only needed for the AUR half, and only when that half is non-empty.
HAVE_YAY=0
command -v yay >/dev/null 2>&1 && HAVE_YAY=1

# ---------------------------------------------------------------------------
# Resolve every name BEFORE installing any of them
# ---------------------------------------------------------------------------

repo_pkgs=("${REPO_REQUIRED[@]}")
aur_pkgs=("${AUR_REQUIRED[@]}")
if [ "$OPTIONAL" -eq 1 ]; then
    repo_pkgs+=("${REPO_OPTIONAL[@]}")
    aur_pkgs+=("${AUR_OPTIONAL[@]}")
fi

missing_repo=()
for p in "${repo_pkgs[@]}"; do
    pacman -Si "$p" >/dev/null 2>&1 || missing_repo+=("$p")
done

missing_aur=()
if [ "${#aur_pkgs[@]}" -gt 0 ]; then
    if [ "$HAVE_YAY" -eq 0 ]; then
        warn "yay not found, but these are AUR packages: ${aur_pkgs[*]}"
        warn "install an AUR helper (yay/paru) or build them by hand"
        missing_aur=("${aur_pkgs[@]}")
    else
        for p in "${aur_pkgs[@]}"; do
            # `yay -Ss' prints `aur/NAME version ...'; match the name exactly so
            # a substring hit (guile-json3 vs guile-json) is not taken for it.
            yay -Ss "$p" 2>/dev/null | grep -qE "^(aur|extra|core)/$p " \
                || missing_aur+=("$p")
        done
    fi
fi

if [ "${#missing_repo[@]}" -gt 0 ] || [ "${#missing_aur[@]}" -gt 0 ]; then
    [ "${#missing_repo[@]}" -gt 0 ] && warn "not in any official repository: ${missing_repo[*]}"
    [ "${#missing_aur[@]}" -gt 0 ]  && warn "not found in the AUR: ${missing_aur[*]}"
    die "nothing was installed -- fix the names above first"
fi

say "all ${#repo_pkgs[@]} repository packages and ${#aur_pkgs[@]} AUR packages resolve"

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

# `--needed' so a second run is a no-op rather than a reinstall.
repo_cmd=(sudo pacman -S --needed --noconfirm "${repo_pkgs[@]}")
aur_cmd=(yay -S --needed --noconfirm "${aur_pkgs[@]}")

if [ "$DRY_RUN" -eq 1 ]; then
    say ""
    say "would run:"
    say "  ${repo_cmd[*]}"
    [ "${#aur_pkgs[@]}" -gt 0 ] && say "  ${aur_cmd[*]}"
    say ""
    say "and then, by hand (not Arch packages):"
    say "  cd <scheme-utils checkout> && sudo make install PREFIX=/usr"
    exit 0
fi

say ""
say "==> official repositories"
"${repo_cmd[@]}"

if [ "${#aur_pkgs[@]}" -gt 0 ]; then
    say ""
    say "==> AUR"
    # yay must not run as root; it asks for sudo itself when it needs to.
    "${aur_cmd[@]}"
fi

# ---------------------------------------------------------------------------
# What is left, and what to check
# ---------------------------------------------------------------------------

say ""
say "==> done.  Still to do by hand:"
say ""
say "  scheme-utils is REQUIRED and is not an Arch package -- it is where the"
say "  REPL back door lives, and Guile does not search ~/.local/share/guile on"
say "  its own:"
say ""
say "      cd <scheme-utils checkout> && sudo make install PREFIX=/usr"
say ""
say "  scheme-toolkit and scheme-desktop are this project; bin/scheme-toolkit"
say "  adds their -L paths itself."
say ""
say "  Then check the environment, which is where the silent failures are:"
say ""
say "      bin/scheme-toolkit check-env"
say ""
say "  A typelib imported in ENUMS-ONLY mode reports no error and gives 24"
say "  bindings instead of 143; check-env is what notices."
