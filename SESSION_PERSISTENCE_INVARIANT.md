# ⛔ Telegram Session Persistence — Non-Negotiable Invariant

> Read this in full before changing **anything** under `TDLibConfiguration`, the TDLib
> database/files paths, credential resolution, auth-state handling, or `scripts/package.sh`
> signing. This file exists because this exact bug was "fixed" before and regressed. It must
> never regress again.

## The invariant (absolute)

**CocoGram must never force a logged-in user to re-authenticate** (phone number + OTP +
possibly 2FA password). Not once. Not on any machine. Not on any build (`swift run` dev
binary or the installed/notarized `.app`). Not from any working directory. Not after any
number of relaunches.

The ONLY acceptable times a login prompt may appear:
1. The very first login ever, on a machine with no existing session.
2. The user **deliberately** enters different credentials via the in-app setup screen to
   switch accounts.
3. The user, or Telegram itself (remote "terminate session"), intentionally ends the session.

Anything else is a P0 regression.

## Why this is sacred

Re-auth means: open Telegram on your phone, wait for an SMS/app code, type it, maybe type a
2FA password. It is the single most disruptive thing this app can do, and it had been
happening on nearly every launch. The user has lost significant time to it. Treat every
storage/auth/path/signing change as capable of destroying the session, and **verify it can't
(see the checklist) before claiming it is safe.**

## The only two ways a session is ever lost — and the rule that forbids each

A TDLib login lives in `td.binlog` inside the database directory. It is lost iff:

1. **The app points at a different database directory than last time** → TDLib finds no
   session there → re-auth.
   **RULE A — Fixed path.** The database directory is a CONSTANT. It must not depend on
   `api_id`, the test-DC flag, the current working directory, environment variables, or which
   binary is running. Every launch of every build resolves the byte-identical path.

2. **The app connects with a different `api_id`/`api_hash` than the session was created
   with** → Telegram's server-side anti-abuse can revoke the session → TDLib destroys the
   local DB → re-auth.
   **RULE B — Pin the credentials.** On the first successful login, the `api_id`/`api_hash`
   (and test-DC flag) are written into the database directory and are **authoritative
   forever**. Launch-time config (`.cocogram.local`, `credentials.conf`, env vars) is used
   ONLY to perform that first login. Once pinned, the pin wins unconditionally.

Both rules must hold simultaneously. Fixing one without the other still loses sessions.

## Implementation contract (this is what the code must do)

- **Database/files path:** `~/Library/Application Support/CocoGram/tdlib/database` and
  `…/tdlib/files`. No `api_id` segment, no `-test` segment, no cwd, no slot. (An explicit
  `COCOGRAM_TDLIB_DATABASE` / `COCOGRAM_TDLIB_FILES` override is allowed for deliberate dev
  use only — it is never set in normal operation.)
- **Pin file:** lives *inside* the database directory (e.g. `session.pin`). Holds
  `COCOGRAM_API_ID`, `COCOGRAM_API_HASH`, `COCOGRAM_TDLIB_TEST_DC`. It is coupled to the
  session: delete the database dir → the pin goes with it → clean first-login next time.
- **`TDLibConfiguration.resolve()`:** if a pin exists, return the pinned credentials with the
  fixed path, **ignoring all launch-time config**. Only when no pin exists may it read
  env/local/saved config to bootstrap the first login.
- **Writing the pin:** when authorization reaches `Ready` (credentials proven good), write the
  pin if absent. Never overwrite an existing pin on a normal launch.
- **Clearing the pin:** only when the user explicitly saves new credentials via the setup
  screen (a deliberate account switch). Normal launches never clear it.

## Forbidden — these CAUSED the regression, never reintroduce them

- ❌ **Per-`api_id` storage slots** (`tdlib/api-<id>/…`). This made the installed app and the
  dev build read two different databases and was the direct cause of repeated re-auth.
- ❌ Any database-path segment derived from `api_id`, the test-DC flag, cwd, or env (other than
  the one explicit override).
- ❌ Moving/"migrating" the database between locations as a normal-launch behavior.
- ❌ Trusting `.cocogram.local` / `credentials.conf` / env over the pin once a session exists.

## Verification checklist — run ALL of it before claiming any auth/storage change is safe

1. Log the resolved `databaseDirectory` for each of: installed app (cwd `/`), `swift run`
   (cwd = repo, `.cocogram.local` present), and a run with differing env `COCOGRAM_API_ID`.
   It MUST be byte-identical in every case (absent an explicit `COCOGRAM_TDLIB_DATABASE`).
2. With a pin present, confirm `resolve()` returns the SAME `api_id` in every one of those
   cases (the pin overrides launch-time config).
3. On disk, after launching different binaries, confirm there is exactly ONE `td.binlog`
   under `…/CocoGram/tdlib/` — never a second directory.
4. Relaunch test: launch → reach Ready → quit → relaunch → it must NOT prompt for phone.
5. Grep the path-building code: no `api_id`, cwd, or env appears in the database path.

## History (so future-me does not repeat it)

The original code used a single fixed path and worked. A prior session, trying to prevent a
*theoretical* server-side revocation from an `api_id` mismatch, introduced per-`api_id`
storage slots. That change itself created two divergent databases (installed app on the old
path, dev build on `tdlib/api-<id>/…`) and became the actual, repeated cause of the re-auth
the user reported. The correct fix is fixed-path **plus** credential pinning — not slots.
