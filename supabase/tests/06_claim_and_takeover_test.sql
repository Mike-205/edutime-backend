-- ============================================================================
-- 06: Claiming an identity — bind, take over, dispute
-- ============================================================================
-- 0019. The roster (0017) declares who exists; this is how someone proves a row
-- is theirs.
--
-- The centrepiece is the squat-then-takeover sequence below, because it is the
-- one place this design deliberately accepts a hole rather than closing it. The
-- password branch cannot prove anything — there is no channel to verify against
-- — so a classmate genuinely CAN claim an unclaimed row. TODO §0.5 accepts that
-- on the grounds that a student account is read-only, so the harm is denying
-- someone their own account rather than a breach, and answers it with
-- detect-and-recover instead of prevention.
--
-- These tests assert BOTH halves of that bargain: that the squat succeeds, and
-- that it is worthless the moment the real owner signs in with the university
-- address that proves the identity.
--
-- Seeded people used here (all BSC-CS 2023). Lydia and Ruth are both real
-- Google OAuth signups since Task 1 (plan 5/5) converted every seed account —
-- this file's own fixture below resets their email/email_verified_at to null
-- to put them back on the "no email" footing this section relies on:
--   ...051 Lydia Chebet    no email (reset by this file) -> provisional only
--   ...052 Victor Onyango  eb1.67470.23@...  -> OAuth, derives EB1/67470/23
--   ...053 Ruth Nyaguthii  no email (reset by this file) -> provisional only
--   ...054 Ian Maina       no email, no roster row — used as a spare identity
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(30);


-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
create function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
end;
$$;

create function pg_temp.lydia()  returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000051'::uuid $$;
create function pg_temp.victor() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000052'::uuid $$;
create function pg_temp.ruth()   returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000053'::uuid $$;
create function pg_temp.ian()    returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000054'::uuid $$;
create function pg_temp.fst_rep()  returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000001'::uuid $$;
create function pg_temp.fhss_rep() returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000002'::uuid $$;
create function pg_temp.mercy()  returns uuid language sql immutable as
  $$ select '22222222-0000-4000-8000-000000000011'::uuid $$;   -- class rep, provisional

create function pg_temp.no_match() returns text language sql immutable as $$
  select 'We could not match those details. Check your registration number and full name with your class rep.'
$$;

create function pg_temp.cohort(p_code text, p_intake_year int) returns uuid language sql stable as $$
  select c.id from cohorts c join programmes p on p.id = c.programme_id
  where p.code = p_code and c.intake_year = p_intake_year and c.parent_cohort_id is null;
$$;


-- ---------------------------------------------------------------------------
-- Roster fixture
-- ---------------------------------------------------------------------------
-- student_roster is retired in Task 7 of this plan (AUTH_FLOW_REFACTOR.md /
-- plan 5/5) — until then, claim_roster_row and resolve_roster_dispute still
-- read it directly. seed.sql no longer builds any roster rows at all (Task 1
-- moved that data onto users' new identity columns instead), so this file
-- builds the minimal rows the functions under test need to find, keyed on
-- the same reg numbers/names the accounts above already carry.
--
-- Victor, Lydia and Ruth are unclaimed — matches the "no email" comment on
-- each of them above, and gives the squat/takeover/no-match cases something
-- real to match against. Mercy's row is deliberately 'provisional' (not the
-- 'oauth' her own users.claim_method now holds post-Task-1) because the
-- "class rep is never evicted automatically" case below specifically needs
-- an existing claim a verified OAuth claim COULD legally displace, so the
-- test reaches the scheduling-authority check rather than "already claimed".
insert into student_roster (
  reg_number, first_name, last_name, middle_name, cohort_id,
  claimed_by, claimed_at, claim_method
) values
  ('EB1/67470/23', 'Victor', 'Onyango',   null,     pg_temp.cohort('EB1', 2023), null, null, null),
  ('EB1/67455/23', 'Lydia',  'Chebet',    null,     pg_temp.cohort('EB1', 2023), null, null, null),
  ('EB1/67488/23', 'Ruth',   'Nyaguthii', null,     pg_temp.cohort('EB1', 2023), null, null, null),
  ('EB1/67277/23', 'Mercy',  'Wanjiku',   'Njeri',  pg_temp.cohort('EB1', 2023),
   pg_temp.mercy(), now(), 'provisional');

