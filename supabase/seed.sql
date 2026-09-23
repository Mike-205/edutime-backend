-- ============================================================================
-- seed.sql — Chuka University development dataset
-- ============================================================================
-- Run by `supabase db reset` (see [db.seed] in config.toml). Not idempotent:
-- it assumes an empty database and will fail on a second run. That is
-- deliberate — reset is the only supported way to reseed.
--
-- WHAT IS REAL AND WHAT IS NOT
--   Real, supplied by the project owner: faculty and department names,
--   programme names and their internal codes (EB1, BA2, ...), the unit lists
--   per programme, building names/abbreviations, room numbering, the 3-hour
--   lecture slots, and the teaching-staff names used as `lecturer_name`.
--   Invented: programme `abbreviation` values (the real ones were not
--   available), all STUDENT AND CLASS-REP identities and registration numbers,
--   every email address, room capacities, and the semester each unit is taught
--   in. Nothing here should be mistaken for real student data.
--
-- HOW IT SEEDS
--   Reference data (faculties -> venues) goes in by direct INSERT, which is the
--   Superadmin path: §10 of TECHNICAL_DISCOVERY says reference data is
--   superadmin-seeded and bypasses RLS.
--
--   Cohorts, join-request decisions and every event instead go through the real
--   SECURITY DEFINER functions, with `request.jwt.claims` set so auth.uid()
--   returns the acting rep. That costs a little readability and buys a lot:
--   the seed exercises create_cohort_with_class_rep's faculty scoping,
--   create_event's proposal branch and recurrence materialization,
--   confirm_event_cohort, confirm_attendance, promote_class_rep,
--   reschedule_event's 0013 ordering fix and cancel_event — and it produces
--   genuine event_audit_log and notifications rows instead of a hand-faked
--   approximation of them. If a function is broken, `db reset` says so.
--
-- WHAT THIS SEED CANNOT DO (and why the gaps are visible in the data)
--   * Nothing dispatches the notifications rows to a device. Push delivery is
--     TODO §3.1 and needs an Edge Function that does not exist yet, so the
--     notifications table fills up correctly and silently.
--
--   Three long-standing gaps CLOSED by 0022, listed because the shape of this
--   file changed with them:
--   * Attendance is no longer permanently 'pending' — §11 confirms one lecture
--     through confirm_attendance, so the dashboard has something in it.
--   * One BSC-CS 2024 unit is now a real materialized weekly SERIES rather than
--     a hand-listed occurrence. How many rows it produces depends on the date
--     you reset (the horizon is the cohort's term end), which is the correct
--     behaviour and worth knowing before you diff two seeded databases.
--   * Assistant class reps go through promote_class_rep instead of a direct
--     UPDATE as postgres.
--
-- Login for every seeded account: password `chuka1234`.
--   Reg-number accounts sign in with the synthetic address, e.g.
--     eb1.67277.23@auth.internal
--   OAuth-path accounts use their university address, e.g.
--     eb1.67312.23@student.chuka.ac.ke
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. Seed-only helpers (dropped at the bottom of this file)
-- ----------------------------------------------------------------------------
-- These exist so the data below reads as data. They are removed at the end so
-- they can never be mistaken for part of the application's API surface.

-- Creates an auth.users row and lets 0002's on_auth_user_created trigger build
-- the public.users profile from raw_user_meta_data — i.e. the same path a real
-- signup takes, rather than writing public.users directly.
create or replace function seed_user(
  p_id          uuid,
  p_login_email text,
  p_first       text,
  p_last        text,
  p_middle      text,
  p_reg_number  text,
  p_provider    text   -- 'email' = reg-number path A, 'google' = OAuth path B
)
returns uuid
language plpgsql
as $$
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, last_sign_in_at,
    raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  )
  values (
    '00000000-0000-0000-0000-000000000000',
    p_id, 'authenticated', 'authenticated',
    p_login_email,
    extensions.crypt('chuka1234', extensions.gen_salt('bf')),
    now(), now(),
    jsonb_build_object('provider', p_provider, 'providers', jsonb_build_array(p_provider)),
    jsonb_strip_nulls(jsonb_build_object(
      'first_name',  p_first,
      'last_name',   p_last,
      'middle_name', p_middle,
      'reg_number',  p_reg_number
    )),
    now(), now(),
    '', '', '', ''
  );

  -- The identity is always recorded as 'email' even for the OAuth-path accounts,
  -- so every seeded account can sign in with a password in local development.
  -- raw_app_meta_data.provider above still says 'google' for those, and that is
  -- the field 0002's sync trigger reads to decide whether the address is already
  -- verified — so the two signup paths stay distinguishable in public.users
  -- while both remain loginable here. A real Google signup would have a 'google'
  -- identity and no password at all.
  insert into auth.identities (
    id, user_id, provider_id, identity_data, provider,
    last_sign_in_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), p_id, p_id::text,
    jsonb_build_object(
      'sub', p_id::text, 'email', p_login_email,
      'email_verified', true, 'phone_verified', false
    ),
    'email', now(), now(), now()
  );

  -- 0019 stopped the auth trigger copying reg_number out of raw_user_meta_data
  -- — that client-asserted field was the hole Phase R exists to close, so the
  -- trigger now leaves it null and only claim_roster_row() may set it.
  --
  -- The seed writes it directly instead, as postgres. That is the Superadmin
  -- path, the same one §9 already uses to drop students into their cohorts, and
  -- it is legitimate here for the same reason: this file IS the institution,
  -- fabricating a starting state rather than pretending to be a signup.
  --
  -- §9.5 below then builds the roster from these rows and marks them claimed,
  -- so the dev dataset ends up in the state a real intake would produce.
  update public.users set reg_number = p_reg_number where id = p_id;

  return p_id;
end;
$$;

-- Makes auth.uid() return p_user for the rest of the enclosing transaction, so
-- the privileged functions can be called as a real rep. is_local = true, so
-- every caller must be inside a DO block or an explicit transaction — the
-- impersonation then unwinds on its own.
create or replace function seed_act_as(p_user uuid)
returns void
language plpgsql
as $$
begin
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text,
    true
  );
end;
$$;

create or replace function seed_course(p_prog_code text, p_abbr text)
returns uuid language sql stable as $$
  select c.id
  from courses c
  join programmes p on p.id = c.programme_id
  where p.code = p_prog_code and c.abbreviation = p_abbr;
$$;

create or replace function seed_venue(p_building text, p_room text)
returns uuid language sql stable as $$
  select v.id
  from venues v
  join rooms r     on r.id = v.room_id
  join buildings b on b.id = r.building_id
  where b.abbreviation = p_building and r.number = p_room;
$$;

create or replace function seed_cohort(p_prog_code text, p_intake_year int)
returns uuid language sql stable as $$
  select c.id from cohorts c join programmes p on p.id = c.programme_id
  where p.code = p_prog_code and c.intake_year = p_intake_year;
$$;

-- One create_event attachment: which cohort attends, and as which unit. Returns
-- a single-element jsonb array so several can be concatenated with `||` for a
-- combined lecture:
--
--   seed_att('EB1', 2023,'CNDS') || seed_att('EB3', 2023,'AIML')
--
-- which is the whole point of 0021/0022's per-cohort course: one lecture, one
-- room, one lecturer, and each cohort seeing the unit from its OWN programme.
create or replace function seed_att(p_prog_code text, p_intake_year int, p_course_abbr text)
returns jsonb language sql stable as $$
  select jsonb_build_array(jsonb_build_object(
    'cohort_id', seed_cohort(p_prog_code, p_intake_year),
    'course_id', seed_course(p_prog_code, p_course_abbr)
  ));
$$;

-- Timetable anchor. Day 1 = Monday of NEXT week, in Africa/Nairobi, so every
-- seeded lecture is always in the future no matter which day you reset on
-- (anchoring to the current week puts the whole timetable in the past when you
-- happen to reset on a Saturday or Sunday).
create or replace function seed_slot(p_day int, p_hour int)
returns timestamptz language sql stable as $$
  select (
    date_trunc('week', (now() at time zone 'Africa/Nairobi'))
      + interval '7 days'
      + make_interval(days => p_day - 1, hours => p_hour)
  ) at time zone 'Africa/Nairobi';
$$;


-- ============================================================================
-- 1. Faculties
-- ============================================================================
insert into faculties (id, name, abbreviation, description) values
  ('aaaaaaaa-0000-4000-8000-000000000001',
   'Faculty of Science and Technology', 'FST',
   'Physical, biological and computing sciences.'),
  ('aaaaaaaa-0000-4000-8000-000000000002',
   'Faculty of Humanities and Social Sciences', 'FHSS',
   'Humanities, social sciences and communication.');


