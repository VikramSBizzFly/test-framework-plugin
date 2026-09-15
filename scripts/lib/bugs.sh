# shellcheck shell=sh
# lib/bugs.sh -- the bug store and `tf.sh bug`
#
# Sourced by scripts/tf.sh; defines functions only. See tf.sh for BUGS and
# BUG_HEADER.
#
# tests/.cache/bugs.csv is the store behind tests/bug-report.xlsx: one row per
# bug, in the team's bug-sheet columns, plus a hidden `case_id` tying each bug
# to the case that raised it. Same guarantees as the case store -- it is written
# only through _tf_commit, backed up, gated and restorable.
#
# The split of work is the point of this file. Everything that can be looked up
# is filled in here, deterministically: the number, the module, the steps, what
# should and did happen, the reporter, the environment, the link, the date. The
# agent supplies only judgement -- a description, a severity, a priority, its
# reasoning. People own the rest: the issue link, the dev's comment, and what
# happens to the bug's status after it is raised.

BUG_STATUSES='Open|In Progress|Fixed|Retest|Reopened|Closed|Not a Bug'
BUG_SEVERITIES='Critical|High|Medium|Low'
BUG_PRIORITIES='High|Medium|Low'

cmd_bug() {
  sub="${1:-}"; [ $# -gt 0 ] && shift
  case "$sub" in
    from) _bug_from "$@" ;;
    set)  _bug_set "$@" ;;
    list) _bug_list "$@" ;;
    ""|help) die "bug: use  bug from <case-id> [field=value ...]  |  bug set <BUG-NNN> field=value ...  |  bug list [--status Open]" ;;
    *) die "bug: unknown subcommand '$sub' (from, set, list)" ;;
  esac
}

_bug_init() {
  mkdir -p "$CACHE"
  [ -f "$BUGS" ] || printf '%s\n' "$BUG_HEADER" > "$BUGS"
}

# _bug_secrets -- every password, token or secret in credentials.json, one per
# line. A bug report is the file most likely to be pasted somewhere public, so a
# value carrying one of these is refused rather than written.
_bug_secrets() {
  [ -f "$CREDS" ] || return 0
  tr -d '\r\n' < "$CREDS" |
    grep -o '"[A-Za-z_]*\(password\|passwd\|token\|secret\|api_key\|apikey\)[A-Za-z_]*"[[:space:]]*:[[:space:]]*"[^"]*"' |
    sed 's/^.*:[[:space:]]*"\(.*\)"$/\1/' |
    awk 'length($0) >= 3'
}

# _bug_assign <file> <field=value>... -- validate assignments into a TAB file
# the awk writer reads. Refuses an unknown field, an out-of-list severity,
# priority or status, a line break, and anything carrying a credential.
_bug_assign() {
  _a_out="$1"; shift
  : > "$_a_out"
  _a_secrets="$(_bug_secrets)"
  for _a in "$@"; do
    case "$_a" in *=*) ;; *) die "bug: '$_a' is not field=value" ;; esac
    _a_k="${_a%%=*}"; _a_v="${_a#*=}"
    case "$_a_k" in
      description|desc)  _a_k="Bug Description" ;;
      severity)          _a_k="Severity" ;;
      priority)          _a_k="Priority" ;;
      comments|comment)  _a_k="QA Comments" ;;
      status)            _a_k="Status(QA)" ;;
      actual)            _a_k="Actual Result" ;;
      link)              _a_k="Bug Link" ;;
      dev)               _a_k="Dev Comment" ;;
    esac
    case ",$BUG_HEADER," in
      *",$_a_k,"*) ;;
      *) die "bug: no column '$_a_k' in the bug sheet" ;;
    esac
    [ "$_a_k" = case_id ] && die "bug: case_id is set by the engine, not by hand"
    case "$_a_v" in *"
