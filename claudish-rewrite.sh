#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# claudish-rewrite  —  on-demand, LLM-invocable plain-language rewriter
#
# The display hook (rewrite.sh) and the Markdown hook (rewrite-md.sh) are both
# PASSIVE: one fires on assistant messages, the other on Write/Edit under a
# gated directory. Neither can be called on demand. This script exposes the
# same rewrite — same providers.sh, same language resolution, same Markdown
# prompt — as a CLI that a human, a slash command, or an agent (via Bash) can
# invoke on any file or piped text.
#
# It is NOT a hook and shares no code path with them beyond providers.sh and
# lang.sh, so it cannot change what you see on screen or what the hooks write.
#
# Usage:
#   claudish-rewrite [options] [FILE]
#   cat notes.md | claudish-rewrite [options]
#
#   FILE        read this file; omit (or pass "-") to read stdin.
#
# Output (default: stdout):
#   -o FILE       write the rewrite to FILE
#   --sibling     write NAME.<suffix>.md next to the input (FILE input only)
#   --overwrite   replace the input FILE in place (FILE input only)
#   --suffix W    sibling infix: NAME.W.md (default "plain")
#
#   -l, --language LANG   rewrite into LANG (else CLAUDISH_LANG / the session's
#                         settings `language`; with neither, keep the input's
#                         language)
#   --prompt-file FILE    whole replacement system prompt (else
#                         CLAUDISH_MD_PROMPT_FILE, else the built-in default)
#   -h, --help
#
# Provider/model/timeout come from the same CLAUDISH_* env as the hooks (see
# providers.sh). Default provider is local ollama — nothing leaves the machine.
#
# FAIL-LOUD, unlike the hooks. The hooks fail OPEN (a dead provider just leaves
# your text untouched) because they run behind your back. This is on demand:
# you asked, so a failure prints why to stderr and exits non-zero rather than
# silently handing back the original. Nothing is written on failure.
# ---------------------------------------------------------------------------
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

die() { printf 'claudish-rewrite: %s\n' "$*" >&2; exit 1; }

# providers.sh and lang.sh expect the caller to define dbg() and set LLM_TIMEOUT.
dbg() { [ "${CLAUDISH_DEBUG:-0}" = "1" ] && printf '%s [rewrite-cli] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; return 0; }
LLM_TIMEOUT="${CLAUDISH_REWRITE_TIMEOUT:-${CLAUDISH_MD_TIMEOUT:-150}}"
STUB="${CLAUDISH_STUB:-0}"

. "$SELF_DIR/providers.sh" 2>/dev/null || die "cannot load providers.sh next to this script"
claudish_language() { :; }
. "$SELF_DIR/lang.sh" 2>/dev/null || dbg "no lang.sh; keeping the input's language"

MARKER="<!-- claudish-to-english:rewritten -->"

# ---- parse args ----------------------------------------------------------
file=""; out_mode="stdout"; out_file=""; suffix="plain"
lang_override=""; lang_set=0; prompt_file="${CLAUDISH_MD_PROMPT_FILE:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    -o)            out_mode="file"; out_file="${2:-}"; [ -n "$out_file" ] || die "-o needs a path"; shift 2 ;;
    --sibling)     out_mode="sibling"; shift ;;
    --overwrite)   out_mode="overwrite"; shift ;;
    --suffix)      suffix="${2:-}"; [ -n "$suffix" ] || die "--suffix needs a word"; shift 2 ;;
    -l|--language) lang_override="${2:-}"; lang_set=1; shift 2 ;;
    --prompt-file) prompt_file="${2:-}"; shift 2 ;;
    -h|--help)     sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --)            shift; break ;;
    -*)            die "unknown option: $1" ;;
    *)             [ -z "$file" ] || die "more than one FILE given"; file="$1"; shift ;;
  esac
