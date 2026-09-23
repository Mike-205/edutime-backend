# Auth Flow — client contract and user journeys

*`AUTH_FLOW_REFACTOR.md` is the design doc that drove this rewrite — it explains
**why** the design is what it is, in prose that is deliberately not verbatim against the
live code. This file is **what the client must do, in order**: the exact call sequence,
the exact strings, the exact thing a user sees when something goes wrong. Function
names, parameter names, and error text below are taken directly from the live migration
files, not paraphrased. (`TECHNICAL_DISCOVERY.md` §10 still describes the old
roster/password design as current — it has not been updated for this rewrite yet, so
treat it as stale, not as a second source of rationale, until it is.)*

State as of `0053` (2026-09-20). No Flutter client exists yet — Part 1 is the spec it
needs to be built against; Part 2 describes what the mechanics in Part 1 imply the UI
has to handle, not an observed app.

Every account authenticates with Google OAuth. There is no password path, no synthetic
address, no pre-declared roster, and no password-recovery subsystem — all of it was
dropped; none of it exists in this schema any more.

---

## Part 1 — Technical: the client contract

### The rule everything else assumes

Signup is still a claim against an identity, but there is no pre-declared roster to
check it against. Instead there are **two OAuth tiers**, distinguished purely by the
domain of the Google account the student signs up with:

| | Personal email | School email |
|---|---|---|
| Address | Any Google account | `@student.chuka.ac.ke` only |
| Who it's for | No school email yet, or none intended | Anyone with one |
| Identity fields | Typed by the student, self-attested | Derived from the proven address, server-side, nothing typed |
| `claim_method` after claiming | `provisional` | `oauth` |
| Can be displaced later | yes — by a real `oauth` claim | never |

`is_school_email(p_email)` (`0039`) is the domain test: true for any address matching
`^[^@]+@student\.chuka\.ac\.ke$`, case- and whitespace-normalized first, regardless of
whether the local part looks like a registration number. `handle_new_auth_user()`
(`0039`) runs this test once, at signup, and files the proven address into exactly one
of two columns on the new `users` row: `school_email`/`school_email_verified_at` or
`personal_email`/`personal_email_verified_at` — never both, and both timestamped `now()`
immediately, before any identity claim exists.

`claim_method` (nullable, values `'provisional'` / `'oauth'`) is the only column any
access decision reads. It starts `null` for both tiers at signup and is set for the
first time by whichever identity-claim path below actually runs.

### Flow 1 — personal email

1. Client runs Google OAuth against any address. `handle_new_auth_user` fires once;
   `personal_email`/`personal_email_verified_at` are set, `claim_method` stays `null`.
2. The student's name is pulled from the OAuth profile, shown back, editable.
3. The client shows an identity form **immediately, before any cohort is shown**: a
   programme picker, a self-sponsored toggle, a student number field, an admission year
   field.
