# shellcheck shell=sh
# lib/generate.sh -- generated cases: the RBAC and auth sweeps
#
# Sourced by scripts/tf.sh; defines functions only. See tf.sh for the paths
# and schema variables these rely on.

# ================================================================ generation

# rbac [routes_file] [privileged_file] [--owner ROLE]
#
# Two sweeps, both written in plain English because a person reads this file:
#   1. nobody (logged out) against every non-public page
#   2. every non-owner role against every restricted page
#
# Which pages are restricted cannot be derived from a glob, so the caller may
# supply a list -- /test-run has the model produce one ONCE from the guards,
# which is a single cheap pass rather than per-case work. With no list, a
# conservative name heuristic is used and says so.
#
# Everything here is `type=page`: a permission check must be judged by what the
# browser actually renders, not by a status code.
cmd_rbac() {
  routes_file="$CACHE/routes.txt"; priv_file=""; owner="admin"
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner) owner="$2"; shift 2 ;;
      *) if [ -z "${_r_set:-}" ]; then routes_file="$1"; _r_set=1; else priv_file="$1"; fi; shift ;;
    esac
  done
  [ -f "$routes_file" ] || die "rbac: no route list at $routes_file"
  [ -f "$CREDS" ] || die "rbac: no $CREDS"
  roles="$(json_keys "$CREDS" roles 2>/dev/null)"
  [ -n "$roles" ] || die "rbac: no roles in $CREDS"

  if [ -n "$priv_file" ] && [ -f "$priv_file" ]; then
    priv="$(cat "$priv_file")"
    echo "rbac: restricted pages from $priv_file" >&2
  else
    priv="$(grep -iE '/(admin|settings|manage|internal|config|users|roles|permissions|billing|audit|reports?|payroll|employees)' "$routes_file" || true)"
    echo "rbac: no restricted-page list given; guessing from names ($(printf '%s' "$priv" | grep -c . ) pages)" >&2
  fi

  # HEADER plus the two state columns merge needs; merge routes each to its file
  printf '%s,type,route,tags\n' "$HEADER"
  n=0; m=0
  while IFS= read -r route; do
    [ -n "$route" ] || continue
    case "$route" in
      /|/login|/signin|/signup|/register|/forgot*|/reset*|/public/*|/health*|/about|/pricing|/terms|/privacy|/apply|/404|/500) continue ;;
      */api/*|/api/*) continue ;;
    esac
    n=$((n + 1))
    probe="$(probe_url "$route")"
    printf 'AUTH-%03d,%s,nobody,%s,%s,high,new,,page,%s,\n' \
      "$n" \
      "$(csv_esc "$(area_of "$route")")" \
      "$(csv_esc "Open $probe without logging in")" \
      "$(csv_esc "Should not open - sends me to the login page")" \
      "$probe"
  done < "$routes_file"

  # API endpoints: no browser, because rendering JSON in Chromium proves
  # nothing. These stay curl cases and stay free.
  a=0
  while IFS= read -r route; do
    case "$route" in /api/*|*/api/*) ;; *) continue ;; esac
    a=$((a + 1))
    probe="$(probe_url "$route")"
    printf 'API-%03d,%s,nobody,%s,%s,high,new,,api,%s,refused\n' \
      "$a" \
      "$(csv_esc "$(area_of "$route")")" \
      "$(csv_esc "Call $probe without logging in")" \
      "$(csv_esc "Should be refused")" \
      "$probe"
  done < "$routes_file"

  [ -n "$priv" ] || return 0
  for role in $roles; do
    [ "$role" = "$owner" ] && continue
    printf '%s
' "$priv" | while IFS= read -r route; do
      [ -n "$route" ] || continue
      case "$route" in */api/*|/api/*) continue ;; esac
      m=$((m + 1))
      probe="$(probe_url "$route")"
      printf 'PERM-%s-%03d,%s,%s,%s,%s,high,new,,page,%s,\n' \
        "$(printf '%s' "$role" | tr 'a-z' 'A-Z' | cut -c1-4)" "$m" \
        "$(csv_esc "$(area_of "$route")")" \
        "$(csv_esc "$(who_label "$role")")" \
        "$(csv_esc "Log in as $(who_label "$role") and open $probe")" \
        "$(csv_esc "Should not open - I am not allowed to see this")" \
        "$probe"
    done
  done
}

# Plain words for roles. "anonymous" means nothing to most readers.
who_label() {
  case "$1" in
    user|member|staff|employee) echo "normal user" ;;
    anonymous|"")               echo "nobody" ;;
    *)                          echo "$1" ;;
  esac
}

# The area column groups cases the way a person would: by the first path
# segment, which is almost always the feature name.
area_of() {
  a="$(printf '%s' "$1" | sed -e 's#^/##' -e 's#/.*$##' -e 's#[^A-Za-z0-9_-].*##')"
  [ -n "$a" ] || a="home"
  printf '%s' "$a"
}

# Parameterised routes cannot be fetched literally. Substitute a probe value so
# the guard is still exercised: an unauthenticated /employees/1 must redirect
# whether or not employee 1 exists.
probe_url() {
  printf '%s' "$1" |
    sed -e 's#:[A-Za-z_][A-Za-z0-9_]*#1#g' \
        -e 's#\[\[\.\.\.[A-Za-z0-9_]*\]\]#1#g' \
        -e 's#\[\.\.\.[A-Za-z0-9_]*\]#1#g' \
        -e 's#\[[A-Za-z0-9_]*\]#1#g' \
        -e 's#<[^>]*>#1#g' \
        -e 's#{[^}]*}#1#g'
}

csv_esc() { printf '%s' "$1" | sed 's/"/""/g' | awk '{ if ($0 ~ /[",]/) printf "\"%s\"", $0; else printf "%s", $0 }'; }
