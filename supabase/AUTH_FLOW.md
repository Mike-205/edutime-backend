# Auth Flow — client contract and user journeys

*This file and `TECHNICAL_DISCOVERY.md` §10 cover the same ground on purpose, for
different jobs. §10 explains **why** the design is what it is — the trade-offs, the
things considered and rejected. This file is **what the client must do, in order**: the
exact call sequence, the exact strings, the exact thing a user sees when something goes
wrong. If the two ever disagree, §10 is the rationale and this file has the bug.*

State as of `0036` (2026-08-25). No Flutter client exists yet — Part 1 is the spec it
needs to be built against; Part 2 describes what the mechanics in Part 1 imply the UI
has to handle, not an observed app.

---

## Part 1 — Technical: the client contract

### The rule everything else assumes

Signup is a **claim against a pre-declared identity**, never account creation. The
institution already knows who exists (`student_roster`). A bare `auth.users` row buys a
`public.users` row with a name and maybe an email — no `reg_number`, no `cohort_id`.
`claim_roster_row()` is the only way out of that state, and both paths below end there.

### The synthetic-address transform — the single most important spec in this file

The registration-number-password path has no real email to authenticate with, so the
client builds one. **This transform is entirely client-side — no migration or function
in this repo builds or validates it** (`TODO.md` §4.4). Get it wrong and the failure is
silent: GoTrue does a normal "no such user" lookup and returns a normal "invalid
credentials" error, indistinguishable from an actually-wrong password.

**The rule:** strip whitespace, uppercase-normalize (same as `normalize_reg_number()`),
lowercase the result, replace every `/` with `.`, append `@auth.internal`.

| Registration number (as typed) | Synthetic address |
|---|---|
| `EB1/67277/23` | `eb1.67277.23@auth.internal` |
| `EB1/67358/23` | `eb1.67358.23@auth.internal` |
| `EB1/71004/24` | `eb1.71004.24@auth.internal` |
| `EB3/67903/23` | `eb3.67903.23@auth.internal` |
| `BA2/70115/24` | `ba2.70115.24@auth.internal` |

Verified against every password-path account in `seed.sql`. **Signup and login must call
the same function to build this string** — two separate implementations of the same five
rules is exactly how this drifts. `never surface this address in the UI` — the user only
ever types/sees their registration number (`0002` §A).

### Path A — Registration number + password

1. Client collects **registration number, full name, and a password** — in that order,
   before anything is created, because the reg number is needed to build the address in
   step 2.
2. Client derives the synthetic address (above) and calls `auth.signUp(email: synthetic,
   password)`. `[auth.email] enable_confirmations = false`, so nothing is ever mailed to
   `@auth.internal` and there is no confirmation step to wait on.
3. `on_auth_user_created` fires `handle_new_auth_user()` once. Because
   `raw_app_meta_data->>'provider'` is not `google`/`apple`, `public.users.email` and
   `email_verified_at` both stay `NULL`. `first_name`/`last_name` are filled from
   `raw_user_meta_data` — client-supplied, provisional, about to be overwritten.
4. Client calls `claim_roster_row(p_reg_number, p_first_name, p_last_name,
   p_acting_user => auth.uid())`. Because `email` is null, this takes the **provisional**
   branch: name + number must match one `student_roster` row, no further proof.
   `claim_method = 'provisional'`. On success, `users.first_name/last_name/middle_name`
   are overwritten with the roster's authoritative names — whatever the client sent at
   signup is discarded.

### Path B — University email (Google OAuth)

1. Client runs the standard Google OAuth flow against a `@student.chuka.ac.ke` address.
   No reg number is needed yet — Google doesn't know it.
2. `handle_new_auth_user()` fires once. `raw_app_meta_data->>'provider' = 'google'`, so
   `public.users.email` is set to the real address and `email_verified_at = now()`
   **immediately, before any roster claim** — the account is "verified" in the trust
   sense before it has an identity in the roster sense.
3. **The client must still separately collect the registration number** and call
   `claim_roster_row` — OAuth alone does not bind an identity, it only proves an inbox.
   Because `email IS NOT NULL AND email_verified_at IS NOT NULL`, this takes the
   **OAuth** branch: `reg_number_from_email(email)` derives a reg number from the
   *proven* address and requires it to exactly equal what the user typed. Mismatch
   raises — describe this branch by those two columns, not "signed up with Google": an
   OAuth-created account with either unset (shouldn't happen given step 2, but the check
   exists regardless) still claims as `provisional`.
4. `claim_method = 'oauth'`. This claim can never be displaced by anything — not another
   OAuth claim, not a provisional one.

### Returning-user login

- **Password**: `signInWithPassword` against the *same* synthetic address, rebuilt by
  the *same* function as signup. Any drift here is the failure mode this whole section
  exists to prevent.
- **OAuth**: same Google flow. GoTrue matches the existing `auth.users` row by address
  rather than inserting a new one, so `handle_new_auth_user` does not re-fire (it's
  `AFTER INSERT`, never `UPDATE`). If the client calls `claim_roster_row` again
  defensively on every login, it's a safe no-op — the idempotent-reclaim branch
  (`v_existing.reg_number = v_norm → return`) exits before any matching logic runs.

### Password recovery (password-path accounts only)

Two separate steps, both self-service, both before anything can be recovered:

1. `set_recovery_email(p_email, p_acting_user)` — stores a personal address, sends a
   6-digit OTP via `functions/recovery-email-setup` (Axene).
