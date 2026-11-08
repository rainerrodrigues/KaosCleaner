# Development

## Requirements

- [Julia](https://julialang.org/downloads/) 1.12 (the version in `Manifest.toml`)
- Python 3.9+
- A C compiler (PackageCompiler uses it to link the library; on Windows it
  downloads one itself)
- About 8 GB of RAM and 15 minutes for a full engine build

## Layout

| Path | What |
|---|---|
| `src/KaosCleaner.jl` | Module and C entry points |
| `src/options.jl` | Cleaning options and their JSON parsing |
| `src/cleaning.jl` | Loading, text cleaning, renaming, selection, deduplication |
| `src/inference.jl` | Type inference and imputation |
| `src/logging.jl` | Buffered logging for the host |
| `src/cdata.jl` | Arrow C Data Interface export |
| `src/streaming.jl` | Chunked processing and the Arrow C Stream Interface |
| `build.jl`, `build/` | Engine build: PackageCompiler environment, precompile trace, thread-safe init (`kaos_init.c`) |
| `include/kaoscleaner.h` | C API |
| `python/kaos_cleaner/` | Python package: `__init__.py` (public API), `_runtime.py` (finding, unpacking and loading the engine) |
| `scripts/build_wheel.py` | Packs a build into a platform wheel |
| `scripts/benchmark.py` | Times pandas, Polars and kaos-cleaner on generated data |
| `test/`, `python/tests/` | Julia and Python tests |
| `docs/`, `mkdocs.yml` | This site |

## Test the engine

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

The Julia tests exercise everything, including the C entry points and the
stream callbacks, without compiling the library.

## Build the engine

```bash
julia build.jl
```

This writes `kaos_binaries/`. It targets your CPU; set
`KAOS_CPU_TARGET=generic` for a library that must run on other machines (CI
does). The build runs `build/precompile.jl` so the code paths it exercises
are compiled in; add to it when you add a feature, or the first call that
uses the feature will be slow.

## Test from Python

```bash
python -m venv venv && . venv/bin/activate
pip install pyarrow polars cffi pytest pytest-benchmark pandas
pytest python/tests -v
```

Run from a checkout, the tests use `python/kaos_cleaner` with
`kaos_binaries/`. Crash- and hang-prone tests run in child processes with
timeouts, so a segfault fails one test instead of the run.

## Build a wheel

```bash
pip install build
python scripts/build_wheel.py          # xz-compressed, a few minutes
python scripts/build_wheel.py --gzip   # larger, seconds; for local testing
```

The wheel lands in `dist/`. On Linux it is tagged manylinux with the oldest
glibc the runtime needs.

## Docs

```bash
pip install -r docs/requirements.txt
mkdocs serve
```

The API reference comes from the docstrings in `python/kaos_cleaner`.

## Code quality checks

```bash
pip install pre-commit && pre-commit install
```

pre-commit then runs ruff (lint and format) and a few file checks on every
commit. CI runs the same ruff checks plus mypy on every pull request:

```bash
ruff check python/ scripts/ && ruff format --check python/ scripts/
```
```bash
cd python && mypy
```

On the Julia side, the test suite includes [Aqua.jl](https://github.com/JuliaTesting/Aqua.jl)
(compat bounds, unused dependencies, piracy, ambiguities). For deeper checks,
[JET.jl](https://github.com/aviatesk/JET.jl) finds type instabilities and
calls that cannot succeed:

```julia
using JET, KaosCleaner
report_package(KaosCleaner; target_modules=(KaosCleaner,))
```

## Commit messages

Releases are generated from commit messages, so use
[Conventional Commits](https://www.conventionalcommits.org/):

| Message | Release |
|---|---|
| `fix: ...`, `perf: ...` | patch (0.1.0 → 0.1.1) |
| `feat: ...` | minor (0.1.0 → 0.2.0) |
| `BREAKING CHANGE:` in the body | minor while below 1.0, major after |
| `docs:`, `test:`, `ci:`, `chore:`, `refactor:`, `style:` | none |

For a pull request that will be squash-merged, the PR title is the commit
message that counts.

## Continuous integration

| Workflow | When | What |
|---|---|---|
| `ci.yml` | Every pull request; Mondays on `main` | Julia tests, Linux engine build, Python tests, speed gate against pandas. The weekly run first updates to the newest compatible Julia packages and installs the latest Python packages |
| `docs.yml` | PRs and `main` touching docs or the Python package | Strict docs build; deploy to GitHub Pages from `main` |
| `build_wheel.yml` | Every push to `main`, or manually | Release (see below); manual runs on a branch build and test all wheels without releasing |
| `codeql.yml` | PRs, `main`, Mondays | CodeQL security analysis of the Python package and the workflows |
| `dependabot-automerge.yml` | When CI or Docs finishes on a Dependabot PR | Merges minor and patch updates once every check passed; majors wait for review |
| `compathelper.yml` | Mondays, or manually | Opens PRs when Julia dependencies release versions outside `[compat]` |

## Automated maintenance

Most upkeep runs without you:

- **Dependabot** opens weekly PRs for GitHub Actions and the docs toolchain.
  Minor and patch updates merge themselves once CI and Docs pass; major
  updates stay open for review, since they can change behaviour.
- **CompatHelper** does the same for the Julia dependencies' `[compat]`
  bounds; see [Setting up CompatHelper](#setting-up-compathelper).
- **The weekly CI run** tests `main` against the newest packages, so an
  upstream release that breaks the engine shows up as a failed run (GitHub
  emails you) before users report it.
- **CodeQL** scans every change and weekly for security issues.
- **semantic-release** versions, tags and publishes; only the PyPI step
  waits for your approval.

None of these commits are `feat:` or `fix:`, so maintenance alone never
cuts a release. TagBot is not used: semantic-release already tags each
version and keeps `Project.toml` in step, which is what Julia's registry
needs.

To test the Windows and macOS wheels of a branch before merging:

```bash
gh workflow run build_wheel.yml --ref my-branch
```

## Releasing

Merging to `main` is releasing. `build_wheel.yml`:

1. runs python-semantic-release (`releaserc.toml`), which reads the commits
   since the last tag and, if a release is due, bumps the version in
   `Project.toml` and `python/kaos_cleaner/__init__.py`, updates
   `CHANGELOG.md`, commits, tags `vX.Y.Z` and creates a GitHub release;
2. builds the engine and a wheel on Linux, Windows and macOS from that tag,
   and tests each installed wheel;
3. attaches the wheels to the GitHub release;
4. if the repository variable `PUBLISH_TO_PYPI` is `true`, publishes to
   TestPyPI and then, after approval in the `pypi` environment, to PyPI.

Publishing uses Trusted Publishing: each index needs a publisher for this
repository, workflow `build_wheel.yml` and environment `testpypi` or `pypi`.
No tokens are stored.

PyPI enforces two things only at upload time, so both are checked earlier:

- **File size**: each wheel must stay under PyPI's 100 MiB per-file limit.
  `build.jl` strips debug information from the bundled Julia libraries to
  get there (Linux ~81 MiB, Windows ~74 MiB, macOS ~68 MiB).
- **Classifiers**: every classifier in `python/pyproject.toml` must be on
  PyPI's official list; `python/tests/test_metadata.py` checks this in CI.

## Setting up CompatHelper

CompatHelper checks every Monday whether a Julia dependency has released a
version outside the `[compat]` bounds in `Project.toml`, and opens a pull
request that widens the bound. CI on that pull request then shows whether
the new version works. Setup takes three steps.

**1. Let GitHub Actions open pull requests.** Settings → Actions → General
→ *Workflow permissions*: tick **Allow GitHub Actions to create and approve
pull requests**, and save. Or from a terminal:

```bash
gh api -X PUT repos/rainerrodrigues/KaosCleaner/actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true
```

The default token stays read-only; each workflow asks for the permissions
it needs.

**2. Give it a deploy key, so CI runs on its pull requests.** GitHub does
not start workflows for pushes made with the workflow's own token. Pushing
over SSH with a deploy key avoids that. Create a key pair without a
passphrase, in a temporary directory:

```bash
ssh-keygen -t ed25519 -N "" -C compathelper -f compathelper_key
```

Add the public half as a deploy key with write access (Settings → Deploy
keys → Add deploy key, paste `compathelper_key.pub`, tick *Allow write
access*), or:

```bash
gh repo deploy-key add compathelper_key.pub --allow-write --title CompatHelper
```

Store the private half as the secret `COMPATHELPER_PRIV` (Settings →
Secrets and variables → Actions → New repository secret), or:

```bash
gh secret set COMPATHELPER_PRIV < compathelper_key
```

Then delete both files; GitHub keeps the only copies it needs:

```bash
rm compathelper_key compathelper_key.pub
```

Without the deploy key, CompatHelper still opens pull requests, but CI does
not start on them until you push a commit to the branch.

**3. Run it once to check.** It runs every Monday; start it now with:

```bash
gh workflow run compathelper.yml
```

```bash
gh run list --workflow compathelper.yml --limit 1
```

A green run with no new pull request means every dependency is within its
bounds. When it does open one, merge it once CI passes; its commits are not
Conventional Commits, so this never cuts a release. It changes only the
allowed versions: the compiled library keeps the exact versions pinned in
`Manifest.toml` until you run `julia --project=. -e "using Pkg; Pkg.update()"`
and commit the result (the weekly CI run already tests the newest versions).

## Publishing to Julia's General registry

The Julia package (`KaosCleaner`) can be registered so that Julia users get
it with `Pkg.add("KaosCleaner")`. `Project.toml` already has the required
compat bounds for every dependency and for Julia itself, which Aqua.jl checks.

1. Install the [JuliaRegistrator](https://github.com/JuliaRegistries/Registrator.jl)
   GitHub app on this repository.
2. On the commit to register (a release commit on `main`), comment
   `@JuliaRegistrator register`. Registrator opens a pull request on
   [General](https://github.com/JuliaRegistries/General).
3. New packages wait three days before the pull request is merged
   automatically, provided the automated checks pass.
4. Every later release needs the same comment on its release commit;
   versions come from `Project.toml`, which semantic-release keeps in step
   with the Python package.
