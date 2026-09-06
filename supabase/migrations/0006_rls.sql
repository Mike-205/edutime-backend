-- ============================================================================
-- 0006: Row-Level Security
-- ============================================================================
-- Superadmin is NOT represented here at all — it operates via a Postgres
-- role / Supabase service_role key that bypasses RLS entirely, since it's
-- infrastructure-only and never exposed in the app UI.
--
-- Helper: current user's row, looked up once per policy check.
-- ============================================================================

create or replace function current_app_user()
returns users
language sql
stable
security definer
as $$
  select * from users where id = auth.uid();
$$;


-- ----------------------------------------------------------------------------
-- users
-- ----------------------------------------------------------------------------
alter table users enable row level security;

-- Anyone authenticated can read basic user rows (needed for e.g. "who's my
-- class rep", displaying names on audit trails, etc). If you want to lock
-- this down further later (e.g. hide reg_number from other students), split
-- into a public view — not necessary for MVP.
create policy users_read_all
  on users for select
  using (auth.uid() is not null);

-- Users can update their own profile fields (name, notification prefs —
-- add a column for that when it exists). Role/cohort_id/class_rep_rank
-- changes must go through the privileged functions in 0003, never a direct
-- client UPDATE, so this policy intentionally does NOT grant those columns
-- via a blanket USING/CHECK — enforce column-level restriction with a
-- trigger or a narrower column grant if your Postgres version doesn't
-- support column-level RLS cleanly.
create policy users_update_own_profile
  on users for update
  using (id = auth.uid());


-- ----------------------------------------------------------------------------
-- departments / programmes — Faculty Rep manages their own faculty's, full stop
-- ----------------------------------------------------------------------------
alter table departments enable row level security;
alter table programmes enable row level security;

create policy departments_read_all
  on departments for select
  using (auth.uid() is not null);

create policy departments_write_faculty_rep
  on departments for all
  using (
    exists (
      select 1 from current_app_user() u
      where u.role = 'faculty_rep' and u.faculty_id = departments.faculty_id
    )
  )
  with check (
    exists (
      select 1 from current_app_user() u
      where u.role = 'faculty_rep' and u.faculty_id = departments.faculty_id
    )
  );

create policy programmes_read_all
  on programmes for select
  using (auth.uid() is not null);

create policy programmes_write_faculty_rep
  on programmes for all
  using (
    exists (
      select 1 from current_app_user() u
      join departments d on d.id = programmes.department_id
      where u.role = 'faculty_rep' and u.faculty_id = d.faculty_id
    )
  )
  with check (
    exists (
      select 1 from current_app_user() u
      join departments d on d.id = programmes.department_id
      where u.role = 'faculty_rep' and u.faculty_id = d.faculty_id
    )
  );


-- ----------------------------------------------------------------------------
-- courses — Faculty Rep: any semester in their faculty. Class Rep: ONLY
-- their own cohort's CURRENT semester.
-- ----------------------------------------------------------------------------
alter table courses enable row level security;

create policy courses_read_all
  on courses for select
  using (auth.uid() is not null);

create policy courses_write_faculty_rep
  on courses for all
  using (
    exists (
      select 1 from current_app_user() u
      join programmes p on p.id = courses.programme_id
      join departments d on d.id = p.department_id
      where u.role = 'faculty_rep' and u.faculty_id = d.faculty_id
    )
  )
  with check (
    exists (
      select 1 from current_app_user() u
      join programmes p on p.id = courses.programme_id
      join departments d on d.id = p.department_id
      where u.role = 'faculty_rep' and u.faculty_id = d.faculty_id
    )
  );

-- Class rep insert-only, scoped to their cohort's programme AND current
-- semester specifically (not update/delete — editing/removing a course
-- they didn't scope-check at creation stays a faculty_rep-only action).
create policy courses_insert_class_rep_current_semester
  on courses for insert
  with check (
    exists (
      select 1 from current_app_user() u
      join cohorts c on c.id = u.cohort_id
      where u.role = 'class_rep'
        and c.programme_id = courses.programme_id
        and c.current_semester = courses.semester_taught
    )
  );


-- ----------------------------------------------------------------------------
-- cohorts — read by anyone (needed for join-request cohort picker); writes
-- only via the privileged functions in 0003 (create_cohort_with_class_rep),
-- so no direct INSERT/UPDATE policy is granted here.
-- ----------------------------------------------------------------------------
alter table cohorts enable row level security;

create policy cohorts_read_all
  on cohorts for select
  using (auth.uid() is not null);

-- Class rep can update their OWN cohort's config (semester progression,
-- pace) — but not create new cohorts (that stays Faculty-Rep-only, via the
-- atomic function).
create policy cohorts_update_own_class_rep
  on cohorts for update
  using (
    exists (
      select 1 from current_app_user() u
      where u.role = 'class_rep' and u.cohort_id = cohorts.id
    )
  );


-- ----------------------------------------------------------------------------
-- cohort_join_requests
-- ----------------------------------------------------------------------------
alter table cohort_join_requests enable row level security;

create policy join_requests_student_read_own
  on cohort_join_requests for select
  using (student_id = auth.uid());

create policy join_requests_rep_read_for_their_cohort
  on cohort_join_requests for select
  using (
    exists (
      select 1 from current_app_user() u
      where u.role = 'class_rep' and u.cohort_id = cohort_join_requests.cohort_id
    )
  );

create policy join_requests_student_create
  on cohort_join_requests for insert
  with check (student_id = auth.uid());

-- Approve/decline go through the SECURITY DEFINER functions in 0003, not a
-- direct UPDATE — no update policy granted here on purpose.


-- ----------------------------------------------------------------------------
-- venues / rooms / buildings — read-only to all app users; writes are
-- superadmin-seeded only (bypasses RLS), no policy needed for writes.
-- ----------------------------------------------------------------------------
alter table buildings enable row level security;
alter table rooms enable row level security;
alter table venues enable row level security;

create policy buildings_read_all on buildings for select using (auth.uid() is not null);
create policy rooms_read_all     on rooms     for select using (auth.uid() is not null);
create policy venues_read_all    on venues    for select using (auth.uid() is not null);


-- ----------------------------------------------------------------------------
-- events — the core scheduling table
-- ----------------------------------------------------------------------------
-- WHY events isn't fully cohort-restricted on SELECT: venue availability
-- (0007) needs to know occupancy across ALL cohorts. Rather than opening up
-- events directly, cross-cohort visibility is handled by a narrow view that
-- exposes only venue_id + time range — see 0007. This policy keeps full
-- event detail (lecturer name, course, attendance status) private to the
-- owning cohort.
alter table events enable row level security;

create policy events_read_own_cohort
  on events for select
  using (
    exists (
      select 1 from current_app_user() u
      where u.cohort_id = events.cohort_id
    )
  );

create policy events_write_class_rep_own_cohort
  on events for insert
  with check (
    exists (
      select 1 from current_app_user() u
      where u.role = 'class_rep' and u.cohort_id = events.cohort_id
    )
  );

create policy events_update_class_rep_own_cohort
  on events for update
  using (
    exists (
      select 1 from current_app_user() u
      where u.role = 'class_rep' and u.cohort_id = events.cohort_id
    )
  );

-- Faculty Reps deliberately get NO write access to events — scheduling
-- authority belongs to class reps alone, per the trust model.


-- ----------------------------------------------------------------------------
-- event_audit_log — append-only, read by cohort members, never editable
-- ----------------------------------------------------------------------------
alter table event_audit_log enable row level security;

create policy audit_log_read_own_cohort
  on event_audit_log for select
  using (
    exists (
      select 1 from current_app_user() u
      join events e on e.id = event_audit_log.event_id
      where u.cohort_id = e.cohort_id
    )
  );

-- No insert/update/delete policy: all writes to this table happen through
-- SECURITY DEFINER functions (reschedule_event, and equivalent
-- create/cancel functions to be added alongside the app's event-creation
-- flow), never direct client writes.


-- ----------------------------------------------------------------------------
-- notifications — a user only ever sees their own
-- ----------------------------------------------------------------------------
alter table notifications enable row level security;

create policy notifications_read_own
  on notifications for select
  using (user_id = auth.uid());

create policy notifications_mark_read_own
  on notifications for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