4. The client calls `claim_identity_personal(p_programme_id, p_self_sponsored,
   p_student_number, p_admission_year, p_acting_user)` — `p_acting_user` must equal
   `auth.uid()`. This is its own write, straight onto `users`, independent of any cohort
   choice. In the order the live function actually checks them:
   - Caller must be `role = 'student'` (a promoted rep can't run this), or it raises
     `Only a student account may claim a personal-email identity`.
   - Calling it at all on an account that already holds an `oauth` claim raises `An
     OAuth-verified identity cannot be replaced by a personal-email claim` — nothing
     about this flow can ever downgrade a school-email account.
   - `p_student_number` is trimmed; blank raises `A student number is required`.
   - Calling this again with the same student number is a safe no-op (idempotent
     re-claim). Calling it with a *different* student number after already claiming one
     raises `This account has already claimed a different identity`.
   - `p_programme_id` must reference a real row in `programmes`, or the call raises
     `Programme % does not exist`.
   - If the account already carries a `cohort_id` (a rare, defensive case — this
     normally only fires when `resolve_identity_dispute` cleared identity fields but not
     `cohort_id`, and the student is retrying), the new programme must match that
     cohort's programme, or it raises `This account's existing cohort does not match the
     programme being claimed`.
   - `p_admission_year` must be between 2000 and next calendar year inclusive, or it
     raises `Admission year % is not plausible`.
   - Finally, the format itself is **not validated** beyond non-blank — the uniqueness
     constraint on `users.student_number` is the real gate. A collision raises `Student
     number % is already claimed`.
   - On success: `programme_id`, `self_sponsored`, `student_number`, `admission_year` are
     set and `claim_method` becomes `'provisional'`. No `cohort_id` is touched.
5. Only now does the client show cohorts — scoped to the claimed `programme_id`, never
   the full list. The student picks one and the client inserts a row directly into
   `cohort_join_requests (student_id, cohort_id)` (status defaults to `'pending'`; a
   student can have only one pending request at a time).
6. The cohort's class rep reviews the request and calls `approve_cohort_join_request`
   (see below) or `decline_cohort_join_request(p_request_id, p_decided_by)`. On
   approval, `approve_cohort_join_request` re-checks that the student's already-claimed
   `programme_id` matches the target cohort's `programme_id` — mismatch raises `This
   student's programme does not match this cohort's programme — approval refused`. On
   decline, the request row is marked `'declined'` and the student is free to request
   again.

### Flow 2 — school email

1. Client runs Google OAuth against a `@student.chuka.ac.ke` address specifically.
   `handle_new_auth_user` fires once; `school_email`/`school_email_verified_at` are set,
   `claim_method` stays `null`.
2. **There is no client-side identity call in this flow at all.** Nothing is typed,
   nothing is shown for programme/self-sponsored/student number/admission year — those
   four facts are derived later, entirely server-side, from the proven `school_email`
   via `reg_number_from_email()` + `parse_reg_number()`.
3. There is no `programme_id` stored on this account until commit time, but the client
   can still scope the cohort list the same way Flow 1 does: `reg_number_from_email()`
   and `parse_reg_number()` are both granted to `authenticated`, so the client may call
   them read-only against the proven `school_email` to derive a programme for display
   purposes, without that call writing anything. The student picks a cohort and the
   client inserts the same `cohort_join_requests` row as Flow 1.
4. The cohort's class rep reviews the request and calls `approve_cohort_join_request`.
   Internally, `approve_cohort_join_request` detects a not-yet-committed school-email
   account by three conditions all holding at once: `claim_method is null`,
   `school_email_verified_at is not null`, `cohort_id is null`. When they do, it calls
   `commit_school_identity(p_student_id, p_cohort_id, p_actor_id)` **before** setting
   `cohort_id` — this function is internal only (no `EXECUTE` grant to any role,
   including `authenticated`); a client never calls it directly.
   - `commit_school_identity` derives `reg_number_from_email(school_email)` and parses
     it. If nothing derives, it raises `Could not derive a student identity from this
     school email. A faculty rep must resolve this.`
   - If the derived programme disagrees with the target cohort's programme, it raises
     `The identity derived from this school email does not match this cohort's
     programme`.
   - Otherwise it commits `programme_id`, `self_sponsored`, `student_number`,
     `admission_year` and sets `claim_method = 'oauth'` — see **Takeover**, below, for
     what happens first if that `student_number` is already held by someone else.
   - `approve_cohort_join_request` then proceeds exactly as in Flow 1: marks the request
     `'approved'` and sets `users.cohort_id`.
5. `claim_method = 'oauth'` — permanently the stronger of the two tiers.

### Takeover

Both `commit_school_identity` and `link_school_email_identity` (below) run the same
check before committing a derived `student_number`: if another `users` row already
holds that number,

- and that row is already `claim_method = 'oauth'` — refuse. Two proven school-email
  accounts cannot legitimately derive the same number; this raises `Two proven
  school-email accounts derive the same student number. This cannot happen under
  correct operation and needs a faculty rep to investigate before either account is
  touched.` This is an escalation for a state that should never occur, not a routine
  outcome.
- and that row's `role = 'class_rep'` — refuse. Scheduling authority is never
  auto-evicted: `That identity is held by an account with scheduling authority. A
  faculty rep must resolve this.`
- otherwise (the holder is `provisional`) — evict it automatically: clear its
  `reg_number`, `programme_id`, `self_sponsored`, `student_number`, `admission_year`,
  `claim_method`, and `cohort_id`; insert a `notifications` row for it (`type =
  'account_taken_over'`, title `Your account has been unlinked`, message *"The
  university account for this registration number signed in, so the identity has moved
  to it. If you believe this is wrong, contact your faculty rep."*); and write an
  `identity_audit_log` row (`action = 'takeover'`). The evicted account is not deleted —
  it keeps its login and notification history, but loses everything gated by
  `cohort_id`.

This only ever runs one direction: a personal-email (`provisional`) claim can never
evict anyone, because `claim_identity_personal` refuses outright the moment the caller
already holds `oauth`, and nothing in Flow 1 derives a `student_number` for someone
else's account. Only a proven school-email identity can trigger a takeover.

### Linking

Two self-service RPCs, both requiring `enable_manual_linking = true` in
`config.toml` (already set) and both called immediately after a successful client-side
`linkIdentity()` call against Google.

**`link_school_email_identity(p_actor_id)`** — for a `provisional` (Flow 1) account that
later links a school address to the *same* `auth.users` row, to upgrade in place without
a second signup or a takeover of its own account:

- If the account is already `oauth` with this exact `school_email` on file, it's a safe
  no-op (idempotent).
- If `claim_method` is anything other than `'provisional'`, it raises `Only a
  provisional-claim account can link a school email this way`.
- If the account already has a `school_email` on file, it raises `This account already
  signed up with a school email; use the cohort join-request flow`.
- If no linked school-email identity is found on the auth side, it raises `No linked
  school-email identity was found for this account`.
- It then derives the four facts from the newly linked address the same way Flow 2
  does, and compares them against what's already stored on the row:
  - **Match** → upgrade in place: `school_email`/`school_email_verified_at`,
    `programme_id`, `self_sponsored`, `student_number`, `admission_year` all set,
    `claim_method` flips to `'oauth'`. No rep involved. An `identity_audit_log` row is
    written (`action = 'identity_linked'`).
  - **Mismatch, and nobody else holds the derived `student_number`** → refused:
    `The identity derived from this account's linked school email does not match what
    was recorded at signup. A faculty rep must resolve this before the school email can
    be confirmed.` See **Dispute resolution**, below.
  - **Mismatch, and the derived `student_number` is already held by someone else** →
    the same takeover logic as `commit_school_identity` runs (same three outcomes, same
    error text) before the row above upgrades.

**`link_personal_email_identity(p_actor_id)`** — for an `oauth` (school-email-verified)
account to attach a personal address afterward, as a post-graduation recovery contact:

- Requires `claim_method = 'oauth'`; anything else raises `Only a school-email-verified
  account can link a personal email as a recovery contact`.
- If no linked personal-email identity is found, it raises `No linked personal-email
  identity was found for this account`.
- Otherwise it is **unconditional**: no rep, no faculty rep, no derivation, no
  comparison against anything. It sets `personal_email`/`personal_email_verified_at`,
  overwriting any personal email already on file — re-linking a new address simply
  replaces the old one. Never touches `claim_method` or any of the four identity fields.
  An `identity_audit_log` row is written (`action = 'identity_linked'`).

### Dispute resolution

`resolve_identity_dispute(p_user_id, p_actor_id)` — callable only by a `faculty_rep`
(`p_actor_id` must equal `auth.uid()` and hold `role = 'faculty_rep'`; not scoped to one
faculty). This is what a faculty rep calls after physically/out-of-band verifying which
side of a link mismatch (above) is correct, when the student's own claim is the one
found wrong:

- Clears `claim_method`, `programme_id`, `self_sponsored`, `student_number`, and
  `admission_year` on the target account. **Deliberately does not clear `cohort_id`** —
  the account didn't lose its identity to someone else's proven claim, a rep just
  decided the self-typed data can't be trusted yet, so it isn't ejected from a cohort it
  may legitimately belong to.
- Writes an `identity_audit_log` row (`action = 'dispute_resolved'`).
- The student then redoes `claim_identity_personal` with corrected data. If the dispute
  also involved the wrong programme, `claim_identity_personal`'s own existing guard
  (refusing a programme that disagrees with an already-set `cohort_id`) catches that on
  the retry, and the student retries `link_school_email_identity` from there.

---

## Part 2 — UX implications

### 1. New student, personal-email signup

Amina picks "Sign in with Google," authenticates with her personal Gmail address. The
very next screen is the identity form — programme picker, self-sponsored toggle,
student number, admission year — because there is nothing else to show yet; the app
calls `claim_identity_personal` the moment she submits it. Only after that succeeds does
she see a cohort list (scoped to her programme), pick one, and land in a "pending
approval" state until her class rep decides. Her account is `provisional` — nothing in
the UI needs to say so.

### 2. New student, school-email signup

Kevin picks "Sign in with your university email," authenticates against his
`@student.chuka.ac.ke` address. **The app must show no identity form at all** — there is
nothing to type; the four facts don't exist yet even server-side, only the proven
address does. He goes straight to a cohort list and files a join request. The very next
screen is "pending class rep approval" — a state that must exist in the UI even
though nothing about Kevin's own identity is uncertain, because approval is what
triggers `commit_school_identity` and there is no other event that will. If approval
never happens, Kevin's account stays inert (`claim_method` still `null`) indefinitely —
worth a "still waiting?" affordance eventually, but there's no timeout mechanism today.

### 3. Linking a school email onto an existing personal-email account

A student who signed up via Flow 1 later gets a school Google account activated and
links it. Three distinct outcomes the client must be able to show, and only one of them
shows anything at all:

- **Silent upgrade.** The derived identity matches what was already on file — the app
  can show a quiet confirmation ("Your account is now verified") but there's genuinely
  nothing more to ask the user.
- **"Contact your faculty rep."** The derived identity disagrees with what's on file and
  nobody else holds the derived number — the app shows exactly that instruction and
  stops; there is no retry the app itself can offer.
- **Nothing visible at all.** The link silently evicts someone else's stale,
  incorrect-claim account (a takeover) — from this student's side, the screen just shows
  the upgrade succeeding. The interesting UI state here belongs to the *other* account
  (scenario 5 below), not this one.

### 4. Recovery-contact linking (school-email accounts only)

An `oauth` student links a personal address — typically prompted proactively, since a
school mailbox stops working after graduation or withdrawal and this is the only
lifeline past that point. This call cannot fail for identity reasons (there's nothing to
compare), so the only UI states are "no personal Google account was actually linked yet"
(surfaces the `No linked personal-email identity was found` error) and success. Re-doing
this later silently replaces the address on file — worth telling the user that plainly,
since there's no confirmation step in the RPC itself.

### 5. A personal-email account gets evicted (takeover, on the losing side)

Someone signed up via personal email and typed in a real classmate's student number —
typo or impersonation, the mechanism doesn't care which — and a class rep approved
without catching it. Weeks later the real owner shows up via school email (either
signing up fresh, Flow 2, or linking a school address onto an already-existing
provisional account of their own). The moment that identity is proven, the impostor
account is evicted automatically: it receives an `account_taken_over` notification
("Your account has been unlinked... if you believe this is wrong, contact your faculty
rep") and goes inert — loses `cohort_id` and all four identity fields, keeps its
notification history. This is a real screen: a previously-working account that now
shows almost nothing needs a UI state that explains why, not a blank timetable that
looks like a bug.

### 6. Escalation to a faculty rep, then back

A student hits the "contact your faculty rep" outcome from scenario 3. There is no
in-app path forward from here — resolution happens out-of-band (the rep verifies the
person physically, then calls `resolve_identity_dispute`). Once that happens, the
student's account has no claim at all (`claim_method` is `null` again, `cohort_id`
unchanged) — the client should route a signed-in user in this state straight back to the
Flow 1 identity form, since that's the only way out of it, and then to
`link_school_email_identity` again once the corrected claim is in.

### 7. Returning login, either tier

Same as any OAuth app: Google, whichever account they signed up or linked with. Nothing
identity-side happens again on a bare login — `claim_identity_personal`,
`commit_school_identity`, and both linking functions only ever run in response to an
explicit client action (a form submission, an approval, a fresh `linkIdentity()` call),
never automatically on sign-in.
