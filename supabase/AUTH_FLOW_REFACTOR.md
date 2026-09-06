# Auth flow refactor — proposed redesign, not yet implemented

> **Status: proposal, dated 2026-08-25. Nothing in this file is built.** `AUTH_FLOW.md`
> describes what the database actually does today (roster + password/`auth.internal` +
> OAuth, as of `0036`). This file describes where that design is headed and *why* — the
> conclusion of a design conversation, not a migration plan. Treat every function, column,
> and table name below as **proposed**, not existing, unless a footnote says otherwise. No
> migration number is assigned yet.

---

## 0. Why this exists — what's wrong with the shipped design

The roster (`student_roster`, `0017`) was a deliberate, reasoned choice (`TODO.md` §0.5):
pre-declare every enrolled student's identity so a signup can be checked against something
authoritative, instead of trusting whatever a stranger types. It works, and it shipped.

Two things about it don't hold up under scrutiny:

- **It doesn't actually prevent impersonation.** The provisional-claim branch matches on
  name + registration number only — anyone who knows (or guesses) a classmate's details
  can claim their row first. The roster raises the bar; it does not close the hole. Only
  an `oauth` claim (a provider-proven address) closes it, and that was always available
  without a roster.
- **Acquiring and maintaining it is disproportionate to what it buys.** Getting a
  complete, accurate roster out of the registrar before day one is high-friction and
  low-accuracy in practice — and the thing it protects against, an OAuth signup can
  already protect against on its own.

**The conclusion:** drop `student_roster` and the password/`auth.internal` path entirely.
Authenticate with OAuth only, on two different email tiers, and move identity
verification from *"acquire a complete roster upfront"* to *"a human who actually knows
this person vouches for them, at the moment they try to join a specific group."* That
human is the class rep, and the moment is a join request — not a pre-loaded table.

---

## 1. The two paths

| | Personal email | School email |
|---|---|---|
| Provider | Google OAuth, any address | Google OAuth, `@student.chuka.ac.ke` only |
| Who it's for | No school email yet, or none intended | Anyone with one |
| Identity fields | Typed by the student, self-attested | Derived from the proven address |
| Trust level | Weak — nothing institutional backs it yet | Strong — the institution issued this mailbox |
| Cohort placement | Always a request, always reviewed | Always a request, always reviewed (§4) |

Both are OAuth. There is no password path and no synthetic-email transform in this
design — the entire class of "silent failure indistinguishable from a wrong password"
problem `TODO.md` §4.4 raised about `auth.internal` disappears because there's nothing
synthetic to build.

---

## 2. Registration number becomes four stored facts, not one string

Today `reg_number` is one composed string (`EB1/67277/23`), parsed on demand by
`parse_reg_number()` (`0017`) into programme, sponsorship, student number, and year.
Under this redesign those four facts are stored directly, on `users`, instead of being
re-derived from a string every time something needs one of them:

- **`programme_id`** — a real FK to `programmes`. Never typed as a code; the student
  picks their programme by name from a picker. `programmes` is small (~30 rows),
  human-curated, and fine to expose publicly — there's nothing to scope there, only
  `cohorts` need scoping.
- **`self_sponsored boolean`** — set directly (a signup toggle on the personal-email
  path), not inferred from an `S` hidden in a programme code. This is a real,
  independent fact: `TODO.md`'s deferred "Branching" entry ties it straight to academic
  pace — **GSS can only run bimester; SSP may move to trimester, but only collectively,
  by quorum, escalated through the class rep** (a feature that doesn't exist yet).
  Storing this now means the eligibility list for that future feature already exists
  when it's built, the same way `cohorts.join_code` sits generated-but-dormant today.
- **`student_number`** — the true unique, permanent identity anchor. Confirmed: two
  students in different intake years can never share one. This is the one field that
  survives a future inter-programme/faculty transfer unchanged.
- **`admission_year`** — descriptive only. Not part of the unique key, and **not
  reliable for current cohort placement** — a deferred student's number still says
  their original year, but they may be running with a later cohort (§4).

**Why decompose at all:** it's the same move already used for `cohorts.name` in this
schema — derive the display string from stored parts, don't store the string and
reverse-engineer parts out of it on every read. It also directly enables a scenario
that isn't built yet but is coming: **inter-programme/faculty transfer**, a few weeks
into a semester, where `programme_id` changes but `student_number` and `admission_year`
stay fixed to the person. That's a different thing from "branching" (a pace change
within the same programme) and isn't covered by that deferred item — it needs its own
line whenever it's picked up.

