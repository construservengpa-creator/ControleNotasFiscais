-- 📄 XML do CT-e obrigatório (aplicar depois de 20261017_importar_ctes.sql).
--
-- Todo card ligado a um CT-e (o card do próprio CT-e importado do SIENGE, ou a nota fiscal
-- que recebeu um CT-e) precisa do XML do CT-e anexado antes de sair de onde está:
-- concluir, homologar, distribuir ou mover para outra coluna ficam bloqueados. Ir para
-- Pendências e reabrir uma nota concluída continuam liberados. O administrador pode
-- liberar o card sem XML (ex.: CT-e "Indisponível" no SIENGE) com justificativa.
--
-- Ao anexar o XML, o navegador lê o arquivo e chama rpc_analisar_cte_xml, que refaz a
-- análise com os dados do próprio CT-e — principalmente as chaves das NF-es transportadas:
--   * confere que o XML é do CT-e do card (e, no card de uma NF, que o CT-e cita essa NF);
--   * acha as notas fiscais pela chave da NF-e (ou CNPJ do emitente + número, que estão
--     dentro da chave, quando a nota foi cadastrada sem chave) e grava nelas o CT-e. Um CT-e
--     de várias notas entra em todas: o valor do frete fica na primeira e as demais ficam
--     marcadas como "CT-e compartilhado";
--   * nota já concluída/encerrada que recebe o CT-e é reaberta em Pendências;
--   * o card próprio do CT-e, quando as notas são encontradas, é encerrado com a
--     observação "CT-e vinculado à NF …" (não é excluído).

alter table public.notas add column if not exists cte_xml_recebido_em timestamptz;
alter table public.notas add column if not exists cte_xml_dispensado_por uuid;
alter table public.notas add column if not exists cte_xml_dispensado_em timestamptz;
alter table public.notas add column if not exists cte_xml_dispensa_obs text;
alter table public.notas add column if not exists frete_cte_compartilhado text;

-- Chave de acesso de CT-e: modelo 57 nas posições 21-22.
create or replace function public.chave_e_cte(p_chave text)
 returns boolean
 language sql
 immutable
 set search_path to 'public', 'pg_temp'
as $function$
  select length(d) = 44 and substr(d, 21, 2) = '57'
    from (select regexp_replace(coalesce(p_chave, ''), '\D', '', 'g') d) x;
$function$;

create or replace function public.nota_precisa_xml_cte(n public.notas)
 returns boolean
 language sql
 stable
 set search_path to 'public', 'pg_temp'
as $function$
  select (n.frete_cte_chave is not null or public.chave_e_cte(n.chave_acesso))
     and n.cte_xml_recebido_em is null
     and n.cte_xml_dispensado_em is null;
$function$;

create or replace function public.notas_cte_xml_obrigatorio()
 returns trigger
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.status is distinct from old.status
     and old.status is distinct from 'concluido'
     and new.status is distinct from 'pendencias'
     and coalesce(current_setting('app.cte_analise', true), '') <> 'true'
     and public.nota_precisa_xml_cte(new) then
    raise exception 'Anexe o XML do CT-e % neste card antes de concluir ou movê-lo (ou peça ao administrador para liberar sem XML).',
      coalesce(nullif(trim(new.frete_cte), ''), new.numero) using errcode = 'P0001';
  end if;
  return new;
end;
$function$;
revoke execute on function public.notas_cte_xml_obrigatorio() from public, anon;
drop trigger if exists notas_cte_xml_obrigatorio_trg on public.notas;
create trigger notas_cte_xml_obrigatorio_trg before update of status on public.notas
  for each row execute function public.notas_cte_xml_obrigatorio();

