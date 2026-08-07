# git-file-size-limit

A GitHub Action that fails a pull request when a changed file exceeds a size
limit — a guardrail against accidentally committing large binaries, datasets,
or notebooks with saved outputs.

Exemptions use **real gitignore syntax**, enforced with `git check-ignore`
rather than an approximation: globs, `/`-anchoring, directory-only patterns,
and negation (`!`) all work exactly as they do in a `.gitignore`. Adding a
file to the exemption list is the explicit approval — it shows up in the
diff and gets reviewed like any other change.

Only files *changed* in the pull request are checked (three-dot diff against
the merge-base, matching what GitHub's "Files changed" tab shows), so
pre-existing large files in the repo are never flagged unless a PR touches
them. Deletions are ignored.

## Quick start

```yaml
name: File size check

on:
  pull_request:

jobs:
  check-file-size:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0 # required: the action diffs against the base commit

      - uses: innate-inc/git-file-size-limit@v1
        with:
          max_size: 100KB
```

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `max_size` | No | `100KB` | Maximum allowed size for a changed file. A byte count or a suffixed value: `B`, `KB`, `MB`, `GB` (e.g. `500KB`, `2MB`, `1.5GB`). |
| `ignore_file` | No | `.sizelimitignore` | Path to a gitignore-syntax file listing exemptions. |
| `base_sha` | No | PR base SHA | Override the base of the diff. |
| `head_sha` | No | PR head SHA | Override the head of the diff. |
| `fail_on_violation` | No | `true` | Set to `false` to report violations without failing the build. |

## Outputs

| Name | Description |
| --- | --- |
| `status` | `pass` or `fail`. |
| `violations_count` | Number of files that exceeded the limit. |
| `violations` | Markdown bullet list of offending files (path, size, limit); empty when none. |

## Exempting a file

Add a pattern to `.sizelimitignore` (or whatever `ignore_file` points to) at
the repo root:

```gitignore
# Generated lockfiles are large but legitimate.
uv.lock
yarn.lock

# All 3D model assets.
*.glb

# One specific large file, anchored to the repo root.
/docs/assets/demo.gif
```

Because this file is gitignore syntax evaluated with `git check-ignore
--no-index`, standard rules apply: patterns without a `/` match at any
depth, a leading `/` anchors to the repo root, a trailing `/` matches
directories only, `**` matches across directories, and a leading `!`
re-includes a path an earlier pattern excluded.

## Posting the result as a PR comment

The action doesn't post a comment itself — pair its outputs with a
comment action if you want one:

```yaml
      - id: size_check
        uses: innate-inc/git-file-size-limit@v1
        with:
          max_size: 100KB

      - if: always() && steps.size_check.outputs.violations_count != '0'
        uses: peter-evans/create-or-update-comment@v5
        with:
          issue-number: ${{ github.event.pull_request.number }}
          body: |
            ### File size check failed

            The following files exceed **${{ github.event.inputs.max_size || '100KB' }}**:

            ${{ steps.size_check.outputs.violations }}

            Exempt intentionally large files by adding them to `.sizelimitignore`.
```

## Why not just scan the whole repo?

Some size-check actions scan every file in the working tree on every run.
That flags pre-existing large files (checked out from git history) on PRs
that never touched them, which trains people to ignore the check. This
action only looks at what a given PR actually changed.

## License

MIT — see [LICENSE](./LICENSE).
