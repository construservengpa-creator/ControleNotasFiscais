-- 🧾 Validador de NF: Pedido, Responsável e Comprador de cada nota do relatório SIENGE.
--
-- Ficam só no validador, ligados à chave de acesso da NF-e (valem também para nota que ainda não tem card).
--   * pedido          — nº do pedido de compras (texto livre);
--   * responsavel_id  — quem cuida da nota na obra (usuário do sistema);
--   * comprador_id    — comprador da nota (usuário do sistema).
-- Qualquer usuário ativo vê e preenche; quem alterou por último e quando ficam gravados pelo banco.

create table if not exists public.validador_nf_dados (
  chave           text primary key check (chave ~ '^[0-9A-Z]{44}$'),
  pedido          text check (pedido is null or length(btrim(pedido)) between 1 and 60),
  responsavel_id  uuid references public.profiles(id) on delete set null,
  comprador_id    uuid references public.profiles(id) on delete set null,
  atualizado_por  uuid,
  atualizado_em   timestamptz not null default now()
);
create index if not exists validador_nf_dados_responsavel_idx on public.validador_nf_dados (responsavel_id);
create index if not exists validador_nf_dados_comprador_idx on public.validador_nf_dados (comprador_id);

-- quem alterou e quando vêm do banco, não do navegador
create or replace function public.validador_nf_dados_carimbo()
 returns trigger
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
begin
  new.atualizado_por := auth.uid();
  new.atualizado_em := now();
  new.pedido := nullif(btrim(coalesce(new.pedido, '')), '');
  return new;
end;
$function$;
drop trigger if exists validador_nf_dados_carimbo on public.validador_nf_dados;
create trigger validador_nf_dados_carimbo before insert or update on public.validador_nf_dados
  for each row execute function public.validador_nf_dados_carimbo();

alter table public.validador_nf_dados enable row level security;
drop policy if exists validador_nf_dados_select on public.validador_nf_dados;
create policy validador_nf_dados_select on public.validador_nf_dados for select to authenticated
  using ((select public.current_is_active()));
drop policy if exists validador_nf_dados_insert on public.validador_nf_dados;
create policy validador_nf_dados_insert on public.validador_nf_dados for insert to authenticated
  with check ((select public.current_is_active()));
drop policy if exists validador_nf_dados_update on public.validador_nf_dados;
create policy validador_nf_dados_update on public.validador_nf_dados for update to authenticated
  using ((select public.current_is_active())) with check ((select public.current_is_active()));
grant select, insert, update on public.validador_nf_dados to authenticated;

-- Lista de usuários ativos para escolher Responsável/Comprador. O operador não enxerga todos os perfis
-- (profiles_select), por isso a lista vem por esta função, só com id, nome e perfil.
create or replace function public.validador_usuarios()
 returns table(id uuid, name text, role text)
 language sql
 stable
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select p.id, p.name, p.role
  from profiles p
  where public.current_is_active() and p.active and p.role <> 'pendente'
  order by p.name;
$function$;
revoke all on function public.validador_usuarios() from public, anon;
grant execute on function public.validador_usuarios() to authenticated;
