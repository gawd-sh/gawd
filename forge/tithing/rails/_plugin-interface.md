# Tithing Rails Plugin Interface

**Version:** 1.0
**Date:** 2026-05-27
**Author:** The Logos (handoff E3)
**Spec reference:** §17.7 (rails decision deferred); architecture/tithing-abstraction.md §6
**Stability:** v1.0 contract — additive changes only after v1.0.

A "rails plugin" is a directory under `/usr/local/lib/gawd/tithing/rails/<plugin-name>/` that integrates a specific payment provider (Stripe, Patreon, GiveButter, custom) with the Gawd's tithing abstraction layer. The abstraction layer auto-discovers plugins and calls into them via the contract below.

**Why this matters:** spec §17.7 defers the rails decision. Until the maintainer picks, every code path that touches money goes through the abstraction layer (`/usr/local/lib/gawd/tithing/abstraction.sh`), which talks to plugins via this interface. When the rails decision lands, the implementer writes a plugin against this interface; nothing above the plugin changes.

---

## 1. Plugin directory layout

```
/usr/local/lib/gawd/tithing/rails/<plugin-name>/
├── plugin.json                       — manifest (REQUIRED)
├── record_tithe.sh                   — REQUIRED
├── recurring_setup.sh                — REQUIRED
├── recurring_status.sh               — REQUIRED
├── failed_charge_callback.sh         — REQUIRED
├── refund.sh                         — OPTIONAL (highly recommended)
├── chargeback_callback.sh            — OPTIONAL (highly recommended)
└── lib/                              — plugin-private helpers (OPTIONAL)
```

The abstraction layer calls only the REQUIRED scripts in normal flow. OPTIONAL scripts enable additional capability surfaces (refund operations, chargeback handling).

---

## 2. plugin.json — required manifest

```json
{
  "name": "<plugin-name>",
  "version": "1.0",
  "supports": ["one_time", "recurring", "refund", "chargeback"],
  "currencies": ["USD", "EUR", "GBP"],
  "secrets_required": ["RAILS_API_KEY", "RAILS_WEBHOOK_SECRET"],
  "webhook_url_template": "https://gawd.sh/webhook/<plugin-name>/{gawd_id}"
}
```

| Field | Type | Meaning |
|---|---|---|
| `name` | string | Plugin identifier. Must match directory name. |
| `version` | string | Semver. Bump on breaking changes. |
| `supports` | array | Capability flags. Recognized: `one_time`, `recurring`, `refund`, `chargeback`. The abstraction layer reads this to decide whether a refund call is supported. |
| `currencies` | array | ISO 4217 codes the rails accepts. The abstraction validates currency at process time. |
| `secrets_required` | array | KEY NAMES that must exist in `~/.secrets/`. NEVER values. The abstraction layer probes presence (by key name) at load time; missing keys put the plugin in degraded mode. |
| `webhook_url_template` | string | The public URL the rails should POST webhooks to. `{gawd_id}` placeholder is substituted per deployment. May be null for plugins that don't use webhooks. |

---

## 3. Required scripts

All scripts read a JSON payload from stdin, emit a JSON response to stdout, and use exit codes per the table below.

### 3.1 `record_tithe.sh`

Process a one-time charge OR record an externally-received tithe.

**Stdin (JSON):**
```json
{
  "amount": 25.00,
  "currency": "USD",
  "source": "tip" | "recurring-charge" | "manual" | "refund" | "chargeback",
  "prophit_id": "paul",
  "recurring_id": "rcr_abc123",
  "metadata": { "free": "form" }
}
```

**Stdout (success):**
```json
{
  "ok": true,
  "rails_txn_id": "ch_xyz789",
  "rails_status": "succeeded"
}
```

**Stdout (failure):**
```json
{
  "ok": false,
  "error_kind": "card_declined" | "invalid_amount" | "rails_unavailable" | "other",
  "detail": "human-readable error",
  "retryable": true | false
}
```

