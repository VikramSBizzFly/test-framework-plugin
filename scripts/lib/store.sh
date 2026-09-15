# shellcheck shell=sh
# lib/store.sh -- the case store: select, set, merge, prune and friends
#
# Sourced by scripts/tf.sh; defines functions only. See tf.sh for the paths
# and schema variables these rely on.

need_csv() { [ -f "$CSV" ] || die "no $CSV (run /test-setup first)"; }

# ====================================================================== CSV ops

cmd_init_csv() {
  # Create the whole layout, not just the CSV. Other subcommands write into
  # these directories and should not each have to guess whether they exist.
  mkdir -p "$TESTS_DIR" "$CACHE" "$RESULTS" "$TESTS_DIR/.auth" "$TESTS_DIR/evidence"
  [ -f "$STATE" ] || printf '%s\n' "$STATE_HEADER" > "$STATE"
  [ -f "$CSV" ] && { echo "exists: $CSV"; return 0; }
  printf '%s\n' "$HEADER" > "$CSV"
  echo "created: $CSV"
}

need_state() {
  if [ ! -f "$STATE" ]; then
    mkdir -p "$CACHE"          # a suite may exist without .cache/ ever being made
    printf '%s\n' "$STATE_HEADER" > "$STATE"
    return 0
  fi
  [ "$(head -1 "$STATE" | tr -d '\r')" = "$STATE_HEADER" ] || _tf_upgrade_state
}

# A state file from an older release lacks newer bookkeeping columns, and `set`
# silently ignores a column its file has no header for. Append whatever is
# missing, empty, keeping every existing column where it is.
_tf_upgrade_state() {
  _u_t="$STATE.tmp.$$"
  awk -v want="$STATE_HEADER" "$AWKLIB"'
    NR == 1 {
      sub(/\r$/, ""); hdrmap($0, H)
      nw = split(want, W, ","); add = ""; nadd = 0
      for (i = 1; i <= nw; i++) if (!(W[i] in H)) { add = add "," W[i]; nadd++ }
      if (nadd == 0) { quit = 1; exit 9 }
      pad = ""; for (i = 1; i <= nadd; i++) pad = pad ","
      print $0 add; next
    }
    { sub(/\r$/, ""); print ($0 == "" ? $0 : $0 pad) }
    END { if (quit) exit 9 }
  ' "$STATE" > "$_u_t"
  if [ $? = 0 ]; then _tf_commit "$_u_t" "$STATE"; else rm -f "$_u_t"; fi
}

# Join testcases.csv with .cache/state.csv on id, emitting one wide row per
# case. Everything that needs a bookkeeping column reads through this, so the
# two-file split stays invisible to the rest of the script.
joined() {
  need_state
  awk "$AWKLIB"'
    NR == FNR {
      if (FNR == 1) { ns = hdrmap($0, SH); shdr = $0; next }
      n = csvsplit($0, S)
      ST[S[SH["id"]]] = $0
      next
    }
    FNR == 1 {
      nh = hdrmap($0, H); hsplit = csvsplit($0, HA)
      # emit the combined header once
      line = $0
      m = csvsplit(shdr, SA)
      for (i = 2; i <= m; i++) line = line "," csvq(SA[i])
      print line
      next
    }
    {
      n = csvsplit($0, F); id = F[H["id"]]
      line = $0
      m = csvsplit(shdr, SA)
      if (id in ST) { k = csvsplit(ST[id], SF)
        for (i = 2; i <= m; i++) line = line "," csvq(SF[i]) }
      else for (i = 2; i <= m; i++) line = line ","
      print line
    }
  ' "$STATE" "$CSV"
}

