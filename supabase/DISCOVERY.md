# Project Discovery

## Problem Statement

University cohorts currently track their lecture schedule through word-of-mouth, WhatsApp messages, and physical notice boards — with no shared system to catch when two cohorts are accidentally booked into the same room at the same time, and no formal way to track that some lecturers are inconsistent (present one week, absent the next), which means even a "correct" schedule doesn't tell a student whether the lecture is actually going to happen. Right now, the only real safeguard is a class representative manually phoning the lecturer the day before or a few hours ahead to check — an invisible, easily-forgotten task with no system support.

## Target Users

**Primary — Student.** Every account starts here. A student consumes schedule information: they view their cohort's upcoming lectures, browse a calendar, get notified when something changes, and check which venues are free anywhere on campus. Students never create or modify lectures.

**Secondary — Class Representative.** A student elevated by a Faculty Rep, up to two per cohort (a primary and an assistant fallback, holding identical permissions — the assistant only matters operationally if the primary needs replacing). The only role with scheduling authority: creating, editing, rescheduling, and cancelling lectures for their cohort, plus managing cohort membership and adding courses to their cohort's current semester.

**Secondary — Faculty Representative.** The trust anchor for an entire faculty. Manages departments, programmes, and courses (across any semester, unlike class reps), and is the only person who can promote a student into the class rep role — because in the real world, they're the one who physically ran the election and witnessed the result. Never schedules lectures themselves.

**Infrastructure-only — Superadmin.** Never appears in the app. Bootstraps the first Faculty Reps after verifying them manually, and helps seed initial reference data like venues.

## Current Workarounds

- WhatsApp groups and word-of-mouth for schedule changes.
- Physical notice boards, easily out of date.
- Class reps personally phoning lecturers to confirm attendance, with no record of who was called, when, or what was said — purely memory-based.
- Students physically walking around campus checking which rooms are occupied, since there's no way to check remotely.

## Solution Overview

A mobile app that is a single, trustworthy source of truth for a cohort's lecture schedule. "Trustworthy" is the operative word — the schedule is only useful if students can believe the person editing it is genuinely their legitimately-elected class rep, and if the system itself refuses to let two cohorts collide in the same room at the same time. Authority to schedule anything flows through an unbroken, real-world-anchored chain: a Superadmin bootstraps Faculty Reps, Faculty Reps personally witness and promote elected Class Reps, and only Class Reps can ever touch the schedule. On top of this, the app formalizes the lecturer-reliability problem: every lecture carries a separate day-of confirmation status, so a class rep's "did I actually call and check" task becomes a visible, trackable part of the system instead of something that lives only in someone's memory.

## Core Value Proposition

One place a student can check and believe — conflict-free, real-time, and backed by a chain of accountability all the way up to a witnessed election.

## Out of Scope

Deliberately excluded from the first build — not abandoned, just deferred to a later phase:

- **Branching & merging** — trimester-track students splitting into subgroups, merge requests, and Faculty Rep approval of those requests. Useful context to keep in mind while designing (so nothing built now blocks it), but zero functionality ships for it in MVP.
- **Formal cohort-join approval as the ONLY path** — the request/approve flow (student requests to join a specific cohort, class rep approves or declines) is the primary MVP flow, but a self-service join-code fallback is kept dormant in the data model for a possible future addition, not built out as a user-facing feature yet.
- **Lecturer self-service accounts** — lecturers are referenced by name only; they never log in or interact with the app directly.
- **Faculty-wide analytics or reporting dashboards.**
- **Web application** — mobile only for MVP.
- **Recurring combined (cross-cohort) lectures** — a one-off combined lecture (one lecturer teaching several cohorts at once) is in MVP scope, but a *recurring* combined series, where multiple cohorts' reps would need to reconfirm every single occurrence, is explicitly deferred.
- **Opting a single cohort out of a scheduled combined lecture mid-series**, or any nuance beyond the core opt-out/cancel mechanics already built.

## User Journey (First Use)

1. A new student signs up — either with their registration number, full name, and a password, or by signing in with their official university email (Google/Apple), which verifies them instantly.
2. The app identifies their academic programme from their registration number and shows every cohort under that programme (Year 1 Semester 1 through however many semesters the programme runs).
3. The student requests to join the cohort matching their actual progress — accounting for students who deferred, transferred, or repeated a year, since the "obvious" cohort based on admission year isn't always the right one.
4. The cohort's class rep reviews and approves (or declines) the request.
5. Once approved, the student immediately sees their cohort's upcoming lectures — venue, lecturer, time, and status — on a calendar they can browse by day, week, or semester.
6. As the class rep makes changes (new lecture, reschedule, cancellation), the student's calendar updates within seconds, and they get a push notification.
7. At any point, the student can open a venue browser to see which rooms are free anywhere on campus, right now or at a chosen time — solving the "wandering around looking for an open room" problem.

## Success Criteria

*(Carried forward as a placeholder from the original design conversation — concrete numeric targets were not set during this design pass and should be defined before launch.)*

- Zero venue double-bookings caused by the system itself (the core promise of the app).
- A meaningful share of lectures in active cohorts show a confirmed (not just pending) attendance status ahead of their start time, indicating the confirmation-call feature is actually being used as intended.
- Students report checking the app instead of relying on WhatsApp/notice boards as their primary source of schedule truth.

## Constraints

- **Team**: solo developer for MVP, splitting work across a Flutter (mobile UI) repository and a Supabase-based backend repository (Postgres, RLS, Edge Functions, and related TypeScript).
- **Platform**: mobile only (iOS/Android via Flutter) — no web app in this phase.
- **Institutional dependency**: the university-email verification path relies on the `@student.chuka.ac.ke` domain; the registration-number path exists specifically to accommodate students without that email yet (e.g. incoming first-years).
- **Scale**: designed around a real but modest institutional size — roughly 5–10 Faculty Reps university-wide at MVP, which is why Faculty Rep onboarding is manual/out-of-band rather than self-service.

## Open Questions

- Exact numeric success metrics for a 3-month post-launch check-in haven't been defined yet.
- Password recovery for registration-number-only accounts (no email on file yet) is acknowledged as unresolved — several options were named (linking an email later, a personal recovery email, admin-assisted recovery, SMS) but none finalized.
- Whether a self-service join-code fallback will actually ship in a later phase, or stay permanently dormant in the schema.
- The precise cadence and anti-spam mechanism for the "call this lecturer" confirmation nudge (how far ahead of the lecture, and how to avoid repeatedly nagging about the same one) is still undesigned.
- Opting a single cohort out of an already-scheduled combined lecture is possible, but there's no equivalent mechanic yet for a cohort that wants to join an *already-scheduled* combined lecture after the fact.
