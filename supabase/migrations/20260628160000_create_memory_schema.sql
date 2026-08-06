-- Phase 1 Supabase memory schema
-- Purpose: durable project/session memory for an API based GPT companion app.

create extension if not exists pgcrypto with schema extensions;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table if not exists public.memory_projects (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null,
  description text,
  status text not null default 'active' check (status in ('active', 'archived')),
  repo_url text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.memory_sessions (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  project_id uuid not null references public.memory_projects(id) on delete cascade,
  title text not null,
  source text not null default 'app' check (source in ('app', 'chatgpt_web', 'github', 'document', 'manual')),
  external_ref text,
  metadata jsonb not null default '{}'::jsonb,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.memory_messages (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  project_id uuid not null references public.memory_projects(id) on delete cascade,
  session_id uuid references public.memory_sessions(id) on delete cascade,
  role text not null check (role in ('system', 'user', 'assistant', 'tool', 'note')),
  content text not null,
  token_estimate integer,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.memory_session_summaries (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  project_id uuid not null references public.memory_projects(id) on delete cascade,
  session_id uuid references public.memory_sessions(id) on delete cascade,
  summary text not null,
  decisions text[] not null default '{}',
  open_tasks text[] not null default '{}',
  files_discussed text[] not null default '{}',
  next_steps text[] not null default '{}',
  importance integer not null default 3 check (importance between 1 and 5),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.memory_items (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  project_id uuid not null references public.memory_projects(id) on delete cascade,
  source_session_id uuid references public.memory_sessions(id) on delete set null,
  title text not null,
  content text not null,
  tags text[] not null default '{}',
  importance integer not null default 3 check (importance between 1 and 5),
  is_pinned boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.memory_artifacts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  project_id uuid not null references public.memory_projects(id) on delete cascade,
  session_id uuid references public.memory_sessions(id) on delete set null,
  name text not null,
  artifact_type text not null default 'link',
  url_or_path text,
  notes text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.memory_files (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  project_id uuid not null references public.memory_projects(id) on delete cascade,
  session_id uuid references public.memory_sessions(id) on delete set null,
  file_name text not null,
  file_type text,
  file_hash text,
  storage_path text,
  summary text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.memory_tool_events (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  project_id uuid references public.memory_projects(id) on delete cascade,
  session_id uuid references public.memory_sessions(id) on delete set null,
  action text not null,
  status text not null default 'ok' check (status in ('ok', 'error')),
  request jsonb not null default '{}'::jsonb,
  response jsonb not null default '{}'::jsonb,
  error text,
  created_at timestamptz not null default now()
);

create index if not exists idx_memory_projects_owner on public.memory_projects(owner_id);
create index if not exists idx_memory_sessions_owner_project on public.memory_sessions(owner_id, project_id);
create index if not exists idx_memory_messages_owner_session on public.memory_messages(owner_id, session_id);
create index if not exists idx_memory_session_summaries_owner_project on public.memory_session_summaries(owner_id, project_id);
create index if not exists idx_memory_items_owner_project on public.memory_items(owner_id, project_id);
create index if not exists idx_memory_items_tags on public.memory_items using gin(tags);
create index if not exists idx_memory_items_title_trgm_ready on public.memory_items(project_id, updated_at desc);
create index if not exists idx_memory_artifacts_owner_project on public.memory_artifacts(owner_id, project_id);
create index if not exists idx_memory_files_owner_project on public.memory_files(owner_id, project_id);
create index if not exists idx_memory_tool_events_owner_project on public.memory_tool_events(owner_id, project_id);

drop trigger if exists set_memory_projects_updated_at on public.memory_projects;
create trigger set_memory_projects_updated_at
before update on public.memory_projects
for each row execute function public.set_updated_at();

drop trigger if exists set_memory_sessions_updated_at on public.memory_sessions;
create trigger set_memory_sessions_updated_at
before update on public.memory_sessions
for each row execute function public.set_updated_at();

drop trigger if exists set_memory_session_summaries_updated_at on public.memory_session_summaries;
create trigger set_memory_session_summaries_updated_at
before update on public.memory_session_summaries
for each row execute function public.set_updated_at();

drop trigger if exists set_memory_items_updated_at on public.memory_items;
create trigger set_memory_items_updated_at
before update on public.memory_items
for each row execute function public.set_updated_at();

drop trigger if exists set_memory_artifacts_updated_at on public.memory_artifacts;
create trigger set_memory_artifacts_updated_at
before update on public.memory_artifacts
for each row execute function public.set_updated_at();

drop trigger if exists set_memory_files_updated_at on public.memory_files;
create trigger set_memory_files_updated_at
before update on public.memory_files
for each row execute function public.set_updated_at();

create or replace function public.memory_project_is_owned(check_project_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.memory_projects
    where id = check_project_id
      and owner_id = auth.uid()
  );
$$;

create or replace function public.memory_session_is_owned(check_session_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select check_session_id is null or exists (
    select 1
    from public.memory_sessions
    where id = check_session_id
      and owner_id = auth.uid()
  );
$$;

alter table public.memory_projects enable row level security;
alter table public.memory_sessions enable row level security;
alter table public.memory_messages enable row level security;
alter table public.memory_session_summaries enable row level security;
alter table public.memory_items enable row level security;
alter table public.memory_artifacts enable row level security;
alter table public.memory_files enable row level security;
alter table public.memory_tool_events enable row level security;

drop policy if exists memory_projects_owner_all on public.memory_projects;
create policy memory_projects_owner_all
on public.memory_projects
for all
to authenticated
using (owner_id = auth.uid())
with check (owner_id = auth.uid());

drop policy if exists memory_sessions_owner_all on public.memory_sessions;
create policy memory_sessions_owner_all
on public.memory_sessions
for all
to authenticated
using (owner_id = auth.uid())
with check (owner_id = auth.uid() and public.memory_project_is_owned(project_id));

drop policy if exists memory_messages_owner_all on public.memory_messages;
create policy memory_messages_owner_all
on public.memory_messages
for all
to authenticated
using (owner_id = auth.uid())
with check (
  owner_id = auth.uid()
  and public.memory_project_is_owned(project_id)
  and public.memory_session_is_owned(session_id)
);

drop policy if exists memory_session_summaries_owner_all on public.memory_session_summaries;
create policy memory_session_summaries_owner_all
on public.memory_session_summaries
for all
to authenticated
using (owner_id = auth.uid())
with check (
  owner_id = auth.uid()
  and public.memory_project_is_owned(project_id)
  and public.memory_session_is_owned(session_id)
);

drop policy if exists memory_items_owner_all on public.memory_items;
create policy memory_items_owner_all
on public.memory_items
for all
to authenticated
using (owner_id = auth.uid())
with check (
  owner_id = auth.uid()
  and public.memory_project_is_owned(project_id)
  and public.memory_session_is_owned(source_session_id)
);

drop policy if exists memory_artifacts_owner_all on public.memory_artifacts;
create policy memory_artifacts_owner_all
on public.memory_artifacts
for all
to authenticated
using (owner_id = auth.uid())
with check (
  owner_id = auth.uid()
  and public.memory_project_is_owned(project_id)
  and public.memory_session_is_owned(session_id)
);

drop policy if exists memory_files_owner_all on public.memory_files;
create policy memory_files_owner_all
on public.memory_files
for all
to authenticated
using (owner_id = auth.uid())
with check (
  owner_id = auth.uid()
  and public.memory_project_is_owned(project_id)
  and public.memory_session_is_owned(session_id)
);

drop policy if exists memory_tool_events_owner_all on public.memory_tool_events;
create policy memory_tool_events_owner_all
on public.memory_tool_events
for all
to authenticated
using (owner_id = auth.uid())
with check (
  owner_id = auth.uid()
  and (project_id is null or public.memory_project_is_owned(project_id))
  and public.memory_session_is_owned(session_id)
);
