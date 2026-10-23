-- 🔓 Encerramento do card do CT-e liberado pela trava de campos sensíveis
-- (aplicar depois de 20261019_cte_vinculo_inverso.sql).
--
-- O gatilho notas_guard_campos_sensiveis só deixa mudar status, responsável,
-- homologação, validação do lançamento e nº do título com app.rpc_call = 'true'
-- (como faz aplicar_mudanca_status). cte_encerrar_card mudava o status do card do
-- CT-e direto, sem esse sinal, e era barrado com "Mudança de status, responsável ou
-- homologação só pode ser feita pelas rotinas do sistema.":
--   * ao anexar o XML do CT-e cujas notas fiscais já estão cadastradas, a análise
--     inteira era desfeita e o card ficava sem o XML;
--   * no vínculo automático ao gravar a nota fiscal, o frete ia para a nota, mas o
--     card do CT-e ficava aberto (o erro só virava um aviso no log).
--
-- O gatilho notas_guard_edicao_geral também barrava: fora admin, supervisor e validador
-- da obra, ninguém altera descrição e dados do frete, a menos que app.integracao = 'true'.
-- Isso derrubava o encerramento rodado sem usuário (SQL Editor) e a análise do XML feita
-- pelo responsável ou por quem cadastrou a nota (que rpc_analisar_cte_xml permite) ao
-- gravar o frete na nota fiscal. As duas rotinas passam a ligar app.integracao só durante
-- as próprias gravações, depois de conferir a permissão, e restauram o valor anterior.
--
-- A restrição notas_concluido_exige_titulo (nota concluída precisa do nº do título)
-- também barrava o encerramento: o card do CT-e encerrado pelo vínculo não tem título,
-- o lançamento do frete segue na nota fiscal. A restrição é recriada com essa exceção,
-- mantendo a regra existente (lida do próprio banco) para todo o resto.
--
-- Não usa aplicar_mudanca_status porque ela exige o nº do título para concluir e
-- registra a conclusão como tratamento da nota — aqui o card só é encerrado.

create or replace function public.cte_encerrar_card(p_card_id bigint, p_lista_nfs text, p_como text)
 returns void
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_rpc_call text := coalesce(current_setting('app.rpc_call', true), '');
  v_integracao text := coalesce(current_setting('app.integracao', true), '');
begin
  perform set_config('app.cte_analise', 'true', true);
  perform set_config('app.rpc_call', 'true', true);
  perform set_config('app.integracao', 'true', true);
  update public.notas set
    status = 'concluido', completed_at = now(),
    lancamento_validado_por = auth.uid(), lancamento_validado_em = now(),
    lancamento_validado_obs = 'CT-e vinculado à(s) NF ' || p_lista_nfs || ' — card encerrado automaticamente; o lançamento do frete segue na(s) nota(s) fiscal(is).',
    descricao = trim(coalesce(descricao, '') || ' CT-e vinculado à(s) NF ' || p_lista_nfs || ' ' || p_como || '.')
  where id = p_card_id and status is distinct from 'concluido';
  perform set_config('app.integracao', v_integracao, true);
  perform set_config('app.rpc_call', v_rpc_call, true);
  perform set_config('app.cte_analise', 'false', true);
end;
$function$;
revoke all on function public.cte_encerrar_card(bigint, text, text) from public, anon, authenticated;