"*) die "bug: $_a_k contains a line break; keep each field to one line" ;; esac
    case "$_a_k" in
      Severity)    printf '%s' "$_a_v" | grep -Eqx "$BUG_SEVERITIES" || die "bug: Severity must be one of: $(printf '%s' "$BUG_SEVERITIES" | tr '|' ',')" ;;
      Priority)    printf '%s' "$_a_v" | grep -Eqx "$BUG_PRIORITIES" || die "bug: Priority must be one of: $(printf '%s' "$BUG_PRIORITIES" | tr '|' ',')" ;;
      'Status(QA)') printf '%s' "$_a_v" | grep -Eqx "$BUG_STATUSES" || die "bug: Status(QA) must be one of: $(printf '%s' "$BUG_STATUSES" | tr '|' ',')" ;;
    esac
    if [ -n "$_a_secrets" ]; then
      printf '%s\n' "$_a_secrets" | while IFS= read -r _a_s; do
        case "$_a_v" in *"$_a_s"*) echo "x"; break ;; esac
      done | grep -q x && die "bug: refusing to write $_a_k -- it contains a credential from $CREDS"
    fi
    printf '%s\t%s\n' "$_a_k" "$(printf '%s' "$_a_v" | tr '\t' ' ')" >> "$_a_out"
  done
}

# bug from <case-id> [field=value ...] -- raise, update or reopen the bug for
# one case.
_bug_from() {
  cid="${1:-}"; [ -n "$cid" ] || die "bug from: which case? (bug from AUTH-002 ...)"
  shift
  need_csv; _bug_init

  row="$(cmd_select --cols id,module,steps,data,expected,actual,route,viewport --format plain 2>/dev/null |
         awk -F'\t' -v id="$cid" '$1 == id { print; exit }')"
  [ -n "$row" ] || die "bug from: no case $cid"

  assign="$CACHE/.bug-assign.$$"
  _bug_assign "$assign" "$@"

  base="$(json_get "$CREDS" base_url 2>/dev/null)"
  host="$(printf '%s' "$base" | sed -e 's#^[a-zA-Z]*://##' -e 's#/.*$##')"
  case "${host%%:*}" in
    localhost|127.0.0.1|0.0.0.0|::1|*.local|*.localhost|host.docker.internal) where=local ;;
    *) where=remote ;;
  esac
  reporter="$(git config user.name 2>/dev/null)"
  [ -n "$reporter" ] || reporter="$(json_get "$FRAMEWORK" reporter 2>/dev/null)"
  [ -n "$reporter" ] || reporter="QA automation"

  tmp="$BUGS.tmp.$$"
  awk -v row="$row" -v cid="$cid" -v assign="$assign" -v base="$base" \
      -v where="$where" -v host="$host" -v reporter="$reporter" \
      -v today="$(date +%Y-%m-%d)" "$AWKLIB"'
    BEGIN {
      split(row, C, "\t")          # id module steps data expected actual route viewport
      while ((getline l < assign) > 0) {
        t = index(l, "\t"); A[substr(l, 1, t - 1)] = substr(l, t + 1); NA++
      }
      b = base; sub(/\/+$/, "", b)
      ENGINE["Module"]             = C[2]
      ENGINE["Steps to Reproduce"] = C[3]
      ENGINE["Test data"]          = C[4]
      ENGINE["Expected Result"]    = C[5]
      ENGINE["Actual Result"]      = C[6]
      ENGINE["Access Link"]        = (C[7] == "" ? b : b C[7])
      ENGINE["Environment"]        = where " (" host ")" (C[8] != "" ? ", viewport " C[8] : "")
    }
    NR == 1 { nh = hdrmap($0, H); split($0, HN, ","); print; next }
    $0 == "" { next }
    {
      n = csvsplit($0, F)
      no = F[H["Bug No"]]
      if (match(no, /^BUG-[0-9]+$/)) { k = substr(no, 5) + 0; if (k > max) max = k }
      ROW[++nrows] = $0
      if (F[H["case_id"]] == cid) HIT = nrows      # the latest bug for this case wins
    }
    END {
      if (HIT) {
        n = csvsplit(ROW[HIT], F)
        st = F[H["Status(QA)"]]
        if (st == "Not a Bug") {
          for (i = 1; i <= nrows; i++) print ROW[i]
          print "NOTABUG " F[H["Bug No"]] > "/dev/stderr"
          exit 0
        }
        for (k in ENGINE) if (ENGINE[k] != "") F[H[k]] = ENGINE[k]
        for (k in A) F[H[k]] = A[k]
        verb = "updated"
        if (st == "Closed" || st == "Fixed") { F[H["Status(QA)"]] = "Reopened"; verb = "reopened" }
        ROW[HIT] = csvjoin(F, n)
        for (i = 1; i <= nrows; i++) print ROW[i]
        print "OK " F[H["Bug No"]] " " verb > "/dev/stderr"
        exit 0
      }
      for (i = 1; i <= nrows; i++) print ROW[i]
      split("", R)
      for (i = 1; i <= nh; i++) R[i] = ""
      no = sprintf("BUG-%03d", max + 1)
      R[H["Bug No"]]      = no
      R[H["Status(QA)"]]  = "Open"
      R[H["Reporter"]]    = reporter
      R[H["found date"]]  = today
      R[H["case_id"]]     = cid
      for (k in ENGINE) R[H[k]] = ENGINE[k]
      for (k in A) R[H[k]] = A[k]
      if (R[H["Bug Description"]] == "") R[H["Bug Description"]] = "Case " cid " fails: " ENGINE["Expected Result"]
      print csvjoin(R, nh)
      print "OK " no " created" > "/dev/stderr"
    }
  ' "$BUGS" > "$tmp" 2>"$tmp.msg"
  rc=$?
  msg="$(cat "$tmp.msg" 2>/dev/null)"; rm -f "$tmp.msg" "$assign"
  [ "$rc" = 0 ] || { rm -f "$tmp"; die "bug from: could not update $BUGS"; }

  case "$msg" in
    NOTABUG*)
      rm -f "$tmp"
      echo "bug: ${msg#NOTABUG } was marked Not a Bug by a person -- left as it is. Raise a new one by hand if this failure is different."
      return 0 ;;
  esac
  _tf_commit "$tmp" "$BUGS" || die "bug from: $BUGS was not changed"
  printf 'bug: %s (case %s)\n' "${msg#OK }" "$cid"
}

