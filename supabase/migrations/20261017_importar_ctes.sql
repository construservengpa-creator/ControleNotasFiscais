-- 🚚 Importação dos CT-es do relatório SIENGE ("CT-es Recebidos").
--
-- O navegador lê o relatório, fica só com os CT-es cujo tomador é AMETA, RAF ou
-- um dos consórcios e que ainda não foram escriturados, e chama
-- rpc_vincular_ctes. Para cada CT-e a função:
--   * ignora o que já foi tratado (CT-e já vinculado a uma nota, ou já
--     importado antes como card próprio);
--   * procura a nota fiscal que informou esse CT-e no frete (nº do CT-e +
--     transportador ou valor do frete) e grava nela os dados do CT-e,
--     marcando "lançamento do frete pendente";
--   * se essa nota já tinha sido concluída/encerrada, reabre o card e o coloca
--     em Pendências com a observação de que o lançamento do frete está pendente;
--   * devolve como "nao_encontrado"/"ambiguo" o que não achou nota — o
--     navegador importa esses CT-es como cards novos em "Importadas SIENGE"
--     pela mesma rotina da importação de notas (rpc_importar_lote).

alter table public.notas add column if not exists frete_cte_chave text;
alter table public.notas add column if not exists frete_lancamento_pendente boolean not null default false;
create index if not exists notas_frete_cte_chave_idx on public.notas (frete_cte_chave);

-- O aviso "lançamento do frete pendente" sai quando a nota é concluída de novo
-- (o título do frete foi lançado).
create or replace function public.notas_frete_pendente_limpa()
 returns trigger
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.status = 'concluido' and old.status is distinct from 'concluido' then
    new.frete_lancamento_pendente := false;
  end if;
  return new;
end;
$function$;
revoke execute on function public.notas_frete_pendente_limpa() from public, anon;
drop trigger if exists notas_frete_pendente_limpa_trg on public.notas;
create trigger notas_frete_pendente_limpa_trg before update of status on public.notas
  for each row execute function public.notas_frete_pendente_limpa();

-- Nome de empresa reduzido ao que identifica (sem acento, sem LTDA, TRANSPORTES, "E", "DE" etc.)
-- e sem espaços — "H G Transportes" e "H G TRANSPORTE E LOCACAO LTDA" viram "hg" e "hglocacao".
-- Serve para comparar o transportador digitado na nota com o emitente do CT-e.
create or replace function public.nome_empresa_compacto(p text)
 returns text
 language sql
 immutable
 set search_path to 'public', 'pg_temp'
as $function$
  select coalesce(string_agg(w, '' order by ord), '')
    from regexp_split_to_table(
           lower(translate(coalesce(p, ''), 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇáàâãäéèêëíìîïóòôõöúùûüç',
                                            'AAAAAEEEEIIIIOOOOOUUUUCaaaaaeeeeiiiiooooouuuuc')),
           '[^a-z0-9]+') with ordinality as t(w, ord)
   where w <> ''
     and w not in ('ltda', 'eireli', 'epp', 'me', 'sa', 's', 'a', 'e', 'de', 'do', 'da', 'dos', 'das',
                   'transporte', 'transportes', 'transportadora', 'transp', 'logistica', 'log',
                   'cargas', 'carga', 'comercio', 'servicos', 'rodoviario', 'rodoviaria',
                   'express', 'expresso', 'filial', 'matriz');
$function$;

-- Mesmo transportador? Um nome compacto começa com o outro, ou têm uma palavra significativa em comum.
create or replace function public.mesma_empresa(a text, b text)
 returns boolean
 language sql
 immutable
 set search_path to 'public', 'pg_temp'
as $function$
  with n as (select public.nome_empresa_compacto(a) ca, public.nome_empresa_compacto(b) cb)
  select n.ca <> '' and n.cb <> '' and (
           starts_with(n.ca, n.cb) or starts_with(n.cb, n.ca)
           or exists (select 1
                        from regexp_split_to_table(lower(translate(coalesce(a, ''), 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇáàâãäéèêëíìîïóòôõöúùûüç',
                                                   'AAAAAEEEEIIIIOOOOOUUUUCaaaaaeeeeiiiiooooouuuuc')), '[^a-z0-9]+') w
                       where length(w) >= 4 and public.nome_empresa_compacto(w) <> ''
                         and position(w in public.nome_empresa_compacto(b)) > 0))
    from n;
$function$;

-- Reabre uma nota já concluída/encerrada e a coloca em Pendências com a observação de que o
-- lançamento do frete está pendente. Devolve null quando deu certo, ou o motivo da recusa
-- (a nota continua com o CT-e gravado, só não é reaberta).
create or replace function public.cte_reabrir_em_pendencias(p_nota_id bigint, p_cte_numero text, p_emitente text, p_valor numeric)
 returns text
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_msg text := 'Lançamento do frete pendente — CT-e ' || coalesce(nullif(trim(p_cte_numero), ''), '?')
                || coalesce(' de ' || nullif(trim(p_emitente), ''), '')
                || coalesce(' (R$ ' || replace(to_char(p_valor, 'FM999999990.00'), '.', ',') || ')', '')
                || ' recebido depois da conclusão da nota.';
begin
  perform public.rpc_reabrir(p_nota_id);
  if (select status from public.notas where id = p_nota_id) is distinct from 'pendencias' then
    perform public.aplicar_mudanca_status(p_nota_id, 'pendencias', null, v_msg, null);
  end if;
  return null;
exception when others then
  return sqlerrm;
