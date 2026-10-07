-- 💬 Mensagens gerais ("todos os participantes") passam a avisar todos que trabalham na nota:
-- responsáveis pela validação da obra (como antes), o usuário a quem a nota está atribuída, quem cadastrou a nota,
-- quem já escreveu no diálogo dela e os administradores. Para os grupos novos, só contam mensagens a partir de
-- 07/10/2026 (evita encher o aviso com conversas antigas). Diretas continuam indo só para o destinatário.
create or replace function public.comentarios_pendentes()
 returns table(id bigint, nota_id bigint, mensagem text, created_at timestamp with time zone, autor_id uuid, autor_nome text, nota_numero text, nota_fornecedor text)
 language sql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
  select nc.id, nc.nota_id, nc.mensagem, nc.created_at, nc.autor_id,
         p.name as autor_nome, n.numero as nota_numero, n.fornecedor as nota_fornecedor
  from nota_comentarios nc
  join notas n on n.id = nc.nota_id
  left join profiles p on p.id = nc.autor_id
  where public.current_is_active()
    and (
      (nc.destinatario_id = auth.uid() and nc.lida_em is null)
      or
      (
        nc.destinatario_id is null
        and nc.autor_id <> auth.uid()
        and not exists (
          select 1 from nota_comentario_leituras l
          where l.comentario_id = nc.id and l.usuario_id = auth.uid()
        )
        and (
          exists (select 1 from obra_validadores ov where ov.obra_id = n.obra_id and ov.user_id = auth.uid())
          or (
            nc.created_at >= '2026-10-07 00:00:00-03'
            and (
              n.assigned_to = auth.uid()
              or n.created_by = auth.uid()
              or public."current_role"() = 'admin'
              or exists (select 1 from nota_comentarios c2 where c2.nota_id = nc.nota_id and c2.autor_id = auth.uid())
            )
          )
        )
      )
    )
  order by nc.created_at desc
  limit 50;
$function$;
revoke execute on function public.comentarios_pendentes() from public, anon;
grant execute on function public.comentarios_pendentes() to authenticated, service_role;