**Exit codes:**
- 0 — success
- 1 — argument / payload error
- 2 — rails-side error (the rails returned non-2xx)

The rails plugin is responsible for actually charging the card (or whatever the rails-specific operation is). The plugin must NOT write to the local ledger — the abstraction layer does that.

### 3.2 `recurring_setup.sh`

Create a recurring tithe subscription on the rails side.

**Stdin (JSON):**
```json
{
  "prophit_id": "paul",
  "amount": 25.00,
  "currency": "USD",
  "cadence": "weekly" | "monthly" | "annual"
}
```

**Stdout (success):**
```json
{
  "ok": true,
  "recurring_id": "rcr_abc123",
  "status": "active" | "pending_confirmation",
  "next_charge_at": "2026-06-03T14:00:00Z"
}
```

**Exit codes:** 0, 1, 2 (as above).

### 3.3 `recurring_status.sh`

Return current state of all recurring subscriptions for a Prophit.

**Stdin (JSON):**
```json
{"prophit_id": "paul"}
```

**Stdout (success):**
```json
{
  "ok": true,
  "recurring": [
    {
      "recurring_id": "rcr_abc123",
      "amount": 25.00,
      "currency": "USD",
      "cadence": "monthly",
      "status": "active",
      "next_charge_at": "2026-06-27T14:00:00Z"
    }
  ]
}
```

**Exit codes:** 0, 1, 2.

The `recurring` array MAY be empty (no recurring set up). `status` values: `active`, `paused`, `cancelled`, `failed-pending-retry`.

### 3.4 `failed_charge_callback.sh`