end;
$function$;
revoke all on function public.cte_reabrir_em_pendencias(bigint, text, text, numeric) from public, anon, authenticated;

create or replace function public.rpc_vincular_ctes(p_ctes jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  c jsonb;
  v_chave text;
  v_num text;
  v_emit text;
  v_cnpj_emit text;
  v_valor numeric;
  v_data date;
  v_ids bigint[];
  v_nota public.notas;
  v_status_antes text;
  v_resultado text;
  v_erro text;
  v_saida jsonb := '[]'::jsonb;
begin
  if not public.current_is_active() or public."current_role"() not in ('admin', 'supervisor') then
    raise exception 'Apenas administradores e supervisores podem importar CT-es.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_ctes) is distinct from 'array' then
    raise exception 'Lista de CT-es inválida.' using errcode = '22023';
  end if;

  for c in select * from jsonb_array_elements(p_ctes) loop
    v_chave := nullif(regexp_replace(coalesce(c->>'chave', ''), '\D', '', 'g'), '');
    v_num := nullif(ltrim(regexp_replace(split_part(coalesce(c->>'numero', ''), '/', 1), '\D', '', 'g'), '0'), '');
    v_emit := nullif(trim(coalesce(c->>'emitente', '')), '');
    v_cnpj_emit := nullif(regexp_replace(coalesce(c->>'cnpjEmitente', ''), '\D', '', 'g'), '');
    v_valor := case when coalesce(c->>'valor', '') ~ '^\d+(\.\d+)?$' then (c->>'valor')::numeric end;
    v_data := case when coalesce(c->>'dataEmissao', '') ~ '^\d{4}-\d{2}-\d{2}$' then (c->>'dataEmissao')::date end;
    v_resultado := null; v_erro := null; v_nota := null;

    if v_chave is null or v_num is null then
      v_saida := v_saida || jsonb_build_object('chave', c->>'chave', 'resultado', 'invalido');
      continue;
    end if;

    -- já tratado antes?
    select n.* into v_nota from public.notas n where n.frete_cte_chave = v_chave order by n.id limit 1;
    if found then
      v_saida := v_saida || jsonb_build_object('chave', v_chave, 'resultado', 'ja_vinculado', 'notaId', v_nota.id, 'numeroNota', v_nota.numero);
      continue;
    end if;
    if exists (select 1 from public.notas n where regexp_replace(coalesce(n.chave_acesso, ''), '\D', '', 'g') = v_chave) then
      v_saida := v_saida || jsonb_build_object('chave', v_chave, 'resultado', 'ja_importado');
      continue;
    end if;

    -- nota fiscal que informou este CT-e no frete
    select coalesce(array_agg(n.id order by n.id), '{}') into v_ids
      from public.notas n
     where n.frete_cte_chave is null
       and ltrim(regexp_replace(split_part(coalesce(n.frete_cte, ''), '/', 1), '\D', '', 'g'), '0') = v_num
       and (
         nullif(trim(coalesce(n.frete_transportador, '')), '') is null
         or (v_valor is not null and n.frete_valor = v_valor)
         or public.mesma_empresa(n.frete_transportador, v_emit)
       );

    if cardinality(v_ids) = 0 then
      v_saida := v_saida || jsonb_build_object('chave', v_chave, 'resultado', 'nao_encontrado');
      continue;
    end if;
    if cardinality(v_ids) > 1 then
      v_saida := v_saida || jsonb_build_object('chave', v_chave, 'resultado', 'ambiguo', 'notaIds', to_jsonb(v_ids));
      continue;
    end if;

    -- grava o CT-e na nota (só completa o que estiver vazio)
    update public.notas set
      frete = 'sim',
      frete_cte = coalesce(nullif(trim(frete_cte), ''), c->>'numero'),
      frete_transportador = coalesce(nullif(trim(frete_transportador), ''), v_emit),
      frete_valor = coalesce(frete_valor, v_valor),
      frete_cte_chave = v_chave,
      frete_lancamento_pendente = true
    where id = v_ids[1]
    returning * into v_nota;
    v_status_antes := v_nota.status;
    v_resultado := 'vinculado';

    insert into public.audit_log (user_id, user_name, action, entity_type, entity_id, details)
    values (auth.uid(), (select name from public.profiles where id = auth.uid()), 'cte_vinculado', 'nota_fiscal', v_nota.id::text,
            c || jsonb_build_object('statusAnterior', v_status_antes));

    -- nota já encerrada: reabre e coloca em Pendências com a observação do frete
    if v_status_antes = 'concluido' then
      v_erro := public.cte_reabrir_em_pendencias(v_nota.id, c->>'numero', v_emit, v_valor);
      v_resultado := case when v_erro is null then 'reaberto' else 'vinculado_sem_reabrir' end;
    end if;

    v_saida := v_saida || jsonb_build_object('chave', v_chave, 'resultado', v_resultado, 'notaId', v_nota.id,
                                             'numeroNota', v_nota.numero, 'fornecedor', v_nota.fornecedor,
                                             'statusAnterior', v_status_antes, 'erro', v_erro);
  end loop;

  return v_saida;
end;
$function$;

revoke all on function public.rpc_vincular_ctes(jsonb) from public, anon;
grant execute on function public.rpc_vincular_ctes(jsonb) to authenticated;
revoke all on function public.nome_empresa_compacto(text) from public, anon;
grant execute on function public.nome_empresa_compacto(text) to authenticated;
revoke all on function public.mesma_empresa(text, text) from public, anon;
grant execute on function public.mesma_empresa(text, text) to authenticated;
