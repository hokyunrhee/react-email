#!/usr/bin/env bash
# Maps the files a pull request changed to the Vitest roots nyorori must run in.
#
# Usage: bash .github/nyorori-roots.sh <base> [<head>]
#   Run from the repository root. <base> and <head> are git refs; the diff is
#   <base>...<head> (from their merge-base), as nyorori computes it.
#
# A root is the deepest directory above a changed file that holds a
# vitest.config.* file. Only JS/TS files and the component formats nyorori
# refuses (.vue, .svelte, .astro, .mdx, .marko, .gjs, .gts) count.
#
# Output, for $GITHUB_OUTPUT:
#   matrix=[{"root":..,"build":..,"node_options":..,"exclude":..}, ...]
# A Markdown report of the mapping goes to stderr and, in Actions, to the job summary.
set -euo pipefail
base=$1
head=${2:-HEAD}

# Per-root settings for this repository. Sets skip, build, node_options, exclude.
root_config() {
  skip='' build='' node_options='' exclude=''
  case "$1" in
    .)
      skip='repository-root config: files outside the package roots (scripts/, apps/docs) have no tests of their own here' ;;
    packages/editor)
      skip='test.projects with a browser-mode project: nyorori exits 2 on Vitest 4.1' ;;
    packages/react-email)
      # Its tests import the built @react-email/render.
      build='pnpm --filter @react-email/render run build'
      # Fixture trees under src/ would be judged as source and reported as NoCoverage.
      exclude=$'**/test/**\n**/tests/**\n**/testing/**\n**/e2e/**' ;;
    apps/web)
      # Some of its tests import the built react-email and @react-email/render.
      build='pnpm --filter react-email... run build' ;;
    packages/render)
      exclude=$'**/testing/**\n**/e2e/**' ;;
    packages/ui)
      build='pnpm --filter react-email... run build'
      node_options='--experimental-vm-modules --disable-warning=ExperimentalWarning'
      exclude=$'**/tests/**\n**/testing/**' ;;
  esac
}

summary() {
  printf '%s\n' "$@" >&2
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"; fi
}

configs=$(git ls-files -- '*vitest.config.*' | grep -E '(^|/)vitest\.config\.[cm]?[jt]s$' || true)
declare -A is_root=()
while IFS= read -r d; do
  [ -n "$d" ] && is_root[$d]=1
done < <(printf '%s\n' "$configs" | grep . | sed -E 's#(^|/)vitest\.config\.[cm]?[jt]s$##; s#^$#.#')

declare -A files_of=()
noroot=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  d=$(dirname "$f")
  root=''
  while :; do
    if [ -n "${is_root[$d]:-}" ]; then root=$d; break; fi
    [ "$d" = . ] && break
    d=$(dirname "$d")
  done
  if [ -z "$root" ]; then noroot+=("$f"); continue; fi
  files_of[$root]+="$f "
done < <(git diff --name-only --no-renames "$base...$head" -- \
  '*.js' '*.jsx' '*.mjs' '*.cjs' '*.ts' '*.tsx' '*.mts' '*.cts' \
  '*.vue' '*.svelte' '*.astro' '*.mdx' '*.marko' '*.gjs' '*.gts')

matrix='[]'
summary '## nyorori roots' '' '| Root | Changed files | Run |' '|---|---|---|'
for root in $( (( ${#files_of[@]} )) && printf '%s\n' "${!files_of[@]}" | sort); do
  root_config "$root"
  n=$(wc -w <<< "${files_of[$root]}")
  if [ -n "$skip" ]; then
    summary "| \`$root\` | $n | skipped: $skip |"
    continue
  fi
  summary "| \`$root\` | $n | yes |"
  matrix=$(jq -c --arg root "$root" --arg build "$build" --arg node_options "$node_options" --arg exclude "$exclude" \
    '. + [{root: $root, build: $build, node_options: $node_options, exclude: $exclude}]' <<< "$matrix")
done
if [ ${#noroot[@]} -gt 0 ]; then
  summary '' "${#noroot[@]} changed file(s) under no Vitest root: ${noroot[*]}"
fi
echo "matrix=$matrix"