-- Análise do XML: a mesma de 20261019_cte_vinculo_inverso.sql, com app.integracao ligado só
-- durante as gravações (ver o cabeçalho). Em relação a 20261018_cte_xml_obrigatorio.sql:
--   * guarda no card do CT-e as chaves das NF-es do XML (cte_nfe_chaves);
--   * no XML anexado na nota fiscal, encerra o card próprio do mesmo CT-e, se houver;
--   * desliga o vínculo automático enquanto ela mesma grava as notas.
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
  v_card_cte public.notas;
  v_card_cte_encerrado jsonb;
  v_nao_encontradas text[];
  v_integracao text := coalesce(current_setting('app.integracao', true), '');
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

  perform set_config('app.cte_analise_xml', 'true', true);
  -- permissão já conferida acima: as gravações abaixo são da rotina, não edição do usuário
  perform set_config('app.integracao', 'true', true);

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
    update public.notas set cte_xml_recebido_em = now(), cte_nfe_chaves = v_nfes where id = p_nota_id;
    -- notas fiscais encontradas: o frete segue nelas e o card do CT-e é encerrado (não excluído)
    if cardinality(v_alvos) > 0 and v_nota.status <> 'concluido' then
      select string_agg(numero, ', ' order by id) into v_lista from public.notas where id = any (v_alvos);
      perform public.cte_encerrar_card(p_nota_id, v_lista, 'pela análise do XML');
      v_card_encerrado := true;
    end if;
  else
    -- XML anexado na nota fiscal: o card próprio do mesmo CT-e, se houver, também é encerrado
    select * into v_card_cte from public.notas c
     where public.chave_e_cte(c.chave_acesso) and regexp_replace(c.chave_acesso, '\D', '', 'g') = v_chave
     order by c.id limit 1 for update;
    if found then
      update public.notas set cte_xml_recebido_em = coalesce(cte_xml_recebido_em, now()), cte_nfe_chaves = v_nfes
       where id = v_card_cte.id;
      if v_card_cte.status is distinct from 'concluido' and cardinality(v_alvos) > 0 then
        select string_agg(numero, ', ' order by id) into v_lista from public.notas where id = any (v_alvos);
        perform public.cte_encerrar_card(v_card_cte.id, v_lista, 'pela análise do XML anexado na nota fiscal');
        v_card_cte_encerrado := jsonb_build_object('id', v_card_cte.id, 'numero', v_card_cte.numero);
      end if;
    end if;
  end if;

  perform set_config('app.cte_analise_xml', 'false', true);
  perform set_config('app.integracao', v_integracao, true);

  insert into public.audit_log (user_id, user_name, action, entity_type, entity_id, details)
  values (auth.uid(), (select name from public.profiles where id = auth.uid()), 'cte_xml_anexado', 'nota_fiscal', p_nota_id::text,
          p_cte || jsonb_build_object('vinculadas', v_vinculadas, 'cardEncerrado', v_card_encerrado,
                                      'cardCteEncerrado', v_card_cte_encerrado));

  return jsonb_build_object('chave', v_chave, 'cardCte', v_e_card, 'cardEncerrado', v_card_encerrado,
                            'cardCteEncerrado', v_card_cte_encerrado,
                            'vinculadas', v_vinculadas, 'ignoradas', v_ignoradas,
                            'nfesNaoEncontradas', to_jsonb(v_nao_encontradas));
end;
$function$;

revoke all on function public.rpc_analisar_cte_xml(bigint, jsonb) from public, anon;
grant execute on function public.rpc_analisar_cte_xml(bigint, jsonb) to authenticated;

-- Exceção na notas_concluido_exige_titulo para o card do CT-e encerrado pelo vínculo.
do $migracao$
declare
  v_def text;
begin
  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c
   where c.conrelid = 'public.notas'::regclass and c.conname = 'notas_concluido_exige_titulo';
  if v_def is null or v_def like '%CT-e vinculado%' then
    return;
  end if;
  v_def := regexp_replace(regexp_replace(v_def, '^CHECK\s*', ''), '\s*NOT VALID\s*$', '');
  alter table public.notas drop constraint notas_concluido_exige_titulo;
  execute format('alter table public.notas add constraint notas_concluido_exige_titulo check (%s or (public.chave_e_cte(chave_acesso) and coalesce(lancamento_validado_obs, '''') like ''CT-e vinculado à(s) NF %%''))', v_def);
end
$migracao$;

-- Cards de CT-e que ficaram abertos porque o encerramento era barrado, embora o frete
-- já esteja gravado em nota(s) fiscal(is): encerra agora.
select public.cte_encerrar_card(c.id, c.lista, 'na correção do encerramento automático')
  from (select card.id, string_agg(nf.numero, ', ' order by nf.id) as lista
          from public.notas card
          join public.notas nf on nf.frete_cte_chave = regexp_replace(card.chave_acesso, '\D', '', 'g')
                              and not public.chave_e_cte(nf.chave_acesso)
         where public.chave_e_cte(card.chave_acesso)
           and card.status is distinct from 'concluido'
         group by card.id) c;