-- ============================================================================
-- 2. Departments
-- ============================================================================
insert into departments (id, faculty_id, name) values
  ('bbbbbbbb-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000001', 'Physical Sciences'),
  ('bbbbbbbb-0000-4000-8000-000000000002', 'aaaaaaaa-0000-4000-8000-000000000001', 'Biological Sciences'),
  ('bbbbbbbb-0000-4000-8000-000000000003', 'aaaaaaaa-0000-4000-8000-000000000001', 'Computer Science'),
  ('bbbbbbbb-0000-4000-8000-000000000004', 'aaaaaaaa-0000-4000-8000-000000000002', 'Humanities'),
  ('bbbbbbbb-0000-4000-8000-000000000005', 'aaaaaaaa-0000-4000-8000-000000000002', 'Social Sciences');


-- ============================================================================
-- 3. Programmes
-- ============================================================================
-- `code` is the internal programme code that prefixes a registration number
-- (EB1/67277/23). Per 0001, the self-sponsored variant is NOT a separate row:
-- EB1 government-sponsored and EB1S self-sponsored share this one programme
-- and differ only in the pace their cohorts run at.
--
-- `abbreviation` is invented — Chuka's official short forms were not available.
-- It is load-bearing: create_cohort_with_class_rep composes a cohort's name as
-- `abbreviation || ' ' || intake_year`, so changing one renames its cohorts.
--
-- duration_semesters is 8 for every bachelor's degree except Electrical &
-- Electronics Engineering, which runs five years.
insert into programmes (department_id, name, abbreviation, code, level, duration_semesters)
select d.id, p.name, p.abbr, p.code, 'degree'::programme_level, p.sems
from (values
  -- Computer Science ---------------------------------------------------------
  ('Computer Science',  'Bachelor of Science in Computer Science',                    'BSC-CS',   'EB1',  8),
  ('Computer Science',  'Bachelor of Science in Applied Computer Science',            'BSC-ACS',  'EB3',  8),
  ('Computer Science',  'Bachelor of Science in Business Information Technology',     'BSC-BIT',  'EB11', 8),
  -- Physical Sciences -------------------------------------------------------
  ('Physical Sciences', 'Bachelor of Science (General)',                              'BSC-GEN',  'EB2',  8),
  ('Physical Sciences', 'Bachelor of Science in Mathematics',                         'BSC-MATH', 'EB6',  8),
  ('Physical Sciences', 'Bachelor of Science in Physics',                             'BSC-PHY',  'EB7',  8),
  ('Physical Sciences', 'Bachelor of Science in Chemistry / Industrial Chemistry',    'BSC-CHEM', 'EB8',  8),
  ('Physical Sciences', 'Bachelor of Science in Actuarial Science',                   'BSC-ACT',  'EB9',  8),
  ('Physical Sciences', 'Bachelor of Science in Applied Statistics',                  'BSC-STAT', 'EB10', 8),
  ('Physical Sciences', 'Bachelor of Science in Electrical & Electronics Engineering','BSC-EEE',  'EB12', 10),
  -- Biological Sciences -----------------------------------------------------
  ('Biological Sciences', 'Bachelor of Science in Biochemistry',                      'BSC-BCHM', 'EB4',  8),
  ('Biological Sciences', 'Bachelor of Science in Biomedical Science & Technology',   'BSC-BMST', 'EB5',  8),
  ('Biological Sciences', 'Bachelor of Science in Biology',                           'BSC-BIO',  'EB13', 8),
  ('Biological Sciences', 'Bachelor of Science in Microbiology & Biotechnology',      'BSC-MBB',  'EB14', 8),
  ('Biological Sciences', 'Bachelor of Science in Fisheries & Aquaculture',           'BSC-FAQ',  'EB15', 8),
  -- Social Sciences ---------------------------------------------------------
  ('Social Sciences', 'Bachelor of Arts (General)',                                   'BA-GEN',   'BA1',  8),
  ('Social Sciences', 'Bachelor of Arts in Criminology & Security Studies',           'BA-CRIM',  'BA2',  8),
  ('Social Sciences', 'Bachelor of Arts in Economics & Sociology',                    'BA-ECSO',  'BA3',  8),
  ('Social Sciences', 'Bachelor of Science in Economics & Statistics',                'BSC-ECST', 'BA4',  8),
  ('Social Sciences', 'Bachelor of Science in Community Development',                 'BSC-CD',   'BA5',  8),
  ('Social Sciences', 'Bachelor of Psychology',                                       'BPSY',     'BA6',  8),
  ('Social Sciences', 'Bachelor of Arts in Geography & Economics',                    'BA-GEOE',  'BA7',  8),
  ('Social Sciences', 'Bachelor of Arts in Project Planning & Management',            'BA-PPM',   'BA13', 8),
  ('Social Sciences', 'Bachelor in Government & International Relations',             'BGIR',     'BA14', 8),
  -- Humanities --------------------------------------------------------------
  ('Humanities', 'Bachelor of Arts in Journalism & Mass Communication',               'BA-JMC',   'BA8',  8),
  ('Humanities', 'Bachelor of Arts in Kiswahili & Mass Communication',                'BA-KMC',   'BA9',  8),
  ('Humanities', 'Bachelor of Science in Information Science',                         'BSC-IS',   'BA10', 8),
  ('Humanities', 'Bachelor of Arts in History & Economics',                           'BA-HE',    'BA11', 8),
  ('Humanities', 'Bachelor of Arts in Philosophy',                                    'BA-PHIL',  'BA12', 8),
  ('Humanities', 'Bachelor of Arts in Linguistics & Literature',                      'BA-LL',    'BA15', 8),
  ('Humanities', 'Bachelor of Arts in Religious Studies',                             'BA-RS',    'BA16', 8)
) as p(dept, name, abbr, code, sems)
join departments d on d.name = p.dept;


