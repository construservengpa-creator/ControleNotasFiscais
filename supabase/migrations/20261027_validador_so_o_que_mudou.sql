-- ⚡ Validador de NF: importar e abrir só com o que mudou.
-- (aplicar depois de 20261027_validador_menos_trafego.sql; pode rodar de novo sem problema)
--
-- * validador_nf_gravar_lote: o atualizado_em só muda quando algum dado da nota mudou. Antes toda nota que vinha
--   no relatório ficava "atualizada", e quem abria o validador depois de uma importação baixava a base inteira.
-- * validador_nf_marcar_presentes: na importação o navegador compara o arquivo com a base que já tem e manda
--   completas só as notas novas/alteradas; as iguais vão só como [chave, linha, atualizado_em] e são marcadas
--   como vindas nesta carga. Se a nota mudou no banco desde então (atualizado_em diferente), ela volta na lista
--   de recusadas e o navegador a manda completa.
-- * validador_nf_presenca: lista compacta [chave, linha] das notas que vieram numa carga — o navegador que já tem
--   a base em cache usa para saber quais vieram no último relatório sem baixar tudo de novo.

-- 1) grava um lote de linhas da carga (sem chave repetida dentro do mesmo lote) — igual a antes, mas o
--    atualizado_em só muda quando algum dado da nota mudou.
create or replace function public.validador_nf_gravar_lote(p_carga bigint, p_linhas jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_res jsonb;
begin
  if not public.validador_pode_carregar() then
    raise exception 'Só administradores e supervisores podem atualizar a base do validador.' using errcode = '42501';
  end if;
  if not exists (select 1 from validador_nf_cargas c where c.id = p_carga and c.enviado_por = auth.uid() and not c.concluida) then
    raise exception 'Carga % não está aberta para este usuário.', p_carga;
  end if;
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) > 5000 then
    raise exception 'Lote inválido (máximo de 5000 linhas por vez).';
  end if;

  with src as (
    select upper(regexp_replace(coalesce(x.chave, ''), '[^0-9A-Za-z]', '', 'g')) as chave,
           left(x.emitente, 300) as emitente, left(x.cnpj_emitente, 30) as cnpj_emitente, left(x.uf_emitente, 4) as uf_emitente,
           left(x.destinatario, 300) as destinatario, left(x.cnpj_destinatario, 30) as cnpj_destinatario, left(x.uf_destinatario, 4) as uf_destinatario,
           left(x.manifesto, 100) as manifesto, left(x.natureza, 300) as natureza,
           x.recebimento, x.emissao, left(x.numero_serie, 60) as numero_serie, x.valor,
           left(x.escrituracao, 100) as escrituracao, left(x.titulo, 60) as titulo, x.linha
    from jsonb_to_recordset(p_linhas) as x(chave text, emitente text, cnpj_emitente text, uf_emitente text,
         destinatario text, cnpj_destinatario text, uf_destinatario text, manifesto text, natureza text,
         recebimento date, emissao date, numero_serie text, valor numeric, escrituracao text, titulo text, linha int)
  ), ok as (
    select * from src where chave ~ '^[0-9A-Z]{44}$'
  ), up as (
    insert into validador_nf_notas as t (chave, emitente, cnpj_emitente, uf_emitente, destinatario, cnpj_destinatario,
           uf_destinatario, manifesto, natureza, recebimento, emissao, numero_serie, valor, escrituracao, titulo, linha,
           primeira_carga, ultima_carga, alterada_na_carga, titulo_desde, atualizado_em)
    select chave, emitente, cnpj_emitente, uf_emitente, destinatario, cnpj_destinatario, uf_destinatario, manifesto,
           natureza, recebimento, emissao, numero_serie, valor, escrituracao, titulo, linha,
           p_carga, p_carga, p_carga, case when coalesce(btrim(titulo), '') not in ('', '0') then now() end, now()
    from ok
    on conflict (chave) do update set
      emitente = excluded.emitente, cnpj_emitente = excluded.cnpj_emitente, uf_emitente = excluded.uf_emitente,
      destinatario = excluded.destinatario, cnpj_destinatario = excluded.cnpj_destinatario,
      uf_destinatario = excluded.uf_destinatario, manifesto = excluded.manifesto, natureza = excluded.natureza,
      recebimento = excluded.recebimento, emissao = excluded.emissao, numero_serie = excluded.numero_serie,
      valor = excluded.valor, escrituracao = excluded.escrituracao, titulo = excluded.titulo, linha = excluded.linha,
      ultima_carga = p_carga,
      alterada_na_carga = case when (t.emitente, t.cnpj_emitente, t.uf_emitente, t.destinatario, t.cnpj_destinatario,
            t.uf_destinatario, t.manifesto, t.natureza, t.recebimento, t.emissao, t.numero_serie, t.valor, t.escrituracao, t.titulo)
          is distinct from (excluded.emitente, excluded.cnpj_emitente, excluded.uf_emitente, excluded.destinatario,
            excluded.cnpj_destinatario, excluded.uf_destinatario, excluded.manifesto, excluded.natureza, excluded.recebimento,
            excluded.emissao, excluded.numero_serie, excluded.valor, excluded.escrituracao, excluded.titulo)
        then p_carga else t.alterada_na_carga end,
      titulo_desde = case
        when coalesce(btrim(excluded.titulo), '') in ('', '0') then null
        when coalesce(btrim(t.titulo), '') in ('', '0') then now()
        else t.titulo_desde end,
      -- só conta como atualizada quando algum dado mudou (só ter vindo de novo, ou mudar de linha, não conta):
      -- é por esta data que o navegador sabe o que precisa baixar de novo.
      atualizado_em = case when (t.emitente, t.cnpj_emitente, t.uf_emitente, t.destinatario, t.cnpj_destinatario,
            t.uf_destinatario, t.manifesto, t.natureza, t.recebimento, t.emissao, t.numero_serie, t.valor, t.escrituracao, t.titulo)
          is distinct from (excluded.emitente, excluded.cnpj_emitente, excluded.uf_emitente, excluded.destinatario,
            excluded.cnpj_destinatario, excluded.uf_destinatario, excluded.manifesto, excluded.natureza, excluded.recebimento,
            excluded.emissao, excluded.numero_serie, excluded.valor, excluded.escrituracao, excluded.titulo)
        then now() else t.atualizado_em end
    returning (xmax = 0) as nova, (t.alterada_na_carga = p_carga) as mudou
  )
  select jsonb_build_object(
    'novas', count(*) filter (where nova),
    'alteradas', count(*) filter (where not nova and mudou),
    'gravadas', count(*),
    'ignoradas', (select count(*) from src) - count(*))
  into v_res from up;
  return v_res;
