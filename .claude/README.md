# Claude Code Configuration

This directory contains Claude Code-specific configuration for the istio-scale-tests repository.

## Files

### `settings.json`
Project-level Claude Code configuration that:

1. **Reduces permission prompts** for common read-only operations:
   - File listing (`ls`, `find`)
   - Content viewing (`cat`, `grep`, `head`, `tail`)
   - Git inspection (`git status`, `git log`, `git diff`)
   - Version checks (`helm version`, `terraform version`, etc.)

2. **Allows common commands** without prompting:
   - Searching for script patterns (`grep` for `SETUP_CONTEXTS`, `DRY_RUN`)
   - Listing Helm charts and manifests
   - Linting operations (`helm lint`, `shellcheck`, `terraform validate`)

3. **Always includes key context files**:
   - `AGENTS.md` — Implementation rules, conventions, and common tasks
   - `config/versions.env` — Version pins and environment variables

### Local Overrides

Create `settings.local.json` in this directory for personal preferences. It will be ignored by git (add to `.gitignore` if needed).

Example `settings.local.json`:
```json
{
  "permissions": {
    "bash": {
      "defaultAllow": true
    }
  }
}
```

## Usage

Claude Code automatically loads `settings.json` when working in this repository. No manual action needed.

To verify configuration:
```bash
# Check if settings are loaded (via Claude Code)
cat .claude/settings.json
```

## Maintenance

When adding new common read-only commands to scripts, consider adding them to `allowedCommands` or `allowPatterns` to reduce friction.
