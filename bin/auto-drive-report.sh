#!/usr/bin/env bash
# bin/auto-drive-report.sh - turn auto-drive run logs into a markdown report.
#
# Weekly input: the driver's rendered run log as it appears in the Actions job
# log (raw driver stderr, optionally prefixed with timestamps / job names).
# Markers are matched as substrings, so any line prefix is tolerated.
#
# Usage:
#   bash bin/auto-drive-report.sh [--runs-url-prefix PREFIX] PATH...
#
#   PATH            log file, or directory scanned recursively for *.log
#                   (analysis order: sorted path order)
#   --runs-url-prefix PREFIX
#                   link files named run-<id>.log to PREFIX/<id>
#
# Output (stdout, markdown):
#   # auto-drive run analysis
#   <!-- auto-drive-report runs=N findings=N actionable=N -->   <- machine-readable
#   ## Outcomes     outcome -> run count
#   ## Totals       rounds / handoffs / PRs / review requests / bug reports
#   ## Models       per-model round table
#   ## Findings     [actionable] and [informational] entries with log excerpts
#   ## Runs         per-run table
#
# `actionable=` is the weekly workflow's gate: it dispatches the driver only
# when that number is greater than zero.
#
# Exit codes:
#   0  report written (zero logs still reports runs=0)
#   1  usage error or unreadable path (details on stderr)
set -euo pipefail

EXCERPT_MAX=5

usage() {
  cat <<'EOF'
Usage: auto-drive-report.sh [--runs-url-prefix PREFIX] PATH...

Turn auto-drive run logs into a markdown report on stdout.

PATH is a log file, or a directory scanned recursively for *.log files
(analysis order is the sorted path order). Lines may carry any prefix
(Actions timestamps, job names): markers are matched as substrings, so both
raw driver stderr and `gh run view --log` output work.

Options:
  --runs-url-prefix PREFIX  link run-<id>.log files to PREFIX/<id>
  -h, --help                show this help

The report starts with a machine-readable meta line:
  <!-- auto-drive-report runs=N findings=N actionable=N -->
The weekly workflow hands the driver a findings issue only when actionable > 0.

Exit codes: 0 = report written, 1 = usage error or unreadable path.
EOF
}

