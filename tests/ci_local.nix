# ci-local against a repository of its own and a stand-in for `gh` that writes down what it is asked to post,
# then a job table against the workflow that reads it: by default this repository's, or a caller's own.
{ pkgs, tool ? ../ci-local.py, table ? ../ci/local.json, workflow ? ../.github/workflows/checks.yml, jobs ? [ "checks" ] }:
pkgs.runCommand "ci-local" { nativeBuildInputs = [ pkgs.git pkgs.python3 ]; } ''
  set -eu
  export HOME=$TMPDIR/home FLAG=$TMPDIR/flag POSTED=$TMPDIR/posted ORIGIN=$TMPDIR/origin.git
  mkdir -p "$HOME" $TMPDIR/bin
  tool() { python3 -P ${tool} "$@"; }
  fail() { echo "FAIL: $1" >&2; exit 1; }
  cat > $TMPDIR/bin/gh <<'GH'
  #!/bin/sh
  commit=$(echo "$4" | sed 's|.*/||')
  git --git-dir "$ORIGIN" rev-parse -q --verify "refs/ci-local/$commit" > /dev/null && held=held || held=absent
  git --git-dir "$ORIGIN" rev-parse -q --verify refs/heads/main > /dev/null && branch=$(git --git-dir "$ORIGIN" rev-parse refs/heads/main) || branch=none
  echo "$* | $held | $branch" >> "$POSTED"
  GH
  chmod +x $TMPDIR/bin/gh
  export PATH=$TMPDIR/bin:$PATH
  git config --global user.name tester && git config --global user.email tester@example.invalid && git config --global init.defaultBranch main
  git config --global url."$ORIGIN".insteadOf "git@github.com:owner/project.git"
  git init -q --bare "$ORIGIN"
  git init -q $TMPDIR/work && cd $TMPDIR/work
  git remote add origin git@github.com:owner/project.git
  here=$(python3 -c 'import platform; print(("macos" if platform.system() == "Darwin" else platform.system().lower()) + "-" + platform.machine().lower())')
  mkdir ci
  cat > ci/local.json <<JSON
  { "jobs": {
    "passes": { "platform": "$here", "run": "true" },
    "fails": { "platform": "$here", "run": "false" },
    "elsewhere": { "platform": "another-platform", "run": "true" },
    "litters": { "platform": "$here", "run": "touch stray" },
    "after": { "platform": "$here", "run": "true" },
    "turns": { "platform": "$here", "run": "test ! -e $FLAG" },
    "slow": { "platform": "$here", "run": "test -e $TMPDIR/once || { touch $TMPDIR/once; sleep 2; }" },
    "meets": { "platform": "$here", "light": true, "run": "touch $TMPDIR/met-1; for turn in \$(seq 100); do test -e $TMPDIR/met-2 && exit 0; sleep 0.1; done; exit 1" },
    "met": { "platform": "$here", "light": true, "run": "touch $TMPDIR/met-2; for turn in \$(seq 100); do test -e $TMPDIR/met-1 && exit 0; sleep 0.1; done; exit 1" }
  } }
  JSON
  git add ci && git commit -qm first
  first=$(git rev-parse HEAD)
  passes=.git/ci-local/trees/$(git rev-parse 'HEAD^{tree}')

  echo "A pass is for a commit: nothing is recorded on a tree with anything else in it"
  touch extra
  tool run passes 2> $TMPDIR/refused && fail "ran on a dirty tree"
  grep -q "commit or remove them first" $TMPDIR/refused || fail "the refusal does not say why"
  rm extra

  echo "A pass is recorded, a failure is not, and another platform's job is refused"
  tool run passes turns
  test -s $passes/passes.json && test -s $passes/turns.json || fail "passes were not recorded"
  tool run fails && fail "a failing job reported success"
  test ! -e $passes/fails.json || fail "a failure was recorded"
  tool run elsewhere 2> $TMPDIR/refused && fail "ran another platform's job"
  grep -q "would not stand in for it" $TMPDIR/refused || fail "the refusal does not name the platform"

  echo "A job that leaves a file behind is not recorded, the file is named, and the jobs after it still run"
  tool run litters after > $TMPDIR/ran 2> $TMPDIR/refused && fail "a job that changed the tree reported success"
  test ! -e $passes/litters.json && test ! -e $passes/after.json || fail "a job was recorded on a changed tree"
  grep -q "litters left the tree changed" $TMPDIR/refused && grep -q "^?? stray$" $TMPDIR/refused || fail "the file left behind is not named: $(cat $TMPDIR/refused)"
  grep -q "after passed, but litters had left the tree changed before it ran" $TMPDIR/ran || fail "the job after it did not run, or did not say why it is not recorded: $(cat $TMPDIR/ran)"
  rm stray

  echo "A job that passes again keeps the time its first run took"
  tool run slow | grep -q "slow passed in [2-9] s" || fail "the first run was not timed"
  tool run slow | grep -q "slow passed in [01] s; recorded for .* (first run: [2-9] s)" || fail "the second run does not name the first run's time"
  grep -q '"seconds": [2-9],' $passes/slow.json || fail "the receipt lost the first run's time"
  rm $passes/slow.json

  echo "Light jobs named next to each other run at the same time"
  tool run meets met || fail "each waits for the other to have started; one after the other, neither can pass"
  test -s $passes/meets.json && test -s $passes/met.json || fail "the light jobs were not recorded"
  rm $passes/meets.json $passes/met.json
  tool status | grep -q "local/$here/passes .*not published" || fail "the status does not list the pass"

  echo "A push posts the passes before the branch moves, for that commit, and leaves nothing behind"
  tool push -q origin main
  test "$(git --git-dir "$ORIGIN" rev-parse refs/heads/main)" = "$first" || fail "the branch was not pushed"
  test "$(wc -l < "$POSTED")" = 2 || fail "expected two statuses: $(cat "$POSTED")"
  grep -q "^api --method POST repos/owner/project/statuses/$first -f state=success -f context=local/$here/passes -f description=passed on .* | held | none$" "$POSTED" || fail "the pass was not posted as expected: $(cat "$POSTED")"
  grep -q "context=local/$here/turns " "$POSTED" || fail "the second pass was not posted"
  test -z "$(git --git-dir "$ORIGIN" for-each-ref refs/ci-local)" || fail "the holding ref was left behind"
  tool status | grep -q "local/$here/passes .* published" || fail "the status does not say published"

  echo "A reworded commit has the same files, so it has the passes; they are posted on it when it is pushed"
  git commit -q --amend -m "first, reworded"
  reworded=$(git rev-parse HEAD)
  test "$reworded" != "$first" || fail "the commit was not reworded"
  tool status | grep -q "local/$here/passes .*not published  (run on $(echo $first | cut -c1-12), the same files)" || fail "the reworded commit lost its pass: $(tool status)"
  git checkout -q -b reworded
  tool push -q origin reworded
  grep -q "statuses/$reworded -f state=success -f context=local/$here/passes " "$POSTED" || fail "the pass was not posted on the reworded commit"
  test "$(wc -l < "$POSTED")" = 4 || fail "expected two more statuses: $(cat "$POSTED")"
  git checkout -q main && git reset -q --hard $first && git branch -q -D reworded

  echo "A job that fails after its pass was published takes the pass back, on every commit it was posted on"
  touch "$FLAG"
  tool run turns && fail "the turned job reported success"
  test ! -e $passes/turns.json || fail "the stale pass was kept"
  grep -q "statuses/$first -f state=failure -f context=local/$here/turns " "$POSTED" && grep -q "statuses/$reworded -f state=failure -f context=local/$here/turns " "$POSTED" || fail "the failure was not posted on both commits: $(tail -2 "$POSTED")"

  echo "A commit with nothing recorded is pushed as it is"
  echo more > file && git add file && git commit -qm second
  before=$(wc -l < "$POSTED")
  tool push -q origin main 2>&1 | grep -q "nothing is recorded" || fail "did not say nothing is recorded"
  test "$(git --git-dir "$ORIGIN" rev-parse refs/heads/main)" = "$(git rev-parse HEAD)" && test "$(wc -l < "$POSTED")" = "$before" || fail "pushed wrongly or posted something"

  echo "A repository without a job table names both .github/ci/local.json and ci/local.json"
  git init -q $TMPDIR/missing && cd $TMPDIR/missing
  git commit -q --allow-empty -m empty
  tool run passes 2> $TMPDIR/missing-err && fail "ran without a job table"
  grep -qF ".github/ci/local.json" $TMPDIR/missing-err && grep -qF "ci/local.json" $TMPDIR/missing-err || fail "missing-table error did not name both locations: $(cat $TMPDIR/missing-err)"

  echo "Primary .github/ci/local.json works without ci/local.json"
  git init -q $TMPDIR/primary && cd $TMPDIR/primary
  mkdir -p .github/ci
  cat > .github/ci/local.json <<JSON
  { "jobs": {
    "primary": { "platform": "$here", "run": "true" }
  } }
  JSON
  git add .github && git commit -qm primary
  primary_passes=.git/ci-local/trees/$(git rev-parse 'HEAD^{tree}')
  tool run primary
  test -s "$primary_passes/primary.json" || fail "primary .github/ci/local.json pass was not recorded"
  tool run fallback 2> $TMPDIR/primary-err && fail "unknown job succeeded on primary table"
  grep -qF ".github/ci/local.json names no job fallback" $TMPDIR/primary-err || fail "unknown-job error did not name .github/ci/local.json: $(cat $TMPDIR/primary-err)"

  echo "Primary .github/ci/local.json takes precedence over fallback ci/local.json"
  mkdir -p ci
  cat > ci/local.json <<JSON
  { "jobs": {
    "fallback": { "platform": "$here", "run": "true" }
  } }
  JSON
  git add ci && git commit -qm both
  both_passes=.git/ci-local/trees/$(git rev-parse 'HEAD^{tree}')
  tool run primary
  test -s "$both_passes/primary.json" || fail "primary job failed when both tables exist"
  tool run fallback 2> $TMPDIR/precedence-err && fail "fallback job ran despite .github/ci/local.json existing"
  grep -qF ".github/ci/local.json names no job fallback" $TMPDIR/precedence-err || fail "precedence error did not name .github/ci/local.json: $(cat $TMPDIR/precedence-err)"
  cd $TMPDIR/work

  echo "The workflow skips exactly what the table names, and runs the same commands"
  table=${table} workflow=${workflow}
  for job in ${toString jobs}; do
    run=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["jobs"][sys.argv[2]]["run"])' $table $job)
    where=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["jobs"][sys.argv[2]]["platform"])' $table $job)
    grep -qF "run: $run" $workflow || fail "the workflow does not run '$run' for $job"
    test "$(grep -cF "'local/$where/$job'" $workflow)" = 2 || fail "the workflow does not skip $job on local/$where/$job at the step and at the job"
  done
  grep -qF 'github.event.pull_request.head.sha || github.sha' ${../.github/workflows/local-passes.yml} || fail "the statuses are not read from a pull request's head commit"
  touch $out
''
