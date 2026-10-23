-- =============================================================================
-- CAIE O Level Progress Tracker — Supabase schema
-- Subjects: Maths 4024, Chemistry 5070, Physics 5054, Computer Science 2210
-- English deferred. Spaced-repetition trigger + RLS included.
-- =============================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.priority_level as enum ('High', 'Med', 'Low');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.task_type as enum ('Theory', 'Topical', 'Quiz', 'Yearly');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.task_status as enum ('Not Started', 'In Progress', 'Done');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.app_role as enum ('tutor', 'student');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Profiles (maps Supabase Auth users → tutor | student)
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text,
  role public.app_role not null default 'student',
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.email),
    coalesce((new.raw_user_meta_data->>'role')::public.app_role, 'student')
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.current_role()
returns public.app_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- ---------------------------------------------------------------------------
-- Core tables
-- ---------------------------------------------------------------------------
create table if not exists public.subjects (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  caie_code text not null unique,
  total_chapters integer not null check (total_chapters >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.chapters (
  id uuid primary key default gen_random_uuid(),
  subject_id uuid not null references public.subjects (id) on delete cascade,
  name text not null,
  syllabus_code text,
  sort_order integer not null default 0,
  priority_level public.priority_level not null default 'Med',
  created_at timestamptz not null default now(),
  unique (subject_id, name)
);

create index if not exists chapters_subject_id_idx on public.chapters (subject_id);
create index if not exists chapters_subject_sort_idx on public.chapters (subject_id, sort_order);

create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  chapter_id uuid not null references public.chapters (id) on delete cascade,
  task_type public.task_type not null,
  status public.task_status not null default 'Not Started',
  confidence_score integer check (
    confidence_score is null or (confidence_score between 1 and 5)
  ),
  next_review_date timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (chapter_id, task_type)
);

create index if not exists tasks_chapter_id_idx on public.tasks (chapter_id);
create index if not exists tasks_next_review_date_idx on public.tasks (next_review_date);
create index if not exists tasks_status_idx on public.tasks (status);

create table if not exists public.mistake_log (
  id uuid primary key default gen_random_uuid(),
  chapter_id uuid not null references public.chapters (id) on delete cascade,
  paper_reference text,
  mistake_description text not null,
  correct_concept text not null,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists mistake_log_chapter_id_idx on public.mistake_log (chapter_id);

-- ---------------------------------------------------------------------------
-- Spaced repetition: set next_review_date when confidence_score changes
--   1–2 → +3 days | 3 → +7 days | 4–5 → +21 days
-- ---------------------------------------------------------------------------
create or replace function public.set_next_review_date_from_confidence()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();

  if new.confidence_score is null then
    return new;
  end if;

  -- Only recalculate when score is newly set or actually changed
  if tg_op = 'INSERT'
     or old.confidence_score is distinct from new.confidence_score then
    if new.confidence_score between 1 and 2 then
      new.next_review_date := now() + interval '3 days';
    elsif new.confidence_score = 3 then
      new.next_review_date := now() + interval '7 days';
    elsif new.confidence_score between 4 and 5 then
      new.next_review_date := now() + interval '21 days';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_tasks_spaced_repetition on public.tasks;
create trigger trg_tasks_spaced_repetition
  before insert or update of confidence_score on public.tasks
  for each row
  execute function public.set_next_review_date_from_confidence();

-- Keep updated_at fresh on any task update
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_tasks_touch_updated_at on public.tasks;
create trigger trg_tasks_touch_updated_at
  before update on public.tasks
  for each row
  execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Row Level Security
-- Shared household model: authenticated tutor + student both see syllabus data.
-- Tutor: full write. Student: update tasks + insert/read mistakes.
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.subjects enable row level security;
alter table public.chapters enable row level security;
alter table public.tasks enable row level security;
alter table public.mistake_log enable row level security;

-- Profiles
drop policy if exists profiles_select_own_or_tutor on public.profiles;
create policy profiles_select_own_or_tutor on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.current_role() = 'tutor');

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

drop policy if exists profiles_tutor_update_roles on public.profiles;
create policy profiles_tutor_update_roles on public.profiles
  for update to authenticated
  using (public.current_role() = 'tutor')
  with check (public.current_role() = 'tutor');

-- Subjects / chapters: everyone authenticated can read; tutor writes
drop policy if exists subjects_select_authenticated on public.subjects;
create policy subjects_select_authenticated on public.subjects
  for select to authenticated using (true);

drop policy if exists subjects_write_tutor on public.subjects;
create policy subjects_write_tutor on public.subjects
  for all to authenticated
  using (public.current_role() = 'tutor')
  with check (public.current_role() = 'tutor');

drop policy if exists chapters_select_authenticated on public.chapters;
create policy chapters_select_authenticated on public.chapters
  for select to authenticated using (true);

drop policy if exists chapters_write_tutor on public.chapters;
create policy chapters_write_tutor on public.chapters
  for all to authenticated
  using (public.current_role() = 'tutor')
  with check (public.current_role() = 'tutor');

-- Tasks: both can read; student + tutor can update; tutor can insert/delete
drop policy if exists tasks_select_authenticated on public.tasks;
create policy tasks_select_authenticated on public.tasks
  for select to authenticated using (true);

drop policy if exists tasks_update_authenticated on public.tasks;
create policy tasks_update_authenticated on public.tasks
  for update to authenticated
  using (public.current_role() in ('tutor', 'student'))
  with check (public.current_role() in ('tutor', 'student'));

drop policy if exists tasks_insert_tutor on public.tasks;
create policy tasks_insert_tutor on public.tasks
  for insert to authenticated
  with check (public.current_role() = 'tutor');

drop policy if exists tasks_delete_tutor on public.tasks;
create policy tasks_delete_tutor on public.tasks
  for delete to authenticated
  using (public.current_role() = 'tutor');

-- Mistake log: both read; both insert; tutor update/delete; student update own
drop policy if exists mistake_log_select_authenticated on public.mistake_log;
create policy mistake_log_select_authenticated on public.mistake_log
  for select to authenticated using (true);

drop policy if exists mistake_log_insert_authenticated on public.mistake_log;
create policy mistake_log_insert_authenticated on public.mistake_log
  for insert to authenticated
  with check (
    public.current_role() in ('tutor', 'student')
    and (created_by is null or created_by = auth.uid())
  );

drop policy if exists mistake_log_update_own_or_tutor on public.mistake_log;
create policy mistake_log_update_own_or_tutor on public.mistake_log
  for update to authenticated
  using (
    public.current_role() = 'tutor' or created_by = auth.uid()
  )
  with check (
    public.current_role() = 'tutor' or created_by = auth.uid()
  );

drop policy if exists mistake_log_delete_tutor on public.mistake_log;
create policy mistake_log_delete_tutor on public.mistake_log
  for delete to authenticated
  using (public.current_role() = 'tutor');

-- ---------------------------------------------------------------------------
-- Seed: subjects + chapters + default 4 tasks per chapter
-- ---------------------------------------------------------------------------
do $$
declare
  v_subject_id uuid;
  v_chapter_id uuid;
  v_sort integer;
begin
  -- Idempotent-ish: skip if subjects already seeded
  if exists (select 1 from public.subjects) then
    raise notice 'subjects already present — skipping seed';
    return;
  end if;

  -- Mathematics (4024)
  insert into public.subjects (name, caie_code, total_chapters)
  values ('Mathematics', '4024', 68)
  returning id into v_subject_id;

  v_sort := 0;
  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.1 Types of number', '1.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.2 Sets', '1.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.3 Powers and roots', '1.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.4 Fractions, decimals and percentages', '1.4', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.5 Ordering', '1.5', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.6 The four operations', '1.6', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.7 Indices I', '1.7', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.8 Standard form', '1.8', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.9 Estimation', '1.9', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.10 Limits of accuracy', '1.10', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.11 Ratio and proportion', '1.11', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.12 Rates', '1.12', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.13 Percentages', '1.13', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.14 Using a calculator', '1.14', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.15 Time', '1.15', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.16 Money', '1.16', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.17 Exponential growth and decay', '1.17', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.18 Surds', '1.18', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.1 Introduction to algebra', '2.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.2 Algebraic manipulation', '2.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.3 Algebraic fractions', '2.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.4 Indices II', '2.4', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.5 Equations', '2.5', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.6 Inequalities', '2.6', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.7 Sequences', '2.7', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.8 Proportion', '2.8', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.9 Graphs in practical situations', '2.9', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.10 Graphs of functions', '2.10', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.11 Sketching curves', '2.11', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.12 Functions', '2.12', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '3.1 Coordinates', '3.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '3.2 Drawing linear graphs', '3.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '3.3 Gradient of linear graphs', '3.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '3.4 Length and midpoint', '3.4', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '3.5 Equations of linear graphs', '3.5', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '3.6 Parallel lines', '3.6', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '3.7 Perpendicular lines', '3.7', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '4.1 Geometrical terms', '4.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '4.2 Geometrical constructions', '4.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '4.3 Scale drawings', '4.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '4.4 Similarity', '4.4', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '4.5 Symmetry', '4.5', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '4.6 Angles', '4.6', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '4.7 Circle theorems I', '4.7', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '4.8 Circle theorems II', '4.8', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '5.1 Units of measure', '5.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '5.2 Area and perimeter', '5.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '5.3 Circles, arcs and sectors', '5.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '5.4 Surface area and volume', '5.4', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '5.5 Compound shapes and parts of shapes', '5.5', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '6.1 Pythagoras’ theorem', '6.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '6.2 Right-angled triangles', '6.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '6.3 Non-right-angled triangles', '6.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '6.4 Pythagoras’ theorem and trigonometry', '6.4', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '7.1 Transformations', '7.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '7.2 Vectors in two dimensions', '7.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '7.3 Magnitude of a vector', '7.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '7.4 Vector geometry', '7.4', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '8.1 Introduction to probability', '8.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '8.2 Relative and expected frequencies', '8.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '8.3 Probability of combined events', '8.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '9.1 Classifying statistical data', '9.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '9.2 Interpreting statistical data', '9.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '9.3 Averages and measures of spread', '9.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '9.4 Statistical charts and diagrams', '9.4', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '9.5 Scatter diagrams', '9.5', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '9.6 Cumulative frequency diagrams', '9.6', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '9.7 Histograms', '9.7', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  -- Chemistry (5070)
  insert into public.subjects (name, caie_code, total_chapters)
  values ('Chemistry', '5070', 49)
  returning id into v_subject_id;

  v_sort := 0;
  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.1 Solids, liquids and gases', '1.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.2 Diffusion', '1.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.1 Elements, compounds and mixtures', '2.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.2 Atomic structure and the Periodic Table', '2.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.3 Isotopes', '2.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.4 Ion and ionic bonds', '2.4', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.5 Simple molecules and covalent bonds', '2.5', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.6 Giant covalent structures', '2.6', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.7 Metallic bonding', '2.7', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '3.1 Formulae', '3.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '3.2 Relative masses of atoms and molecules', '3.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '3.3 The mole and the Avogadro constant', '3.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '4.1 Electrolysis', '4.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '4.2 Hydrogen–oxygen fuel cells', '4.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '5.1 Exothermic and endothermic reactions', '5.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '6.1 Physical and chemical changes', '6.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '6.2 Rate of reaction', '6.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '6.3 Reversible reactions and equilibrium', '6.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '6.4 Redox', '6.4', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '7.1 The characteristic properties of acids and bases', '7.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '7.2 Oxides', '7.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '7.3 Preparation of salts', '7.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '8.1 Arrangement of elements', '8.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '8.2 Group I properties', '8.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '8.3 Group VII properties', '8.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '8.4 Transition elements', '8.4', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '8.5 Noble gases', '8.5', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '9.1 Properties of metals', '9.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '9.2 Uses of metals', '9.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '9.3 Alloys and their properties', '9.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '9.4 Reactivity series', '9.4', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '9.5 Corrosion of metals', '9.5', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '9.6 Extraction of metals', '9.6', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '10.1 Water', '10.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '10.2 Fertilisers', '10.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '10.3 Air quality and climate', '10.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '11.1 Formulae, functional groups and terminology', '11.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '11.2 Naming organic compounds', '11.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '11.3 Fuels', '11.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '11.4 Alkanes', '11.4', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '11.5 Alkenes', '11.5', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '11.6 Alcohols', '11.6', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '11.7 Carboxylic acids', '11.7', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '11.8 Polymers', '11.8', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '12.1 Experimental design', '12.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '12.2 Acid–base titrations', '12.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '12.3 Chromatography', '12.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '12.4 Separation and purification', '12.4', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '12.5 Identification of ions and gases', '12.5', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  -- Physics (5054)
  insert into public.subjects (name, caie_code, total_chapters)
  values ('Physics', '5054', 25)
  returning id into v_subject_id;

  v_sort := 0;
  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.1 Physical quantities and measurement techniques', '1.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.2 Motion', '1.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.3 Mass and weight', '1.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.4 Density', '1.4', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.5 Forces', '1.5', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.6 Momentum', '1.6', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.7 Energy, work and power', '1.7', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.8 Pressure', '1.8', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.1 Kinetic particle model of matter', '2.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.2 Thermal properties and temperature', '2.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.3 Transfer of thermal energy', '2.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '3.1 General properties of waves', '3.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '3.2 Light', '3.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '3.3 Electromagnetic spectrum', '3.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '3.4 Sound', '3.4', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '4.1 Simple magnetism and magnetic fields', '4.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '4.2 Electrical quantities', '4.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '4.3 Electric circuits', '4.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '4.4 Practical electricity', '4.4', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '4.5 Electromagnetic effects', '4.5', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '4.6 Uses of an oscilloscope', '4.6', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '5.1 The nuclear model of the atom', '5.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '5.2 Radioactivity', '5.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '6.1 Earth and the Solar System', '6.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '6.2 Stars and the Universe', '6.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  -- Computer Science (2210)
  insert into public.subjects (name, caie_code, total_chapters)
  values ('Computer Science', '2210', 24)
  returning id into v_subject_id;

  v_sort := 0;
  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.1 Number systems', '1.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.2 Text, sound and images', '1.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '1.3 Data storage and compression', '1.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.1 Types and methods of data transmission', '2.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.2 Methods of error detection', '2.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '2.3 Encryption', '2.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '3.1 Computer architecture', '3.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '3.2 Input and output devices', '3.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '3.3 Data storage', '3.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '3.4 Network hardware', '3.4', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '4.1 Types of software and interrupts', '4.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '4.2 Types of programming language, translators and integrated development environments', '4.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '5.1 The internet and the world wide web', '5.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '5.2 Digital currency', '5.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '5.3 Cyber security', '5.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '6.1 Automated systems', '6.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '6.2 Robotics', '6.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '6.3 Artificial intelligence', '6.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '7 Algorithm design and problem-solving', '7', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '8.1 Programming concepts', '8.1', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '8.2 Arrays', '8.2', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '8.3 File handling', '8.3', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '9 Databases', '9', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

  v_sort := v_sort + 1;
  insert into public.chapters (subject_id, name, syllabus_code, sort_order, priority_level)
  values (v_subject_id, '10 Boolean logic', '10', v_sort, 'Med')
  returning id into v_chapter_id;

  insert into public.tasks (chapter_id, task_type, status)
  values
    (v_chapter_id, 'Theory', 'Not Started'),
    (v_chapter_id, 'Topical', 'Not Started'),
    (v_chapter_id, 'Quiz', 'Not Started'),
    (v_chapter_id, 'Yearly', 'Not Started');

end $$;

-- Helpful views for dashboards (optional)
create or replace view public.subject_progress as
select
  s.id as subject_id,
  s.name as subject_name,
  s.caie_code,
  count(t.id) as total_tasks,
  count(t.id) filter (where t.status = 'Done') as completed_tasks,
  round(
    100.0 * count(t.id) filter (where t.status = 'Done') / nullif(count(t.id), 0),
    1
  ) as percent_complete
from public.subjects s
left join public.chapters c on c.subject_id = s.id
left join public.tasks t on t.chapter_id = c.id
group by s.id, s.name, s.caie_code;

create or replace view public.spaced_repetition_queue as
select
  t.id as task_id,
  s.name as subject_name,
  c.name as chapter_name,
  c.priority_level,
  t.task_type,
  t.confidence_score,
  t.next_review_date,
  t.status
from public.tasks t
join public.chapters c on c.id = t.chapter_id
join public.subjects s on s.id = c.subject_id
where t.next_review_date is not null
  and t.next_review_date::date <= current_date
order by t.next_review_date asc, c.priority_level asc, t.confidence_score asc nulls first;

create or replace view public.bottleneck_chapters as
select
  c.id as chapter_id,
  s.name as subject_name,
  c.name as chapter_name,
  c.priority_level,
  avg(t.confidence_score)::numeric(3,2) as avg_confidence,
  count(m.id) as mistake_count
from public.chapters c
join public.subjects s on s.id = c.subject_id
left join public.tasks t on t.chapter_id = c.id and t.confidence_score is not null
left join public.mistake_log m on m.chapter_id = c.id
group by c.id, s.name, c.name, c.priority_level
having
  avg(t.confidence_score) <= 2.5
  or count(m.id) >= 3
order by avg(t.confidence_score) asc nulls last, count(m.id) desc;

grant select on public.subject_progress to authenticated;
grant select on public.spaced_repetition_queue to authenticated;
grant select on public.bottleneck_chapters to authenticated;

