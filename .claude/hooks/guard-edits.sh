#!/usr/bin/env bash
# PreToolUse (Edit|Write|NotebookEdit|Bash): enforce what AGENTS.md can only ask for.
#   deny  key material written by an edit tool anywhere (its content would
#         come from the model), or by the shell inside the repo
#   deny  a shell command that prints key material (cat, grep, git diff, …),
#         which would put the secret into the conversation
#   deny  generated files and lockfiles in the repo
#   ask   files that must be changed with a tool, not by hand
#   deny  writing the bootloader or xloader partition (fastboot, or dd on the unit)
# Piping a secret from 1Password into a file outside the repo for a command
# to consume (`op read … > "$tmp/key.rsa"`) stays allowed: nothing is printed.
# tool_paths.py resolves which files a call writes or reads, including shell
# redirections, sed -i, tee, cp/mv and heredocs; its docstring has the limits.
set -uo pipefail

root="${CLAUDE_PROJECT_DIR:?}"
input="$(cat)"

verdict="" reason=""
# The most restrictive answer wins: deny > ask.
decide() {
  [[ "$verdict" == deny || ("$verdict" == ask && "$1" == ask) ]] && return
  verdict="$1" reason="$2"
}

# $1 = basename, $2 = repo-relative path (or the absolute one outside the repo).
key_material() {
  case "$1" in
    *.example | *.example.* | *.sample | *.template | *.dist) return 1 ;; # committed templates
    # The device root password, WiFi profiles (PSK), abuild and fleet signing
    # keys (*.rsa; the *.rsa.pub next to them is public), app signing keys.
    .nexus_pw | *.rsa | .env | .env.* | *.p8 | *.pem | *.jks | *.keystore | \
      key.properties | service-account*.json | google-services.json | GoogleService-Info.plist) return 0 ;;
  esac
  # The private overlay's baked personal access: WiFi PSK, MQTT login, ssh keys.
  case "/$2" in
    */private/access/*) return 0 ;;
    # A WiFi profile carries its PSK — except the aports' own ethernet
    # profiles (eth-direct, eth-lan), which are shipped, secret-free and the
    # recovery link to a unit, so they must stay readable.
    /pmos/*.nmconnection) ;;
    *.nmconnection | *.nmconnection.*) return 0 ;;
  esac
  return 1
}

# The two writes that can brick a Nexus Q: the bootloader and xloader
# partitions. `Bash(fastboot *)` is allowed in settings.json, so this is what
# stands between an agent and them — by fastboot, or by dd on the unit.
brick="$(printf '%s' "$input" | python3 -c '
import json, re, sys
e = json.load(sys.stdin)
cmd = (e.get("tool_input") or {}).get("command", "") if e.get("tool_name") == "Bash" else ""
fb = re.search(r"\bfastboot\b[^;&|\n]*\b(flash|erase|format)(:\S+)?\s+(bootloader|xloader)\b", cmd)
dd = re.search(r"\bdd\b[^;&|\n]*\bof=\S*(xloader|bootloader|mmcblk\d+boot\d)", cmd)
print("yes" if fb or dd else "")
')"
if [[ -n "$brick" ]]; then
  verdict=deny
  reason="Writing the bootloader or xloader partition is the one way to brick a Nexus Q (INSTALL.md). No instruction clears this."
fi

while IFS=$'\t' read -r kind path; do
  [[ -n "$path" ]] || continue
  rel="${path#"$root/"}"
  base="${rel##*/}"
  inside=false
  [[ "$path" == "$root/"* ]] && inside=true
  if key_material "$base" "$rel"; then
    case "$kind" in
      E) decide deny "$rel holds key material. Secrets live in 1Password and never pass through the model." ;;
      W) $inside && decide deny "$rel holds key material. It comes from 1Password (scripts/gen-wifi-profile.sh, scripts/install-fleet-signing-key.sh), not by hand." ;;
      R) decide deny "$rel holds key material; printing it would put the secret into the conversation. Let the command that needs it read it (\`source\`, a file argument, \`op read\` piped into it)." ;;
    esac
    continue
  fi
  # Everything below guards the repo's own files against being written.
  if [[ "$kind" == R ]] || ! $inside; then continue; fi
  case "$base" in
    *.lock | package-lock.json | pnpm-lock.yaml | go.sum)
      decide deny "$rel is a lockfile; change the manifest (pubspec.yaml, Podfile) and let the package manager rewrite it." ;;
    project.pbxproj)
      decide ask "Hand edits corrupt project.pbxproj easily; prefer Xcode or an xcodeproj script." ;;
  esac
  # Leading slash so top-level directories match too.
  case "/$rel" in
    # Not output/: the build agent copies images there from the shell, legitimately.
    */build/* | */.dart_tool/* | */ephemeral/* | */GeneratedPluginRegistrant.* | */Generated.xcconfig)
      decide deny "$rel is generated; change its source instead." ;;
    /kernel/patches/*.patch)
      decide ask "Kernel patches are exported from the git patch stack (git format-patch; scripts/regen-dts-patch.sh for the DTS) and must apply with GNU patch on a pristine tree. A hand edit easily breaks the hunk headers." ;;
  esac
done < <(printf '%s' "$input" | python3 "$(dirname "$0")/tool_paths.py")

[[ -n "$verdict" ]] || exit 0
python3 -c 'import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
      "permissionDecision": sys.argv[1], "permissionDecisionReason": sys.argv[2]}}))' "$verdict" "$reason"
