-- ============================================================================
-- 0001: Enums + reference/academic structure
-- Faculties -> Departments -> Programmes -> Courses -> Cohorts, Buildings/Rooms/Venues
-- ============================================================================

create type user_role       as enum ('student', 'class_rep', 'faculty_rep');
create type programme_level as enum ('certificate', 'diploma', 'degree', 'master', 'phd');
create type cohort_pace     as enum ('bimester', 'trimester');
create type room_type       as enum ('lecture_hall', 'lab', 'conference_hall');
create type venue_type      as enum ('physical', 'online');
create type venue_platform  as enum ('google_meet', 'kenet');
create type recurrence_type as enum ('none', 'day', 'week', 'month');

-- Rank distinguishes "primary" vs "assistant fallback" class rep. Both hold
-- IDENTICAL permissions at all times — this is not a privilege tier, purely
-- a readiness label. The assistant only matters operationally if the
-- primary needs replacing, which a Faculty Rep does manually (no
-- auto-promotion logic at MVP).
create type class_rep_rank as enum ('primary', 'assistant');

-- Status of a student's request to join a cohort. Declined requests can be
-- re-submitted (no permanent block) — history is kept as separate rows
-- rather than overwritten, so a rep can see prior decisions.
create type join_request_status as enum ('pending', 'approved', 'declined');


-- Faculty --------------------------------------------------------------------
create table faculties (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  abbreviation  text not null,
  description   text,
  created_at    timestamptz not null default now()
);

-- Department ------------------------------------------------------------------
-- Ownership: created/managed by the Faculty Rep of the parent faculty (or
-- superadmin during early seeding). See 0006 RLS.
create table departments (
  id            uuid primary key default gen_random_uuid(),
  faculty_id    uuid not null references faculties (id) on delete cascade,
  name          text not null,
  description   text,
  created_at    timestamptz not null default now()
);

-- Programme ----------------------------------------------------------------------
-- Government-sponsored (e.g. "EB3") and self-sponsored (e.g. "EBS3") variants
-- of the SAME programme share one row here — they run identical courses.
-- The only functional difference is pace choice (see cohorts.pace below):
-- self-sponsored students may choose bimester or trimester, government-
-- sponsored are locked to the standard pace. That distinction is resolved by
-- registration-number parsing at signup time, NOT by duplicating this table.
create table programmes (
  id                    uuid primary key default gen_random_uuid(),
  department_id         uuid not null references departments (id) on delete cascade,
  name                  text not null,
  abbreviation          text not null,
  code                  text not null,          -- e.g. 'EB3' (canonical code;
                                                  -- 'EBS3' self-sponsored variant
                                                  -- is parsed at signup, not stored
                                                  -- as a separate programme)
  description           text,
  level                 programme_level not null,
  duration_semesters    int  not null check (duration_semesters > 0),
  created_at            timestamptz not null default now()
);

-- Course (Unit) ------------------------------------------------------------------
-- Faculty Reps can add a course to ANY semester of a programme in their
-- faculty. Class Reps can only add a course to their OWN cohort's CURRENT
-- semester (e.g. a 3.1 rep can add a course for semester_taught = 3, not any
-- other semester). Enforced in 0006 RLS, not here.
create table courses (
  id                uuid primary key default gen_random_uuid(),
  programme_id        uuid not null references programmes (id) on delete cascade,
  name              text not null,
  abbreviation      text not null,
  description       text,
  semester_taught   int not null check (semester_taught > 0),
  lecture_hours     int check (lecture_hours is null or lecture_hours > 0),
  credits           int check (credits is null or credits > 0),
  created_at        timestamptz not null default now()
);

-- Cohort ---------------------------------------------------------------------
-- name is composed by the cohort-creation function (0003) as
-- "<programme.abbreviation> <intake_year>"; stored for cheap reads since it
-- depends on a joined table.
-- join_code is retained even though the PRIMARY join flow is now
-- request/approve (see 0003 cohort_join_requests) — kept unused for now so a
-- future self-service fallback doesn't require a schema migration to
-- reintroduce it.
create table cohorts (
  id                uuid primary key default gen_random_uuid(),
  programme_id        uuid not null references programmes (id) on delete restrict,
  name              text not null,
  join_code         text not null unique,
  intake_year       int not null,
  current_semester  int not null check (current_semester > 0),
  pace              cohort_pace not null default 'bimester',
  created_at        timestamptz not null default now()
);

-- Building -------------------------------------------------------------------
create table buildings (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  abbreviation text not null,
  description  text,
  image_url    text,
  created_at   timestamptz not null default now()
);

-- Room -----------------------------------------------------------------------
-- Building-specific: only rooms a building actually has get a row. Display
-- name (e.g. "S-101") is composed on read as
-- buildings.abbreviation || '-' || rooms.number, never stored, so it can
-- never drift from the building it belongs to.
create table rooms (
  id          uuid primary key default gen_random_uuid(),
  building_id uuid not null references buildings (id) on delete cascade,
  number      text not null,
  capacity    int check (capacity is null or capacity > 0),
  room_type   room_type not null,
  created_at  timestamptz not null default now(),
  constraint rooms_building_number_unique unique (building_id, number)
);

-- Venue ----------------------------------------------------------------------
-- Conflict model (the invariant the whole app protects):
--   * PHYSICAL venues are SHARED reference data — exactly one venue row per
--     room (venues_room_idx below). Two events pointing at that room share
--     venue_id, so the EXCLUDE constraint in 0004 catches double-booking.
--   * ONLINE venues are created PER EVENT (a fresh row per meeting link).
--     They never share venue_id, so the same EXCLUDE never fires falsely.
create table venues (
  id            uuid primary key default gen_random_uuid(),
  type          venue_type not null,
  room_id       uuid references rooms (id) on delete set null,
  meeting_link  text,
  platform      venue_platform,
  label         text,
  created_at    timestamptz not null default now(),
  constraint venues_physical_has_room
    check (type <> 'physical' or room_id is not null),
  constraint venues_online_has_link
    check (type <> 'online' or meeting_link is not null)
);

create unique index venues_room_idx on venues (room_id) where room_id is not null;
