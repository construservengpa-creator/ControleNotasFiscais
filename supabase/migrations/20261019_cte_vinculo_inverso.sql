-- 🔁 Vínculo inverso do CT-e (aplicar depois de 20261018_cte_xml_obrigatorio.sql).
--
-- Até aqui o frete só se ligava à nota fiscal quando a nota chegava primeiro: a importação
-- do relatório de CT-es (rpc_vincular_ctes) ou o XML do CT-e achavam a nota e gravavam o
-- frete nela. Quando o CT-e chegava primeiro, ele virava card próprio em "Importadas SIENGE"
-- e a nota cadastrada depois não se ligava a ele.
--
-- Agora, sempre que uma nota fiscal é gravada (cadastro manual, importação em lote, API do
-- Estoque ou edição) sem CT-e vinculado, o banco procura um card de CT-e que seja dela:
--   1. pela chave da NF-e: o XML do CT-e anexado no card cita a chave desta nota (ou o CNPJ
--      do emitente + número, que estão dentro da chave, quando a nota não tem chave);
--   2. senão, pelo nº do CT-e informado no frete da nota + transportador ou valor do frete
--      (a mesma regra da importação do relatório), desde que o CT-e ainda não esteja em
--      outra nota e que o XML do card, se anexado, não cite outras NF-es.
-- Achando um único card, o frete é gravado na nota (com "lançamento do frete pendente"), o
-- XML/liberação do card valem para a nota, o card do CT-e é encerrado com a observação
-- "CT-e vinculado à NF …" e, se a nota já estava concluída, ela é reaberta em Pendências.
-- Um card de CT-e já concluído à mão (frete lançado no próprio card) só empresta os dados:
-- a nota não fica com o lançamento pendente.
--
-- O XML do CT-e anexado na nota fiscal também passa a encerrar o card próprio do mesmo
-- CT-e, se houver, e as chaves das NF-es lidas do XML ficam guardadas no card
-- (cte_nfe_chaves) para o vínculo pela chave.

alter table public.notas add column if not exists cte_nfe_chaves text[];

create index if not exists notas_cte_nfe_chaves_idx on public.notas using gin (cte_nfe_chaves)
  where cte_nfe_chaves is not null;
create index if not exists notas_card_cte_numero_idx
  on public.notas (ltrim(regexp_replace(split_part(coalesce(numero, ''), '/', 1), '\D', '', 'g'), '0'))
  where public.chave_e_cte(chave_acesso);

-- Chaves de NF-e dos XMLs de CT-e já anexados em cards de CT-e (estão no audit_log).
update public.notas n set cte_nfe_chaves = x.chaves
  from (select distinct on (a.entity_id) a.entity_id::bigint id,
               array(select distinct regexp_replace(k, '\D', '', 'g')
                       from jsonb_array_elements_text(coalesce(a.details->'nfeChaves', '[]'::jsonb)) k
                      where length(regexp_replace(k, '\D', '', 'g')) = 44) chaves
          from public.audit_log a
         where a.action = 'cte_xml_anexado' and a.entity_type = 'nota_fiscal' and a.entity_id ~ '^\d+$'
         order by a.entity_id, a.id desc) x
 where n.id = x.id and public.chave_e_cte(n.chave_acesso) and n.cte_nfe_chaves is null;

-- Encerra o card próprio de um CT-e cujo frete passou para nota(s) fiscal(is).
create or replace function public.cte_encerrar_card(p_card_id bigint, p_lista_nfs text, p_como text)
 returns void
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
begin
  perform set_config('app.cte_analise', 'true', true);
  update public.notas set
    status = 'concluido', completed_at = now(),
    lancamento_validado_por = auth.uid(), lancamento_validado_em = now(),
    lancamento_validado_obs = 'CT-e vinculado à(s) NF ' || p_lista_nfs || ' — card encerrado automaticamente; o lançamento do frete segue na(s) nota(s) fiscal(is).',
    descricao = trim(coalesce(descricao, '') || ' CT-e vinculado à(s) NF ' || p_lista_nfs || ' ' || p_como || '.')
  where id = p_card_id and status is distinct from 'concluido';
  perform set_config('app.cte_analise', 'false', true);
end;
$function$;
revoke all on function public.cte_encerrar_card(bigint, text, text) from public, anon, authenticated;

-- Card de CT-e encerrado pelo vínculo com a nota (e não concluído à mão com o frete lançado nele).
create or replace function public.card_cte_encerrado_por_vinculo(c public.notas)
 returns boolean
 language sql
 stable
 set search_path to 'public', 'pg_temp'
as $function$
  select c.status = 'concluido' and coalesce(c.lancamento_validado_obs, '') like 'CT-e vinculado à(s) NF %';
$function$;
revoke all on function public.card_cte_encerrado_por_vinculo(public.notas) from public, anon, authenticated;

