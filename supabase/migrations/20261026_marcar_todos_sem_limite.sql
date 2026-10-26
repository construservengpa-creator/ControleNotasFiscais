-- 💬 "Marcar todas como lidas" não zerava o contador: a primeira versão de marcar_todos_comentarios_lidos()
-- (20261026_marcar_lidas_todos_participantes.sql) partia de historico_notificacoes(), que devolve no máximo
-- 200 itens (lidas e não lidas) — as pendentes mais antigas que isso ficavam de fora.
-- Agora marca direto, sem limite, só para quem chamou: as diretas a ele e as gerais escritas por outras
-- pessoas. (Registrar leitura de uma mensagem geral que a pessoa nem recebe não muda nada para ela.)
create or replace function public.marcar_todos_comentarios_lidos()
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
   where destinatario_id = v_uid and lida_em is null;
  get diagnostics v_diretas = row_count;

  insert into nota_comentario_leituras (comentario_id, usuario_id, lida_em)
  select nc.id, v_uid, now()
    from nota_comentarios nc
   where nc.destinatario_id is null
     and nc.autor_id is distinct from v_uid
     and not exists (select 1 from nota_comentario_leituras l where l.comentario_id = nc.id and l.usuario_id = v_uid);
  get diagnostics v_gerais = row_count;

  return v_diretas + v_gerais;
end;
$function$;
revoke execute on function public.marcar_todos_comentarios_lidos() from public, anon;
grant execute on function public.marcar_todos_comentarios_lidos() to authenticated, service_role;