**A structural risk worth naming for whoever builds this:** once `programme_id` is a
real column, a transfer means updating it and `cohort_id` together. If those two are
ever set in separate statements, a row can transit a moment where its programme
disagrees with its own cohort's programme. `cohorts_stream_inherits` already solved this
exact shape of problem elsewhere in this schema with a composite FK; the same mechanism
— `(cohort_id, programme_id)` referencing `cohorts (id, programme_id)` — is the right
tool here too, so the disagreement is structurally impossible rather than trigger-caught.

**The `S`-encoding collision, considered and dismissed:** the self-sponsored variant of
a programme code inserts an `S` before the trailing digits (`EB1` → `EBS1`). In theory
two real codes could collide under that transform (a real code `BS` colliding with a
real code `B`'s self-sponsored form). Checked against every seeded code today (`EB1`–
`EB15`, `BA1`–`BA16`, `EIM`, `EMFW`) — none contain the letter `S` at all, so this isn't
live. More importantly, it's not really our risk to guard against: the school controls
programme-code assignment, and a collision would break their own systems' ability to
tell the two apart, for the same reason it would break ours. `programmes` is a small,
manually-curated table, not user input — not worth a DB-level guard.

**Where the `S` still has to be parsed, and why that's fine:** the school-email path
(§4) derives its four facts from a proven address like
`ebs1.67277.23@student.chuka.ac.ke` — a string shaped by a convention we don't control.
`parse_reg_number`'s existing `S`-stripping logic doesn't go away; it becomes the *one*
canonical boundary parser, run exactly once, converting that external string into the
four stored facts. The personal-email path never touches it — programme comes from a
picker, sponsorship from a toggle, nothing to parse.

**Two identity-bearing addresses, not one.** Once §5/§6 let a single account hold both a
school and a personal identity, a generic `users.email`/`email_verified_at` pair stops
meaning anything specific — it's whichever address happened to land there first. Split
it: `school_email` / `school_email_verified_at` and `personal_email` /
`personal_email_verified_at`, four columns instead of two. This matters beyond tidiness:
`reg_number_from_email` (§2, §4) needs *the school address specifically* to derive
anything — pointed at a generic `email` column, it silently reads whichever identity
happens to be there and either derives garbage or `null`. Named columns make "the
identity-bearing address" something code points at directly, not a convention someone
has to remember.

**Rule, stated as a prohibition:** `claim_method` is the only column any access decision
reads. `school_email_verified_at` is *evidence* — written once, by the claim/link
handlers, at the moment `claim_method` gets set to `oauth`. It is not itself a source of
authorization. If a future policy ever checks `school_email_verified_at is not null`
directly instead of `claim_method`, that's a regression back to re-deriving identity per
query — the exact thing confirmed above as *not* how this schema works today. `claim_method`
is the verdict; keep it the only one anyone reads.

**This requires updating the existing write-guard, not just adding columns.** `0014` and
`0032` both protect `users` updates with a literal column-name allowlist — a trigger body
that checks `NEW.email is distinct from OLD.email`, `NEW.email_verified_at is distinct
from OLD.email_verified_at`, and so on, rejecting any client write that touches a listed
column. The four new columns aren't on that list and would ship writable by anyone unless
both trigger bodies are updated to name them — the old `email`/`email_verified_at` would
stay locked down while the identity data that actually matters moved to unprotected
columns. This also means the guard's "legitimate writer" story gets more granular:
`0032`'s comment currently says `email_verified_at` has *exactly one* legitimate writer
(`0019`) — under this split, the claim path and the §5/§6 link handlers are all
legitimate writers of one column or another, and the guard needs to know which function
may touch which of the four, not just gate on one shared writer.

---

## 3. Flow 1 — personal email

1. OAuth against any personal address (Gmail, etc.).
2. Name is pulled from the OAuth profile, shown back, editable — never trusted blindly.
3. Student picks their programme (picker), toggles self-sponsored, types student number
   and admission year. Format/existence-checked (programme resolves to a real row, year
   is plausible) — not checked against a roster, because there isn't one.
4. **Claiming happens right here, immediately — not bundled into the cohort request.**
   Submitting these four facts is its own write, straight into `users`: the four fields,
   `claim_method = 'provisional'`, no `cohort_id` yet. `student_number`'s uniqueness
   constraint fires at this exact moment. If someone else already holds that number, this
   is where it's caught — at data entry, before a single cohort has been shown — not
   after a whole cohort request that was always going to fail. (An earlier draft of this
   section bundled the number claim into the join request itself, which meant two people
   could both get as far as picking a cohort, land in front of two different reps who
   couldn't see each other, and only collide when the second approval hit the constraint.
   This is what closes that: the collision can't happen past this step, because only one
   claim on a given number can ever exist.)