runs_url_prefix=""
paths=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --runs-url-prefix)
      [[ $# -ge 2 ]] || { echo "--runs-url-prefix needs a value" >&2; exit 1; }
      runs_url_prefix="$2"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      paths+=("$1")
      shift
      ;;
  esac
done

if [[ ${#paths[@]} -eq 0 ]]; then
  usage >&2
  exit 1
fi

log_files=()
for path in "${paths[@]}"; do
  if [[ -d "${path}" ]]; then
    while IFS= read -r found; do
      log_files+=("${found}")
    done < <(find "${path}" -type f -name '*.log' | LC_ALL=C sort)
  elif [[ -f "${path}" ]]; then
    log_files+=("${path}")
  else
    echo "No such file or directory: ${path}" >&2
    exit 1
  fi
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

# One awk pass per log: emit tab-separated events, keep the excerpts that make
# a finding actionable evidence instead of a bare label.
extract_events() {
  awk '
    function trimmed(s) { gsub(/^[ \t\r]+/, "", s); gsub(/[ \t\r]+$/, "", s); return s }
    function after(s, mark,   p) { p = index(s, mark); if (p == 0) return ""; return substr(s, p + length(mark)) }
    function before(s, mark,   p) { p = index(s, mark); if (p == 0) return ""; return substr(s, 1, p - 1) }
    BEGIN { excerpts = 0 }
    {
      line = $0
      sub(/\r$/, "", line)

      if (index(line, "opencode: trying model ") > 0) {
        print "model_try\t" trimmed(after(line, "opencode: trying model "))
        next
      }
      if (index(line, "Model ") > 0) {
        rest = after(line, "Model ")
        if (index(rest, " completed the work.") > 0) {
          print "model_done\t" trimmed(before(rest, " completed the work."))
          next
        }
        if (index(rest, " failed before completing the work: environment error") > 0) {
          print "model_env\t" trimmed(before(rest, " failed before completing the work: environment error"))
          next
        }
        if (index(rest, " failed before completing the work; handing off") > 0) {
          print "model_fail\t" trimmed(before(rest, " failed before completing the work; handing off"))
          next
        }
        if (index(rest, " left the working tree unchanged and only wrote .commit-msg") > 0) {
          print "model_nowork\t" trimmed(before(rest, " left the working tree unchanged and only wrote .commit-msg"))
          next
        }
        if (index(rest, " produced no complete work; handing off") > 0) {
          print "model_incomplete\t" trimmed(before(rest, " produced no complete work; handing off"))
          next
        }
      }

      if (index(line, "Handing off session ") > 0) print "session_handoff"
      if (index(line, "Created PR #") > 0) print "pr_created"
      # "Review requested on PR #" and "Review already requested on PR #".
      if (index(line, "requested on PR #") > 0) print "handoff"
      if (index(line, "is ready for a human reviewer:") > 0) print "handoff"
      if (index(line, "Ready to merge:") > 0) print "ready_merge"
      if (index(line, "is merged while waiting") > 0 || index(line, "is already merged. Nothing to do.") > 0) print "merged"
      if (index(line, "is closed without merge") > 0) print "closed"
      if (index(line, "the PR could not be read back either") > 0) print "handoff_unconfirmed"
      if (index(line, "every model round died on an environment error") > 0) print "env_down"
      if (index(line, "ERROR: no available model completed the work") > 0) print "no_model"
      if (index(line, "exhausted while waiting. Exiting.") > 0) print "budget_exhausted"
      if (index(line, "opencode exceeded the remaining driver time budget") > 0) print "budget_stop"
      if (index(line, "Driver exited abnormally") > 0) print "abnormal"
      if (index(line, "Bug report issue ") > 0) print "bug"

      if (excerpts < '"${EXCERPT_MAX}"' && (index(line, "ERROR:") > 0 || index(line, "WARNING:") > 0 || index(line, "Driver exited abnormally") > 0 || index(line, "Bug report issue ") > 0 || index(line, "exhausted while waiting") > 0)) {
        excerpts++
        print "excerpt\t" line
      }
    }
  ' "$1"
}

declare -A outcome_runs=()
declare -A model_rounds=()
declare -A model_done=()
declare -A model_env=()
declare -A model_fail=()
declare -A model_nowork=()
declare -A model_incomplete=()

total_rounds=0
total_session_handoffs=0
total_prs=0
total_reviews=0
total_bugs=0
total_budget_stops=0

finding_severity=()
finding_title=()
finding_detail=()
runs_rows=()

run_index=0
for logfile in ${log_files[@]+"${log_files[@]}"}; do
  run_index=$((run_index + 1))
  events="${tmp_dir}/events-${run_index}"
  extract_events "${logfile}" > "${events}"

  display="$(basename "${logfile}")"
  link=""
  if [[ -n "${runs_url_prefix}" && "${display}" =~ ^run-(.+)\.log$ ]]; then
    link="${runs_url_prefix}/${BASH_REMATCH[1]}"
  fi

  rounds=0
  models_in_run=""
  has_any=0 has_handoff=0 has_ready=0 has_merged=0 has_closed=0
  has_unconfirmed=0 has_env=0 has_nomodel=0 has_budget=0 has_bug=0 has_abnormal=0
  file_session_handoffs=0 file_prs=0 file_reviews=0 file_bugs=0 file_budget_stops=0
  excerpts=""

  while IFS=$'\t' read -r kind value; do
    [[ -n "${kind}" ]] || continue
    has_any=1
    case "${kind}" in
      model_try)
        rounds=$((rounds + 1))
        model_rounds["${value}"]=$((${model_rounds["${value}"]:-0} + 1))
        case ",${models_in_run}," in
          *",${value},"*) ;;
          *) models_in_run="${models_in_run:+${models_in_run},}${value}" ;;
        esac
        ;;
      model_done)
        model_done["${value}"]=$((${model_done["${value}"]:-0} + 1))
        ;;
      model_env)
        model_env["${value}"]=$((${model_env["${value}"]:-0} + 1))
        ;;
      model_fail)
        model_fail["${value}"]=$((${model_fail["${value}"]:-0} + 1))
        ;;
      model_nowork)
        model_nowork["${value}"]=$((${model_nowork["${value}"]:-0} + 1))
        ;;
      model_incomplete)
        model_incomplete["${value}"]=$((${model_incomplete["${value}"]:-0} + 1))
        ;;
      session_handoff) file_session_handoffs=$((file_session_handoffs + 1)) ;;
      pr_created) file_prs=$((file_prs + 1)) ;;
      handoff)
        has_handoff=1
        file_reviews=$((file_reviews + 1))
        ;;
      ready_merge) has_ready=1 ;;
      merged) has_merged=1 ;;
      closed) has_closed=1 ;;
      handoff_unconfirmed) has_unconfirmed=1 ;;
      env_down) has_env=1 ;;
      no_model) has_nomodel=1 ;;
      budget_exhausted) has_budget=1 ;;
      budget_stop) file_budget_stops=$((file_budget_stops + 1)) ;;
      abnormal) has_abnormal=1 ;;
      bug)
        has_bug=1
        file_bugs=$((file_bugs + 1))
        ;;
      excerpt)
        excerpts="${excerpts}${excerpts:+$'\n'}${value}"
        ;;
    esac
  done < "${events}"

  if [[ ${has_env} -gt 0 ]]; then
    outcome="environment-down"
    severity="informational"
    title="environment-down: every model round died on an environment error"
  elif [[ ${has_nomodel} -gt 0 ]]; then
    outcome="no-model-completed"
    severity="actionable"
    title="no-model-completed: no available model completed the work"
  elif [[ ${has_budget} -gt 0 ]]; then
    outcome="time-budget-exhausted"
    severity="actionable"
    title="time-budget-exhausted: the driver stopped at its time budget"
  elif [[ ${has_bug} -gt 0 || ${has_abnormal} -gt 0 ]]; then
    outcome="bug-reported"
    severity="actionable"
    title="bug-reported: the run ended with a bug report issue"
  elif [[ ${has_unconfirmed} -gt 0 ]]; then
    outcome="handoff-unconfirmed"
    severity="informational"
    title="handoff-unconfirmed: the review request could not be read back"
  elif [[ ${has_ready} -gt 0 ]]; then
    outcome="ready-to-merge"
    severity=""
    title=""
  elif [[ ${has_handoff} -gt 0 ]]; then
    outcome="handed-off"
    severity=""
    title=""
  elif [[ ${has_merged} -gt 0 ]]; then
    outcome="merged"
    severity=""
    title=""
  elif [[ ${has_closed} -gt 0 ]]; then
    outcome="closed"
    severity=""
    title=""
  elif [[ ${has_any} -eq 0 ]]; then
    outcome="no-driver-output"
    severity="actionable"
    title="no-driver-output: the run log carries no driver output"
  else
    outcome="unknown"
    severity="actionable"
    title="unknown: the run log ends without a recognizable outcome"
  fi

  if [[ -n "${severity}" ]]; then
    detail="log: ${display}"
    if [[ -n "${link}" ]]; then
      detail="${detail}
