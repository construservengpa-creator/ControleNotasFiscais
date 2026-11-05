-- 🔒 Quadro (Controle de Notas): cada usuário só vê os cards das empresas/obras a que tem acesso.
-- (aplicar depois de 20261105_validador_acesso_por_empresa.sql; pode rodar de novo sem problema)
--
-- Usa o mesmo acesso do Validador de NF (tabela validador_acessos, definida na tela Usuários):
--   * admin, ou usuário com "todas" → vê todos os cards (como antes);
--   * os outros veem o card quando:
--       - a obra do card está liberada para ele, ou é uma obra em que ele é responsável pela validação de
--         recebimento (obra_validadores), ou uma obra cadastrada com o CNPJ de uma empresa liberada; ou
--       - o CNPJ do destinatário é de uma empresa liberada; ou
--       - o card está atribuído a ele, ou foi ele quem cadastrou (para não sumir trabalho que já é dele).
--
-- As regras entram como políticas RESTRITIVAS: somam-se (com "e") às regras que o quadro já tem por papel e
-- coluna — ninguém passa a ver mais do que via antes, só menos. Valem para ver, alterar e excluir cards, e
-- também para o histórico de movimentações, os anexos (e os arquivos deles) e o diálogo de cada card.

-- Obras liberadas para o usuário logado (lista + responsável pela validação + obras das empresas liberadas).
create or replace function public.acesso_obras_permitidas()
 returns bigint[]
 language sql
 stable
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(array_agg(distinct o), '{}')
    from (select unnest(a.obra_ids) o from validador_acessos a where a.user_id = auth.uid()
          union
          select ov.obra_id from obra_validadores ov where ov.user_id = auth.uid()
          union
          select oc.obra_id from obra_cnpjs oc
           where regexp_replace(oc.cnpj, '\D', '', 'g') = any (public.validador_cnpjs_permitidos())) x
   where public.current_is_active() and o is not null;
$function$;

-- A regra para uma nota, lendo a nota sem RLS (usada pelas tabelas ligadas à nota — evita recursão
-- com as regras que já existem na tabela notas).
create or replace function public.acesso_nota_permitida(p_nota_id bigint)
 returns boolean
 language sql
 stable
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select public.validador_ve_tudo()
      or exists (select 1 from notas n
                  where n.id = p_nota_id
                    and (n.assigned_to = auth.uid() or n.created_by = auth.uid()
                         or n.obra_id = any (public.acesso_obras_permitidas())
                         or regexp_replace(coalesce(n.cnpj_destinatario, ''), '\D', '', 'g') = any (public.validador_cnpjs_permitidos())));
$function$;

revoke all on function public.acesso_obras_permitidas() from public, anon;
revoke all on function public.acesso_nota_permitida(bigint) from public, anon;
grant execute on function public.acesso_obras_permitidas() to authenticated;
grant execute on function public.acesso_nota_permitida(bigint) to authenticated;

-- Cards
drop policy if exists notas_acesso_empresa_select on public.notas;
create policy notas_acesso_empresa_select on public.notas as restrictive for select to authenticated
  using ((select public.validador_ve_tudo())
         or assigned_to = (select auth.uid()) or created_by = (select auth.uid())
         or obra_id = any ((select public.acesso_obras_permitidas())::bigint[])
         or regexp_replace(coalesce(cnpj_destinatario, ''), '\D', '', 'g') = any ((select public.validador_cnpjs_permitidos())::text[]));
drop policy if exists notas_acesso_empresa_update on public.notas;
create policy notas_acesso_empresa_update on public.notas as restrictive for update to authenticated
  using ((select public.validador_ve_tudo())
         or assigned_to = (select auth.uid()) or created_by = (select auth.uid())
         or obra_id = any ((select public.acesso_obras_permitidas())::bigint[])
         or regexp_replace(coalesce(cnpj_destinatario, ''), '\D', '', 'g') = any ((select public.validador_cnpjs_permitidos())::text[]));
drop policy if exists notas_acesso_empresa_delete on public.notas;
create policy notas_acesso_empresa_delete on public.notas as restrictive for delete to authenticated
  using ((select public.validador_ve_tudo())
         or assigned_to = (select auth.uid()) or created_by = (select auth.uid())
         or obra_id = any ((select public.acesso_obras_permitidas())::bigint[])
         or regexp_replace(coalesce(cnpj_destinatario, ''), '\D', '', 'g') = any ((select public.validador_cnpjs_permitidos())::text[]));

-- Movimentações, anexos e diálogo seguem a nota
drop policy if exists movements_acesso_empresa on public.movements;
create policy movements_acesso_empresa on public.movements as restrictive for select to authenticated
  using ((select public.validador_ve_tudo()) or public.acesso_nota_permitida(nota_id));
drop policy if exists anexos_acesso_empresa on public.anexos;
create policy anexos_acesso_empresa on public.anexos as restrictive for select to authenticated
  using ((select public.validador_ve_tudo()) or public.acesso_nota_permitida(nota_id));
drop policy if exists nota_comentarios_acesso_empresa on public.nota_comentarios;
create policy nota_comentarios_acesso_empresa on public.nota_comentarios as restrictive for select to authenticated
  using ((select public.validador_ve_tudo()) or public.acesso_nota_permitida(nota_id));
drop policy if exists nota_comentarios_acesso_empresa_insert on public.nota_comentarios;
create policy nota_comentarios_acesso_empresa_insert on public.nota_comentarios as restrictive for insert to authenticated
  with check ((select public.validador_ve_tudo()) or public.acesso_nota_permitida(nota_id));

create index if not exists notas_cnpj_dest_digitos_idx
  on public.notas ((regexp_replace(coalesce(cnpj_destinatario, ''), '\D', '', 'g')));
create index if not exists notas_obra_id_idx on public.notas (obra_id);
