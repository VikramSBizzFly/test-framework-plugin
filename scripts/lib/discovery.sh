# shellcheck shell=sh
# lib/discovery.sh -- routes, forms, schemas, cache keys and coverage
#
# Sourced by scripts/tf.sh; defines functions only. See tf.sh for the paths
# and schema variables these rely on.

# ================================================================= discovery

# routes [srcdir] -- derive the route list from framework file conventions.
# Deterministic; the model is never asked to enumerate what a glob can answer.
cmd_routes() {
  src="${1:-.}"
  {
    # Next.js app router
    find "$src" -type f \( -name 'page.tsx' -o -name 'page.jsx' -o -name 'page.ts' -o -name 'page.js' \) \
      -not -path '*/node_modules/*' 2>/dev/null |
      sed -e 's#.*/app##' -e 's#/page\.[jt]sx\?$##' -e 's#^$#/#' -e 's#(\([^)]*\))/##g'
    # Next.js pages router
    find "$src" -type d -name pages -not -path '*/node_modules/*' 2>/dev/null | while read -r d; do
      find "$d" -type f \( -name '*.tsx' -o -name '*.jsx' \) -not -name '_*' 2>/dev/null |
        sed -e "s#^$d##" -e 's#\.[jt]sx$##' -e 's#/index$##' -e 's#^$#/#'
    done
    # React Router / Vue Router literals
    grep -rhoE "path:[[:space:]]*['\"][^'\"]+['\"]" "$src" \
      --include='*.tsx' --include='*.jsx' --include='*.ts' --include='*.js' --include='*.vue' \
      --exclude-dir=node_modules 2>/dev/null | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/"
    # Django
    grep -rhoE "path\([[:space:]]*['\"][^'\"]*['\"]" "$src" --include='urls.py' 2>/dev/null |
      sed -E "s/.*['\"]([^'\"]*)['\"].*/\/\1/"
    # Flask / FastAPI
    grep -rhoE "@[a-zA-Z_]+\.(route|get|post|put|delete)\([[:space:]]*['\"][^'\"]+['\"]" "$src" \
      --include='*.py' 2>/dev/null | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/"
    # Rails
    grep -rhoE "^[[:space:]]*(get|post|put|patch|delete)[[:space:]]+['\"][^'\"]+['\"]" "$src" \
      --include='routes.rb' 2>/dev/null | sed -E "s/.*['\"]([^'\"]+)['\"].*/\/\1/"
    # Spring / .NET attributes
    grep -rhoE "@(Request|Get|Post|Put|Delete)Mapping\([\"']?[^\"')]*" "$src" \
      --include='*.java' 2>/dev/null | sed -E "s/.*[\"']([^\"']*).*/\1/"
    grep -rhoE "\[Route\(\"[^\"]+\"\)\]" "$src" --include='*.cs' 2>/dev/null |
      sed -E 's/.*"([^"]+)".*/\/\1/'
    # Express
    grep -rhoE "(app|router)\.(get|post|put|patch|delete)\([[:space:]]*['\"][^'\"]+['\"]" "$src" \
      --include='*.js' --include='*.ts' --exclude-dir=node_modules 2>/dev/null |
      sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/"
  } 2>/dev/null |
    sed -e 's#//*#/#g' -e 's#\(.\)/$#\1#' |
    grep -E '^/' | grep -vE '\.(css|js|png|svg|ico|map|json)$' |
    # component references, not URLs: a final segment like LoginPage / UserView
    grep -vE '/[A-Z][A-Za-z0-9]*(Page|Component|View|Layout|Screen)$' |
    sort -u
}

# forms [srcdir] -- where forms live, for the page modeller to prioritise.
cmd_forms() {
  src="${1:-.}"
  grep -rlE '<form|onSubmit|handleSubmit|<Form' "$src" \
    --include='*.tsx' --include='*.jsx' --include='*.vue' --include='*.html' \
    --include='*.erb' --include='*.py' --exclude-dir=node_modules 2>/dev/null | sort -u
}