-- Lydia and Ruth are used below as the file's "no email" password-branch
-- squatter/claimants (see the header comment). Task 1's seed conversion made
-- both real Google OAuth signups, so both now carry a verified
-- users.email — Ruth's own (school) address, Lydia's own (personal) one.
-- claim_roster_row (0019) still keys its oauth/provisional split on that
-- exact generic pair, unconditionally on provider (0039's note: kept that
-- way deliberately, since this still-live function reads it) — so whichever
-- of them acts here would now either wrongly derive its OWN number instead
-- of squatting on someone else's (Ruth), or fail the derivation check with a
-- personal address that was never going to parse (Lydia), long before
-- reaching the claimed/unclaimed logic this file actually tests. Reset here
-- to recreate the "no verified email" premise both scenarios need.
update users set email = null, email_verified_at = null
where id in (pg_temp.lydia(), pg_temp.ruth());


-- ---------------------------------------------------------------------------
-- Deriving a registration number from a university address
-- ---------------------------------------------------------------------------
-- Note the direction. We never generate an address FROM a number — that would
-- let a derived string set email_verified_at. This reads an address a provider
-- already proved and works out which row it describes.
select is(
  reg_number_from_email('eb1.67470.23@student.chuka.ac.ke'), 'EB1/67470/23',
  'a student address describes exactly one registration number'
);

-- A lecturer or administrator address. Nobody in the seed holds one any more —
-- the faculty reps used to, before 2026-08-24 corrected them to the students
-- they actually are (TECHNICAL_DISCOVERY §10) — but the parse rule still has to
-- reject the parent domain, since a non-student mailbox describes no student.
select is(
  reg_number_from_email('j.mwangi@chuka.ac.ke'), null,
  'a staff address on the parent domain describes none'
);

select is(
  reg_number_from_email('j.doe@student.chuka.ac.ke'), null,
  'a valid student mailbox that is not reg-number shaped must not half-parse'
);

select is(
  reg_number_from_email('eb1.67455.23@auth.internal'), null,
  'the synthetic login address proves nothing and derives nothing'
);


-- ---------------------------------------------------------------------------
-- The squat — accepted, by design
-- ---------------------------------------------------------------------------
-- Ruth knows Victor's registration number and official name, because they are
-- classmates and both are printed on every attendance sheet they have ever
-- signed. On the password branch there is nothing to stop her.
select pg_temp.act_as(pg_temp.ruth());

select lives_ok(
  format($$ select claim_roster_row('EB1/67470/23','Victor','Onyango',%L::uuid) $$,
         pg_temp.ruth()),
  'a classmate CAN claim an unclaimed row on the password branch — this is the known hole'
);

select is(
  (select claim_method::text from student_roster where reg_number = 'EB1/67470/23'),
  'provisional',
  '...and the claim is marked provisional, which is what makes it reversible'
);

select is(
  (select reg_number from users where id = pg_temp.ruth()), 'EB1/67470/23',
  '...and it really does bind — the squatter holds the identity until challenged'
);


-- ---------------------------------------------------------------------------
-- ...and the takeover that makes it worthless
-- ---------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.victor());

select lives_ok(
  format($$ select claim_roster_row('EB1/67470/23','Victor','Onyango',%L::uuid) $$,
         pg_temp.victor()),
  'the real owner signing in with the university email takes the identity back'
);