url: ${link}"
    fi
    detail="${detail}
outcome: ${outcome}"
    if [[ -n "${excerpts}" ]]; then
      detail="${detail}
excerpts:
\`\`\`log
${excerpts}
\`\`\`"
    fi
    finding_severity+=("${severity}")
    finding_title+=("${title}")
    finding_detail+=("${detail}")
  fi

  outcome_runs["${outcome}"]=$((${outcome_runs["${outcome}"]:-0} + 1))
  total_rounds=$((total_rounds + rounds))
  total_session_handoffs=$((total_session_handoffs + file_session_handoffs))
  total_prs=$((total_prs + file_prs))
  total_reviews=$((total_reviews + file_reviews))
  total_bugs=$((total_bugs + file_bugs))
  total_budget_stops=$((total_budget_stops + file_budget_stops))
  runs_rows+=("${display}|${outcome}|${rounds}|${models_in_run}")
done

sorted_models=()
if [[ ${#model_rounds[@]} -gt 0 ]]; then
  while IFS= read -r model; do
    sorted_models+=("${model}")
  done < <(printf '%s\n' "${!model_rounds[@]}" | LC_ALL=C sort)
fi

# Models that got rounds but never finished one: model-selection signal for the
# next period, informational by itself.
never_completed=""
for model in ${sorted_models[@]+"${sorted_models[@]}"}; do
  if [[ $((${model_done["${model}"]:-0})) -eq 0 ]]; then
    never_completed="${never_completed}${never_completed:+$'\n'}- \`${model}\` (${model_rounds["${model}"]} round(s), 0 completed)"
  fi
done
if [[ -n "${never_completed}" ]]; then
  finding_severity+=("informational")
  finding_title+=("models with no completed round this period")
  finding_detail+=("${never_completed}")
fi

runs_total=${#log_files[@]}
findings_total=${#finding_severity[@]}
actionable_total=0
for severity in ${finding_severity[@]+"${finding_severity[@]}"}; do
  if [[ "${severity}" == "actionable" ]]; then
    actionable_total=$((actionable_total + 1))
  fi
done

printf '# auto-drive run analysis\n\n'
printf '<!-- auto-drive-report runs=%d findings=%d actionable=%d -->\n\n' \
  "${runs_total}" "${findings_total}" "${actionable_total}"

if [[ ${runs_total} -eq 0 ]]; then
  printf '_No run logs found in the given paths._\n'
  exit 0
fi

printf 'Analyzed %d run log(s): %d finding(s), %d actionable.\n\n' \
  "${runs_total}" "${findings_total}" "${actionable_total}"

printf '## Outcomes\n\n'
printf '| outcome | runs |\n| --- | ---: |\n'
for outcome in environment-down no-model-completed time-budget-exhausted bug-reported \
  handoff-unconfirmed unknown no-driver-output ready-to-merge handed-off merged closed; do
  count="${outcome_runs["${outcome}"]:-0}"
  if [[ "${count}" -gt 0 ]]; then
    printf '| %s | %d |\n' "${outcome}" "${count}"
  fi
done

printf '\n## Totals\n\n'
printf -- '- rounds: %d\n' "${total_rounds}"
printf -- '- session handoffs: %d\n' "${total_session_handoffs}"
printf -- '- PRs created: %d\n' "${total_prs}"
printf -- '- review hand-offs: %d\n' "${total_reviews}"
printf -- '- bug reports filed: %d\n' "${total_bugs}"
printf -- '- round budget stops: %d\n' "${total_budget_stops}"

printf '\n## Models\n\n'
printf '| model | rounds | completed | env errors | no work | incomplete | other failures |\n'
printf '| --- | ---: | ---: | ---: | ---: | ---: | ---: |\n'
for model in ${sorted_models[@]+"${sorted_models[@]}"}; do
  printf '| %s | %d | %d | %d | %d | %d | %d |\n' \
    "${model}" \
    "${model_rounds["${model}"]:-0}" \
    "${model_done["${model}"]:-0}" \
    "${model_env["${model}"]:-0}" \
    "${model_nowork["${model}"]:-0}" \
    "${model_incomplete["${model}"]:-0}" \
    "${model_fail["${model}"]:-0}"
done

printf '\n## Findings\n\n'
if [[ ${findings_total} -eq 0 ]]; then
  printf 'No findings for this period.\n'
else
  number=0
  for ((i = 0; i < findings_total; i++)); do
    number=$((number + 1))
    printf '### F%d. [%s] %s\n\n' "${number}" "${finding_severity[$i]}" "${finding_title[$i]}"
    printf '%s\n\n' "${finding_detail[$i]}"
  done
fi

printf '## Runs\n\n'
printf '| log | outcome | rounds | models |\n| --- | --- | ---: | --- |\n'
for row in ${runs_rows[@]+"${runs_rows[@]}"}; do
  IFS='|' read -r row_log row_outcome row_rounds row_models <<<"${row}"
  row_display="${row_log}"
  if [[ -n "${runs_url_prefix}" && "${row_log}" =~ ^run-(.+)\.log$ ]]; then
    row_display="[${row_log}](${runs_url_prefix}/${BASH_REMATCH[1]})"
  fi
  printf '| %s | %s | %s | %s |\n' "${row_display}" "${row_outcome}" "${row_rounds}" "${row_models:-none}"
done