5. Account is inert here: identity claimed, no cohort, nothing visible.
6. App suggests cohorts matching `programme_id` (scoped near `admission_year` — see the
   open question in §9) — never the full cohort list. Student picks one, files a join
   request.
7. **The cohort's class rep always reviews the request** — approves or declines, based
   on whether they actually recognize this person as a real classmate. This is the
   verification step that used to be the roster; now it's one human vouching for one
   person, at the moment it matters, instead of a table vouching for everyone upfront.
8. On approval: `cohort_id` is set. The four identity fields don't change here — they
   were already committed at step 4.

---

## 4. Flow 2 — school email

1. Google OAuth against `@student.chuka.ac.ke` specifically.
2. The proven address is run through the boundary parser (§2) — all four facts derived
   automatically. Nothing typed, nothing to get wrong.
3. **Cohort placement is not automatic**, and this is a deliberate correction from an
   earlier draft of this design: `admission_year` says when someone *started*, not who
   they're *currently studying with*. A deferred student needs to be able to pick a
   cohort other than the one their number would predict. So the student sees suggested
   cohorts for their derived `programme_id` and picks one, same as Flow 1.
4. **The class rep of the chosen cohort always reviews the request too** — decided
   deliberately, not because it's structurally required (the identity fields are already
   strongly proven by this point) but because it's the simpler, uniform rule. A tiered
   alternative was considered and rejected for now — see §9.