# select --status new --priority P0 --feature auth --cols id,steps [--count]
cmd_select() {
  need_csv
  filters=''; cols=''; limit=0; count=0; format=csv
  while [ $# -gt 0 ]; do
    case "$1" in
      --cols)   cols=""; for _c in $(printf '%s' "$2" | tr ',' ' '); do
                  cols="$cols${cols:+,}$(alias_col "$_c")"; done; shift 2 ;;
      --limit)  limit="$2"; shift 2 ;;
      --count)  count=1; shift ;;
      --format) format="$2"; shift 2 ;;
      --tag)    filters="$filters|tags~$2"; shift 2 ;;
      --where)  filters="$filters|$2"; shift 2 ;;
      --*)      filters="$filters|$(alias_col "$(printf '%s' "$1" | sed 's/^--//')")=$2"; shift 2 ;;
      *) die "select: unexpected argument '$1'" ;;
    esac
  done
  joined | awk -v filters="$filters" -v cols="$cols" -v limit="$limit" \
      -v count="$count" -v format="$format" "$AWKLIB"'
    NR == 1 { hdrmap($0, H); hdr = $0; nh = csvsplit($0, HA); next }
    {
      n = csvsplit($0, F)
      nf = split(filters, FS_, "|")
      for (i = 1; i <= nf; i++) {
        if (FS_[i] == "") continue
        neg = 0
        if (index(FS_[i], "~") > 0 && index(FS_[i], "=") == 0) {
          k = substr(FS_[i], 1, index(FS_[i], "~") - 1)
          v = substr(FS_[i], index(FS_[i], "~") + 1)
          if (!(k in H)) next
          if (index("," F[H[k]] ",", "," v ",") == 0) next
          continue
        }
        k = substr(FS_[i], 1, index(FS_[i], "=") - 1)
        v = substr(FS_[i], index(FS_[i], "=") + 1)
        if (!(k in H)) next
        # comma-separated value list means OR
        if (index(v, ",") > 0) {
          ok = 0; m = split(v, VL, ",")
          for (j = 1; j <= m; j++) if (F[H[k]] == VL[j]) ok = 1
          if (!ok) next
        } else if (F[H[k]] != v) next
      }
      matched++
      if (count) next
      if (limit > 0 && matched > limit) next
      if (!printed_hdr && format == "csv") {
        if (cols == "") print hdr
        else { m = split(cols, C, ","); line = ""
               for (i = 1; i <= m; i++) line = line (i > 1 ? "," : "") C[i]
               print line }
        printed_hdr = 1
      }
      if (cols == "") { print $0; next }
      m = split(cols, C, ","); out = ""
      for (i = 1; i <= m; i++) {
        v = (C[i] in H) ? F[H[C[i]]] : ""
        out = out (i > 1 ? (format == "plain" ? "\t" : ",") : "") (format == "plain" ? v : csvq(v))
      }
      print out
    }
    END { if (count) print matched + 0 }
  '
}

# set <id> col=value [col=value ...]
#
# Routes each assignment to whichever file owns that column. `status` and
# `notes` live in testcases.csv; everything else is bookkeeping and goes to
# .cache/state.csv. The human file is rewritten only if a value actually
# changed, so a run that changes nothing leaves it untouched in git.
cmd_set() {
  need_csv; need_state
  id="$1"; shift
  [ $# -gt 0 ] || die "set: no assignments given"
  human=''; state=''
  for a in "$@"; do
    k="${a%%=*}"; k="$(alias_col "$k")"
    case " $HUMAN_COLS " in
      *" $k "*) human="$human|$k=${a#*=}" ;;
      *)        state="$state|$k=${a#*=}" ;;
    esac
  done
  if [ -n "$human" ]; then _tf_apply "$CSV" "$id" "$human" 0 || die "set: $id was not changed"; fi
  if [ -n "$state" ]; then _tf_apply "$STATE" "$id" "$state" 1 || die "set: $id was not changed"; fi
  return 0
}

# _tf_apply <file> <id> <|-separated assigns> <create-if-missing>
_tf_apply() {
  _f="$1"; _id="$2"; _as="$3"; _create="$4"
  _t="$_f.tmp.$$"
  awk -v id="$_id" -v assigns="$_as" -v create="$_create" "$AWKLIB"'
    NR == 1 { nh = hdrmap($0, H); nhdr = nh; print; next }
    {
      n = csvsplit($0, F)
      if (F[H["id"]] == id) {
        na = split(assigns, A, "|"); changed = 0
        for (i = 1; i <= na; i++) {
          if (A[i] == "") continue
          k = substr(A[i], 1, index(A[i], "=") - 1)
          v = substr(A[i], index(A[i], "=") + 1)
          if ((k in H) && F[H[k]] != v) { F[H[k]] = v; changed = 1 }
        }
        found = 1
        if (changed) { dirty = 1; print csvjoin(F, n) } else print
        next
      }
      print
    }
    END {
      if (!found && create) {
        for (i = 1; i <= nhdr; i++) R[i] = ""
        R[H["id"]] = id
        na = split(assigns, A, "|")
        for (i = 1; i <= na; i++) {
          if (A[i] == "") continue
          k = substr(A[i], 1, index(A[i], "=") - 1)
          v = substr(A[i], index(A[i], "=") + 1)
          if (k in H) R[H[k]] = v
        }
        print csvjoin(R, nhdr); dirty = 1
      } else if (!found)
        print "tf: set: no such id: " id > "/dev/stderr"
      exit (dirty ? 0 : 9)      # 9 = nothing changed, keep the original file
    }
  ' "$_f" > "$_t"
  _rc=$?
  if [ "$_rc" = 0 ]; then _tf_commit "$_t" "$_f" || return 1; else rm -f "$_t"; fi
  return 0
}