Webhook handler. Called BY the rails (via the abstraction layer's webhook receiver) when a recurring charge fails.

**Stdin (rails-specific webhook payload):**
The exact JSON shape varies by rails. The plugin parses the rails-specific format and extracts the relevant fields.

**Stdout (success):**
```json
{
  "ok": true,
  "recurring_id": "rcr_abc123",
  "prophit_id": "paul",
  "action": "notified"
}
```

**Exit codes:** 0, 1, 2.

Inside this script, the plugin should:
1. Parse the rails-specific webhook payload.
2. Verify the webhook signature (using `RAILS_WEBHOOK_SECRET`).
3. Resolve `recurring_id` to `prophit_id` (via rails metadata or local mapping).
4. Call `tithe.failed_charge(recurring_id, prophit_id)` — exposed via the abstraction layer.
5. Emit the success JSON.

The abstraction layer's `tithe.failed_charge` call will write a ledger entry and notify the money-voice state machine.

---

## 4. Optional scripts

### 4.1 `refund.sh`

Process a refund of a prior charge.

**Stdin (JSON):**
```json
{
  "rails_txn_id": "ch_xyz789",
  "reason": "duplicate-charge"
}
```

**Stdout (success):**
```json
{
  "ok": true,
  "refund_id": "rfd_abc",
  "status": "succeeded"
}
```

If the plugin does NOT implement `refund.sh`, the abstraction layer's `tithe.refund` returns `error_kind: "refund_not_supported"` and recommends manual reconciliation.

### 4.2 `chargeback_callback.sh`

Webhook handler for chargeback events. Same general shape as `failed_charge_callback.sh` but the abstraction layer treats chargebacks as a stronger signal (transition to Quiet).

---

## 5. Secret-handling discipline

### Hard rules
1. Plugin source code MUST NOT contain literal API keys, webhook secrets, or any credential string.
2. Plugin scripts read secrets via the `secrets` helper at invocation time: `secrets get RAILS_API_KEY`.
3. The plugin manifest's `secrets_required` array lists the KEY NAMES the plugin needs. Names only. Never values.
4. Webhook signatures MUST be verified before any state mutation.

### Soft rules
1. Plugins should fail loudly (exit 2) if a required secret is missing — don't proceed with a half-credentialed call.
2. Plugins should not log secret-adjacent data (full webhook payloads often contain card fingerprints — log only the fields you need to debug).

---

## 6. Discovery and switching

The active rails plugin is named in `~/.gawd/state/active-rails.txt` — a single-line file containing the plugin directory name. Default: `stub`.

**Switching plugins** (operator workflow):
1. Verify the new plugin is installed (`ls /usr/local/lib/gawd/tithing/rails/<new>/`).
2. Verify required secrets are provisioned (`secrets list | grep -F <required-key-names>`).
3. Atomically swap: `echo "<new>" > ~/.gawd/state/active-rails.txt.tmp && mv ~/.gawd/state/active-rails.txt.tmp ~/.gawd/state/active-rails.txt`.
4. Restart any long-running services that cache the rails name (Gawd daemon: graceful reload sufficient).

The abstraction layer reads `active-rails.txt` on every API call (cheap read; the file is tiny). No daemon restart strictly required, but in-flight operations finish with the old plugin.

---

## 7. Implementing a new plugin — checklist

When the maintainer picks the v1 rails, follow this checklist:

- [ ] Create `/usr/local/lib/gawd/tithing/rails/<name>/` directory.
- [ ] Write `plugin.json` with accurate `supports`, `currencies`, `secrets_required`.
- [ ] Implement all four required scripts.
- [ ] Implement `refund.sh` if the rails supports it (probably yes).
- [ ] Implement `chargeback_callback.sh` if the rails sends chargeback webhooks.
- [ ] Provision required secrets via `secrets set <KEY>`.
- [ ] Run the integration test suite (described in §8 below).
- [ ] Switch `active-rails.txt` to the new plugin name.
- [ ] Verify with a test tithe end-to-end (small amount, immediately refunded).

---

## 8. Integration test suite (suggested)

Every new plugin should pass these tests before being switched to active:

1. **`record_tithe`:** process a $1 tip; verify rails_txn_id returned; verify charge appears in rails dashboard.
2. **`recurring_setup`:** create a $1/weekly subscription; verify recurring_id returned and `recurring_status` lists it.
3. **`recurring_status`:** query an unknown Prophit; verify empty list returned, exit 0.
4. **`failed_charge_callback`:** simulate a webhook payload (rails-side test mode usually allows this); verify ledger entry + state-machine transition.
5. **`refund` (if implemented):** refund the $1 tip from test 1; verify negative ledger entry; verify rails dashboard reflects the refund.
6. **Secrets discipline:** grep the plugin source for `api_key`, `token`, `secret` patterns; expect zero literal-string matches.
7. **Manifest correctness:** `plugin.json` parseable; `supports` accurate.

---

## 9. The stub plugin

A reference implementation lives at `/usr/local/lib/gawd/tithing/rails/stub/`. It implements all four required scripts as no-ops that:

- Write a synthetic `rails_txn_id` based on timestamp.
- Maintain a local file-based recurring-state for `recurring_status`.
- Accept (but do not validate) webhook payloads.

The stub is the default `active-rails` and is suitable for F3 validation testing, development on offline substrates, and as a reference for new-plugin authors. The stub is NOT a production rails.

---

## 10. §17.7 status (as of 2026-05-27)

Rails not yet selected. The candidates (per spec §17.7):

| Candidate | Recurring UX | Webhook reliability | Fees | Notes |
|---|---|---|---|---|
| Stripe | Strong | Strong | 2.9% + 30¢ | Industry standard; most mature; supports complex recurring schedules. |
| Patreon | Strong (native tiers) | Moderate | ~5-12% effective | Has native "tier" concept aligned with named-giving-levels UX. |
| GiveButter | Strong | Moderate | 2.9% + 30¢ + small platform fee | Built for donations; tax-treatment-friendly. |
| Custom | TBD | TBD | TBD | Maximum control but maximum engineering. |

When the maintainer decides, write the plugin against this interface. The abstraction layer above is stable.

---

*End of plugin interface. Implementation reference: `/usr/local/lib/gawd/tithing/rails/stub/`.*
