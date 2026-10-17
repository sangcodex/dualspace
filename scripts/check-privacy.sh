#!/bin/zsh
# Audit shareable files and Git's index without printing sensitive matches.
set -euo pipefail
TASK_ROOT="${0:A:h:h}"
cd "$TASK_ROOT"
command -v rg >/dev/null || { print -u2 'Install ripgrep to run the privacy check.'; exit 1; }
mkdir -p .local
AUDIT_ROOT="$(mktemp -d "$TASK_ROOT/.local/privacy-check.XXXXXX")"
trap 'rm -rf "$AUDIT_ROOT"' EXIT
git init --bare --quiet "$AUDIT_ROOT/git"
audit_git() {
  git --git-dir="$AUDIT_ROOT/git" --work-tree="$TASK_ROOT" -c core.bare=false -c core.excludesFile=/dev/null "$@"
}

failures=0
for sample in \
  .local/Profiles/example/account.dat Profiles/example/account.dat \
  Retired/example.bundle/Contents/Info.plist backups/instances.json \
  instances.json launch.json local.db local.sqlite-wal logs/app.log \
  app.crash app.ips captures/window.png screenshots/window.png \
  dist/DualSpace.app/Contents/Info.plist Example.app/Contents/Info.plist \
  installer.dmg backup.zip .env .env.local signing.p12 credentials.json; do
  if ! audit_git check-ignore --no-index -q -- "$sample"; then
    print -r -- "Missing ignore protection: $sample"
    (( failures += 1 ))
  fi
done

pattern='(/Users|/home)/[[:alnum:]_.-]+/|local\.dualspace\.instance\.i[0-9a-f]{32}|-[0-9a-f]{8}\.app|wxid_[[:alnum:]_-]{6,}|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----|(gh[pousr]_|github_pat_)[[:alnum:]_]{20,}|sk-[[:alnum:]_-]{24,}'
scan_content() {
  local input="$1" label="$2" result=0
  rg --text --quiet -e "$pattern" -- "$input" || result=$?
  if (( result == 0 )); then
    print -r -- "Review private content: $label"
    (( failures += 1 ))
  elif (( result > 1 )); then
    print -r -- "Could not inspect: $label"
    (( failures += 1 ))
  fi
  return 0
}

files=("${(@0)$(audit_git ls-files -z --others --exclude-standard)}")
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
tracked=()
if [[ "$repo_root" == "$TASK_ROOT" ]]; then
  tracked=("${(@0)$(git ls-files -z)}")
  files+=("${tracked[@]}")
  for relative in "${tracked[@]}"; do
    [[ -n "$relative" ]] || continue
    if audit_git check-ignore --no-index -q -- "$relative"; then
      print -r -- "Ignored file is already tracked: $relative"
      (( failures += 1 ))
    fi
    if git show ":$relative" > "$AUDIT_ROOT/index-content"; then
      scan_content "$AUDIT_ROOT/index-content" "index:$relative"
    else
      print -r -- "Could not inspect index entry: $relative"
      (( failures += 1 ))
    fi
  done
else
  print 'No repository index exists; checking project ignore rules and shareable files.'
fi

checked=0
for relative in "${(u)files[@]}"; do
  [[ -n "$relative" ]] || continue
  if [[ -L "$relative" ]]; then
    print -r -- "Review shareable symlink: $relative"
    (( failures += 1 ))
  elif [[ -f "$relative" ]]; then
    scan_content "$relative" "$relative"
    (( checked += 1 ))
  fi
done

if (( failures > 0 )); then
  print -r -- "Privacy check failed: $failures issue(s). No data was uploaded."
  exit 1
fi
print -r -- "Privacy check passed: $checked shareable files; ignore samples and available index checked."