-- ============================================================================
-- 4. Courses (units)
-- ============================================================================
-- Only the eleven programmes with a supplied unit list are populated; the other
-- twenty exist so registration-number parsing and the cohort picker have real
-- programmes to resolve against, and get units when someone needs them.
--
-- semester_taught is INVENTED — the lists arrived unsequenced. Units are laid
-- out so that each programme with a seeded cohort has 2-3 units in that
-- cohort's current semester, which is what a real 3-hour-slot timetable looks
-- like (one unit meets two or three times a week, it does not get one lecture).
-- Every unit is 3 lecture hours and 3 credits, matching the default slot.
insert into courses (programme_id, name, abbreviation, semester_taught, lecture_hours, credits)
select p.id, c.name, c.abbr, c.sem, 3, 3
from (values
  -- EB1  B.Sc. Computer Science ----------------------------------------------
  ('EB1',  'Structured Programming & C / C++',                  'SPC',   1),
  ('EB1',  'Data Structures and Algorithms',                    'DSA',   2),
  ('EB1',  'Object-Oriented Programming (Java / Python)',       'OOP',   3),
  ('EB1',  'Operating Systems & System Architecture',           'OSSA',  4),
  ('EB1',  'Database Management Systems (SQL)',                 'DBMS',  5),
  ('EB1',  'Software Engineering & System Analysis',            'SESA',  5),
  ('EB1',  'Computer Networks & Distributed Systems',           'CNDS',  5),
  -- EB3  B.Sc. Applied Computer Science --------------------------------------
  ('EB3',  'Web Application Development',                       'WEBD',  3),
  ('EB3',  'Mobile Application Development (Android / Flutter)','MOBD',  4),
  ('EB3',  'Artificial Intelligence & Machine Learning',        'AIML',  5),
  ('EB3',  'Cybersecurity & Network Defense',                   'CSND',  5),
  ('EB3',  'Cloud Computing & DevOps',                          'CCDO',  5),
  ('EB3',  'Data Mining & Business Intelligence',               'DMBI',  6),
  -- EB6  B.Sc. Mathematics ---------------------------------------------------
  ('EB6',  'Calculus I, II & Multivariable',                    'CALC',  1),
  ('EB6',  'Linear Algebra & Abstract Algebra',                 'ALG',   2),
  ('EB6',  'Differential Equations (Ordinary & Partial)',       'DE',    3),
  ('EB6',  'Real Analysis & Complex Analysis',                  'ANAL',  4),
  ('EB6',  'Numerical Analysis & Mathematical Modelling',       'NAMM',  5),
  -- EB8  B.Sc. Chemistry / Industrial Chemistry ------------------------------
  ('EB8',  'General Inorganic & Organic Chemistry',             'GIOC',  1),
  ('EB8',  'Physical Chemistry & Thermodynamics',               'PCT',   2),
  ('EB8',  'Analytical Chemistry & Spectroscopy',               'ACS',   3),
  ('EB8',  'Chemical Kinetics & Surface Chemistry',             'CKSC',  4),
  ('EB8',  'Industrial Chemical Processes & Polymer Chemistry', 'ICPP',  5),
  -- EB12 B.Sc. Electrical & Electronics Engineering --------------------------
  ('EB12', 'Circuit Theory & Electrical Measurements',          'CTEM',  1),
  ('EB12', 'Electromagnetic Fields & Waves',                    'EMFW',  2),
  ('EB12', 'Digital Electronics & Microprocessors',             'DEM',   3),
  ('EB12', 'Control Engineering & Signal Processing',           'CESP',  4),
  ('EB12', 'Power Systems & Energy Conversion',                 'PSEC',  5),
  -- EB4  B.Sc. Biochemistry --------------------------------------------------
  ('EB4',  'Biomolecules & Enzymology',                         'BENZ',  1),
  ('EB4',  'Metabolism of Carbohydrates, Lipids & Proteins',    'MCLP',  2),
  ('EB4',  'Molecular Biology & Recombinant DNA',               'MBRD',  3),
  ('EB4',  'Clinical Biochemistry & Endocrinology',             'CBE',   4),
  ('EB4',  'Immunology & Biochemical Pharmacology',             'IBP',   5),
  -- EB14 B.Sc. Microbiology & Biotechnology ----------------------------------
  ('EB14', 'General Microbiology & Mycology',                   'GMM',   1),
  ('EB14', 'Environmental & Industrial Microbiology',           'EIM',   2),
  ('EB14', 'Microbial Genetics & Genomics',                     'MGG',   3),
  ('EB14', 'Plant & Animal Biotechnology',                      'PAB',   4),
  ('EB14', 'Food & Fermentation Technology',                    'FFT',   5),
  -- EB5  B.Sc. Biomedical Science & Technology -------------------------------
  ('EB5',  'Human Anatomy & Physiology',                        'HAP',   1),
  ('EB5',  'Medical Parasitology & Vector Biology',             'MPVB',  2),
  ('EB5',  'Pathology & Histology',                             'PATH',  3),
  ('EB5',  'Medical Virology & Bacteriology',                   'MVB',   4),
  ('EB5',  'Hematology & Transfusion Science',                  'HTS',   5),
  -- BA2  B.A. Criminology & Security Studies ---------------------------------
  ('BA2',  'Introduction to Criminological Theories',           'ICT',   1),
  ('BA2',  'Criminal Law, Procedures & Evidence',               'CLPE',  2),
  ('BA2',  'Crime Prevention & Community Policing',             'CPCP',  3),
  ('BA2',  'Forensics & Crime Scene Investigation',             'FCSI',  3),
  ('BA2',  'Cybercrime & Security Management',                  'CSM',   4),
  ('BA2',  'Penology & Correctional Systems',                   'PCS',   5),
  -- BA3  B.A. Economics & Sociology ------------------------------------------
  ('BA3',  'Microeconomics & Macroeconomics',                   'MICM',  1),
  ('BA3',  'Sociological Theories & Thought',                   'STT',   2),
  ('BA3',  'Social Research Methods & Statistics',              'SRMS',  3),
  ('BA3',  'Social Change & Economic Development',              'SCED',  4),
  ('BA3',  'Public Finance & Monetary Economics',               'PFME',  5),
  -- BA5  B.Sc. Community Development -----------------------------------------
  ('BA5',  'Principles of Community Mobilization',              'PCM',   1),
  ('BA5',  'Project Planning, Management & Evaluation',         'PPME',  2),
  ('BA5',  'Gender, Poverty & Sustainable Development',         'GPSD',  3),
  ('BA5',  'Resource Mobilization & NGO Management',            'RMNM',  4),
  ('BA5',  'Conflict Resolution & Peace Building',              'CRPB',  5),
  -- BA8  B.A. Journalism & Mass Communication --------------------------------
  ('BA8',  'Introduction to Mass Communication',                'IMC',   1),
  ('BA8',  'News Writing & Reporting',                          'NWR',   2),
  ('BA8',  'Media Law & Ethics',                                'MLE',   3),
  ('BA8',  'Digital Media & Multimedia Production',             'DMMP',  4),
  ('BA8',  'Broadcast Journalism (Radio & TV)',                 'BJRT',  5),
  ('BA8',  'Public Relations & Corporate Communication',        'PRCC',  6),
  -- BA15 B.A. Linguistics & Literature ---------------------------------------
  ('BA15', 'Phonetics, Phonology & Morphology',                 'PPM',   1),
  ('BA15', 'Syntax & Semantics',                                'SYNS',  2),
  ('BA15', 'Sociolinguistics & Language Acquisition',           'SLA',   3),
  ('BA15', 'African Literature & Oral Traditions',              'ALOT',  4),
  ('BA15', 'Literary Criticism & Theory',                       'LCT',   5),
  -- BA10 B.Sc. Information Science -------------------------------------------
  ('BA10', 'Information Organization & Cataloguing',            'IOC',   1),
  ('BA10', 'Archival Management & Records Management',          'ARM',   2),
  ('BA10', 'Knowledge Management Systems',                      'KMS',   3),
  ('BA10', 'Information Retrieval & Digital Libraries',         'IRDL',  4),
  ('BA10', 'Publishing & Desktop Publishing',                   'PDP',   5)
) as c(prog_code, name, abbr, sem)
join programmes p on p.code = c.prog_code;


-- ============================================================================
-- 5. Buildings
-- ============================================================================
-- The Business School's two wings are modelled as two buildings rather than one
-- building with wing-prefixed room numbers, because 0001 composes a room's
-- display name as `building.abbreviation || '-' || rooms.number` — two
-- buildings give "BSL-201", one building would give "BS-L201".
insert into buildings (id, name, abbreviation, description) values
  ('eeeeeeee-0000-4000-8000-000000000001', 'Science Complex',                        'S',   'Lecture halls, core science labs, postgraduate seminars.'),
  ('eeeeeeee-0000-4000-8000-000000000002', 'Media School Complex',                   'MS',  'Media labs, radio station, general lecture rooms.'),
  ('eeeeeeee-0000-4000-8000-000000000003', 'Business School Complex (Left Wing)',    'BSL', 'Lecture halls, computer labs, ground-floor conference rooms.'),
  ('eeeeeeee-0000-4000-8000-000000000004', 'Business School Complex (Right Wing)',   'BSR', 'Lecture halls, computer labs, ground-floor conference rooms.'),
  ('eeeeeeee-0000-4000-8000-000000000005', 'Food Technology Centre',                 'FTC', 'Food processing labs, practical rooms.'),
  ('eeeeeeee-0000-4000-8000-000000000006', 'Pavilion Building',                      'PAV', 'Major events, examinations, large combined lectures.'),
  ('eeeeeeee-0000-4000-8000-000000000007', 'School of Law Complex',                  'LLB', 'Law lecture rooms and the moot court.');


-- ============================================================================
-- 6. Rooms
-- ============================================================================
-- rooms has no name/description column, so a room's purpose ("Plant Science
-- Lab") cannot live here. It is carried on venues.label instead — see §7.
--
-- rooms.number deliberately does NOT repeat the building abbreviation, because
-- 0001 composes the display name as `building.abbreviation || '-' || number`.
-- Storing 'S601' under building 'S' would render as "S-S601", so the room the
-- university calls S601 is stored as '601' and displays as "S-601"; SGT1 is
-- 'GT1' -> "S-GT1"; MS01 is '01' -> "MS-01".

-- Science Complex: two large halls, four ground-tier halls, chemistry lab,
-- two computer labs.
insert into rooms (building_id, number, capacity, room_type) values
  ('eeeeeeee-0000-4000-8000-000000000001', '601',   250, 'lecture_hall'),
  ('eeeeeeee-0000-4000-8000-000000000001', '602',   250, 'lecture_hall'),
  ('eeeeeeee-0000-4000-8000-000000000001', 'GT1',   120, 'lecture_hall'),
  ('eeeeeeee-0000-4000-8000-000000000001', 'GT2',   120, 'lecture_hall'),
  ('eeeeeeee-0000-4000-8000-000000000001', 'GT3',   120, 'lecture_hall'),
  ('eeeeeeee-0000-4000-8000-000000000001', 'GT4',   120, 'lecture_hall'),
  ('eeeeeeee-0000-4000-8000-000000000001', 'LAB1',   45, 'lab'),
  ('eeeeeeee-0000-4000-8000-000000000001', 'CLAB1',  60, 'lab'),
  ('eeeeeeee-0000-4000-8000-000000000001', 'CLAB2',  60, 'lab');