# bulk-set from stdin: lines of "id col=value col=value"
cmd_setmany() {
  need_csv; need_state
  upd="$CACHE/.setmany.$$"; mkdir -p "$CACHE"; cat > "$upd"
  for _f in "$CSV" "$STATE"; do
    _t="$_f.tmp.$$"
    awk -v upd="$upd" "$AWKLIB"'
      BEGIN { while ((getline l < upd) > 0) { split(l, p, " "); U[p[1]] = l } }
      NR == 1 { hdrmap($0, H); print; next }
      {
        n = csvsplit($0, F); id = F[H["id"]]
        if (id in U) {
          np = split(U[id], P, " "); changed = 0
          for (i = 2; i <= np; i++) {
            k = substr(P[i], 1, index(P[i], "=") - 1)
            v = substr(P[i], index(P[i], "=") + 1)
            gsub(/\+/, " ", v)
            if ((k in H) && F[H[k]] != v) { F[H[k]] = v; changed = 1 }
          }
          if (changed) { dirty = 1; print csvjoin(F, n) } else print
          next
        }
        print
      }
      END { exit (dirty ? 0 : 9) }
    ' "$_f" > "$_t"
    if [ $? = 0 ]; then
      _tf_commit "$_t" "$_f" || { rm -f "$upd"; die "setmany: $_f was not changed"; }
    else rm -f "$_t"; fi
  done
  rm -f "$upd"
  return 0
}

# merge [--check] <newcases.csv|newcases.tsv> -- additive, and never destructive.
#
# Existing ids keep their `status` and `notes` (a verdict and a human comment
# are not the generator's to overwrite) and get the rest of their definition
# refreshed. New ids are appended, with a matching row created in state.csv.
# Nothing is ever dropped, so regeneration is safe to re-run.
#
# The incoming file is checked before anything is touched: one row with the
# wrong number of fields -- almost always an unquoted comma in hand-written
# CSV -- rejects the whole file, with its line number, and the store is left
# exactly as it was. Tab-separated input needs no quoting at all, which is why
# agents are told to write it. Both files are built aside and validated before
# either is replaced. `--check` stops there and reports what would change.
cmd_merge() {
  check=0; [ "${1:-}" = "--check" ] && { check=1; shift; }
  need_csv; need_state
  new="${1:-}"; [ -n "$new" ] && [ -f "$new" ] || die "merge: no such file: $new"
  mkdir -p "$CACHE"
  src="$CACHE/.merge-in.$$"; tmp="$CSV.tmp.$$"; stmp="$STATE.tmp.$$"
  _tf_to_csv "$new" > "$src"

  if ! _tf_validate_input "$src"; then
    rm -f "$src"
    die "merge: $new has malformed rows (above) -- nothing was merged.
    A text field containing a comma must be quoted in CSV. Simpler: write the
    file tab-separated (.tsv), where commas need no quoting."
  fi

  awk -v cur="$CSV" -v hdr="$HEADER" -v stf="$STATE" -v stmp="$stmp" "$AWKLIB"'
    function canon(k) {
      if (k == "todo" || k == "do" || k == "steps") return "what to do"
      if (k == "expect" || k == "should" || k == "expected") return "what should happen"
      if (k == "role") return "who"
      if (k == "feature") return "area"
      return k
    }
    BEGIN {
      KEEP["status"] = 1; KEEP["notes"] = 1
      nh = split(hdr, OUT, ",")
    }
    # --- the incoming file, read into memory in its own order
    NR == 1 {
      nn = csvsplit($0, A)
      for (i = 1; i <= nn; i++) NH[canon(A[i])] = i
      next
    }
    $0 == "" { next }
    {
      split("", F); csvsplit($0, F); id = F[NH["id"]]
      if (id == "") { print "merge: line " NR " has no id, skipped" > "/dev/stderr"; next }
      if (id in NIDS) { print "merge: " id " appears twice in the input; the first is used" > "/dev/stderr"; next }
      NIDS[id] = ++norder; ORDER[norder] = id
      for (k in NH) NV[id, k] = F[NH[k]]
    }
    END {
      # --- testcases.csv: refresh existing ids, then append new ones
      c = 0
      while ((getline l < cur) > 0) {
        if (++c == 1) { hdrmap(l, H); print l; continue }
        if (l == "") continue
        split("", F); n = csvsplit(l, F); id = F[H["id"]]
        HAVE[id] = 1
        if (id in NIDS) {
          for (k in H) if (!(k in KEEP) && ((id SUBSEP k) in NV)) F[H[k]] = NV[id, k]
          print csvjoin(F, n); updated++
        } else { print l; kept++ }
      }
      close(cur)
      for (j = 1; j <= norder; j++) {
        id = ORDER[j]
        if (id in HAVE) continue
        for (i = 1; i <= nh; i++) R[i] = ((id SUBSEP OUT[i]) in NV) ? NV[id, OUT[i]] : ""
        if (R[7] == "") R[7] = "new"          # status
        print csvjoin(R, nh); added++
      }

      # --- state.csv: every case gets a bookkeeping row
      c = 0
      while ((getline l < stf) > 0) {
        if (++c == 1) { ns = hdrmap(l, SH); split("", SC); csvsplit(l, SC); print l > stmp; continue }
        if (l == "") continue
        split("", F); csvsplit(l, F); SEEN[F[SH["id"]]] = 1
        print l > stmp
      }
      close(stf)
      for (j = 1; j <= norder; j++) {
        id = ORDER[j]
        if (id in SEEN) continue
        for (i = 1; i <= ns; i++) {
          k = SC[i]
          R[i] = (k == "id") ? id : (((id SUBSEP k) in NV) ? NV[id, k] : "")
          if ((k == "pass_streak" || k == "flake_count") && R[i] == "") R[i] = "0"
        }
        print csvjoin(R, ns) > stmp
      }
      close(stmp)
      printf "merge: %d added, %d updated, %d untouched\n", added, updated, kept > "/dev/stderr"
    }
  ' "$src" > "$tmp"
  rm -f "$src"

  # Validate both before replacing either, so the pair never disagrees.
  if ! _tf_validate "$tmp" || ! _tf_validate "$stmp"; then
    rm -f "$tmp" "$stmp"
    die "merge: the merged store would not parse -- nothing was written"
  fi
  if [ "$check" = 1 ]; then
    rm -f "$tmp" "$stmp"; echo "merge --check: $new is well-formed" >&2; return 0
  fi
  _tf_commit "$tmp" "$CSV" || { rm -f "$stmp"; die "merge: nothing was written"; }
  _tf_commit "$stmp" "$STATE" || die "merge: testcases.csv was updated but state.csv was not -- run: tf.sh check"
}