select is(
  (select claimed_by from student_roster where reg_number = 'EB1/67470/23'),
  pg_temp.victor(),
  'the roster row rebinds to the provider-proven account'
);

select is(
  (select claim_method::text from student_roster where reg_number = 'EB1/67470/23'),
  'oauth',
  '...and is upgraded to oauth, which nothing else can displace'
);

select ok(
  (select reg_number is null and cohort_id is null from users where id = pg_temp.ruth()),
  'the squatter goes inert — no registration number, no cohort, so nothing is visible'
);

select is(
  (select count(*)::int from notifications
    where user_id = pg_temp.ruth() and type = 'account_taken_over'), 1,
  'the evicted account is told why the app went empty'
);

select is(
  (select count(*)::int from identity_audit_log
    where reg_number = 'EB1/67470/23' and action = 'takeover'), 1,
  'the takeover is on the audit trail'
);


-- ---------------------------------------------------------------------------
-- One account, one identity
-- ---------------------------------------------------------------------------
select is(
  (select claim_roster_row('EB1/67470/23','Victor','Onyango', pg_temp.victor())),
  (select id from student_roster where reg_number = 'EB1/67470/23'),
  're-claiming the same row is idempotent, not an error'
);

select throws_ok(
  format($$ select claim_roster_row('EB1/67455/23','Lydia','Chebet',%L::uuid) $$,
         pg_temp.victor()),
  'P0001',
  'This account has already claimed a different identity',
  'one account cannot collect a second identity'
);


-- ---------------------------------------------------------------------------
-- THE RULE: the OAuth address must match the number typed
-- ---------------------------------------------------------------------------
-- Without this check the roster is decorative — anyone could type a
-- classmate's number and then authenticate with their own Google account.
update users
set email = 'eb1.67488.23@student.chuka.ac.ke', email_verified_at = now()
where id = pg_temp.ian();

select pg_temp.act_as(pg_temp.ian());
select throws_ok(
  format($$ select claim_roster_row('EB1/67455/23','Lydia','Chebet',%L::uuid) $$,
         pg_temp.ian()),
  'P0001',
  'This university account does not belong to registration number EB1/67455/23',
  'a verified account cannot claim a row its own address does not describe'
);


-- ---------------------------------------------------------------------------
-- Failures say one thing and one thing only
-- ---------------------------------------------------------------------------
-- Distinguishing "no such number" from "wrong name" would turn this into an
-- oracle for probing the roster — and the roster is exactly the name+number
-- pairs an attacker needs.
select pg_temp.act_as(pg_temp.lydia());

select throws_ok(
  format($$ select claim_roster_row('EB1/67455/23','Wrong','Name',%L::uuid) $$,
         pg_temp.lydia()),
  'P0001',
  pg_temp.no_match(),
  'a wrong name gives the generic message'
);

select throws_ok(
  format($$ select claim_roster_row('EB1/00000/23','Wrong','Name',%L::uuid) $$,
         pg_temp.lydia()),
  'P0001',
  pg_temp.no_match(),
  '...and an unknown registration number gives the IDENTICAL message'
);


-- ---------------------------------------------------------------------------
-- What cannot displace what
-- ---------------------------------------------------------------------------
select lives_ok(
  format($$ select claim_roster_row('EB1/67455/23','Lydia','Chebet',%L::uuid) $$,
         pg_temp.lydia()),
  'Lydia claims her own row on the password branch'
);

select pg_temp.act_as(pg_temp.ruth());
select throws_ok(
  format($$ select claim_roster_row('EB1/67455/23','Lydia','Chebet',%L::uuid) $$,
         pg_temp.ruth()),
  'P0001',
  'That identity has already been claimed',
  'provisional cannot displace provisional — otherwise the row just ping-pongs'
);

select throws_ok(
  format($$ select claim_roster_row('EB1/67470/23','Victor','Onyango',%L::uuid) $$,
         pg_temp.ruth()),
  'P0001',
  'That identity has already been claimed',
  'nothing displaces a provider-proven claim'
);


