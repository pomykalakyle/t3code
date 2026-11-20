#!/usr/bin/env bash
# Fork only (branch `kyle`, Mac). Brings `kyle` up to the newest upstream nightly,
# pushes it, and builds the patched "T3 Code (Nightly)" app on this Mac the way
# .github/workflows/kyle-mac.yml does: stock nightly version, no update feed,
# ad-hoc signed.
#
#   scripts/kyle-update.sh             pull, merge the newest nightly, push, build
#   scripts/kyle-update.sh --install   ...then quit T3, back up the installed app,
#                                      install the new one and reopen it
#   scripts/kyle-update.sh --no-merge  build the current `kyle` as is
#
# The build runs in its own worktree (~/.cache/t3code-kyle-build) so this
# checkout stays clean and keeps its own node_modules.
set -euo pipefail

install=0
merge=1
for arg in "$@"; do
  case "$arg" in
    --install) install=1 ;;
    --no-merge) merge=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'kyle-update: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "builds the Mac app; run it on the Mac"
repo="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$repo"
[ "$(git symbolic-ref --short -q HEAD || true)" = kyle ] || die "check out the kyle branch first"
git diff --quiet HEAD || die "commit or stash your changes first"

export GIT_TERMINAL_PROMPT=0
export PATH="$HOME/.local/share/vite-plus/bin:$PATH"
command -v vp >/dev/null || die "Vite+ missing: curl -fsSL https://vite.plus | bash"

say "Pulling origin/kyle"
git pull -q --ff-only origin kyle

if [ "$merge" = 1 ]; then
  say "Fetching upstream nightly tags"
  git fetch -q --no-tags upstream 'refs/tags/v*:refs/tags/v*'
  tag="$(git tag -l 'v*-nightly.*' --sort=-v:refname | head -1)"
  [ -n "$tag" ] || die "no upstream nightly tags found"
  if git merge-base --is-ancestor "$tag" HEAD; then
    echo "kyle already contains $tag"
  else
    say "Merging $tag"
    # A merge, not a rebase: no force-push, so the other machine fast-forwards.
    git merge -q --no-edit -m "Merge upstream $tag into kyle" "$tag" ||
      die "merge conflict: fix it, commit, then rerun with --no-merge"
  fi
  git push -q origin kyle
fi

# Upstream workflows run on paid runners and can come back after a push.
if command -v gh >/dev/null; then
  slug="$(git remote get-url origin | sed -E 's#^.*github.com[:/]##; s#\.git$##')"
  gh workflow list -R "$slug" --all --json path,state \
    --jq '.[] | select(.state == "active" and (.path | endswith("/kyle-mac.yml") | not)) | .path' |
    while read -r wf; do
      echo "disabling re-enabled workflow $wf"
      gh workflow disable -R "$slug" "$(basename "$wf")"
    done
fi

sha="$(git rev-parse HEAD)"
tag="$(git describe --tags --abbrev=0 --match 'v*-nightly.*' HEAD)"
version="${tag#v}"
build="${KYLE_BUILD_DIR:-$HOME/.cache/t3code-kyle-build}"

say "Building $version + kyle.${sha:0:7} in $build"
if [ -d "$build" ]; then
  git -C "$build" checkout -q --detach --force "$sha"
else
  git worktree add -q --detach "$build" "$sha"
fi
cd "$build"
rm -rf release
vp install
node scripts/update-release-package-versions.ts "$version"
cp .env.example .env
# The default macOS 27 SDK breaks the Command Line Tools linker; 26.5 links.
sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
[ -d "$sdk" ] && export SDKROOT="$sdk"
# No GITHUB_REPOSITORY means no publish config, so the app has no update feed.
env -u GITHUB_REPOSITORY -u T3CODE_DESKTOP_UPDATE_REPOSITORY T3CODE_TELEMETRY_CHANNEL=dev \
  vp run dist:desktop:artifact --platform mac --target dir --arch arm64 --build-version "$version"

app="$(find release -maxdepth 2 -name '*.app' -type d | head -1)"
[ -n "$app" ] || die "build produced no .app"
app="$build/$app"
[ ! -f "$app/Contents/Resources/app-update.yml" ] || die "app-update.yml present: update feed not disabled"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
say "Built $app"

[ "$install" = 1 ] || exit 0

# Installing quits T3, which kills anything T3 started (including the agent
# running this script), so the swap runs detached under launchd's session.
target="/Applications/T3 Code (Nightly).app"
backups="$HOME/.cache/t3code-app-backups"
log="$backups/install.log"
mkdir -p "$backups"
installer="$backups/install.sh"
cat >"$installer" <<'EOF'
set -u
app="$1"; target="$2"; backups="$3"
note() { echo "$(date '+%F %T') $*"; osascript -e "display notification \"$*\" with title \"T3 Code update\""; }
running() { [ "$(osascript -e 'application id "com.t3tools.t3code" is running')" = true ]; }
osascript -e 'tell application id "com.t3tools.t3code" to quit'
for _ in $(seq 1 120); do running || break; sleep 1; done
if running; then note "T3 did not quit; nothing installed"; exit 1; fi
if [ -d "$target" ]; then
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backups/$stamp"
  mv "$target" "$backups/$stamp/" || { note "could not move the old app; nothing installed"; open "$target"; exit 1; }
  # Keep the three newest backups.
  ls -1d "$backups"/2* | sort -r | tail -n +4 | while read -r old; do rm -rf "${old:?}"; done
fi
ditto "$app" "$target"
note "Installed $(defaults read "$target/Contents/Info" CFBundleShortVersionString)"
open "$target"
EOF
say "Installing in the background; T3 will quit and reopen (log: $log)"
python3 - "$installer" "$app" "$target" "$backups" "$log" <<'EOF'
import os, sys
script, app, target, backups, log = sys.argv[1:]
if os.fork():
    sys.exit(0)
os.setsid()
if os.fork():
    os._exit(0)
fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
os.dup2(fd, 1); os.dup2(fd, 2)
os.dup2(os.open(os.devnull, os.O_RDONLY), 0)
os.execv("/bin/bash", ["/bin/bash", script, app, target, backups])
EOF