# bug set <BUG-NNN> field=value ... -- a person's change, or an agent filing the
# issue link once it exists.
_bug_set() {
  no="${1:-}"; [ -n "$no" ] || die "bug set: which bug? (bug set BUG-003 \"Bug Link=...\")"
  shift
  [ $# -gt 0 ] || die "bug set: nothing to set"
  _bug_init
  assign="$CACHE/.bug-assign.$$"
  _bug_assign "$assign" "$@"
  tmp="$BUGS.tmp.$$"
  awk -v no="$no" -v assign="$assign" "$AWKLIB"'
    BEGIN { while ((getline l < assign) > 0) { t = index(l, "\t"); A[substr(l, 1, t - 1)] = substr(l, t + 1) } }
    NR == 1 { hdrmap($0, H); print; next }
    $0 == "" { next }
    {
      n = csvsplit($0, F)
      if (F[H["Bug No"]] == no) { for (k in A) F[H[k]] = A[k]; print csvjoin(F, n); found = 1; next }
      print
    }
    END { exit (found ? 0 : 4) }
  ' "$BUGS" > "$tmp"
  rc=$?; rm -f "$assign"
  [ "$rc" = 4 ] && { rm -f "$tmp"; die "bug set: no bug $no"; }
  [ "$rc" = 0 ] || { rm -f "$tmp"; die "bug set: could not update $BUGS"; }
  _tf_commit "$tmp" "$BUGS" || die "bug set: $BUGS was not changed"
  echo "bug: $no updated"
}

# bug list [--status <Status(QA)>] -- tab-separated, for a person or a caller.
_bug_list() {
  want=""
  [ "${1:-}" = "--status" ] && want="${2:-}"
  [ -f "$BUGS" ] || { echo "bug: no bugs recorded"; return 0; }
  awk -v want="$want" "$AWKLIB"'
    NR == 1 { hdrmap($0, H); next }
    $0 == "" { next }
    {
      csvsplit($0, F)
      if (want != "" && F[H["Status(QA)"]] != want) next
      printf "%s\t%s\t%s\t%s\t%s\n", F[H["Bug No"]], F[H["Status(QA)"]], F[H["Severity"]], F[H["case_id"]], F[H["Bug Description"]]
      shown++
    }
    END { if (!shown) print "bug: none" (want != "" ? " with status " want : "") }
  ' "$BUGS"
}

# _bug_open_count -- used by the summary panel.
_bug_open_count() {
  [ -f "$BUGS" ] || { echo 0; return 0; }
  awk "$AWKLIB"'
    NR == 1 { hdrmap($0, H); next }
    $0 == "" { next }
    { csvsplit($0, F); s = F[H["Status(QA)"]]
      if (s != "Closed" && s != "Not a Bug" && s != "Fixed") n++ }
    END { print n + 0 }
  ' "$BUGS"
}
