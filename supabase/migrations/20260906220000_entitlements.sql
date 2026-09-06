-- Entitlement sync: RevenueCat webhook → installation tier.
--
-- The client never tells the backend it is premium. Tier changes arrive
-- only through the webhook (server-to-server), keyed on the RevenueCat
-- app user ID, which we set to the installation ID.

alter table public.installations
  add column plus_expires_at timestamptz;

-- Replaces the Phase 4B version. Now does two things before any quota
-- decision (it is already called by both reserve_usage and get_usage):
--   1. downgrades a Plus installation whose entitlement has lapsed —
--      a safety net in case an EXPIRATION webhook is missed;
--   2. rolls the monthly period over for monthly tiers.
-- Caller holds the installation row lock.
create or replace function public.refresh_period(p_installation_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_free_allowance integer;
begin
  select full_generation_allowance into v_free_allowance
  from public.usage_config where tier = 'free';

  -- Lapsed Plus → free. The free tier is a LIFETIME 5 which the user had
  -- already consumed before subscribing, so they return with none left
  -- rather than receiving a fresh batch on every lapse.
  update public.installations
  set tier = 'free',
      analyses_used = v_free_allowance,
      refinements_remaining = 0,
      plus_expires_at = null,
      updated_at = now()
  where installation_id = p_installation_id
    and tier = 'plus'
    and plus_expires_at is not null
    and plus_expires_at < now();

  update public.installations i
  set analyses_used = 0,
      refinements_remaining = 0,
      period_start = now(),
      updated_at = now()
  from public.usage_config c
  where i.installation_id = p_installation_id
    and c.tier = i.tier
    and c.period_kind = 'monthly'
    and now() >= i.period_start + interval '1 month';
end;
$$;

-- Applies an entitlement change from the webhook. Creates the installation
-- row if the webhook somehow arrives before the app's first request.
--   p_tier          'plus' | 'free'
--   p_expires_at    entitlement expiry (nullable)
--   p_reset_period  true for a new/renewed period (fresh allowance)
create function public.apply_entitlement(
  p_installation_id uuid,
  p_tier text,
  p_expires_at timestamptz,
  p_reset_period boolean
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_inst public.installations;
  v_free_allowance integer;
begin
  if p_tier not in ('free', 'plus') then
    raise exception 'invalid tier %', p_tier;
  end if;

  insert into public.installations (installation_id)
  values (p_installation_id)
  on conflict (installation_id) do nothing;

  select * into v_inst
  from public.installations
  where installation_id = p_installation_id
  for update;

  select full_generation_allowance into v_free_allowance
  from public.usage_config where tier = 'free';

  if p_tier = 'plus' then
    update public.installations
    set tier = 'plus',
        plus_expires_at = p_expires_at,
        analyses_used = case when p_reset_period then 0 else analyses_used end,
        refinements_remaining = case when p_reset_period then 0 else refinements_remaining end,
        period_start = case when p_reset_period then now() else period_start end,
        updated_at = now()
    where installation_id = p_installation_id
    returning * into v_inst;
  else
    update public.installations
    set tier = 'free',
        plus_expires_at = null,
        analyses_used = greatest(analyses_used, v_free_allowance),
        refinements_remaining = 0,
        updated_at = now()
    where installation_id = p_installation_id
    returning * into v_inst;
  end if;

  return public.usage_status_for(v_inst);
end;
$$;

revoke execute on function public.apply_entitlement(uuid, text, timestamptz, boolean)
  from public, anon, authenticated;
grant execute on function public.apply_entitlement(uuid, text, timestamptz, boolean)
  to service_role;