-- p_cte: dados lidos do XML no navegador —
--   { chave, numero, serie, emitente, cnpjEmitente, valor, dataEmissao, tomadorNome, tomadorCnpj, nfeChaves: [..] }
create or replace function public.rpc_analisar_cte_xml(p_nota_id bigint, p_cte jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_nota public.notas;
  v_chave text := regexp_replace(coalesce(p_cte->>'chave', ''), '\D', '', 'g');
  v_num text := nullif(trim(coalesce(p_cte->>'numero', '')), '');
  v_emit text := nullif(trim(coalesce(p_cte->>'emitente', '')), '');
  v_valor numeric := case when coalesce(p_cte->>'valor', '') ~ '^\d+(\.\d+)?$' then (p_cte->>'valor')::numeric end;
  v_nfes text[];
  v_e_card boolean;
  v_alvos bigint[];
  v_ignoradas jsonb := '[]'::jsonb;
  v_vinculadas jsonb := '[]'::jsonb;
  v_t public.notas;
  v_novo boolean;
  v_erro text;
  v_compart text;
  v_lista text;
  v_card_encerrado boolean := false;
  v_nao_encontradas text[];
begin
  if not public.current_is_active() then
    raise exception 'Usuário inativo.' using errcode = '42501';
  end if;
  if not public.chave_e_cte(v_chave) then
    raise exception 'O arquivo não é um XML de CT-e válido (chave de acesso do CT-e não encontrada).' using errcode = '22023';
  end if;

  select * into v_nota from public.notas where id = p_nota_id for update;
  if not found then raise exception 'Nota fiscal não encontrada.' using errcode = 'P0002'; end if;
  if public."current_role"() not in ('admin', 'supervisor')
     and v_nota.assigned_to is distinct from auth.uid() and v_nota.created_by is distinct from auth.uid() then
    raise exception 'Você não pode anexar o XML do CT-e nesta nota.' using errcode = '42501';
  end if;

  select coalesce(array_agg(distinct d), '{}') into v_nfes
    from (select regexp_replace(x, '\D', '', 'g') d from jsonb_array_elements_text(coalesce(p_cte->'nfeChaves', '[]'::jsonb)) x) y
   where length(d) = 44;

  v_e_card := public.chave_e_cte(v_nota.chave_acesso);
  if v_e_card and regexp_replace(v_nota.chave_acesso, '\D', '', 'g') <> v_chave then
    raise exception 'Este XML é do CT-e %, mas este card é do CT-e %.', v_chave, regexp_replace(v_nota.chave_acesso, '\D', '', 'g') using errcode = '22023';
  end if;
  if not v_e_card then
    if v_nota.frete_cte_chave is not null and v_nota.frete_cte_chave <> v_chave then
      raise exception 'Este XML é do CT-e %, mas esta nota está ligada ao CT-e %.', v_chave, v_nota.frete_cte_chave using errcode = '22023';
    end if;
    if length(regexp_replace(coalesce(v_nota.chave_acesso, ''), '\D', '', 'g')) = 44 and cardinality(v_nfes) > 0
       and not (regexp_replace(v_nota.chave_acesso, '\D', '', 'g') = any (v_nfes)) then
      raise exception 'O CT-e % não cita esta nota fiscal — ele transporta as NF-es %. Confira se o XML é o certo.',
        coalesce(v_num, v_chave), array_to_string(v_nfes, ', ') using errcode = '22023';
    end if;
  end if;

  -- notas fiscais do CT-e: pela chave da NF-e; sem chave cadastrada, pelo CNPJ do emitente + número (que estão na chave)
  select coalesce(array_agg(n.id order by (n.id = p_nota_id) desc, n.id), '{}') into v_alvos
    from public.notas n
   where not public.chave_e_cte(n.chave_acesso)
     and (
       (not v_e_card and n.id = p_nota_id)
       or exists (select 1 from unnest(v_nfes) k
                   where regexp_replace(coalesce(n.chave_acesso, ''), '\D', '', 'g') = k
                      or (length(regexp_replace(coalesce(n.chave_acesso, ''), '\D', '', 'g')) <> 44
                          and regexp_replace(coalesce(n.cnpj_emitente, ''), '\D', '', 'g') = substr(k, 7, 14)
                          and ltrim(regexp_replace(n.numero, '\D', '', 'g'), '0') = ltrim(substr(k, 26, 9), '0')))
     );

  -- nota que já está ligada a outro CT-e não é mexida
  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'numeroNota', n.numero, 'fornecedor', n.fornecedor,
                                               'motivo', 'já ligada ao CT-e ' || coalesce(n.frete_cte, n.frete_cte_chave))), '[]'::jsonb)
    into v_ignoradas
    from public.notas n where n.id = any (v_alvos) and n.frete_cte_chave is not null and n.frete_cte_chave <> v_chave;
  select coalesce(array_agg(a order by ord), '{}') into v_alvos
    from unnest(v_alvos) with ordinality u(a, ord)
   where not exists (select 1 from public.notas n where n.id = a and n.frete_cte_chave is not null and n.frete_cte_chave <> v_chave);

  if cardinality(v_alvos) > 1 then
    select string_agg(numero, ', ' order by id) into v_lista from public.notas where id = any (v_alvos);
  end if;

  for i in 1 .. cardinality(v_alvos) loop
    select * into v_t from public.notas where id = v_alvos[i] for update;
    v_novo := v_t.frete_cte_chave is distinct from v_chave;
    v_compart := case when cardinality(v_alvos) > 1 then 'CT-e compartilhado com as NF ' || v_lista
                       || case when i = 1 then ' — o valor do frete está nesta nota.' else ' — o valor do frete está na NF ' || split_part(v_lista, ', ', 1) || '.' end end;
    update public.notas set
      frete = 'sim',
      frete_cte = coalesce(nullif(trim(frete_cte), ''), v_num),
      frete_transportador = coalesce(nullif(trim(frete_transportador), ''), v_emit),
      frete_valor = case when i = 1 then coalesce(frete_valor, v_valor) else frete_valor end,
      frete_cte_compartilhado = v_compart,
      frete_cte_chave = v_chave,
      frete_lancamento_pendente = case when v_novo then true else frete_lancamento_pendente end,
      cte_xml_recebido_em = now()
    where id = v_t.id;

    v_erro := null;
    if v_novo and v_t.status = 'concluido' then
      v_erro := public.cte_reabrir_em_pendencias(v_t.id, v_num, v_emit, case when i = 1 then v_valor end);
    end if;
    insert into public.audit_log (user_id, user_name, action, entity_type, entity_id, details)
    values (auth.uid(), (select name from public.profiles where id = auth.uid()), 'cte_xml_analisado', 'nota_fiscal', v_t.id::text,
            p_cte || jsonb_build_object('notaDoXml', p_nota_id, 'statusAnterior', v_t.status, 'novoVinculo', v_novo));
    v_vinculadas := v_vinculadas || jsonb_build_object('id', v_t.id, 'numeroNota', v_t.numero, 'fornecedor', v_t.fornecedor,
      'statusAnterior', v_t.status, 'novoVinculo', v_novo,
      'reaberta', v_novo and v_t.status = 'concluido' and v_erro is null, 'erro', v_erro);
  end loop;

  select coalesce(array_agg(k), '{}') into v_nao_encontradas
    from unnest(v_nfes) k
   where not exists (select 1 from public.notas n where n.id = any (v_alvos)
                       and (regexp_replace(coalesce(n.chave_acesso, ''), '\D', '', 'g') = k
                            or (regexp_replace(coalesce(n.cnpj_emitente, ''), '\D', '', 'g') = substr(k, 7, 14)
                                and ltrim(regexp_replace(n.numero, '\D', '', 'g'), '0') = ltrim(substr(k, 26, 9), '0'))));

  if v_e_card then
    update public.notas set cte_xml_recebido_em = now() where id = p_nota_id;
    -- notas fiscais encontradas: o frete segue nelas e o card do CT-e é encerrado (não excluído)
    if cardinality(v_alvos) > 0 and v_nota.status <> 'concluido' then
      select string_agg(numero, ', ' order by id) into v_lista from public.notas where id = any (v_alvos);
      perform set_config('app.cte_analise', 'true', true);
      update public.notas set
        status = 'concluido', completed_at = now(),
        lancamento_validado_por = auth.uid(), lancamento_validado_em = now(),
        lancamento_validado_obs = 'CT-e vinculado à(s) NF ' || v_lista || ' — card encerrado automaticamente; o lançamento do frete segue na(s) nota(s) fiscal(is).',
        descricao = trim(coalesce(descricao, '') || ' CT-e vinculado à(s) NF ' || v_lista || ' pela análise do XML.')
      where id = p_nota_id;
      perform set_config('app.cte_analise', 'false', true);
      v_card_encerrado := true;
    end if;
  end if;

  insert into public.audit_log (user_id, user_name, action, entity_type, entity_id, details)
  values (auth.uid(), (select name from public.profiles where id = auth.uid()), 'cte_xml_anexado', 'nota_fiscal', p_nota_id::text,
          p_cte || jsonb_build_object('vinculadas', v_vinculadas, 'cardEncerrado', v_card_encerrado));

  return jsonb_build_object('chave', v_chave, 'cardCte', v_e_card, 'cardEncerrado', v_card_encerrado,
                            'vinculadas', v_vinculadas, 'ignoradas', v_ignoradas,
                            'nfesNaoEncontradas', to_jsonb(v_nao_encontradas));