-- Media School: MS-01..MS-32 general lecture rooms, MS-33/MS-34 science labs,
-- MS-STUDIO for the radio station.
insert into rooms (building_id, number, capacity, room_type)
select 'eeeeeeee-0000-4000-8000-000000000002', lpad(g::text, 2, '0'), 80, 'lecture_hall'
from generate_series(1, 32) g;

insert into rooms (building_id, number, capacity, room_type) values
  ('eeeeeeee-0000-4000-8000-000000000002', '33',      40, 'lab'),
  ('eeeeeeee-0000-4000-8000-000000000002', '34',      40, 'lab'),
  ('eeeeeeee-0000-4000-8000-000000000002', 'STUDIO',  15, 'lab');

-- Business School wings. Ground floor (0xx) is conference rooms plus two
-- computer labs; floors 1-5 are lecture halls.
insert into rooms (building_id, number, capacity, room_type)
select b.id, lpad(n::text, 3, '0'),
       case when n < 100 then 25 else 150 end,
       case
         when n in (4, 5) then 'lab'::room_type          -- 004/005 computer labs
         when n < 100     then 'conference_hall'::room_type
         else                  'lecture_hall'::room_type
       end
from (values
  ('eeeeeeee-0000-4000-8000-000000000003'::uuid),
  ('eeeeeeee-0000-4000-8000-000000000004'::uuid)
) as b(id)
cross join (
  select n from generate_series(1, 5) n                       -- 001-005
  union all select f * 100 + n from generate_series(1, 5) f,
                                    generate_series(1, 5) n   -- 101-505
) as levels(n)
where not (n > 500 and n % 100 > 3);   -- fifth floor stops at 503

-- Food Technology Centre: specialised processing labs.
insert into rooms (building_id, number, capacity, room_type)
select 'eeeeeeee-0000-4000-8000-000000000005', (f * 100 + n)::text, 30, 'lab'
from generate_series(3, 5) f, generate_series(1, 5) n
where not (f = 5 and n > 2);   -- FTC-501 and FTC-502 only

-- Pavilion and Law Complex.
insert into rooms (building_id, number, capacity, room_type) values
  ('eeeeeeee-0000-4000-8000-000000000006', 'HALL', 1200, 'conference_hall'),
  ('eeeeeeee-0000-4000-8000-000000000007', '1',     100, 'lecture_hall'),
  ('eeeeeeee-0000-4000-8000-000000000007', '2',     100, 'lecture_hall'),
  ('eeeeeeee-0000-4000-8000-000000000007', '3',     100, 'lecture_hall'),
  ('eeeeeeee-0000-4000-8000-000000000007', 'MOOT',   60, 'conference_hall');


-- ============================================================================
-- 7. Venues (physical)
-- ============================================================================
-- Exactly one venue row per room — that is what makes events_no_venue_overlap
-- catch cross-cohort double-booking, since two cohorts booking the same room
-- necessarily share a venue_id (0001, venues_room_idx).
--
-- Online venues are NOT created here: they are one row per meeting link,
-- created alongside the event that uses them (see §11).
insert into venues (type, room_id, label)
select 'physical', r.id, b.abbreviation || '-' || r.number
from rooms r
join buildings b on b.id = r.building_id;

-- Rooms whose purpose the schema has nowhere else to record.
update venues v set label = x.label
from (values
  ('S',   'LAB1',   'S-LAB1 — Chemistry Lab (inorganic, organic, analytical)'),
  ('S',   'CLAB1',  'S-CLAB1 — Computer Lab'),
  ('S',   'CLAB2',  'S-CLAB2 — Computer Lab'),
  ('MS',  '33',     'MS-33 — Plant Science Lab'),
  ('MS',  '34',     'MS-34 — Food Science Lab'),
  ('MS',  'STUDIO', 'MS-STUDIO — Radio Station Studio and Control Room'),
  ('PAV', 'HALL',   'PAV Hall — Main Auditorium'),
  ('LLB', 'MOOT',   'LLB-MOOT — Moot Court Room'),
  ('BSL', '004',    'BSL-004 — Computer Lab'),
  ('BSL', '005',    'BSL-005 — Computer Lab'),
  ('BSR', '004',    'BSR-004 — Computer Lab'),
  ('BSR', '005',    'BSR-005 — Computer Lab')
) as x(building, room, label)
where v.room_id = (
  select r.id from rooms r join buildings b on b.id = r.building_id
  where b.abbreviation = x.building and r.number = x.room
);


-- ============================================================================
-- 8. Users
-- ============================================================================
-- Every account is created through auth.users so 0002's sync trigger builds the
-- public.users profile, exactly as a real signup does. Everyone starts as a
-- 'student' — roles are then granted the way the trust chain requires:
-- faculty reps by the Superadmin here, class reps by a faculty rep in §9.
--
-- EVERY IDENTITY BELOW IS ENTIRELY FICTIONAL, as are all registration numbers
-- and email addresses — the faculty reps included. They used to be the two
-- sitting Deans, on the reasoning that a Dean is who would hold a faculty's
-- trust-anchor account. That was wrong on the facts: a faculty rep is a
-- student, so they are fictional students here like everyone else. See the
-- note on them below, and TECHNICAL_DISCOVERY §10.

