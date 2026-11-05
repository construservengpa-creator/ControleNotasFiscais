-- 💬 Diálogo da nota: lista de usuários para quem dá para direcionar a mensagem.
-- (aplicar depois de 20261106_quadro_acesso_por_empresa.sql; pode rodar de novo sem problema)
--
-- Além de quem já participa do card (o navegador já sabe), o seletor "Direcionar para" oferece:
--   * administradores;
--   * responsáveis pela validação de recebimento da obra da nota (obra_validadores);
--   * usuários com acesso específico à mesma obra ou à mesma empresa (CNPJ do destinatário) da nota
--     (tabela validador_acessos — tela Usuários › Acesso a empresas e obras).
-- Só quem enxerga a nota pode pedir a lista. Usuários com "todas as empresas" não entram aqui (seriam todos);
-- eles continuam aparecendo quando já participam do card.

create or replace function public.nota_destinatarios_autorizados(p_nota_id bigint)
 returns table(id uuid, name text, role text, motivo text)
 language sql
 stable
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
  with n as (
    select nt.id, nt.obra_id, regexp_replace(coalesce(nt.cnpj_destinatario, ''), '\D', '', 'g') as cnpj
      from notas nt
     where nt.id = p_nota_id
       and public.current_is_active()
       and public.acesso_nota_permitida(p_nota_id)
  ), obra_cnpjs_da_nota as (
    select regexp_replace(oc.cnpj, '\D', '', 'g') as cnpj from obra_cnpjs oc join n on oc.obra_id = n.obra_id
  ), cand as (
    select p.id, p.name, p.role,
      case
        when p.role = 'admin' then 1
        when exists (select 1 from obra_validadores ov where ov.obra_id = n.obra_id and ov.user_id = p.id) then 2
        when not coalesce(a.todas, false) and n.obra_id = any (coalesce(a.obra_ids, '{}')) then 3
        when not coalesce(a.todas, false) and (
               (n.cnpj <> '' and n.cnpj = any (coalesce(a.cnpjs, '{}')))
            or (n.cnpj <> '' and exists (select 1 from obra_cnpjs oc where oc.obra_id = any (coalesce(a.obra_ids, '{}'))
                                                                and regexp_replace(oc.cnpj, '\D', '', 'g') = n.cnpj))
            or exists (select 1 from obra_cnpjs_da_nota d where d.cnpj = any (coalesce(a.cnpjs, '{}')))) then 4
      end as ordem
      from n
      cross join profiles p
      left join validador_acessos a on a.user_id = p.id
     where p.active and p.role <> 'pendente' and p.id <> auth.uid()
  )
  select c.id, c.name, c.role,
         case c.ordem when 1 then 'administrador' when 2 then 'responsável pela obra'
                      when 3 then 'mesma obra' else 'mesma empresa' end
    from cand c
   where c.ordem is not null
   order by c.ordem, c.name;
$function$;

revoke all on function public.nota_destinatarios_autorizados(bigint) from public, anon;
grant execute on function public.nota_destinatarios_autorizados(bigint) to authenticated;