-- ANTES de gravar a nota: acha o card do CT-e e grava o frete na própria linha.
create or replace function public.notas_cte_vinculo_auto()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_nf_chave text := regexp_replace(coalesce(new.chave_acesso, ''), '\D', '', 'g');
  v_cnpj text := regexp_replace(coalesce(new.cnpj_emitente, ''), '\D', '', 'g');
  v_num text := ltrim(regexp_replace(coalesce(new.numero, ''), '\D', '', 'g'), '0');
  v_fcte text := ltrim(regexp_replace(split_part(coalesce(new.frete_cte, ''), '/', 1), '\D', '', 'g'), '0');
  v_ids bigint[];
  v_card public.notas;
  v_card_chave text;
  v_outras text;
  v_dono text;
begin
  if new.frete_cte_chave is not null or public.chave_e_cte(new.chave_acesso)
     or coalesce(current_setting('app.cte_analise_xml', true), '') = 'true' then
    return new;
  end if;

  begin
    -- 1. o XML do card cita esta NF-e
    if length(v_nf_chave) = 44 then
      select coalesce(array_agg(c.id order by c.id), '{}') into v_ids
        from public.notas c
       where c.cte_nfe_chaves is not null and public.chave_e_cte(c.chave_acesso)
         and c.cte_nfe_chaves @> array[v_nf_chave];
    elsif v_cnpj <> '' and v_num <> '' then
      select coalesce(array_agg(c.id order by c.id), '{}') into v_ids
        from public.notas c
       where c.cte_nfe_chaves is not null and public.chave_e_cte(c.chave_acesso)
         and exists (select 1 from unnest(c.cte_nfe_chaves) k
                      where substr(k, 7, 14) = v_cnpj and ltrim(substr(k, 26, 9), '0') = v_num);
    else
      v_ids := '{}';
    end if;

    -- 2. nº do CT-e informado no frete + transportador ou valor
    if cardinality(v_ids) = 0 and v_fcte <> '' then
      select coalesce(array_agg(c.id order by c.id), '{}') into v_ids
        from public.notas c
       where public.chave_e_cte(c.chave_acesso)
         and ltrim(regexp_replace(split_part(coalesce(c.numero, ''), '/', 1), '\D', '', 'g'), '0') = v_fcte
         and (
           nullif(trim(coalesce(new.frete_transportador, '')), '') is null
           or (new.frete_valor is not null and new.frete_valor = c.valor)
           or public.mesma_empresa(new.frete_transportador, c.fornecedor)
         )
         and (c.cte_nfe_chaves is null or cardinality(c.cte_nfe_chaves) = 0
              or (length(v_nf_chave) = 44 and c.cte_nfe_chaves @> array[v_nf_chave])
              or (length(v_nf_chave) <> 44 and v_cnpj <> ''
                  and exists (select 1 from unnest(c.cte_nfe_chaves) k
                               where substr(k, 7, 14) = v_cnpj and ltrim(substr(k, 26, 9), '0') = v_num)))
         and not exists (select 1 from public.notas o
                          where o.frete_cte_chave = regexp_replace(c.chave_acesso, '\D', '', 'g')
                            and o.id is distinct from new.id);
    end if;

    if cardinality(v_ids) <> 1 then
      return new;
    end if;

    select * into v_card from public.notas where id = v_ids[1];
    v_card_chave := regexp_replace(v_card.chave_acesso, '\D', '', 'g');

    -- outras notas fiscais do mesmo CT-e (CT-e de várias notas): o valor do frete fica na primeira
    select string_agg(o.numero, ', ' order by o.id) into v_outras
      from public.notas o where o.frete_cte_chave = v_card_chave and o.id is distinct from new.id;
    if v_outras is not null then
      select o.numero into v_dono from public.notas o
       where o.frete_cte_chave = v_card_chave and o.id is distinct from new.id
       order by (o.frete_cte_compartilhado is null or o.frete_cte_compartilhado like '%está nesta nota%') desc, o.id
       limit 1;
    end if;

    new.frete := 'sim';
    new.frete_cte := coalesce(nullif(trim(new.frete_cte), ''), v_card.numero);
    new.frete_transportador := coalesce(nullif(trim(new.frete_transportador), ''), v_card.fornecedor);
    if v_outras is null then
      new.frete_valor := coalesce(new.frete_valor, v_card.valor);
    else
      new.frete_cte_compartilhado := 'CT-e compartilhado com as NF ' || v_outras || ', ' || new.numero
                                     || ' — o valor do frete está na NF ' || v_dono || '.';
    end if;
    new.frete_cte_chave := v_card_chave;
    new.frete_lancamento_pendente := v_card.status is distinct from 'concluido' or public.card_cte_encerrado_por_vinculo(v_card);
    new.cte_xml_recebido_em := coalesce(new.cte_xml_recebido_em, v_card.cte_xml_recebido_em);
    if new.cte_xml_dispensado_em is null and v_card.cte_xml_dispensado_em is not null then
      new.cte_xml_dispensado_em := v_card.cte_xml_dispensado_em;
      new.cte_xml_dispensado_por := v_card.cte_xml_dispensado_por;
      new.cte_xml_dispensa_obs := v_card.cte_xml_dispensa_obs;
    end if;
  exception when others then
    raise warning 'Vínculo automático do CT-e não aplicado na nota %: %', new.numero, sqlerrm;
  end;
  return new;