end;
$function$;

-- 2) marca as notas que vieram no relatório sem mudança (p_linhas = [[chave, linha, atualizado_em], …])
create or replace function public.validador_nf_marcar_presentes(p_carga bigint, p_linhas jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_recusadas jsonb;
begin
  if not public.validador_pode_carregar() then
    raise exception 'Só administradores e supervisores podem atualizar a base do validador.' using errcode = '42501';
  end if;
  if not exists (select 1 from validador_nf_cargas c where c.id = p_carga and c.enviado_por = auth.uid() and not c.concluida) then
    raise exception 'Carga % não está aberta para este usuário.', p_carga;
  end if;
  if jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) > 20000 then
    raise exception 'Lote inválido (máximo de 20000 linhas por vez).';
  end if;

  with src as (
    select x->>0 as chave, case when (x->>1) ~ '^\d+$' then (x->>1)::int end as linha, (x->>2)::timestamptz as atu
      from jsonb_array_elements(p_linhas) x
  ), up as (
    update validador_nf_notas t set ultima_carga = p_carga, linha = coalesce(s.linha, t.linha)
      from src s
     where t.chave = s.chave and t.atualizado_em = s.atu
    returning t.chave
  )
  select coalesce(jsonb_agg(s.chave), '[]'::jsonb) into v_recusadas
    from src s where not exists (select 1 from up where up.chave = s.chave);
  return v_recusadas;
end;
$function$;

-- 3) notas que vieram numa carga, compactas: [[chave, linha], …]
create or replace function public.validador_nf_presenca(p_carga bigint)
 returns jsonb
 language sql
 stable
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(jsonb_build_array(v.chave, v.linha)), '[]'::jsonb)
    from public.validador_nf_notas v
   where v.ultima_carga = p_carga;
$function$;

revoke all on function public.validador_nf_gravar_lote(bigint, jsonb) from public, anon;
grant execute on function public.validador_nf_gravar_lote(bigint, jsonb) to authenticated;
revoke all on function public.validador_nf_marcar_presentes(bigint, jsonb) from public, anon;
grant execute on function public.validador_nf_marcar_presentes(bigint, jsonb) to authenticated;
revoke all on function public.validador_nf_presenca(bigint) from public, anon;
grant execute on function public.validador_nf_presenca(bigint) to authenticated;
