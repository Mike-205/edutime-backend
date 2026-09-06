-- ============================================================================
-- 0033: Confirmation nudge job (3.2)
-- ============================================================================
-- Implements TODO §3.2. `0022` built the half of DISCOVERY's "even a correct
-- schedule doesn't tell you if the lecture will actually happen" problem that
-- RECORDS an outcome (confirm_attendance / unconfirm_attendance). Nothing
-- ever PROMPTED a rep to go make the call in the first place — the job only
-- worked if a rep independently remembered, which is the exact failure
-- DISCOVERY named ("an invisible, easily-forgotten task with no system
-- support"). This migration is the prompt.
--
-- ESCALATING TIERS, NOT ONE WINDOW. The original plan (TODO §3.2, before this
-- migration) was a single ~24h nudge, on the theory that DISCOVERY describes
-- the manual task as "the day before". In practice reps don't share one
-- habit: some call a day out, some call an hour out, some only act once
-- something looks wrong. A single fixed window serves the first group and
-- silently misses the rest. So this sends up to five nudges per event —
-- 24h, 12h, 5h, 1h, 30m out — each one independently idempotent.
--
-- WHY ESCALATION DOESN'T BECOME SPAM: every tier's query still filters on
-- attendance_status = 'pending'. The moment a rep confirms — at any tier —
-- every later tier's query stops matching that event, because it's no longer
-- pending. Nobody who has already acted gets nagged again; only an event
-- that's genuinely still unconfirmed keeps escalating. The tiers are a
-- reminder ladder, not a deadline — a rep who prefers calling an hour before
-- can see the 24h nudge land and still act on their own clock.
--
-- WHY A NEW TABLE INSTEAD OF THE `notifications` NOT-EXISTS CHECK. With one
-- window, "does a confirmation_needed row exist for this event" was enough
-- to make the job idempotent (TODO §3.2's original plan). With five tiers,
-- that check can no longer tell tiers apart — a 12h nudge would look like a
-- duplicate of the 24h one and never fire. `notifications` has no structured
-- metadata column to tag a tier onto (its columns are title/message/type
-- only), and adding one to serve a single caller would be exactly the
-- premature generalization TECHNICAL_DISCOVERY §12 warns against. A small
-- dedicated ledger — one row per (event, tier) once that tier has fired — is
-- the narrower fix.
--
-- ACCEPTED EDGE CASE: AN EVENT CREATED (OR FIRST SEEN PENDING) LESS THAN 24H
-- BEFORE START CAN FIRE SEVERAL TIERS IN ONE RUN. If an event's start time is
-- already inside more than one tier's window the first time this job sees
-- it — e.g. created 45 minutes before start, which is inside the 24h, 12h,
-- 5h and 1h windows simultaneously — all four fire together, because each
-- tier is judged independently against "has this tier fired yet", not
-- against "was a more urgent tier already sent". This is a burst, not a bug:
-- every one of those tiers genuinely never fired before, and the event
-- really is that close to unconfirmed. It is rare (most events are scheduled
-- well ahead) and left unhandled rather than adding a "supersede the less
-- urgent tiers" rule for a case this narrow.
--
-- RECIPIENTS: every attached cohort's class_rep, not just the initiator's —
-- same rule `confirm_attendance` (`0022`) already applies, via the same
-- `event_cohorts` join and the same `confirmation_status not in ('declined',
-- 'left')` exclusion. `notify_cohort_members`'s `p_role_filter` restricts to
-- 'class_rep' — DISCOVERY and `0004`'s comment both describe this as "the
-- class rep's" call to make; faculty_reps aren't looped in here.
--
-- SCHEDULING: `pg_cron`, running the plain function below every 15 minutes —
-- frequent enough to catch the tightest gap between tiers (1h -> 30m is only
-- 30 minutes apart) with margin, cheap enough that it doesn't matter: the
-- query is backed by `events_pending_confirmation_idx` (`0004`), built for
-- exactly this shape of read. The nudge logic itself is a plain SQL function
-- so it stays unit-testable in pgTAP the way `request_password_recovery`
-- (`0031`) is; `cron.schedule` below is a one-line, untestable registration
-- calling it, not where the logic lives.
-- ============================================================================


-- ============================================================================
-- 1. confirmation_nudges_sent — idempotency ledger, one row per (event, tier)
-- ============================================================================
create table confirmation_nudges_sent (
  event_id  uuid not null references events (id) on delete cascade,
  tier      text not null,
  sent_at   timestamptz not null default now(),
  primary key (event_id, tier)
);

comment on table confirmation_nudges_sent is
  'Idempotency ledger for send_confirmation_nudges (0033, TODO 3.2): one row '
  'per (event, tier) once that tier''s nudge has gone out, so the job can '
  're-run on the same window, or catch up after downtime, without '
  're-sending a tier already sent. Not a general notification-dedup '
  'mechanism; scoped to this one job.';

create index confirmation_nudges_sent_event_idx on confirmation_nudges_sent (event_id);

alter table confirmation_nudges_sent enable row level security;

-- Same shape as role_audit_log's policy (0022 §8): readable by faculty reps,
-- who are the people positioned to ask "why didn't my rep get nudged" during
-- a dispute — not narrowed to the rep's own faculty for the same reason
-- role_audit_log isn't (TECHNICAL_DISCOVERY §13.2: a policy that needs a join
-- belongs in a definer function, and this carries no personal data beyond an
-- event id and a tier label).
create policy confirmation_nudges_sent_read_faculty_rep
  on confirmation_nudges_sent
  for select
  to authenticated
  using (
    exists (select 1 from users u where u.id = auth.uid() and u.role = 'faculty_rep')
  );

-- Supabase's inherited default ACL grants TRUNCATE/REFERENCES/TRIGGER on every
-- new public table to anon and authenticated whether anyone asked for it or
-- not (0014 §4's comment has the exact ACL string). 0014 cleared this for the
-- original tables and every migration since has had to repeat it for its own
-- new ones (0017, 0022) — 00_access_control_test.sql fails if this is
-- forgotten, which is exactly what happened drafting this migration.
revoke all on confirmation_nudges_sent from anon, authenticated;
grant select on confirmation_nudges_sent to authenticated;
grant all    on confirmation_nudges_sent to service_role;


-- ============================================================================
-- 2. send_confirmation_nudges — the job itself
-- ============================================================================
create function send_confirmation_nudges()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tier      record;
  v_event     record;
  v_cohort_id uuid;
  v_message   text;
begin
  for v_tier in
    select * from (values
      ('24h', interval '24 hours', 'about a day'),
      ('12h', interval '12 hours', 'about 12 hours'),
      ('5h',  interval '5 hours',  'about 5 hours'),
      ('1h',  interval '1 hour',   'about an hour'),
      ('30m', interval '30 minutes', '30 minutes')
    ) as t(label, span, phrase)
    order by t.span desc
  loop
    for v_event in
      select e.id, e.title, e.lecturer_name
      from events e
      where e.status = 'scheduled'
        and e.attendance_status = 'pending'
        and e.start_time > now()
        and e.start_time <= now() + v_tier.span
        and not exists (
          select 1 from confirmation_nudges_sent cns
          where cns.event_id = e.id and cns.tier = v_tier.label
        )
    loop
      v_message := format(
        '%s is in %s and still unconfirmed - call %s to check they''re coming.',
        coalesce(v_event.title, 'Your lecture'), v_tier.phrase, v_event.lecturer_name
      );

      for v_cohort_id in
        select cohort_id from event_cohorts
        where event_id = v_event.id and confirmation_status not in ('declined', 'left')
      loop
        perform notify_cohort_members(
          v_cohort_id, v_event.id, 'confirmation_needed',
          'Confirm lecturer attendance', v_message, 'class_rep'
        );
      end loop;

      insert into confirmation_nudges_sent (event_id, tier) values (v_event.id, v_tier.label);
    end loop;
  end loop;
end;
$$;

comment on function send_confirmation_nudges() is
  'Scheduled by pg_cron every 15 minutes (see below). Finds scheduled, '
  'still-pending events crossing one of five reminder tiers (24h/12h/5h/1h/'
  '30m out) and writes a confirmation_needed notification to every attached '
  'cohort''s class_rep, once per (event, tier). Stops escalating the moment '
  'a rep confirms, because attendance_status leaving pending removes the '
  'event from every later tier''s query.';

-- Called only by pg_cron (as the migration-owning role); no client should
-- ever invoke this directly, so no execute grant for anon/authenticated.
revoke execute on function send_confirmation_nudges() from public, anon, authenticated;


-- ============================================================================
-- 3. pg_cron registration
-- ============================================================================
create extension if not exists pg_cron;

select cron.schedule(
  'send-confirmation-nudges',
  '*/15 * * * *',
  $$ select send_confirmation_nudges(); $$
);