-- Everything that calls a seed_* helper is wrapped in a DO block on purpose.
-- PL/pgSQL resolves function calls when the line runs; a plain top-level
-- `select seed_user(...)` is resolved when the statement is PREPARED, and the
-- Supabase CLI hands the whole seed file to the server as one pipelined batch —
-- which is how `db reset` came back with "function seed_cohort(unknown) does not
-- exist" for a function created earlier in the very same file. Keeping the calls
-- inside DO blocks sidesteps the ordering question entirely.
do $$
begin
  -- Faculty reps. THEY ARE STUDENTS — same @student address, same registration
  -- number, same cohort as anyone else. Both elevated roles are: a class rep
  -- and a faculty rep are students carrying more responsibility, not a
  -- different kind of person (TECHNICAL_DISCOVERY §10).
  --
  -- This used to model them as the two sitting Deans, on @chuka.ac.ke staff
  -- addresses with no registration number. That was an assumption of this file
  -- and never a requirement — DISCOVERY describes a class rep as "a student
  -- elevated by a Faculty Rep" and nowhere describes a faculty rep as staff.
  -- Corrected 2026-08-24, along with 0032 which is the first thing in the
  -- schema written against the right model. Their names are fictional now, for
  -- the same reason every other student's is.
  --
  -- Provider is 'google', so 0019's trigger sets email and email_verified_at
  -- the way it does for any other OAuth signup — the promotion block below no
  -- longer has to fill those in by hand.
  perform seed_user('22222222-0000-4000-8000-000000000001', 'eb1.66001.23@student.chuka.ac.ke',
                    'Peter',  'Kimani', 'Njoroge', 'EB1/66001/23', 'google');
  perform seed_user('22222222-0000-4000-8000-000000000002', 'ba2.70001.24@student.chuka.ac.ke',
                    'Salome', 'Achieng', null,     'BA2/70001/24', 'google');

  -- Students. Every account is a Google OAuth signup now, split across the two
  -- email tiers: a school-address login (Flow 2) or a personal-address login
  -- (Flow 1). Login addresses for the school tier are the reg number with
  -- slashes as dots, per §10.

  -- EB1 intake 2023 — the cohort most of the seeded timetable belongs to.
  -- Mercy Wanjiku Njeri -- Flow 2 (school email)
  perform seed_user('22222222-0000-4000-8000-000000000011', 'eb1.67277.23@student.chuka.ac.ke',
                    'Mercy',   'Wanjiku',  'Njeri',  'EB1/67277/23', 'google');
  perform seed_user('22222222-0000-4000-8000-000000000012', 'eb1.67312.23@student.chuka.ac.ke',
                    'Brian',   'Otieno',   null,     'EB1/67312/23', 'google');
  perform seed_user('22222222-0000-4000-8000-000000000013', 'eb1.67340.23@student.chuka.ac.ke',
                    'Faith',   'Mueni',    null,     'EB1/67340/23', 'google');
  -- Kevin Kariuki Mwangi -- Flow 1 (personal email)
  perform seed_user('22222222-0000-4000-8000-000000000014', 'kevin.kariuki23@gmail.com',
                    'Kevin',   'Kariuki',  'Mwangi', 'EB1/67358/23', 'google');
  perform seed_user('22222222-0000-4000-8000-000000000015', 'eb1.67401.23@student.chuka.ac.ke',
                    'Aisha',   'Hassan',   null,     'EB1/67401/23', 'google');

  -- EB1 intake 2024 running the trimester pace — self-sponsored students moving
  -- faster, which is why a 2024 intake is already at semester 5 alongside the
  -- 2023 bimester cohort. This is the pace mechanic from §4 in the data.
  -- Dennis Kiprono -- Flow 2 (school email)
  perform seed_user('22222222-0000-4000-8000-000000000021', 'eb1.71004.24@student.chuka.ac.ke',
                    'Dennis',  'Kiprono',  null,     'EB1/71004/24', 'google');
  perform seed_user('22222222-0000-4000-8000-000000000022', 'eb1.71066.24@student.chuka.ac.ke',
                    'Grace',   'Achieng',  'Awuor',  'EB1/71066/24', 'google');

  -- EB3 Applied Computer Science, intake 2023.
  perform seed_user('22222222-0000-4000-8000-000000000031', 'eb3.67891.23@student.chuka.ac.ke',
                    'Samuel',  'Mutuku',   null,     'EB3/67891/23', 'google');
  -- Cynthia Nyambura -- Flow 1 (personal email)
  perform seed_user('22222222-0000-4000-8000-000000000032', 'cynthia.nyambura23@gmail.com',
                    'Cynthia', 'Nyambura', null,     'EB3/67903/23', 'google');

  -- BA2 Criminology & Security Studies, intake 2024 — the FHSS cohort. Exists so
  -- 0014's faculty scoping has a cross-faculty case to be tested against.
  -- Abdul Rashid Omar -- Flow 2 (school email)
  perform seed_user('22222222-0000-4000-8000-000000000041', 'ba2.70115.24@student.chuka.ac.ke',
                    'Abdul',   'Rashid',   'Omar',   'BA2/70115/24', 'google');
  perform seed_user('22222222-0000-4000-8000-000000000042', 'ba2.70233.24@student.chuka.ac.ke',
                    'Naomi',   'Chepkoech',null,     'BA2/70233/24', 'google');
  perform seed_user('22222222-0000-4000-8000-000000000043', 'ba2.70290.24@student.chuka.ac.ke',
                    'Joseph',  'Barasa',   null,     'BA2/70290/24', 'google');

  -- Cohortless students, for the join-request flow in §10.
  -- Lydia Chebet -- Flow 1 (personal email)
  perform seed_user('22222222-0000-4000-8000-000000000051', 'lydia.chebet23@gmail.com',
                    'Lydia',   'Chebet',   null,     'EB1/67455/23', 'google');
  perform seed_user('22222222-0000-4000-8000-000000000052', 'eb1.67470.23@student.chuka.ac.ke',
                    'Victor',  'Onyango',  null,     'EB1/67470/23', 'google');
  -- Ruth Nyaguthii -- Flow 2 (school email), cohortless -- exercises the
  -- Flow 2 join-request discriminator (approve_cohort_join_request's
  -- three-clause check, 0041) against real seed data.
  perform seed_user('22222222-0000-4000-8000-000000000053', 'eb1.67488.23@student.chuka.ac.ke',
                    'Ruth',    'Nyaguthii',null,     'EB1/67488/23', 'google');
  -- Ian Maina -- Flow 1 (personal email), cohortless -- "a first-year with
  -- no university email yet" is still the exact case this account
  -- represents; it just gets there via a personal Google signup now
  -- instead of the retired password path.
  perform seed_user('22222222-0000-4000-8000-000000000054', 'ian.maina26@gmail.com',
                    'Ian',     'Maina',    null,     'EB3/72010/26', 'google');
end $$;

-- Promotion sets `role` and `faculty_id` and NOTHING else — exactly what
-- 0032's bootstrap_faculty_rep does, and for the same reason: a faculty rep is
-- still a student, so their reg_number, their cohort and their roster claim all
-- survive being promoted. This block used to also write `email` and
-- `email_verified_at`, which it no longer needs to: the two accounts are OAuth
-- signups now, so 0019's trigger already set both.
--
-- Their cohort is assigned in §9 with everyone else's, once the cohorts they
-- create actually exist.
--
-- The ::uuid casts are required: a bare CASE over quoted literals is `unknown`
-- to the planner, which will not implicitly coerce into a uuid column.
update users
set role = 'faculty_rep',
    faculty_id = case id
      when '22222222-0000-4000-8000-000000000001'
        then 'aaaaaaaa-0000-4000-8000-000000000001'::uuid
      when '22222222-0000-4000-8000-000000000002'
        then 'aaaaaaaa-0000-4000-8000-000000000002'::uuid
    end
where id in ('22222222-0000-4000-8000-000000000001',
             '22222222-0000-4000-8000-000000000002');


-- ============================================================================
-- 9. Cohorts and class reps
-- ============================================================================
-- Cohorts are created by calling create_cohort_with_class_rep as the relevant
-- faculty rep, not by INSERT — that is the only supported path (§4) and it
-- exercises 0014's faculty scoping, the programme-belongs-to-my-faculty check
-- and the must-be-a-student check on the first rep.
--
-- Cohort names come out as `abbreviation intake_year (pace)` as of 0023, so:
-- 'BSC-CS 2023 (bimester)', 'BSC-CS 2024 (trimester)', 'BSC-ACS 2023 (bimester)',
-- 'BA-CRIM 2024 (bimester)'. The pace is in there because without it the first
-- and second of those would be identical strings — see 0023 §1.
--
-- Nothing below looks a cohort up by name; seed_cohort() keys on
-- (programme code, intake year), which is stable across renames.
do $$
declare
  v_fst_rep  uuid := '22222222-0000-4000-8000-000000000001';
  v_fhss_rep uuid := '22222222-0000-4000-8000-000000000002';
begin
  perform seed_act_as(v_fst_rep);

  perform create_cohort_with_class_rep(
    (select id from programmes where code = 'EB1'),
    2023, 5, 'bimester',
    '22222222-0000-4000-8000-000000000011',   -- Mercy Wanjiku, primary rep
    v_fst_rep
  );

  perform create_cohort_with_class_rep(
    (select id from programmes where code = 'EB1'),
    2024, 5, 'trimester',
    '22222222-0000-4000-8000-000000000021',   -- Dennis Kiprono, primary rep
    v_fst_rep
  );

  perform create_cohort_with_class_rep(
    (select id from programmes where code = 'EB3'),
    2023, 5, 'bimester',
    '22222222-0000-4000-8000-000000000031',   -- Samuel Mutuku, primary rep
    v_fst_rep
  );

  perform seed_act_as(v_fhss_rep);

  perform create_cohort_with_class_rep(
    (select id from programmes where code = 'BA2'),
    2024, 3, 'bimester',
    '22222222-0000-4000-8000-000000000041',   -- Abdul Rashid, primary rep
    v_fhss_rep
  );
end $$;

-- Remaining students join their cohorts. Direct UPDATE (the Superadmin path):
-- the in-app route is a join request, which §10 demonstrates for a few students
-- rather than all of them. In a DO block for the batch-preparation reason
-- explained in §8.
do $$
begin
  update users set cohort_id = seed_cohort('EB1', 2023)
  where id in ('22222222-0000-4000-8000-000000000012',
               '22222222-0000-4000-8000-000000000013',
               '22222222-0000-4000-8000-000000000014',
               '22222222-0000-4000-8000-000000000015');

  update users set cohort_id = seed_cohort('EB1', 2024)
  where id = '22222222-0000-4000-8000-000000000022';

  update users set cohort_id = seed_cohort('EB3', 2023)
  where id = '22222222-0000-4000-8000-000000000032';

  update users set cohort_id = seed_cohort('BA2', 2024)
  where id in ('22222222-0000-4000-8000-000000000042',
               '22222222-0000-4000-8000-000000000043');

  -- The two faculty reps, into the cohorts their own registration numbers
  -- resolve to. They are students, so they belong to a cohort and go on seeing
  -- its timetable — they still attend it. Their faculty-wide authority comes
  -- from `faculty_id`, which is a separate thing entirely and is what 0016
  -- actually checks.
  --
  -- Note they are members of a cohort they themselves created moments ago in
  -- this same block. That is not circular in any way that matters: creating a
  -- cohort needs `role = 'faculty_rep'` and a matching `faculty_id`, never
  -- membership.
  update users set cohort_id = seed_cohort('EB1', 2023)
  where id = '22222222-0000-4000-8000-000000000001';

  update users set cohort_id = seed_cohort('BA2', 2024)
  where id = '22222222-0000-4000-8000-000000000002';
