-- 🔒 Validador de NF: cada usuário só vê os dados das empresas/obras a que tem acesso.
-- (aplicar depois de 20261027_validador_so_o_que_mudou.sql; pode rodar de novo sem problema)
--
-- O acesso de cada usuário fica em validador_acessos (uma linha por usuário), definido pelo administrador na
-- tela Usuários do Controle de Notas:
--   * todas    — vê a base inteira (como era antes);
--   * cnpjs    — empresas liberadas (CNPJ do destinatário, só dígitos);
--   * obra_ids — obras liberadas: valem os CNPJs cadastrados na obra (tabela obra_cnpjs).
-- Administrador sempre vê tudo. Usuário sem linha em validador_acessos não vê nenhuma nota.
-- Para não cortar o acesso de ninguém no dia em que o SQL roda, todos os usuários que já existem começam com
-- "todas"; o administrador restringe cada um depois. Quem for cadastrado daqui para frente começa sem acesso.
--
-- A regra vale no banco (RLS), não só na tela: as notas da base salva (validador_nf_notas), o Pedido/Responsável/
-- Comprador (validador_nf_dados), a lista do último relatório (validador_nf_presenca, que roda com as permissões
-- de quem chama) e os cards da base (validador_cards_da_base, idem) passam a trazer só as empresas liberadas.
-- O arquivo original de cada relatório tem todas as empresas, então só quem vê tudo baixa — e só quem vê tudo
-- atualiza a base (admin, ou supervisor com "todas").

create table if not exists public.validador_acessos (
  user_id        uuid primary key references public.profiles(id) on delete cascade,
  todas          boolean not null default false,
  cnpjs          text[] not null default '{}',
  obra_ids       bigint[] not null default '{}',
  atualizado_por uuid,
  atualizado_em  timestamptz not null default now()
);

-- CNPJs só com dígitos, sem repetidos; quem alterou e quando vêm do banco
create or replace function public.validador_acessos_carimbo()
 returns trigger
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
begin
  new.cnpjs := coalesce((select array_agg(distinct d order by d)
                           from (select regexp_replace(c, '\D', '', 'g') d from unnest(coalesce(new.cnpjs, '{}')) c) x
                          where d ~ '^\d{14}$'), '{}');
  new.obra_ids := coalesce((select array_agg(distinct o order by o) from unnest(coalesce(new.obra_ids, '{}')) o
                             where o is not null), '{}');
  new.atualizado_por := auth.uid();
  new.atualizado_em := now();
  return new;
end;
$function$;
drop trigger if exists validador_acessos_carimbo on public.validador_acessos;
create trigger validador_acessos_carimbo before insert or update on public.validador_acessos
  for each row execute function public.validador_acessos_carimbo();

alter table public.validador_acessos enable row level security;
drop policy if exists validador_acessos_select on public.validador_acessos;
create policy validador_acessos_select on public.validador_acessos for select to authenticated
  using ((select public.current_is_active())
         and (user_id = (select auth.uid()) or (select public."current_role"()) = 'admin'));
drop policy if exists validador_acessos_write on public.validador_acessos;
create policy validador_acessos_write on public.validador_acessos for all to authenticated
  using ((select public.current_is_active()) and (select public."current_role"()) = 'admin')
  with check ((select public.current_is_active()) and (select public."current_role"()) = 'admin');
revoke all on public.validador_acessos from anon;
grant select, insert, update, delete on public.validador_acessos to authenticated;

-- Usuários que já existem: continuam vendo tudo até o administrador restringir.
insert into public.validador_acessos (user_id, todas)
select p.id, true from public.profiles p
on conflict (user_id) do nothing;

-- O usuário logado vê a base inteira?
create or replace function public.validador_ve_tudo()
 returns boolean
 language sql
 stable
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select public.current_is_active()
     and (public."current_role"() = 'admin'
          or exists (select 1 from validador_acessos a where a.user_id = auth.uid() and a.todas));
$function$;

