-- ============================================================================
-- 0036: Unclaimed synthetic-signup diagnostic (TODO 4.4, follow-up)
-- ============================================================================
-- `TODO.md` 4.4 flagged the registration-number-password signup path's real
-- risk: the client builds a synthetic `<reg_number>@auth.internal` address
-- with zero server-side validation (0002 §A), so a client-side transform bug
-- produces an account that's stuck exactly the way a wrong password would
-- look — no error, no log line, nothing to grep for. The decision recorded
-- there was NOT to add a server-side `synthetic_auth_email()` derivation —
-- an RPC makes the transform available, not verifiable, and the real fix is
-- a Flutter-side unit test this repo can't write.
--
-- What this repo CAN add: a way to notice after the fact, for whoever's
-- looking, rather than nothing at all. `unclaimed_synthetic_signups()`
-- surfaces every `@auth.internal` account that has sat unclaimed
-- (`users.reg_number is null`) for over an hour — the grace period exists
-- because signup and claim are two separate client round trips
-- (`auth.signUp` then `rpc('claim_roster_row', ...)`), so a brand-new signup
-- mid-flow is not yet a problem.
--
-- DELIBERATELY NOT NARROWED TO "did the transform actually fail" — that
-- would mean re-deriving the reg number from the email locally inside this
-- function, which is the exact second copy of the transform TODO 4.4
-- rejected creating. An unclaimed synthetic-signup account is the queryable
-- symptom regardless of root cause (transform bug, typo in the reg number at
-- claim time, or an abandoned signup) — all three are the same "someone is
-- stuck, go look" signal to whoever reads this.
--
-- READABLE BY ANY FACULTY REP, NOT SCOPED TO ONE FACULTY. An unclaimed
-- account has no cohort_id and no faculty_id — there is nothing to scope by,
-- the way `roster_placement_divergences()` scopes to the caller's own
-- faculty. Same shape as `confirmation_nudges_sent`'s read policy
-- (TECHNICAL_DISCOVERY §13.2): a diagnostic that needs a join belongs in a
-- SECURITY DEFINER function (auth.users isn't reachable any other way —
-- `authenticated` holds no privilege on it at all), and the only personal
-- data this exposes beyond what `users_read_all` already lets any signed-in
-- user read (the name) is the synthetic email itself.
-- ============================================================================

create function unclaimed_synthetic_signups()
returns table (
  user_id         uuid,
  full_name       text,
  synthetic_email text,
  signed_up_at    timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    u.id,
    trim(u.first_name || ' ' || coalesce(u.middle_name || ' ', '') || u.last_name),
    au.email,
    u.created_at
  from users u
  join auth.users au on au.id = u.id
  where u.reg_number is null
    and au.email like '%@auth.internal'
    and u.created_at < now() - interval '1 hour'
    and exists (
      select 1 from users me
      where me.id = auth.uid() and me.role = 'faculty_rep'
    )
  order by u.created_at;
$$;

comment on function unclaimed_synthetic_signups() is
  'Diagnostic for TODO 4.4 (0036): every @auth.internal account still '
  'unclaimed (reg_number is null) after a 1-hour grace period past signup. '
  'Does not re-derive or validate the email''s reg number — an unclaimed '
  'synthetic account is the symptom this surfaces regardless of cause. '
  'Faculty-rep readable, not scoped to one faculty (no cohort/faculty to '
  'scope an unclaimed account by).';

revoke execute on function unclaimed_synthetic_signups() from public, anon;
grant  execute on function unclaimed_synthetic_signups() to authenticated;