# schemas [srcdir] -- validation constraints, for boundary-case expansion.
cmd_schemas() {
  src="${1:-.}"
  grep -rnE 'z\.(string|number|boolean|enum)\(|\.min\(|\.max\(|\.email\(|\.regex\(' "$src" \
    --include='*.ts' --include='*.tsx' --exclude-dir=node_modules 2>/dev/null
  grep -rnE 'Field\(|constr\(|conint\(|EmailStr|validator' "$src" --include='*.py' 2>/dev/null
  grep -rnE '@(NotNull|NotBlank|Size|Min|Max|Email|Pattern)' "$src" --include='*.java' 2>/dev/null
  grep -rnE '\[(Required|StringLength|Range|EmailAddress|RegularExpression)' "$src" --include='*.cs' 2>/dev/null
}

# hash [srcdir] -- cache key. Changes only when source that could affect the
# UI changes, so an unchanged repo re-generates for free.
cmd_hash() {
  src="${1:-.}"
  if have git && git -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
    { git -C "$src" rev-parse HEAD 2>/dev/null
      git -C "$src" status --porcelain 2>/dev/null
      git -C "$src" diff --stat 2>/dev/null; } | cksum | awk '{print $1}'
  else
    find "$src" -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \
      -o -name '*.py' -o -name '*.java' -o -name '*.cs' -o -name '*.vue' -o -name '*.html' \) \
      -not -path '*/node_modules/*' -not -path '*/tests/*' 2>/dev/null |
      sort | xargs cksum 2>/dev/null | cksum | awk '{print $1}'
  fi
}

# impacted -- git diff -> case ids, via the source_files column.
cmd_impacted() {
  need_csv
  base="${1:-HEAD}"
  changed="$(git diff --name-only "$base" 2>/dev/null; git diff --name-only --cached 2>/dev/null; git ls-files -o --exclude-standard 2>/dev/null)"
  [ -n "$changed" ] || { echo "impacted: no changed files" >&2; return 0; }
  printf '%s\n' "$changed" | sort -u > "$CACHE/.changed.$$" 2>/dev/null || \
    { mkdir -p "$CACHE"; printf '%s\n' "$changed" | sort -u > "$CACHE/.changed.$$"; }
  joined > "$CACHE/.imp.$$"
  awk -v cf="$CACHE/.changed.$$" "$AWKLIB"'
    BEGIN { while ((getline l < cf) > 0) if (l != "") CH[l] = 1 }
    NR == 1 { hdrmap($0, H); next }
    {
      csvsplit($0, F)
      n = split(F[H["source_files"]], SF, ";")
      for (i = 1; i <= n; i++) {
        if (SF[i] == "") continue
        for (c in CH) if (index(c, SF[i]) > 0 || index(SF[i], c) > 0) { print F[H["id"]]; next }
      }
    }
  ' "$CACHE/.imp.$$" | sort -u
  rm -f "$CACHE/.changed.$$" "$CACHE/.imp.$$"
}

# cover -- discovered routes with no case against them.
cmd_cover() {
  need_csv
  routes_file="${1:-$CACHE/routes.txt}"
  [ -f "$routes_file" ] || die "cover: no route list at $routes_file (run tf.sh routes > $routes_file)"
  joined > "$CACHE/.cover.$$"
  awk "$AWKLIB"'
    NR == FNR { if ($0 != "") R[$0] = 1; next }
    FNR == 1 { hdrmap($0, H); next }
    { csvsplit($0, F); COVERED[F[H["route"]]]++ }
    END {
      for (r in R) if (!(r in COVERED)) print "uncovered\t" r
      for (r in R) if (r in COVERED && COVERED[r] < 2) print "thin\t" r "\t" COVERED[r]
    }
  ' "$routes_file" "$CACHE/.cover.$$" | sort
  rm -f "$CACHE/.cover.$$"
}
