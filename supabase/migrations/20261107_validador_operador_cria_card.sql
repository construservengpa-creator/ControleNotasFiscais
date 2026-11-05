-- ➕ Validador de NF: qualquer usuário liberado (inclusive operador) cria o card de UMA nota pendente.
-- (aplicar depois de 20261106_quadro_acesso_por_empresa.sql; pode rodar de novo sem problema)
--
-- O "Criar cards" em lote continua só para admin/supervisor (rpc_importar_lote). Esta função cria um card por
-- vez, a partir da chave de acesso da nota na base salva do validador:
--   * os dados do card vêm da base (validador_nf_notas), não do navegador;
--   * a nota precisa estar entre as empresas liberadas para o usuário (mesma regra do validador/quadro);
--   * só nota pendente (sem título) e que ainda não tem card (mesma checagem de duplicidade da importação);
--   * o card nasce igual ao da importação: "Importadas SIENGE", origem sienge, obra pelo CNPJ do destinatário
--     quando só uma obra tem esse CNPJ, movimentação e auditoria. created_by = quem criou (ele continua vendo
--     o card no quadro mesmo com acesso restrito).

create or replace function public.validador_criar_card(p_chave text)
 returns bigint
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_chave text := upper(regexp_replace(coalesce(p_chave, ''), '[^0-9A-Za-z]', '', 'g'));
  v record;
  v_numero text;
  v_cnpj text;
  v_obra_ids bigint[];
  v_obra_nomes text[];
  v_desc text;
  v_id bigint;
begin
  if not public.current_is_active() or coalesce(public."current_role"(), 'pendente') = 'pendente' then
    raise exception 'Você não tem permissão para executar esta ação.' using errcode = '42501';
  end if;

  select * into v from validador_nf_notas n where n.chave = v_chave;
  if not found then
    raise exception 'Nota não encontrada na base salva do validador.' using errcode = 'P0002';
  end if;

  v_cnpj := regexp_replace(coalesce(v.cnpj_destinatario, ''), '\D', '', 'g');
  if not public.validador_ve_tudo() and not (v_cnpj = any (public.validador_cnpjs_permitidos())) then
    raise exception 'Você não tem acesso às notas desta empresa.' using errcode = '42501';
  end if;
  if coalesce(btrim(v.titulo), '') not in ('', '0') then
    raise exception 'Esta nota já está lançada (tem título) — não precisa de card.' using errcode = '22023';
  end if;
  if coalesce(btrim(v.emitente), '') = '' then
    raise exception 'Nota sem emitente no relatório — não dá para criar o card.' using errcode = '22023';
  end if;

  -- Número: antes da barra de "Número/Série"; sem ele, o número da chave (posições 26 a 34).
  v_numero := btrim(split_part(coalesce(v.numero_serie, ''), '/', 1));
  if v_numero = '' and substr(v_chave, 26, 9) ~ '^\d{9}$' then v_numero := (substr(v_chave, 26, 9))::bigint::text; end if;
  if v_numero = '' then
    raise exception 'Nota sem número no relatório — não dá para criar o card.' using errcode = '22023';
  end if;

  if public.nota_duplicada_de(v_numero, btrim(v.emitente), coalesce(v.valor, 0), v_chave, null) is not null then
    raise exception 'Esta nota já tem card no Controle de Notas.' using errcode = '23505';
  end if;

  select array_agg(o.id order by o.nome), array_agg(o.nome order by o.nome) into v_obra_ids, v_obra_nomes
    from obra_cnpjs oc join obras o on o.id = oc.obra_id
   where v_cnpj <> '' and regexp_replace(oc.cnpj, '\D', '', 'g') = v_cnpj;

  v_desc := concat_ws(' ',
    'Criada pelo Validador de NF a partir do relatório SIENGE (título/nota fiscal avulsa ainda não gerado).',
    case when coalesce(btrim(v.natureza), '') <> '' then 'Natureza da operação: ' || btrim(v.natureza) || '.' end,
    case when coalesce(btrim(v.escrituracao), '') <> '' then 'Escrituração no relatório: ' || btrim(v.escrituracao) || '.' end,
    case when coalesce(btrim(v.manifesto), '') <> '' then 'Manifesto: ' || btrim(v.manifesto) || '.' end,
    'Complete obra, vencimento, forma de pagamento e pedido de compras usando "Editar".',
    case when array_length(v_obra_ids, 1) > 1
      then '[Possíveis obras: ' || array_to_string(v_obra_nomes, ', ') || ' — confirmar em Editar]' end);

  insert into notas (numero, fornecedor, valor, data_emissao, descricao, sede, status,
                     created_by, origem, chave_acesso, destinatario, cnpj_destinatario, obra_id)
  values (v_numero, btrim(v.emitente), coalesce(v.valor, 0), v.emissao, v_desc, 'AMETA', 'importadas_sienge',
          auth.uid(), 'sienge', v_chave, nullif(btrim(coalesce(v.destinatario, '')), ''), nullif(btrim(coalesce(v.cnpj_destinatario, '')), ''),
          case when array_length(v_obra_ids, 1) = 1 then v_obra_ids[1] end)
  on conflict (lower(numero), lower(fornecedor)) do nothing
  returning id into v_id;
  if v_id is null then
    raise exception 'Já existe um card com este número e fornecedor no Controle de Notas.' using errcode = '23505';
  end if;

  insert into movements (nota_id, from_status, to_status, moved_by, method, note)
  values (v_id, null, 'importadas_sienge', auth.uid(), 'importacao_sienge',
          'Card criado pelo Validador de NF a partir do relatório SIENGE — dados incompletos, use "Editar" para completar.');

  perform public.registrar_auditoria('notas_importadas_sienge', 'nota_fiscal', null,
    jsonb_build_object('total', 1, 'origem', 'validador_criar_card', 'nota_id', v_id, 'chave', v_chave));

  return v_id;
end;
$function$;

revoke all on function public.validador_criar_card(text) from public, anon;
grant execute on function public.validador_criar_card(text) to authenticated;
