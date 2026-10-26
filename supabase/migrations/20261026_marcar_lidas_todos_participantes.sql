-- 💬 Leitura das mensagens vale para todos que recebem o aviso.
-- Desde 07/10 (20261007_notificacoes_todos_participantes.sql) o aviso avisa, além dos responsáveis pela
-- validação da obra, quem tem a nota atribuída, quem a cadastrou, quem já escreveu no diálogo e os
-- administradores — mas a leitura individual continuava presa à regra antiga, e o contador do 💬 não
-- baixava para esses grupos. Agora:
--   • marcar_comentarios_lidos(nota): marca como lidas, só para quem chamou, as diretas a ele e todas as
--     gerais da nota (menos as que ele mesmo escreveu);
--   • marcar_todos_comentarios_lidos(): o mesmo para tudo o que está pendente no histórico de quem chamou.
-- A leitura continua individual: nota_comentario_leituras guarda uma linha por mensagem e por usuário.

drop function if exists public.marcar_comentarios_lidos(bigint);
create function public.marcar_comentarios_lidos(p_nota_id bigint)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_uid uuid := auth.uid();
  v_diretas integer;
  v_gerais integer;
begin
  if v_uid is null then raise exception 'Sessão expirada. Entre novamente.'; end if;

  update nota_comentarios set lida_em = now()
   where nota_id = p_nota_id and destinatario_id = v_uid and lida_em is null;
  get diagnostics v_diretas = row_count;

  insert into nota_comentario_leituras (comentario_id, usuario_id, lida_em)
  select nc.id, v_uid, now()
    from nota_comentarios nc
   where nc.nota_id = p_nota_id
     and nc.destinatario_id is null
     and nc.autor_id is distinct from v_uid
     and not exists (select 1 from nota_comentario_leituras l where l.comentario_id = nc.id and l.usuario_id = v_uid);
  get diagnostics v_gerais = row_count;

  return v_diretas + v_gerais;
end;
$function$;
revoke execute on function public.marcar_comentarios_lidos(bigint) from public, anon;
grant execute on function public.marcar_comentarios_lidos(bigint) to authenticated, service_role;

create or replace function public.marcar_todos_comentarios_lidos()
 returns integer
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_uid uuid := auth.uid();
  v_total integer := 0;
  v_nota bigint;
begin
  if v_uid is null then raise exception 'Sessão expirada. Entre novamente.'; end if;
  -- mesmas regras de quem recebe o aviso: as notas com mensagem não lida no histórico de quem chamou
  for v_nota in
    select distinct h.nota_id from public.historico_notificacoes(100000, null, 'mensagem') h where not h.lida
  loop
    v_total := v_total + public.marcar_comentarios_lidos(v_nota);
  end loop;
  return v_total;
end;
$function$;
revoke execute on function public.marcar_todos_comentarios_lidos() from public, anon;
grant execute on function public.marcar_todos_comentarios_lidos() to authenticated, service_role;