end $$;

-- Assistant class reps are promoted in §9.6, AFTER the roster exists —
-- promote_class_rep reads the target's roster claim to decide whether an
-- identity attestation is required, and a promotion run before §9.5 would find
-- no claim at all and demand one for everybody.


-- ----------------------------------------------------------------------------
-- 9.5 Identity facts, derived from the registration numbers above
-- ----------------------------------------------------------------------------
-- student_roster is retired (Plan 5, Task 7) — this used to build claimed and
-- unclaimed roster rows from the accounts above. Its replacement writes the
-- same information onto the columns the new system actually reads:
-- claim_method, programme_id, self_sponsored, student_number, admission_year.
-- Direct UPDATE as postgres, same Superadmin-path reasoning seed_user's own
-- comment already gives for reg_number: this file IS the institution,
-- fabricating a starting state rather than pretending to be a signup.
--
-- school_email is not null is the discriminator (not the old
-- email_verified_at check, which only ever distinguished OAuth from the now-
-- retired password path) — every account here is OAuth now, and the auth
-- trigger (0039) already set school_email/personal_email at signup based on
-- address domain.
--
-- reg_number is then nulled for everyone. A genuine Flow 1 or Flow 2 account
-- never has users.reg_number set (0002/0019's invariant, unchanged by this
-- plan) — leaving it populated here would make the seed data inconsistent
-- with what a real account looks like.
do $$
begin
  -- parse_reg_number(u.reg_number) can't be called directly in this UPDATE's
  -- FROM clause — the target table's own alias isn't a member of the FROM
  -- list, so a function call there can't reference it (42P10). Routing the
  -- parse through a self-joined subquery sidesteps that: the subquery reads
  -- from users like any other FROM item, so its call to parse_reg_number can
  -- reference that copy's reg_number, and the outer UPDATE joins back to it
  -- by id.
  update users u
  set claim_method   = case when u.school_email is not null then 'oauth' else 'provisional' end::claim_method,
      programme_id   = pr.programme_id,
      self_sponsored = pr.is_self_sponsored,
      student_number = pr.student_number,
      admission_year = pr.admission_year
  from (
    select u2.id, (parse_reg_number(u2.reg_number)).*
    from users u2
    where u2.reg_number is not null
      and u2.role in ('student', 'class_rep', 'faculty_rep')
  ) pr
  where u.id = pr.id;

  update users set reg_number = null where reg_number is not null;
end $$;


-- ----------------------------------------------------------------------------
-- 9.6 Assistant class reps
-- ----------------------------------------------------------------------------
-- Through the real function as of 0022. This used to be a direct UPDATE as
-- postgres, because there was NO function that could do it:
-- create_cohort_with_class_rep installs the FIRST rep only, demote_class_rep
-- only empties a slot, and 0014 blocks a client from writing users.role at all
-- — so the assistant rank, i.e. the whole "fallback if the primary needs
-- replacing" mechanism from DISCOVERY, was unreachable from inside the app.
--
-- Runs after §9.5 because promote_class_rep reads the target's claim_method.
--
-- Both targets are OAuth-claimed accounts (Brian and Naomi are the two
-- @student.chuka.ac.ke assistants), so neither needs the identity attestation.
-- That is deliberate: a seed that routinely passed p_identity_attested => true
-- would model the attestation as a formality rather than as the exception it
-- is. 07_phase1_test.sql covers the provisional-target path instead.
do $$
begin
  perform seed_act_as('22222222-0000-4000-8000-000000000001');   -- FST faculty rep
  perform promote_class_rep(
    '22222222-0000-4000-8000-000000000012', 'assistant',         -- Brian Otieno, BSC-CS 2023
    '22222222-0000-4000-8000-000000000001'
  );

  perform seed_act_as('22222222-0000-4000-8000-000000000002');   -- FHSS faculty rep
  perform promote_class_rep(
    '22222222-0000-4000-8000-000000000042', 'assistant',         -- Naomi Chepkoech, BA-CRIM 2024
    '22222222-0000-4000-8000-000000000002'
  );
end $$;


-- ============================================================================
-- 10. Cohort join requests
-- ============================================================================
-- Four students, four outcomes: one approved, one declined, one still pending,
-- and one pending against a different cohort. Note that
-- cohort_join_requests_one_pending_per_student allows only one open request per
-- student at a time, so the declined student can and does re-request.
do $$
begin
  insert into cohort_join_requests (id, student_id, cohort_id, status, requested_at) values
    ('33333333-0000-4000-8000-000000000001', '22222222-0000-4000-8000-000000000051',
     seed_cohort('EB1', 2023), 'pending', now() - interval '3 days'),
    ('33333333-0000-4000-8000-000000000002', '22222222-0000-4000-8000-000000000052',
     seed_cohort('EB1', 2023), 'pending', now() - interval '2 days'),
    ('33333333-0000-4000-8000-000000000003', '22222222-0000-4000-8000-000000000053',
     seed_cohort('EB1', 2023), 'pending', now() - interval '1 day');
end $$;

-- Resolved by the cohort's own class rep, through the real functions.
do $$
declare
  v_cs23_rep uuid := '22222222-0000-4000-8000-000000000011';
begin
  perform seed_act_as(v_cs23_rep);
  perform approve_cohort_join_request('33333333-0000-4000-8000-000000000001', v_cs23_rep);
  perform decline_cohort_join_request('33333333-0000-4000-8000-000000000002', v_cs23_rep);
  -- 33333333-...-0003 is left pending on purpose, so the rep's inbox has work.
end $$;

do $$
begin
  -- The declined student re-requests, which is explicitly allowed (0003: a
  -- decline is not a permanent block). Has to come AFTER the decline above, or
  -- cohort_join_requests_one_pending_per_student rejects it.
  insert into cohort_join_requests (id, student_id, cohort_id, status, requested_at) values
    ('33333333-0000-4000-8000-000000000004', '22222222-0000-4000-8000-000000000052',
     seed_cohort('EB1', 2023), 'pending', now() - interval '4 hours');

  -- The first-year with no university email requests the Applied CS cohort.
  insert into cohort_join_requests (id, student_id, cohort_id, status, requested_at) values
    ('33333333-0000-4000-8000-000000000005', '22222222-0000-4000-8000-000000000054',
     seed_cohort('EB3', 2023), 'pending', now() - interval '6 hours');
end $$;


