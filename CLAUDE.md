# Claude Code instructions

- Do not add any Claude/AI attribution to git: no `Co-Authored-By`, no `Claude-Session` trailer, and no "Generated with Claude Code" footer — neither in commit messages nor in pull request descriptions
- Secrets are stored locally in ~/.secrets/, never in git
- Track tasks as GitHub Issues in this repository
- Scripts should be idempotent (safe to run multiple times)
- Use `uv` for everything Python — venvs, dependency management, and running scripts (`uv venv`, `uv pip`, `uv run`, PEP 723 inline deps). Do not use raw `pip`/`venv`/`virtualenv`
- Language: comments and docs in English, communication with user in Russian