5. **Takeover on approval, not on write.** If the derived `student_number` is already
   held by a `provisional` account, approving this request must trigger a takeover
   (unlink the old holder, send it the same `account_taken_over` notification as today,
   reassign the identity) — not a plain placement, and not a silent constraint failure.
   This is the one place a naive implementation breaks: inserting a *second* `users` row
   for the same `student_number` fails on the uniqueness constraint (§7), which is the
   wrong outcome. The rep approving is what triggers the takeover; the mechanism itself
   doesn't need the rep's input, since `oauth` outranking `provisional` is unconditional.

   **This is not a blind overwrite — it's already a checked, gated process today
   (`claim_roster_row`, `0019`, lines 185–205), and none of those checks depend on
   whether the account being evicted has a `cohort_id` yet:** is there even an existing
   claim to displace; is it already `oauth` (refuse, nothing outranks it — this
   collision *shouldn't be reachable* under correct operation, since two different real
   school addresses can't derive the same number, so hitting this case is a red flag
   worth surfacing, not a routine outcome to handle silently); is the incoming claim
   *not* `oauth` (refuse — provisional can't evict provisional); is the account being
   evicted a `class_rep` (refuse and escalate to the faculty rep instead — never
   auto-evict scheduling authority). Only after all four pass does the reset run.
   **What does change under this redesign: every one of those checks currently reads off
   a `student_roster` row, which won't exist.** They need re-hosting on `users` — the
   `oauth`/`provisional` checks read `claim_method` off the `users` row holding the
   number (already the plan, §7), the `class_rep` check already reads `users.role` today
   so it's untouched, and the audit trail these actions write to needs its own fix — see
   §8.

   **What eviction actually does to the losing account, concretely:** it is not deleted.
   It keeps its login, its notification history, everything except the two fields that
   made it "this person" — `reg_number`/the four identity fields, and `cohort_id`, both
   reset to null. Because nearly everything in this app is gated by cohort membership, an
   evicted account can see almost nothing afterward — a working account one day, an empty
   shell the next, which is exactly why it needs an explicit notification rather than a
   silent state change: *"Your account has been unlinked — a university account for this
   registration number signed in, so the identity has moved to it. If you believe this is
   wrong, contact your faculty rep."* (the existing `0019` wording, unchanged). Whether
   the evicted account had already made it into a cohort or was still sitting in the
   claimed-but-cohortless state from §3 step 4 doesn't matter — the reset is identical
   either way.

   **Worked example.** Someone signs up via personal email, types in a real classmate's
   registration number — typo or deliberate impersonation, the mechanism doesn't care
   which — and a class rep approves them without catching it. Weeks later, the actual
   owner signs up properly with her school email. The moment she does, her number is
   derived automatically, found already claimed, and the four gates above run: yes,
   someone holds it; no, they're not `oauth`; no, they're not a class rep — eviction
   proceeds. The impostor account goes inert and gets the notification above; she gets
   placed once her own join request is approved. Nobody had to notice or investigate —
   the real owner showing up was enough to fix it on its own. This asymmetry only ever
   runs one way: a personal-email account can never evict a school-email one, only the
   reverse — a school-issued address is institutional proof, and nothing about a later
   personal Gmail signup should ever be able to override that.
6. `claim_method = 'oauth'` — permanently the stronger of the two, exactly as today.

---

## 5. Linking a school email to an existing provisional account

A provisional (Flow 1) student who later gets or activates their school email
shouldn't have to sign up a second time and evict their own account via takeover — they
should be able to link it to the account they already have. **Decided:** this uses
Supabase Auth's identity linking (`linkIdentity()`), which attaches a second identity to
the *same* `auth.users` row instead of creating a new one — `enable_manual_linking` is
now `true` in `config.toml` for this. Because `handle_new_auth_user()` only fires `AFTER
INSERT ON auth.users` (`0002`), and a linked identity doesn't insert a new row, this
can't hook into that trigger — it needs its own function the client calls right after
`linkIdentity()` succeeds.

1. While signed in as the provisional account, the client calls `linkIdentity()` against
   Google with the school address.
2. On success, the client calls a new RPC (name TBD — something like
   `sync_school_email_identity`) that derives the four facts from the newly linked,
   proven address through the same boundary parser as Flow 2 (§2), and compares them
   against what's already stored on this `users` row.
3. **Match** → upgrade in place: set `email`/`email_verified_at`, flip `claim_method` to
   `'oauth'`. No rep involved — identity was already approved once; this only
   strengthens the proof that already exists.
4. **Mismatch, derived number held by nobody** → **routes to the faculty rep**, the same
   escalation tier `resolve_roster_dispute` uses today for a conflict no class rep can
   resolve alone. Deliberately not auto-corrected: silently rewriting the stored identity
   to match whatever address gets linked would let a bad — possibly fraudulent —
   provisional approval launder an identity change straight past the rep gate a second
   time, with nobody re-checking it. And deliberately not refused outright either: the
   proven address is materially stronger evidence than the self-typed field it disagrees
   with, so the account being wrong is at least as likely as the link being invalid — a
   human with faculty-level authority should look, not either extreme by default.
5. **Mismatch, derived number already held by another account** → not a new case, same
   shape as the takeover in §4 step 5: the account attempting to link isn't who its own
   stored record claims, and the proven identity already belongs elsewhere.

---

## 6. Linking a personal email to an existing school-email account

The reverse direction of §5. **Why this matters:** a school email is not permanent — it
gets deactivated on graduation or withdrawal, same as at any institution. An account
whose only sign-in method is `@student.chuka.ac.ke` becomes unreachable the day that
address stops resolving. A linked personal email is the account's lifeline past that
point — **nothing in this design should require the school email to still be valid for
an already-established account to keep working.**

Mechanically this mirrors §5 — `linkIdentity()` against Google with a personal address,
while signed in as the `oauth` account — but the whole mismatch tree in §5 collapses,
because a personal address carries no identity claim to check. There is no programme, no
student number, no year to derive from `someone@gmail.com`; nothing to compare it
against. So linking is unconditional: any authenticated `oauth` account can link any
personal email, no rep, no faculty rep, no derivation step at all.

**Stated as a hard invariant, not left implicit:** linking a personal email never writes
`claim_method`, never touches any of the four identity fields (§2), and never downgrades
anything already established. Confirmed above that nothing in this schema re-derives
identity per session — it's read once, off the `users` row — so this holds regardless of
which of the account's linked identities a future login happens to go through.

(Considered and dismissed: an attacker with a live compromised session linking a personal
email as a persistence mechanism. Linking requires an authenticated session — anyone who
has one can already do worse with it. Not a distinct risk worth designing around here.)

---

## 7. Uniqueness and conflict resolution

- `student_number` gets a real uniqueness constraint on `users`. That constraint — not
  anything at request time — is what actually stops two *approved* accounts from
  colliding.
- Two pending requests for the same number can coexist without incident; only one can
  ever be approved, because the second approval's `users` write hits the constraint.
  That's how the conflict actually surfaces — not proactively, at the moment of the
  second approval attempt.
- `oauth` always displaces `provisional`, never the reverse — this is the one property
  worth calling out as non-negotiable: it's what gives the whole design a self-healing
  recovery path (a squatter gets evicted the moment the real owner shows up with school
  email, automatically, no faculty rep needed). Drop it and this redesign loses the one
  thing that made "OAuth wins" valuable in the current shipped design.
- **Resolved by §3 step 4, not by anything in this section.** An earlier draft worried
  that two pending requests for the same number could land with two different class reps
  who can't see each other's queue. Claiming the number at data-entry time, before cohort
  selection, closes this — only one claim on a given `student_number` can ever exist, so
  there's nothing left for two reps to collide over by the time either sees a request.

---

## 8. The identity/takeover audit trail

`roster_audit_log` (`0017`) is not retired by this redesign — it's the one thing that
becomes *more* load-bearing, not less. Under the roster design, this log was mostly
bookkeeping: a record of which pre-vetted roster row moved to which account, with the
roster itself standing as a second, more authoritative source of truth if anything needed
checking. Once the roster is gone, there is no second source of truth — every claim is
either a rep's judgment call or the `oauth`-beats-`provisional` rule firing on its own.
This log becomes the *entire* record of every trust decision the system makes. If a bad
approval or a disputed takeover ever needs investigating, this is the whole paper trail,
not a nice-to-have next to something more authoritative.

The table was already built to survive something like this — worth noting, because it
means the change required is small. Its own comment says so directly: *"Denormalized so
the trail survives the roster row being removed. An audit log that can be erased by
deleting the thing it audits is not an audit log."* `reg_number` is stored as its own
plain text value already, not derived by joining back to the roster. The only piece that
actually depends on `student_roster` is one optional column, `roster_id`, and even that's
`on delete set null` rather than `on delete cascade` — dropping the roster table doesn't
take a single audit row down with it.

So, three changes, not a rebuild:

- **Rename it.** "Roster audit log" stops describing what it holds once there's no
  roster.
- **Drop `roster_id`.** Nothing left for it to point at.
- **Recreate `roster_audit_action` clean.** The current enum (`'created', 'updated',
  'removed', 'claimed', 'takeover', 'unbound', 'dispute_resolved'`) has three values that
  only ever meant "someone edited a roster row" — dead once there's no roster row to
  edit. Postgres can't drop values from an enum in place, so carrying them forward would
  mean three permanently-unused categories forever. **Decided: rebuild the enum with only
  what still means something** — `claimed`, `takeover`, `unbound`, `dispute_resolved` —
  plus one new value for a kind of event this design introduces that doesn't fit any
  existing one: `identity_linked`, for the self-service linking in §5/§6 (an already-
  established identity gaining a second proven address — not a first claim, not a
  takeover).

**Who can read it stays unchanged.** Checked the existing policy — any account with
`role = 'faculty_rep'` can already read the whole log (`roster_audit_read_faculty`,
`0017`), the same tier that resolves disputes elsewhere in this design. No new reader
function needed; this survives as-is.

---

## 9. Deferred — good ideas, not being built now

- **Tiered approval by year-match.** A version of Flow 2 was considered where a request
  matching the derived `admission_year` exactly auto-approves (with the takeover check
  still running), and only a *divergent* year (the deferral case) goes to a human — with
  the divergent case probably owed to the **faculty rep**, not the class rep, since a
  deferred student isn't from the target cohort's own intake and the class rep has no
  basis to recognize them (the same reasoning `resolve_roster_dispute` already uses
  today for "no local knowledge available" cases). Good UX instinct, explicitly shelved
  in favor of "class rep always reviews, full stop" for now (§4 step 4) — worth
  revisiting later.
- **The cohort-suggestion window.** "Suggest cohorts near the derived year" needs an
  actual bound, or a Flow 2 student can request any cohort in their programme across
  every intake ever, landing on reps who can't evaluate most of them. The right window
  size (±1 intake? ±2?) is unverified — same category of "don't guess a specific number"
  as the branching quorum threshold in `TODO.md`. Confirm with whoever owns that policy
  before encoding it.
- **The transfer operation itself.** This doc lays the *foundation* (atomic columns, the
  composite-FK idea in §2) for inter-programme/faculty transfer, not the operation. No
  `transfer_student_programme()`-shaped function is being designed here.

---

## 10. What this retires

If this ships, it replaces outright: `student_roster`, the password + `auth.internal`
signup path and its client-side synthetic-address transform (`TODO.md` §4.4, closed by
construction rather than fixed), and `claim_roster_row`'s roster-matching logic.

**Correction from an earlier draft of this section:** `resolve_roster_dispute` is *not*
fully retired. Ordinary join-request conflicts do fold into "the class rep declines a
request," as originally written here — but §5 gives faculty-rep-level escalation a
second, narrower job under this design (a self-service email-link that doesn't match the
account's stored identity). Whatever replaces `resolve_roster_dispute` needs to keep
serving that case, just for a smaller trigger than "any provisional claim conflict."

**Also not retired: `roster_audit_log`** (renamed, per §8) — it survives the redesign
essentially intact, carrying more weight than it did before, not less.

None of this is deleted yet; this section exists so a future implementer knows what
becomes dead code, not to prompt tearing it out prematurely.