2. `verify_recovery_email(p_code, p_acting_user)` — confirms it.  `user_recovery_email`
   is now `verified_at IS NOT NULL`.

Only then does `functions/recovery-request` → `request_password_recovery(p_reg_number)`
have anything to send. **The response is byte-identical across every refusal reason** —
account doesn't exist, is OAuth-linked, has no verified recovery email, or is inside the
5-minute cooldown — by design, to give an attacker no oracle over the roster.

### The asymmetry, at a glance

| | Password (Path A) | OAuth (Path B) |
|---|---|---|
| `auth.users.email` | synthetic `@auth.internal` | real `@student.chuka.ac.ke` |
| `public.users.email` | stays `NULL` | the real address |
| `email_verified_at` | `NULL` | set at signup, by the trigger |
| `claim_method` | `provisional` | `oauth` |
| Can be displaced later | yes — by a real `oauth` claim | never |
| Password recovery | eligible (once set up + verified) | refused — no password exists |
| `promote_class_rep` | needs `p_identity_attested => true` | promotes with no extra step |

---

## Part 2 — User journeys

Scenario walkthroughs, from the student's side of the screen. Failure paths included on
purpose — the happy path is three steps and easy to build correctly; the failure paths
are where this system's actual opinions live, and where a client implementation is most
likely to improvise something the backend doesn't expect.

### 1. New student, password signup — happy path

Amina types her registration number, full name, and a password, taps **Create
account**. The app builds her synthetic address behind the scenes — she never sees it —
signs her up, and immediately calls the roster claim with the same details. Both match a
roster row nobody else has claimed. She lands on her cohort's timetable. Her account is
`provisional` — nothing in the UI needs to say so; it has no effect on what she can do.

### 2. New student, OAuth signup — happy path

Kevin taps **Sign in with your university email**, picks his Google account, consents.
He's now "logged in" — but his account has no cohort yet, so the app's very next screen
has to ask for his registration number (there's no way around this: Google never learns
it). He types it, the app calls the claim, `reg_number_from_email` on his just-proven
address matches what he typed, and he lands on his timetable. His account is `oauth` —
permanently the stronger of the two.

### 3. Returning login, either path

Same as any app: password or Google, whichever they signed up with. Nothing roster-side
happens again unless the client redundantly calls the claim, which is harmless.

### 4. Roster match fails (wrong number, typo, or a name that doesn't match)

Whatever the actual reason, the student sees **one message**: *"We could not match those
details. Check your registration number and full name with your class rep."* The app
must not attempt to distinguish "no such number" from "number exists, name is wrong" —
that distinction is exactly what would let someone probe the roster for real registration
numbers. The only next action available is: go ask a human.

### 5. A classmate claimed Amina's row first (squatter, then real owner arrives)

Amina never set up an account. A classmate — maliciously or by fat-fingering a friend's
number — claims her row provisionally. Weeks later Amina signs up for real via Google.
Her claim succeeds (OAuth always wins over provisional), and **the squatter's account is
the one that changes**: it receives an `account_taken_over` notification ("Your account
has been unlinked... if you believe this is wrong, contact your faculty rep"), and goes
inert — keeps its notification history, loses its `cohort_id` and `reg_number`, can see
almost nothing from then on. This is a real screen: a previously-working account that
now shows essentially nothing needs a UI state that explains why, not a blank timetable
that looks like a bug.

### 6. Claim blocked because the row is already spoken for and can't be auto-resolved

Two cases end the same way — nothing happens automatically, the app surfaces "contact
your faculty rep," and the resolution happens outside the app entirely
(`resolve_roster_dispute`, faculty rep, physical ID check):

- The row is currently claimed by an account with **`class_rep`** authority. Auto-evicting
  a sitting rep on a signup event would strip a cohort's scheduling authority with no
  human in the loop, so this raises instead of resolving itself.
- The row is currently claimed **`oauth`** by someone else, and the new attempt is also
  trying to claim it. An OAuth claim is provider-proven; nothing outranks it, including
  another OAuth attempt (which would only happen if the roster itself has bad data).

### 7. Forgot password, but the account is OAuth-linked

Wanjiru signed up with her university Google account, has no password, and taps "Forgot
password" out of habit. She sees the exact same generic message everyone sees — *"If that
registration number has a verified recovery email on file, a reset link has been
sent."* — and nothing arrives, because `request_password_recovery` refused the moment it
saw `users.email IS NOT NULL`. **This is expected behavior, not a bug to fix** — the app
could optionally short-circuit this client-side for a better message (OAuth accounts are
knowable client-side too), but the server will never confirm or deny an account's auth
method through this endpoint.

### 8. Forgot password, but recovery email was never set up

A password-path student who never completed `set_recovery_email` +
`verify_recovery_email` requests a reset. Same generic message, same nothing-arrives
outcome — `request_password_recovery` refuses at the "`verified_at IS NULL`" check,
indistinguishable from every other refusal reason from the outside. Worth the app
nudging students to set up recovery email proactively (e.g. right after their first
successful claim), since this is the only account-recovery path that exists for them.

### 9. Signup silently gets stuck

A synthetic-address transform bug, or a student who abandoned the flow between `signUp`
and the roster claim, leaves an account sitting with a real login but no identity — from
the student's side, indistinguishable from "the app is broken," with no error to report.
There's no in-app recovery for this today. A faculty rep can query
`unclaimed_synthetic_signups()` (`0036`) to find every such account stuck more than an
hour, but nothing currently prompts them to look — this is a support-desk tool, not a
self-service one.