# _tf_to_csv <file> -- print the file as CSV. A header containing a tab means
# tab-separated input: split on tabs, quote each field. Otherwise pass through.
_tf_to_csv() {
  if head -1 "$1" | grep -q "$(printf '\t')"; then
    awk -F"$(printf '\t')" "$AWKLIB"'
      { sub(/\r$/, ""); out = ""
        for (i = 1; i <= NF; i++) out = out (i > 1 ? "," : "") csvq($i)
        print out }' "$1"
  else
    sed 's/\r$//' "$1"
  fi
}

# _tf_validate_input <csv> -- like _tf_validate, but any header with an id
# column is acceptable: generators may send extra or reordered columns.
_tf_validate_input() {
  head -1 "$1" | tr ',' '\n' | grep -qx 'id' || { echo "  line 1: the header has no id column" >&2; return 1; }
  _tf_validate "$1" "$(head -1 "$1" | tr -d '\r')"
}

# next-id <PREFIX>  -> PREFIX-007
cmd_next_id() {
  need_csv
  p="$1"
  awk -v p="$p" "$AWKLIB"'
    NR == 1 { hdrmap($0, H); next }
    { csvsplit($0, F); id = F[H["id"]]
      if (index(id, p "-") == 1) { n = substr(id, length(p) + 2) + 0; if (n > max) max = n } }
    END { printf "%s-%03d\n", p, max + 1 }
  ' "$CSV"
}

cmd_stats() {
  need_csv
  joined | awk "$AWKLIB"'
    NR == 1 { hdrmap($0, H); next }
    { csvsplit($0, F); total++
      st[F[H["status"]]]++; ty[F[H["type"]]]++; pr[F[H["priority"]]]++ }
    END {
      printf "total %d\n", total
      printf "status"; for (k in st) printf " %s=%d", (k == "" ? "new" : k), st[k]; printf "\n"
      printf "type";   for (k in ty) printf " %s=%d", (k == "" ? "page" : k), ty[k]; printf "\n"
      printf "prio";   for (k in pr) printf " %s=%d", k, pr[k]; printf "\n"
    }
  '
}

# prune -- remove cases that say the same thing twice.
# Called automatically after merge, so duplicates never reach the user.
cmd_prune() {
  need_csv
  apply=0; [ "${1:-}" = "--apply" ] && apply=1
  tmp="$CSV.tmp.$$"
  awk -v apply="$apply" "$AWKLIB"'
    NR == 1 { hdrmap($0, H); print; next }
    {
      csvsplit($0, F)
      k = F[H["who"]] "|" F[H["what to do"]] "|" F[H["what should happen"]]
      if (k in seen) { dup++; print "duplicate: " F[H["id"]] " same as " seen[k] > "/dev/stderr"; if (apply) next }
      else seen[k] = F[H["id"]]
      print
    }
    END { print "prune: " dup + 0 " duplicate(s)" > "/dev/stderr" }
  ' "$CSV" > "$tmp"
  if [ "$apply" = "1" ]; then _tf_commit "$tmp" "$CSV" --allow-shrink; else rm -f "$tmp"; fi
}