done
[ $# -eq 0 ] || { [ -z "$file" ] && file="$1" || die "more than one FILE given"; }

# ---- read input ----------------------------------------------------------
if [ -z "$file" ] || [ "$file" = "-" ]; then
  [ "$out_mode" = "sibling" ] && die "--sibling needs a FILE, not stdin"
  [ "$out_mode" = "overwrite" ] && die "--overwrite needs a FILE, not stdin"
  content="$(cat)"
  src_label="stdin"
else
  [ -f "$file" ] || die "no such file: $file"
  content="$(cat "$file")" || die "cannot read $file"
  src_label="$file"
fi
[ -n "${content//[[:space:]]/}" ] || die "nothing to rewrite ($src_label is empty)"

# ---- protect YAML frontmatter (rewrite the body only) --------------------
first_line="$(printf '%s' "$content" | head -n1)"
fm=""; body="$content"
if [ "$first_line" = "---" ]; then
  total="$(printf '%s\n' "$content" | wc -l | tr -d ' ')"
  fm="$(printf '%s\n' "$content" | awk 'NR==1{print;next} /^---[[:space:]]*$/{print;exit} {print}')"
  fm_lines="$(printf '%s\n' "$fm" | wc -l | tr -d ' ')"
  if [ "$fm_lines" -lt "$total" ]; then
    body="$(printf '%s\n' "$content" | awk -v n="$fm_lines" 'NR>n')"
  else
    fm=""  # no closing '---' — treat the whole file as body
  fi
fi

# Strip a prior idempotency marker so an --overwrite re-run is not a no-op quirk.
body="$(printf '%s\n' "$body" | grep -vF "$MARKER")"
[ -n "${body//[[:space:]]/}" ] || die "nothing to rewrite once frontmatter is set aside"

# ---- build the prompt ----------------------------------------------------
OUT_LANG=""
if [ "$lang_set" = "1" ]; then
  OUT_LANG="$lang_override"            # explicit flag wins, "" forces keep-language
else
  OUT_LANG="$(claudish_language "$PWD")"
fi

sys="You rewrite Markdown prose into much simpler, plain language. Write the rewrite in the same language as the text you are rewriting. Keep every fact, name, number, link, and file path. Keep all Markdown structure — headings, lists, tables, and links. Do NOT change fenced code blocks or any YAML frontmatter; reproduce them exactly. Use short sentences and everyday words. Output ONLY the rewritten Markdown, with no preamble, labels, or commentary."
if [ -n "$OUT_LANG" ]; then
  sys="$sys"$'\n\n'"Write the rewritten Markdown in $OUT_LANG instead, whatever language the original is in. Use $OUT_LANG for all prose, including headings, list items, and table cells. Keep code, identifiers, file paths, link targets, and YAML frontmatter exactly as they are."
fi
if [ -n "$prompt_file" ]; then
  _p=""; [ -r "$prompt_file" ] && _p="$(cat "$prompt_file" 2>/dev/null)"
  [ -n "$_p" ] && sys="$_p" || die "--prompt-file given but empty/unreadable: $prompt_file"
fi

# ---- rewrite -------------------------------------------------------------
rewrite=""; curl_rc=0; err=""; http=""; truncated=0
if [ "$STUB" = "1" ]; then
  rewrite="STUB-REWRITE ✦ provider=${PROVIDER} model=${MODEL:-default} lang=${OUT_LANG:-same} ✦"$'\n\n'"$body"
else
  llm_complete "$sys" "$body" || die "could not build the request (bad jq input?)"
fi

if [ -z "$rewrite" ]; then
  NOTICE_WHY=""
  llm_notice_why 2>/dev/null || true
  if [ "${truncated:-0}" = "1" ]; then
    die "the rewrite hit the output-token cap and was discarded — raise CLAUDISH_MAX_TOKENS"
  fi
  die "${NOTICE_WHY:-the provider returned an empty rewrite}"
fi

# ---- emit ----------------------------------------------------------------
emit_body() { [ -n "$fm" ] && printf '%s\n\n' "$fm"; printf '%s\n' "$rewrite"; }

case "$out_mode" in
  stdout)
    emit_body
    ;;
  file)
    emit_body > "$out_file".tmp.$$ && mv -f "$out_file".tmp.$$ "$out_file" || die "write failed: $out_file"
    printf 'claudish-rewrite: wrote %s\n' "$out_file" >&2
    ;;
  sibling)
    target="${file%.md}.$suffix.md"
    emit_body > "$target".tmp.$$ && mv -f "$target".tmp.$$ "$target" || die "write failed: $target"
    printf 'claudish-rewrite: wrote %s\n' "$target" >&2
    ;;
  overwrite)
    tmp="$file.tmp.$$"
    { [ -n "$fm" ] && printf '%s\n\n' "$fm"; printf '%s\n\n' "$MARKER"; printf '%s\n' "$rewrite"; } > "$tmp" \
      || die "write failed: $file"
    mv -f "$tmp" "$file" || { rm -f "$tmp"; die "atomic replace failed: $file"; }
    printf 'claudish-rewrite: rewrote %s in place\n' "$file" >&2
    ;;
esac
