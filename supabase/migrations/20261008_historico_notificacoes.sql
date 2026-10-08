-- 📜 Histórico de notificações: tudo o que já apareceu (ou apareceria) nos avisos 💬 e 🗂️ do usuário logado,
-- lidas e não lidas, para consulta posterior. Mesmas regras de destinatário de comentarios_pendentes():
--   • mensagem: diretas a mim + gerais das notas em que eu participo (sem as que eu mesmo escrevi);
--   • atribuição: cada movimentação que atribuiu uma nota a mim, feita por outra pessoa (a atribuição
--     atual conta como lida quando abri a nota; as anteriores, já substituídas, contam como lidas).
-- Paginação por data (p_antes = created_at do último item recebido). p_tipo: null | 'mensagem' | 'atribuicao'.
create or replace function public.historico_notificacoes(
  p_limite int default 50,
  p_antes timestamptz default null,
  p_tipo text default null
)
 returns table(tipo text, ref_id bigint, nota_id bigint, created_at timestamptz, autor_nome text,
               mensagem text, direta boolean, lida boolean, lida_em timestamptz,
               nota_numero text, nota_fornecedor text, para_status text)
 language sql
 stable
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
  with msgs as (
    select 'mensagem'::text as tipo, nc.id as ref_id, nc.nota_id, nc.created_at, nc.autor_id,
           nc.mensagem, (nc.destinatario_id is not null) as direta,
           case when nc.destinatario_id is not null then nc.lida_em else l.lida_em end as lida_em,
           null::text as para_status
    from nota_comentarios nc
    join notas n on n.id = nc.nota_id
    left join nota_comentario_leituras l on l.comentario_id = nc.id and l.usuario_id = auth.uid()
    where (p_tipo is null or p_tipo = 'mensagem')
      and (p_antes is null or nc.created_at < p_antes)
      and (
        nc.destinatario_id = auth.uid()
        or (
          nc.destinatario_id is null
          and nc.autor_id <> auth.uid()
          and (
            exists (select 1 from obra_validadores ov where ov.obra_id = n.obra_id and ov.user_id = auth.uid())
            or n.assigned_to = auth.uid()
            or n.created_by = auth.uid()
            or public."current_role"() = 'admin'
            or exists (select 1 from nota_comentarios c2 where c2.nota_id = nc.nota_id and c2.autor_id = auth.uid())
          )
        )
      )
  ),
  atrs as (
    select 'atribuicao'::text, m.id, m.nota_id, m.moved_at, m.moved_by,
           m.note, true,
           -- vista: abri a nota depois da atribuição, ou ela já não está mais comigo
           case when n.assigned_to = auth.uid() and m.moved_at >= n.assigned_at
                then n.assigned_seen_at else coalesce(n.assigned_seen_at, m.moved_at) end,
           m.to_status
    from movements m
    join notas n on n.id = m.nota_id
    where (p_tipo is null or p_tipo = 'atribuicao')
      and (p_antes is null or m.moved_at < p_antes)
      and m.assigned_to = auth.uid()
      and m.moved_by is distinct from auth.uid()
      and m.to_status <> 'concluido'  -- conclusão/validação também gravam assigned_to, mas não são atribuições
  ),
  tudo as (select * from msgs union all select * from atrs)
  select t.tipo, t.ref_id, t.nota_id, t.created_at, p.name, t.mensagem, t.direta,
         (t.lida_em is not null), t.lida_em, n.numero, n.fornecedor, t.para_status
  from tudo t
  join notas n on n.id = t.nota_id
  left join profiles p on p.id = t.autor_id
  where public.current_is_active()
  order by t.created_at desc, t.ref_id desc
  limit least(greatest(coalesce(p_limite, 50), 1), 200);
$function$;
revoke execute on function public.historico_notificacoes(int, timestamptz, text) from public, anon;
grant execute on function public.historico_notificacoes(int, timestamptz, text) to authenticated, service_role;
