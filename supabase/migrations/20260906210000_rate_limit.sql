-- Basic per-installation rate limiting.
--
-- Intentionally simple: a fixed window counter. Atomic quota enforcement
-- already caps paid AI spend per installation; this only blunts bursts and
-- obvious hammering. Real abuse protection (App Attest, IP limits) is
-- documented in SECURITY.md.

create table public.rate_limit_windows (
  installation_id uuid primary key,
  window_start timestamptz not null default now(),
  hits integer not null default 0
);

alter table public.rate_limit_windows enable row level security;
revoke all on table public.rate_limit_windows from public, anon, authenticated;

-- Returns { allowed, retry_after_seconds }. One atomic upsert per call.
create function public.check_rate_limit(
  p_installation_id uuid,
  p_max_hits integer default 12,
  p_window_seconds integer default 60
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_row public.rate_limit_windows;
begin
  insert into public.rate_limit_windows (installation_id, window_start, hits)
  values (p_installation_id, now(), 1)
  on conflict (installation_id) do update
    set hits = case
          when public.rate_limit_windows.window_start
               < now() - make_interval(secs => p_window_seconds)
          then 1
          else public.rate_limit_windows.hits + 1
        end,
        window_start = case
          when public.rate_limit_windows.window_start
               < now() - make_interval(secs => p_window_seconds)
          then now()
          else public.rate_limit_windows.window_start
        end
  returning * into v_row;

  if v_row.hits > p_max_hits then
    return jsonb_build_object(
      'allowed', false,
      'retry_after_seconds',
      greatest(
        1,
        ceil(
          extract(epoch from (
            v_row.window_start + make_interval(secs => p_window_seconds) - now()
          ))
        )::integer
      )
    );
  end if;

  return jsonb_build_object('allowed', true, 'retry_after_seconds', 0);
end;
$$;

revoke execute on function public.check_rate_limit(uuid, integer, integer)
  from public, anon, authenticated;
grant execute on function public.check_rate_limit(uuid, integer, integer)
  to service_role;