-- CNPJs (só dígitos) liberados para o usuário logado: os da lista + os das obras liberadas.
create or replace function public.validador_cnpjs_permitidos()
 returns text[]
 language sql
 stable
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(array_agg(distinct c), '{}')
    from (select unnest(a.cnpjs) c from validador_acessos a where a.user_id = auth.uid()
          union
          select regexp_replace(oc.cnpj, '\D', '', 'g')
            from validador_acessos a
            join obra_cnpjs oc on oc.obra_id = any (a.obra_ids)
           where a.user_id = auth.uid()) x
   where public.current_is_active() and c is not null and c <> '';
$function$;

-- Para a tela do validador: {todas: bool, cnpjs: [...]} do usuário logado
create or replace function public.validador_meu_acesso()
 returns jsonb
 language sql
 stable
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select jsonb_build_object('todas', public.validador_ve_tudo(),
                            'cnpjs', to_jsonb(case when public.validador_ve_tudo() then '{}'::text[]
                                                   else public.validador_cnpjs_permitidos() end));
$function$;

-- Para a tela Usuários (só admin): empresas (CNPJ do destinatário) que aparecem na base, com nome e quantidade.
create or replace function public.validador_empresas_da_base()
 returns table(cnpj text, nome text, notas bigint)
 language sql
 stable
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select d, max(v.destinatario), count(*)
    from (select regexp_replace(coalesce(cnpj_destinatario, ''), '\D', '', 'g') d, destinatario from validador_nf_notas) v
   where public.current_is_active() and public."current_role"() = 'admin' and d ~ '^\d{14}$'
   group by d
   order by 2;
$function$;

-- Supervisor restrito não atualiza a base (o relatório traz todas as empresas).
create or replace function public.validador_pode_carregar()
 returns boolean
 language sql
 stable
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select public.current_is_active() and public."current_role"() in ('admin', 'supervisor') and public.validador_ve_tudo();
$function$;

revoke all on function public.validador_ve_tudo() from public, anon;
revoke all on function public.validador_cnpjs_permitidos() from public, anon;
revoke all on function public.validador_meu_acesso() from public, anon;
revoke all on function public.validador_empresas_da_base() from public, anon;
grant execute on function public.validador_ve_tudo() to authenticated;
grant execute on function public.validador_cnpjs_permitidos() to authenticated;
grant execute on function public.validador_meu_acesso() to authenticated;
grant execute on function public.validador_empresas_da_base() to authenticated;

-- Notas da base: só as empresas liberadas. Os (select …) são calculados uma vez por consulta.
alter policy validador_nf_notas_select on public.validador_nf_notas
  using ((select public.current_is_active())
         and ((select public.validador_ve_tudo())
              or regexp_replace(coalesce(cnpj_destinatario, ''), '\D', '', 'g') = any ((select public.validador_cnpjs_permitidos())::text[])));

-- Pedido/Responsável/Comprador: só das notas que o usuário enxerga na base.
alter policy validador_nf_dados_select on public.validador_nf_dados
  using ((select public.current_is_active())
         and ((select public.validador_ve_tudo())
              or exists (select 1 from public.validador_nf_notas v where v.chave = validador_nf_dados.chave)));
alter policy validador_nf_dados_insert on public.validador_nf_dados
  with check ((select public.current_is_active())
         and ((select public.validador_ve_tudo())
              or exists (select 1 from public.validador_nf_notas v where v.chave = validador_nf_dados.chave)));
alter policy validador_nf_dados_update on public.validador_nf_dados
  using ((select public.current_is_active())
         and ((select public.validador_ve_tudo())
              or exists (select 1 from public.validador_nf_notas v where v.chave = validador_nf_dados.chave)))
  with check ((select public.current_is_active())
         and ((select public.validador_ve_tudo())
              or exists (select 1 from public.validador_nf_notas v where v.chave = validador_nf_dados.chave)));

-- Arquivos originais dos relatórios (todas as empresas): só quem vê tudo.
alter policy validador_relatorios_select on storage.objects
  using (bucket_id = 'validador-relatorios' and (select public.validador_ve_tudo()));

create index if not exists validador_nf_notas_cnpj_dest_idx
  on public.validador_nf_notas ((regexp_replace(coalesce(cnpj_destinatario, ''), '\D', '', 'g')));
analyze public.validador_nf_notas;