end;
$function$;
revoke execute on function public.notas_cte_vinculo_auto() from public, anon;

-- DEPOIS de gravar: encerra o card do CT-e, avisa as outras notas do CT-e compartilhado e
-- reabre em Pendências a nota que já estava concluída.
create or replace function public.notas_cte_vinculo_auto_pos()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_card public.notas;
  v_lista text;
  v_erro text;
  v_reaberta boolean := false;
begin
  if public.chave_e_cte(new.chave_acesso)
     or coalesce(current_setting('app.cte_analise_xml', true), '') = 'true' then
    return null;
  end if;
  select * into v_card from public.notas c
   where public.chave_e_cte(c.chave_acesso) and regexp_replace(c.chave_acesso, '\D', '', 'g') = new.frete_cte_chave
   order by c.id limit 1;
  if not found then
    return null; -- vínculo feito pela importação do relatório ou pelo XML (não há card do CT-e)
  end if;

  begin
    select string_agg(numero, ', ' order by id) into v_lista from public.notas where frete_cte_chave = new.frete_cte_chave;

    if new.frete_cte_compartilhado is not null then
      update public.notas set
        frete_cte_compartilhado = 'CT-e compartilhado com as NF ' || v_lista || ' — o valor do frete está nesta nota.'
      where frete_cte_chave = new.frete_cte_chave and id <> new.id
        and (frete_cte_compartilhado is null or frete_cte_compartilhado like '%está nesta nota%');
      update public.notas set
        frete_cte_compartilhado = regexp_replace(frete_cte_compartilhado, '^CT-e compartilhado com as NF .* — ',
                                                 'CT-e compartilhado com as NF ' || v_lista || ' — ')
      where frete_cte_chave = new.frete_cte_chave and id <> new.id
        and frete_cte_compartilhado not like '%está nesta nota%';
    end if;

    if v_card.status is distinct from 'concluido' then
      perform public.cte_encerrar_card(v_card.id, v_lista, 'ao cadastrar/atualizar a nota fiscal');
    end if;

    if tg_op = 'UPDATE' and old.status = 'concluido' and new.status = 'concluido' and new.frete_lancamento_pendente then
      v_erro := public.cte_reabrir_em_pendencias(new.id, v_card.numero, v_card.fornecedor,
                                                 case when new.frete_cte_compartilhado is null then v_card.valor end);
      v_reaberta := v_erro is null;
    end if;

    insert into public.audit_log (user_id, user_name, action, entity_type, entity_id, details)
    values (auth.uid(), (select name from public.profiles where id = auth.uid()), 'cte_vinculado_auto', 'nota_fiscal', new.id::text,
            jsonb_build_object('cardCteId', v_card.id, 'cteChave', new.frete_cte_chave, 'cteNumero', v_card.numero,
                               'transportador', v_card.fornecedor, 'statusCardAnterior', v_card.status,
                               'reaberta', v_reaberta, 'erro', v_erro));
  exception when others then
    raise warning 'Card do CT-e % não encerrado após o vínculo com a nota %: %', v_card.numero, new.numero, sqlerrm;
  end;
  return null;
end;
$function$;
revoke execute on function public.notas_cte_vinculo_auto_pos() from public, anon;

drop trigger if exists notas_cte_vinculo_auto_trg on public.notas;
create trigger notas_cte_vinculo_auto_trg
  before insert or update of numero, chave_acesso, cnpj_emitente, frete, frete_cte, frete_transportador, frete_valor
  on public.notas
  for each row when (new.frete_cte_chave is null)
  execute function public.notas_cte_vinculo_auto();

drop trigger if exists notas_cte_vinculo_auto_ins_trg on public.notas;
create trigger notas_cte_vinculo_auto_ins_trg after insert on public.notas
  for each row when (new.frete_cte_chave is not null)
  execute function public.notas_cte_vinculo_auto_pos();

drop trigger if exists notas_cte_vinculo_auto_upd_trg on public.notas;
create trigger notas_cte_vinculo_auto_upd_trg after update on public.notas
  for each row when (old.frete_cte_chave is null and new.frete_cte_chave is not null)
  execute function public.notas_cte_vinculo_auto_pos();

-- Análise do XML: igual à de 20261018_cte_xml_obrigatorio.sql, mais
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

-- Notas já cadastradas cujo CT-e chegou antes e ficou como card próprio: aplica o vínculo
-- agora (só nas notas não concluídas — as concluídas não são reabertas por esta carga).
update public.notas n set numero = n.numero
 where n.frete_cte_chave is null
   and n.status is distinct from 'concluido'
   and not public.chave_e_cte(n.chave_acesso)
   and (nullif(trim(coalesce(n.frete_cte, '')), '') is not null
        or exists (select 1 from public.notas c where c.cte_nfe_chaves is not null and public.chave_e_cte(c.chave_acesso)));