-- ============================================================================
-- 11. The timetable
-- ============================================================================
-- Slots are the standard three-hour blocks: 07:00-10:00, 10:00-13:00,
-- 13:00-16:00, 16:00-19:00 Africa/Nairobi. seed_slot(day, hour) resolves them
-- against next Monday, so the whole timetable is always upcoming.
--
-- Almost every event is recurrence = 'none' and represents one real occurrence;
-- a unit meeting three times a week gets three rows. ONE unit is a genuine
-- materialized weekly series (BSC-CS 2024's OOP lab, below) so the dev dataset
-- exercises 0022's recurrence path — see that block for why it has to be that
-- cohort and not the hero one.
--
-- Grid, checked against both EXCLUDE constraints before writing:
--
--        07-10             10-13              13-16             16-19
--   Mon  CS23  DBMS S601   CS24  SESA S602    CS23  SESA BSL201  -
--        ACS23 CSND BSL005 CRIM  CPCP MS01
--   Tue  CS24  CNDS S601   CS23  CNDS S602    ACS23 CCDO BSL005  CS23 SESA BSL004
--        CRIM  FCSI LLB-1                                        (-> 17-20)
--   Wed  CS23  DBMS S601   ACS23 AIML BSL301  CS23  CNDS BSL004   -
--        CS24  SESA BSL202                    CRIM  FCSI LLB-2
--        (weekly series)
--   Thu  ACS23 CSND kenet  CS23+CS24 DBMS     -                  CS23 SESA S602
--                          PAV-HALL (combined)                   (-> canceled)
--                          CRIM  CPCP MS02
--   Fri  CS23  DBMS meet   CS24  DBMS BSL202  CS23+ACS23 combined -
--        CRIM  CPCP MS01                      S601 (proposed)
--
-- Every call now passes seed_att(cohort, programme, unit) rather than a cohort
-- array plus one course: as of 0021/0022 the unit is a property of the
-- ATTACHMENT, not of the event, so that a combined lecture spanning two
-- programmes shows each cohort the unit from its own.

-- --- BSC-CS 2023: the hero cohort's week ------------------------------------
do $$
declare
  v_rep uuid := '22222222-0000-4000-8000-000000000011';
begin
  perform seed_act_as(v_rep);

  perform create_event(seed_att('EB1', 2023,'DBMS'), seed_venue('S', '601'),
    'Fredrick O. Ogolla',      null, seed_slot(1, 7),  seed_slot(1, 10), 'none', null, v_rep);

  perform create_event(seed_att('EB1', 2023,'SESA'), seed_venue('BSL', '201'),
    'Harun Njenga Ngugi',      null, seed_slot(1, 13), seed_slot(1, 16), 'none', null, v_rep);

  perform create_event(seed_att('EB1', 2023,'CNDS'), seed_venue('S', '602'),
    'Peter Kiplang''at Koech', null, seed_slot(2, 10), seed_slot(2, 13), 'none', null, v_rep);

  perform create_event(seed_att('EB1', 2023,'DBMS'), seed_venue('S', '601'),
    'Fredrick O. Ogolla',      null, seed_slot(3, 7),  seed_slot(3, 10), 'none', null, v_rep);

  -- The one seeded event carrying a title. create_event hardcoded title to null
  -- before 0022 and took no parameter at all, so nothing in the dataset ever
  -- exercised the "title overrides the course name" display path.
  perform create_event(seed_att('EB1', 2023,'CNDS'), seed_venue('BSL', '004'),
    'Peter Kiplang''at Koech', 'CNDS — Practical: subnetting',
    seed_slot(3, 13), seed_slot(3, 16), 'none', null, v_rep);
end $$;

-- --- BSC-CS 2024 (trimester) ------------------------------------------------
do $$
declare
  v_rep uuid := '22222222-0000-4000-8000-000000000021';
begin
  perform seed_act_as(v_rep);

  perform create_event(seed_att('EB1', 2024,'SESA'), seed_venue('S', '602'),
    'Harun Njenga Ngugi',      null, seed_slot(1, 10), seed_slot(1, 13), 'none', null, v_rep);

  perform create_event(seed_att('EB1', 2024,'CNDS'), seed_venue('S', '601'),
    'Peter Kiplang''at Koech', null, seed_slot(2, 7),  seed_slot(2, 10), 'none', null, v_rep);

  perform create_event(seed_att('EB1', 2024,'DBMS'), seed_venue('BSL', '202'),
    'Fredrick O. Ogolla',      null, seed_slot(5, 10), seed_slot(5, 13), 'none', null, v_rep);
end $$;

-- --- A RECURRING series: the only materialized one in the dataset -----------
-- BSC-CS 2024 and not the hero cohort, and that is not an arbitrary choice.
-- BSC-CS 2024 is the only TRIMESTER cohort here, so term_bounds always returns
-- a window for it whatever day you reset on. Every other seeded cohort is
-- bimester, and a bimester cohort has no term at all between May and August
-- (0021 §1) — seeding a series for one of those would make `db reset` succeed
-- for eight months of the year and fail for four.
--
-- p_until is left null, so the horizon is the term end and the number of rows
-- depends on today's date: reset in early January and this produces the better
-- part of a term's worth; reset in the last week of a term and it produces one.
-- Both are correct, and §13 prints the count so it is never a surprise.
do $$
declare
  v_rep uuid := '22222222-0000-4000-8000-000000000021';
begin
  perform seed_act_as(v_rep);

  perform create_event(seed_att('EB1', 2024,'SESA'), seed_venue('BSL', '202'),
    'Harun Njenga Ngugi', 'SESA — weekly practical',
    seed_slot(3, 7), seed_slot(3, 10), 'week', null, v_rep);
end $$;

-- --- BSC-ACS 2023, including a KENET online lecture -------------------------
do $$
declare
  v_rep      uuid := '22222222-0000-4000-8000-000000000031';
  v_online   uuid;
begin
  perform seed_act_as(v_rep);

  perform create_event(seed_att('EB3', 2023,'CSND'), seed_venue('BSL', '005'),
    'Harun Njenga Ngugi',      null, seed_slot(1, 7),  seed_slot(1, 10), 'none', null, v_rep);

  perform create_event(seed_att('EB3', 2023,'CCDO'), seed_venue('BSL', '005'),
    'Fredrick O. Ogolla',      null, seed_slot(2, 13), seed_slot(2, 16), 'none', null, v_rep);

  perform create_event(seed_att('EB3', 2023,'AIML'), seed_venue('BSL', '301'),
    'Peter Kiplang''at Koech', null, seed_slot(3, 10), seed_slot(3, 13), 'none', null, v_rep);

  -- Online venues are one row per meeting link and never shared, so they can
  -- never falsely trip events_no_venue_overlap (0001).
  insert into venues (type, meeting_link, platform, label)
  values ('online', 'https://connect.kenet.or.ke/chuka-acs-csnd', 'kenet',
          'KENET — Applied CS Cybersecurity')
  returning id into v_online;

  perform create_event(seed_att('EB3', 2023,'CSND'), v_online,
    'Harun Njenga Ngugi',      null, seed_slot(4, 7),  seed_slot(4, 10), 'none', null, v_rep);
end $$;

-- --- BA-CRIM 2024 (FHSS) ----------------------------------------------------
do $$
declare
  v_rep uuid := '22222222-0000-4000-8000-000000000041';
begin
  perform seed_act_as(v_rep);

  perform create_event(seed_att('BA2', 2024,'CPCP'), seed_venue('MS', '01'),
    'Abel Bennett Holla',           null, seed_slot(1, 10), seed_slot(1, 13), 'none', null, v_rep);

  perform create_event(seed_att('BA2', 2024,'FCSI'), seed_venue('LLB', '1'),
    'Dennis Mosoti',                null, seed_slot(2, 7),  seed_slot(2, 10), 'none', null, v_rep);

  perform create_event(seed_att('BA2', 2024,'FCSI'), seed_venue('LLB', '2'),
    'Dennis Mosoti',                null, seed_slot(3, 13), seed_slot(3, 16), 'none', null, v_rep);

  perform create_event(seed_att('BA2', 2024,'FCSI'), seed_venue('MS', '02'),
    'Dr. Lenity Kananu Maugu',      null, seed_slot(4, 10), seed_slot(4, 13), 'none', null, v_rep);

  perform create_event(seed_att('BA2', 2024,'CPCP'), seed_venue('MS', '01'),
    'Prof. Christine Atieno Peter', null, seed_slot(5, 7),  seed_slot(5, 10), 'none', null, v_rep);
end $$;

-- --- A CONFIRMED combined lecture: both CS cohorts, one lecturer, PAV Hall --
-- Two cohorts of the SAME programme at the same semester on different paces, so
-- both attach as the same unit — the simplest shape a combined lecture takes.
-- The cross-programme case is the proposal below.
do $$
declare
  v_init_rep    uuid := '22222222-0000-4000-8000-000000000011';  -- BSC-CS 2023
  v_partner_rep uuid := '22222222-0000-4000-8000-000000000021';  -- BSC-CS 2024
  v_event_id    uuid;
begin
  perform seed_act_as(v_init_rep);
  v_event_id := create_event(
    seed_att('EB1', 2023,'DBMS') || seed_att('EB1', 2024,'DBMS'),
    seed_venue('PAV', 'HALL'),
    'Fredrick O. Ogolla', null, seed_slot(4, 10), seed_slot(4, 13), 'none', null, v_init_rep
  );

  -- Starts 'proposed' with BSC-CS 2023 auto-confirmed as initiator. The partner
  -- rep confirming is the last outstanding cohort, which flips the event to
  -- 'scheduled' — and that is the moment both EXCLUDE constraints are really
  -- evaluated.
  perform seed_act_as(v_partner_rep);
  perform confirm_event_cohort(v_event_id, v_partner_rep);

  -- THE HEADLINE FEATURE, with data behind it for the first time. The initiating
  -- rep phoned the lecturer and he confirmed he is coming, so this one event is
  -- attendance_status = 'confirmed' while everything else in the dataset stays
  -- 'pending'. Before 0022 there was no function that could write it and no
  -- UPDATE policy on events, so 'confirmed' was unreachable from anywhere and
  -- the confirmation dashboard was permanently empty.
  --
  -- Note the confirming rep does not have to be the initiator — any attached
  -- cohort's rep may have been the one who made the call. Using the partner rep
  -- here so the dataset demonstrates that rather than just permitting it.
  perform confirm_attendance(v_event_id, v_partner_rep);
end $$;

-- --- A PROPOSED combined lecture, still awaiting confirmation ---------------
-- Cross-programme, and the reason TODO §1.7 exists. One lecturer, one room, two
-- cohorts from two different programmes — and each attaches as ITS OWN unit:
-- Applied CS attends as EB3's AI & ML, Computer Science attends as EB1's
-- Networks & Distributed Systems, both taught by Koech.
--
-- Until 0021 this was impossible to express. events.course_id was a single FK
-- into programme-scoped `courses`, so this event had to borrow EB3's row and a
-- BSC-CS student's calendar showed a unit from a programme they are not
-- enrolled in. As of 0022 create_event REFUSES a course from an unrelated
-- programme outright, so the old form of this block would now raise.
--
-- Left unconfirmed so the app has a live proposal to render and an Applied CS
-- rep with a real decision waiting.
do $$
declare
  v_init_rep uuid := '22222222-0000-4000-8000-000000000011';
begin
  perform seed_act_as(v_init_rep);
  perform create_event(
    seed_att('EB1', 2023,'CNDS') || seed_att('EB3', 2023,'AIML'),
    seed_venue('S', '601'),
    'Peter Kiplang''at Koech', null, seed_slot(5, 13), seed_slot(5, 16), 'none', null, v_init_rep
  );
end $$;

-- --- A RESCHEDULED occurrence ----------------------------------------------
-- Same room, shifted one hour: exactly the case that failed before 0013,
-- because the replacement collided with the occurrence it was replacing on both
-- EXCLUDE constraints. Leaves behind the two-row history the audit trail is
-- built on — a 'rescheduled' row pointing at its replacement via superseded_by.
do $$
declare
  v_rep      uuid := '22222222-0000-4000-8000-000000000011';
  v_event_id uuid;
begin
  perform seed_act_as(v_rep);

  v_event_id := create_event(
    seed_att('EB1', 2023,'SESA'), seed_venue('BSL', '004'),
    'Harun Njenga Ngugi', null, seed_slot(2, 16), seed_slot(2, 19), 'none', null, v_rep
  );

  perform reschedule_event(
    v_event_id, seed_slot(2, 17), seed_slot(2, 20),
    seed_venue('BSL', '004'), v_rep
  );
end $$;

-- --- A CANCELLED lecture ---------------------------------------------------
do $$
declare
  v_rep      uuid := '22222222-0000-4000-8000-000000000011';
  v_event_id uuid;
begin
  perform seed_act_as(v_rep);

  v_event_id := create_event(
    seed_att('EB1', 2023,'SESA'), seed_venue('S', '602'),
    'Harun Njenga Ngugi', null, seed_slot(4, 16), seed_slot(4, 19), 'none', null, v_rep
  );

  perform cancel_event(v_event_id, v_rep);
end $$;

-- --- A Google Meet online lecture -----------------------------------------
do $$
declare
  v_rep    uuid := '22222222-0000-4000-8000-000000000011';
  v_online uuid;
begin
  perform seed_act_as(v_rep);

  insert into venues (type, meeting_link, platform, label)
  values ('online', 'https://meet.google.com/chuka-cs-dbms-clinic', 'google_meet',
          'Google Meet — DBMS Revision Clinic')
  returning id into v_online;

  perform create_event(
    seed_att('EB1', 2023,'DBMS'), v_online,
    'Fredrick O. Ogolla', null, seed_slot(5, 7), seed_slot(5, 10), 'none', null, v_rep
  );
end $$;


-- ============================================================================
-- 12. Tear down the seed helpers
-- ============================================================================
-- They are SECURITY-sensitive-looking (one fabricates auth users, one forges
-- auth.uid()) and must not survive into a database anybody points a client at.
drop function seed_user(uuid, text, text, text, text, text, text);
drop function seed_act_as(uuid);
drop function seed_att(text, int, text);
drop function seed_course(text, text);
drop function seed_venue(text, text);
drop function seed_cohort(text, int);
drop function seed_slot(int, int);

-- Clear any lingering forged JWT claim.
select set_config('request.jwt.claims', '', false);


-- ============================================================================
-- 12.5 Push dispatch secrets (local dev only) — 0034, TODO 3.1
-- ============================================================================
-- invoke_push_dispatch() (0034) no-ops without a push_dispatch_url /
-- push_dispatch_key pair in Vault. The local Docker stack's Kong gateway and
-- the demo service_role key (from `supabase status`) are fixed, public
-- values for every local Supabase project, not real secrets — safe to seed
-- here the same way seed.sql already hands out account passwords
-- ("chuka1234") for a fabricated dev dataset.
--
-- A HOSTED DEPLOYMENT MUST SET ITS OWN PAIR — this section never runs
-- there. Once linked, run once against the hosted project:
--   select vault.create_secret(
--     'https://<project-ref>.supabase.co/functions/v1/dispatch-push',
--     'push_dispatch_url'
--   );
--   select vault.create_secret('<real service_role key>', 'push_dispatch_key');
do $$
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'push_dispatch_url') then
    perform vault.create_secret(
      'http://kong:8000/functions/v1/dispatch-push',
      'push_dispatch_url'
    );
  end if;

  if not exists (select 1 from vault.decrypted_secrets where name = 'push_dispatch_key') then
    perform vault.create_secret(
      -- The fixed local-dev service_role key baked into every `supabase
      -- init` project (config.toml's demo JWT secret) — never a real key.
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU',
      'push_dispatch_key'
    );
  end if;
end $$;


-- ============================================================================
-- 13. Summary
-- ============================================================================
do $$
declare
  r record;
begin
  select
    (select count(*) from faculties)            as faculties,
    (select count(*) from departments)          as departments,
    (select count(*) from programmes)           as programmes,
    (select count(*) from courses)              as courses,
    (select count(*) from buildings)            as buildings,
    (select count(*) from rooms)                as rooms,
    (select count(*) from venues)               as venues,
    (select count(*) from users)                as users,
    (select count(*) from cohorts)              as cohorts,
    (select count(*) from cohort_join_requests
       where status = 'pending')                as pending_joins,
    (select count(*) from events)               as events,
    (select count(*) from events
       where status = 'scheduled')              as scheduled,
    (select count(*) from events
       where status = 'proposed')               as proposed,
    (select count(*) from events
       where status = 'canceled')               as canceled,
    (select count(*) from events
       where status = 'rescheduled')            as rescheduled,
    (select count(*) from events
       where recurrence_group_id is not null)   as in_series,
    (select count(*) from events
       where attendance_status = 'confirmed')   as attendance_confirmed,
    (select count(*) from event_cohorts)        as attachments,
    (select count(*) from event_audit_log)      as audit_rows,
    (select count(*) from notifications)        as notifications
  into r;

  raise notice '';
  raise notice 'Chuka seed loaded';
  raise notice '  reference : % faculties, % departments, % programmes, % courses',
    r.faculties, r.departments, r.programmes, r.courses;
  raise notice '  venues    : % buildings, % rooms, % venues', r.buildings, r.rooms, r.venues;
  raise notice '  people    : % users, % cohorts, % pending join requests',
    r.users, r.cohorts, r.pending_joins;
  raise notice '  timetable : % events (% scheduled, % proposed, % canceled, % rescheduled)',
    r.events, r.scheduled, r.proposed, r.canceled, r.rescheduled;
  -- in_series varies with the reset date: the weekly series runs to the end of
  -- the initiating cohort's term, so it is longer in January than in April.
  raise notice '  phase 1   : % occurrences in a recurring series, % attendance-confirmed',
    r.in_series, r.attendance_confirmed;
  raise notice '  generated : % attachments, % audit rows, % notifications',
    r.attachments, r.audit_rows, r.notifications;
  raise notice '';
  raise notice 'Password for every account: chuka1234';
  raise notice '  class rep (BSC-CS 2023) : eb1.67277.23@student.chuka.ac.ke';
  raise notice '  class rep (BSC-CS 2024) : eb1.71004.24@student.chuka.ac.ke';
  raise notice '  class rep (BSC-ACS 2023): eb3.67891.23@student.chuka.ac.ke';
  raise notice '  class rep (BA-CRIM 2024): ba2.70115.24@student.chuka.ac.ke';
  raise notice '  faculty rep (FST)       : eb1.66001.23@student.chuka.ac.ke';
  raise notice '  faculty rep (FHSS)      : ba2.70001.24@student.chuka.ac.ke';
  raise notice '  plain student           : eb1.67312.23@student.chuka.ac.ke';
  raise notice '';
end $$;
