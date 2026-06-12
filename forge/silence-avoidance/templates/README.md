# Placeholder templates

These files are PLACEHOLDERS shipped with the engine for development and
testing. They are NOT the canonical fallback prose.

**Canonical prose** is produced by Seraph (handoff G3:
`HANDOFF-20260527-GAWDFATHER-SERAPH-fallback-template-prose.md`) and
delivered to `/usr/local/lib/gawd/fallbacks/templates/`.

At forge-build time, `install.sh` copies Seraph's files into the daemon's
`~/.gawd/fallbacks/templates/` directory and these placeholders are
superseded.

If you're seeing these placeholders in production, something went wrong in
the forge pipeline — file a defect and Seraph's templates should be staged.

## Variable contract

Two variables; substitution is byte-deterministic via `render.sh`:

- `{{address_name}}` — the Prophit's address name
- `{{prophit_local_time}}` — short local time string ("14:23 CDT")

No other variables. Adding more breaks the deterministic-render contract.
