-- ============================================================================
-- 19: handle_new_auth_user learns the school/personal email split (0039)
-- ============================================================================
-- Covers three signup shapes: the still-live password/synthetic path (old
-- columns unaffected, new columns untouched), an OAuth signup with a real
-- school address (both old AND new columns populate — old because
-- claim_roster_row still reads them until Plan 5 retires the roster), and an
-- OAuth signup with a personal address (old columns populate as before, new
-- personal_email columns populate, school_email columns stay null).
-- ============================================================================
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(11);


-- ---------------------------------------------------------------------------
-- (a) Password/synthetic signup — unaffected
-- ---------------------------------------------------------------------------
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, email_change,
  email_change_token_new, recovery_token
)
values (
  '00000000-0000-0000-0000-000000000000',
  '44444444-0000-4000-8000-000000000001', 'authenticated', 'authenticated',
  'password.case@auth.internal', 'x', now(), now(),
  jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
  jsonb_build_object('first_name', 'Password', 'last_name', 'Case'),
  now(), now(), '', '', '', ''
);

select is(
  (select email from users where id = '44444444-0000-4000-8000-000000000001'),
  null, 'password/synthetic signup: email stays null, exactly as before'
);
select is(
  (select school_email from users where id = '44444444-0000-4000-8000-000000000001'),
  null, 'password/synthetic signup: school_email stays null'
);
select is(
  (select personal_email from users where id = '44444444-0000-4000-8000-000000000001'),
  null, 'password/synthetic signup: personal_email stays null'
);


-- ---------------------------------------------------------------------------
-- (b) OAuth signup, school address
-- ---------------------------------------------------------------------------
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, email_change,
  email_change_token_new, recovery_token
)
values (
  '00000000-0000-0000-0000-000000000000',
  '44444444-0000-4000-8000-000000000002', 'authenticated', 'authenticated',
  'eb1.88888.26@student.chuka.ac.ke', 'x', now(), now(),
  jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
  jsonb_build_object('first_name', 'School', 'last_name', 'Address'),
  now(), now(), '', '', '', ''
);

select is(
  (select email from users where id = '44444444-0000-4000-8000-000000000002'),
  'eb1.88888.26@student.chuka.ac.ke',
  'OAuth school-address signup: email still populates — claim_roster_row still reads it'
);
select is(
  (select school_email from users where id = '44444444-0000-4000-8000-000000000002'),
  'eb1.88888.26@student.chuka.ac.ke',
  'OAuth school-address signup: school_email populates'
);
select isnt(
  (select school_email_verified_at from users where id = '44444444-0000-4000-8000-000000000002'),
  null, 'OAuth school-address signup: school_email_verified_at is set'
);
select is(
  (select personal_email from users where id = '44444444-0000-4000-8000-000000000002'),
  null, 'OAuth school-address signup: personal_email stays null'
);


-- ---------------------------------------------------------------------------
-- (c) OAuth signup, personal address
-- ---------------------------------------------------------------------------
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, confirmation_token, email_change,
  email_change_token_new, recovery_token
)
values (
  '00000000-0000-0000-0000-000000000000',
  '44444444-0000-4000-8000-000000000003', 'authenticated', 'authenticated',
  'someone.new@gmail.com', 'x', now(), now(),
  jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
  jsonb_build_object('first_name', 'Personal', 'last_name', 'Address'),
  now(), now(), '', '', '', ''
);

select is(
  (select email from users where id = '44444444-0000-4000-8000-000000000003'),
  'someone.new@gmail.com',
  'OAuth personal-address signup: email still populates, same as before this migration'
);
select is(
  (select personal_email from users where id = '44444444-0000-4000-8000-000000000003'),
  'someone.new@gmail.com',
  'OAuth personal-address signup: personal_email populates'
);
select isnt(
  (select personal_email_verified_at from users where id = '44444444-0000-4000-8000-000000000003'),
  null, 'OAuth personal-address signup: personal_email_verified_at is set'
);
select is(
  (select school_email from users where id = '44444444-0000-4000-8000-000000000003'),
  null, 'OAuth personal-address signup: school_email stays null'
);

select * from finish();
rollback;