-- ---------------------------------------------------------------------------
-- A class rep is never evicted automatically
-- ---------------------------------------------------------------------------
-- Mercy holds EB1/67277/23 provisionally AND is the class rep of BSC-CS 2023.
-- Auto-evicting her would strip a cohort's scheduling authority mid-semester,
-- on a signup event, with no human in the loop.
update users
set email = 'eb1.67277.23@student.chuka.ac.ke', email_verified_at = now()
where id = pg_temp.ian();

select pg_temp.act_as(pg_temp.ian());
select throws_ok(
  format($$ select claim_roster_row('EB1/67277/23','Mercy','Wanjiku',%L::uuid) $$,
         pg_temp.ian()),
  'P0001',
  'That identity is held by an account with scheduling authority. A faculty rep must resolve this.',
  'a takeover that would unseat a class rep escalates to a human instead'
);


-- ---------------------------------------------------------------------------
-- Dispute resolution — the manual override
-- ---------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.lydia());
select throws_ok(
  format($$ select resolve_roster_dispute(
              (select id from student_roster where reg_number = 'EB1/67470/23'), %L::uuid) $$,
         pg_temp.lydia()),
  'P0001',
  'Only a faculty_rep may resolve an identity dispute',
  'a student cannot unbind anyone, least of all themselves'
);

select pg_temp.act_as(pg_temp.fhss_rep());
select throws_ok(
  format($$ select resolve_roster_dispute(
              (select id from student_roster where reg_number = 'EB1/67470/23'), %L::uuid) $$,
         pg_temp.fhss_rep()),
  'P0001',
  null,
  'a faculty rep cannot reach into another faculty''s roster'
);

select pg_temp.act_as(pg_temp.fst_rep());
select throws_ok(
  format($$ select resolve_roster_dispute(
              (select id from student_roster where reg_number = 'EB1/67488/23'), %L::uuid) $$,
         pg_temp.fst_rep()),
  'P0001',
  null,
  'there is nothing to resolve on an unclaimed row'
);

select lives_ok(
  format($$ select resolve_roster_dispute(
              (select id from student_roster where reg_number = 'EB1/67470/23'), %L::uuid) $$,
         pg_temp.fst_rep()),
  'the faculty rep for that cohort can sever a claimed identity'
);

select ok(
  (select claimed_by is null and claim_method is null
     from student_roster where reg_number = 'EB1/67470/23'),
  '...the row is freed for a fresh claim rather than deleted'
);

select ok(
  (select reg_number is null and cohort_id is null from users where id = pg_temp.victor()),
  '...and the account it was severed from goes inert'
);

select is(
  (select count(*)::int from identity_audit_log
    where reg_number = 'EB1/67470/23' and action = 'dispute_resolved'), 1,
  '...with an audit row, because an unlogged manual override would be the most '
  'dangerous function in this schema'
);


-- ---------------------------------------------------------------------------
-- The hole Phase R actually exists to close
-- ---------------------------------------------------------------------------
-- handle_new_auth_user used to copy raw_user_meta_data ->> 'reg_number' straight
-- into the column the entire trust model rests on.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, email_change,
  email_change_token_new, recovery_token
)
values (
  '00000000-0000-0000-0000-000000000000',
  '22222222-0000-4000-8000-0000000000ff', 'authenticated', 'authenticated',
  'impostor@auth.internal', 'x', now(), now(),
  jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
  jsonb_build_object('first_name', 'Imp', 'last_name', 'Ostor',
                     'reg_number', 'EB1/67277/23'),
  now(), now(), '', '', '', ''
);

select ok(
  (select reg_number is null and cohort_id is null
     from users where id = '22222222-0000-4000-8000-0000000000ff'),
  'a brand-new account gets NO registration number, however loudly the client asserts one'
);


select * from finish();
rollback;
