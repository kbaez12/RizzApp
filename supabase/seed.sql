-- DEVELOPMENT FIXTURES ONLY.
-- Applied locally by `supabase db reset`. Never run against production.

-- Test Plus installation with a manually specified development period.
-- (There is deliberately NO client endpoint to self-upgrade; RevenueCat
-- webhooks become the entitlement source in a later phase.)
insert into public.installations
  (installation_id, tier, analyses_used, refinements_remaining, period_start)
values
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'plus', 0, 0, now())
on conflict (installation_id)
do update set tier = excluded.tier, period_start = excluded.period_start;

-- Exhausted free installation for 402 testing without burning 5 requests.
insert into public.installations
  (installation_id, tier, analyses_used, refinements_remaining)
values
  ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', 'free', 5, 0)
on conflict (installation_id)
do update set analyses_used = excluded.analyses_used,
              refinements_remaining = excluded.refinements_remaining;