end;
$function$;

create or replace function public.rpc_dispensar_xml_cte(p_nota_id bigint, p_justificativa text)
 returns public.notas
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_nota public.notas;
begin
  if not public.current_is_active() or public."current_role"() <> 'admin' then
    raise exception 'Só o administrador pode liberar um card sem o XML do CT-e.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_justificativa, ''))) < 5 then
    raise exception 'Informe a justificativa para liberar sem o XML do CT-e.' using errcode = '22023';
  end if;
  update public.notas set
    cte_xml_dispensado_por = auth.uid(), cte_xml_dispensado_em = now(), cte_xml_dispensa_obs = trim(p_justificativa)
  where id = p_nota_id
  returning * into v_nota;
  if not found then raise exception 'Nota fiscal não encontrada.' using errcode = 'P0002'; end if;
  insert into public.audit_log (user_id, user_name, action, entity_type, entity_id, details)
  values (auth.uid(), (select name from public.profiles where id = auth.uid()), 'cte_xml_dispensado', 'nota_fiscal', p_nota_id::text,
          jsonb_build_object('justificativa', trim(p_justificativa)));
  return v_nota;
end;
$function$;

revoke all on function public.rpc_analisar_cte_xml(bigint, jsonb) from public, anon;
grant execute on function public.rpc_analisar_cte_xml(bigint, jsonb) to authenticated;
revoke all on function public.rpc_dispensar_xml_cte(bigint, text) from public, anon;
grant execute on function public.rpc_dispensar_xml_cte(bigint, text) to authenticated;
revoke all on function public.chave_e_cte(text) from public, anon;
grant execute on function public.chave_e_cte(text) to authenticated;
revoke all on function public.nota_precisa_xml_cte(public.notas) from public, anon;
grant execute on function public.nota_precisa_xml_cte(public.notas) to authenticated;
