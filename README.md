# ci-local

A job this machine has already passed for a commit is not run again by GitHub.

`ci-local` runs the jobs a repository's `ci/local.json` names for this platform, with the same commands
its workflow uses, and records each pass for the files of the commit. `ci-local push` posts the passes to
GitHub as commit statuses before the branch moves, and the workflow skips each job whose status is there.

```bash
ci-local run            # every job of this platform; or: ci-local run lint checks
ci-local status         # what is recorded for HEAD, and what has been published
ci-local publish        # post the recorded passes as commit statuses (the commit must be on GitHub)
ci-local push           # put the commit on GitHub, post its passes, then git push
```

## What counts as a pass

- A pass is recorded only for a commit: the tree must be clean before and after the job, with `HEAD`
  unchanged. A job that leaves a file behind is not recorded; the file is named, and the jobs after it
  still run, unrecorded, so one stray file does not hide what the others would have said.
- A pass belongs to the commit's files, not its hash. A commit that is reworded, amended or rebased onto
  the same files has the pass too, and `ci-local push` posts it on that commit. The job table is one of
  the files, so the same files always mean the same command.
- The time kept for a pass is that of its first run on those files. A run that passes again from caches
  does not replace it.
- The status is `local/<platform>/<job>`, where the platform is the machine's own (`linux-x86_64`,
  `macos-arm64`, ...). A pass on one platform never stands in for another, and a job the table gives to
  another platform is refused here.
- `ci-local push` first pushes the commit to a holding ref that no workflow watches, posts the statuses,
  removes the ref and then pushes the branch, so the workflow finds the statuses when it starts.
- A job that fails after its pass was published posts a failure in its place, on every commit the pass
  was posted on.
- A commit with nothing recorded is pushed as it is, and every job runs on GitHub as before.

Receipts are kept in the repository's git directory, under `ci-local/trees/<tree>/`.

## The job table

`ci/local.json` in the repository that uses the tool:

```json
{
  "jobs": {
    "lint":   { "platform": "linux-x86_64", "run": "make lint" },
    "checks": { "platform": "linux-x86_64", "run": "ci/checks.sh" }
  }
}
```

Jobs run one after another in the order named. A job marked `"light": true` runs at the same time as the
light jobs named next to it; mark only jobs that leave room for each other on the machine. If one of them
leaves a file behind, none of that group is recorded.

A job may be in the table for the record only. A test run too long for a hosted runner has no job in the
workflow; its status is then the one place a commit shows that it passed.

## The workflow

`.github/workflows/local-passes.yml` is a reusable workflow. It reads the commit's statuses (for a pull
request, those of its head commit, not of the merge GitHub makes), keeps the ones the repository's owner
posted, and gives the contexts that passed as the output `passed`. Pin it by
commit:

```yaml
jobs:
  local:
    uses: schiffy91/ci-local/.github/workflows/local-passes.yml@<commit>
    permissions:
      statuses: read

  checks:
    needs: local
    if: ${{ !contains(fromJSON(needs.local.outputs.passed), 'local/linux-x86_64/checks') }}
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - name: run every check
        if: ${{ !contains(fromJSON(needs.local.outputs.passed), 'local/linux-x86_64/checks') }}
        run: ci/checks.sh
```

Only statuses from the repository's owner count: anyone with write access to a commit's statuses could
otherwise switch a job off.

## Installing

The flake's `packages.<system>.default` is the tool, for `x86_64-linux`, `aarch64-linux` and
`aarch64-darwin`. It needs `git`, `gh` (signed in) and `python3`, which the package brings.

```nix
inputs.ci-local = { url = "github:schiffy91/ci-local"; inputs.nixpkgs.follows = "nixpkgs"; };
# ...
environment.systemPackages = [ inputs.ci-local.packages.${pkgs.stdenv.hostPlatform.system}.default ];
```

## Tests

`ci/checks.sh` builds every flake check. The one check, `ci-local`, runs the tool against a repository
of its own with a stand-in for `gh` that writes down what it is asked to post, and then holds a job table
against the workflow that reads it: every job the table names must be run by the workflow with the same
command and skipped on its status at the job and at the step. A repository that uses the tool builds the
same check against its own files:

```nix
checks.ci-local = import "${inputs.ci-local}/tests/ci_local.nix" {
  inherit pkgs;
  table = ./ci/local.json;
  workflow = ./.github/workflows/checks.yml;
  jobs = [ "lint" "checks" ];
};
```
