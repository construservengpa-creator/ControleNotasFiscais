-- Integração Estoque -> Controle de Notas: função chamada só pela API receber-nota-estoque (service_role).
-- Cria a nota em "Entradas" (origem estoque) ou, se já existir, só completa os campos vazios.
CREATE OR REPLACE FUNCTION public.api_receber_nota_estoque(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_numero text := nullif(trim(coalesce(p->>'numero','')),'');
  v_forn text := nullif(trim(coalesce(p->>'fornecedor','')),'');
  v_chave text := nullif(regexp_replace(coalesce(p->>'chaveAcesso',''),'\D','','g'),'');
  v_cnpj_emit text := nullif(regexp_replace(coalesce(p->>'cnpjEmitente',''),'\D','','g'),'');
  v_cnpj_dest text := nullif(trim(coalesce(p->>'cnpjDestinatario','')),'');
  v_dest text := nullif(trim(coalesce(p->>'destinatario','')),'');
  v_valor numeric := coalesce(nullif(p->>'valor','')::numeric,0);
  v_data date := case when coalesce(p->>'dataEmissao','') ~ '^\d{4}-\d{2}-\d{2}$' then (p->>'dataEmissao')::date end;
  v_estoque_id text := nullif(p->>'estoqueNotaId','');
  v_usuario text := coalesce(nullif(p->>'usuario',''),'Estoque');
  v_pedido text := nullif(trim(coalesce(p->>'pedidoCompras','')),'');
  v_venc date := case when coalesce(p->>'vencimento','') ~ '^\d{4}-\d{2}-\d{2}$' then (p->>'vencimento')::date end;
  v_forma text := nullif(trim(coalesce(p->>'formaPagamento','')),'');
  v_frete text := case when p->>'frete' in ('sim','nao') then p->>'frete' end;
  v_prior text := case when p->>'prioridade' in ('baixa','media','alta') then p->>'prioridade' end;
  -- frete (CT-e à parte): só vale quando frete = 'sim'
  v_f_cte text := case when p->>'frete'='sim' then nullif(trim(coalesce(p->>'freteCte','')),'') end;
  v_f_transp text := case when p->>'frete'='sim' then nullif(trim(coalesce(p->>'freteTransportador','')),'') end;
  v_f_valor numeric := case when p->>'frete'='sim' and coalesce(p->>'freteValor','') ~ '^\d+(\.\d+)?$' then (p->>'freteValor')::numeric end;
  v_f_forma text := case when p->>'frete'='sim' then nullif(trim(coalesce(p->>'freteFormaPagamento','')),'') end;
  v_f_venc date := case when p->>'frete'='sim' and coalesce(p->>'freteVencimento','') ~ '^\d{4}-\d{2}-\d{2}$' then (p->>'freteVencimento')::date end;
  v_obra_id bigint;
  v_id bigint;
  v_cnpj_dig text := nullif(regexp_replace(coalesce(p->>'cnpjDestinatario',''),'\D','','g'),'');
begin
  if v_numero is null or v_forn is null then
    raise exception 'Informe ao menos o número da nota e o fornecedor.' using errcode='22023';
  end if;
  perform set_config('app.integracao','true',true);

  -- obra: id escolhido no estoque; senão pelo nome/código; senão pelo CNPJ do destinatário (se só uma obra ativa tiver)
  if coalesce(p->>'obraId','') ~ '^\d+$' then
    select o.id into v_obra_id from public.obras o where o.id = (p->>'obraId')::bigint;
  end if;
  if v_obra_id is null then
    select o.id into v_obra_id from public.obras o
     where lower(trim(o.nome)) = lower(trim(coalesce(p->>'obraNome','')))
        or (o.codigo is not null and trim(o.codigo) = substring(coalesce(p->>'obraNome','') from '^\s*(\d+)\s*-'))
     order by (lower(trim(o.nome)) = lower(trim(coalesce(p->>'obraNome','')))) desc, o.active desc, o.id limit 1;
  end if;
  if v_obra_id is null and v_cnpj_dig is not null then
    select min(o.id) into v_obra_id from public.obras o join public.obra_cnpjs c on c.obra_id=o.id
     where o.active and regexp_replace(c.cnpj,'\D','','g') = v_cnpj_dig
    having count(distinct o.id) = 1;
  end if;

  -- já existe? chave de acesso; vínculo anterior; ou duplicidade pela regra padrão
  select n.id into v_id from public.notas n
   where (v_chave is not null and regexp_replace(coalesce(n.chave_acesso,''),'\D','','g') = v_chave)
      or (v_estoque_id is not null and n.estoque_nota_id = v_estoque_id)
   order by n.id limit 1;
  if v_id is null then
    v_id := public.nota_duplicada_de(v_numero, v_forn, v_valor, v_chave, v_cnpj_emit);
  end if;

  if v_id is not null then
    -- só completa o que estiver vazio; não sobrescreve o que já foi preenchido no Controle
    update public.notas set
      chave_acesso = coalesce(chave_acesso, v_chave),
      cnpj_emitente = coalesce(cnpj_emitente, v_cnpj_emit),
      estoque_nota_id = coalesce(estoque_nota_id, v_estoque_id),
      destinatario = coalesce(destinatario, v_dest),
      cnpj_destinatario = coalesce(cnpj_destinatario, v_cnpj_dest),
      data_emissao = coalesce(data_emissao, v_data),
      obra_id = coalesce(obra_id, v_obra_id),
      pedido_compras = coalesce(nullif(trim(pedido_compras),''), v_pedido),
      vencimento = coalesce(vencimento, v_venc),
      forma_pagamento = coalesce(nullif(trim(forma_pagamento),''), v_forma),
      frete = case when v_frete = 'sim' then 'sim' else frete end,
      prioridade = case when v_prior = 'alta' then 'alta' else prioridade end,
      frete_cte = coalesce(nullif(trim(frete_cte),''), v_f_cte),
      frete_transportador = coalesce(nullif(trim(frete_transportador),''), v_f_transp),
      frete_valor = coalesce(frete_valor, v_f_valor),
      frete_forma_pagamento = coalesce(nullif(trim(frete_forma_pagamento),''), v_f_forma),
      frete_vencimento = coalesce(frete_vencimento, v_f_venc)
    where id = v_id;
    insert into public.audit_log (user_id,user_name,action,entity_type,entity_id,details)
    values (null, 'Estoque: '||v_usuario, 'nota_vinculada_estoque','nota_fiscal', v_id::text, p);
    return jsonb_build_object('resultado','existente','id',v_id,
      'obraVinculada', (select obra_id is not null from public.notas where id=v_id));
  end if;

  insert into public.notas (numero, fornecedor, valor, data_emissao, descricao, sede, status, created_by,
    obra_id, prioridade, origem, chave_acesso, cnpj_emitente, destinatario, cnpj_destinatario, estoque_nota_id,
    pedido_compras, vencimento, forma_pagamento, frete,
    frete_cte, frete_transportador, frete_valor, frete_forma_pagamento, frete_vencimento)
  values (v_numero, v_forn, v_valor, v_data,
    nullif(trim(coalesce(p->>'descricao','')),''), 'AMETA', 'entradas', null,
    v_obra_id, coalesce(v_prior,'media'), 'estoque', v_chave, v_cnpj_emit, v_dest, v_cnpj_dest, v_estoque_id,
    v_pedido, v_venc, v_forma, coalesce(v_frete,'nao'),
    v_f_cte, v_f_transp, v_f_valor, v_f_forma, v_f_venc)
  on conflict (lower(numero), lower(fornecedor)) do nothing
  returning id into v_id;

  if v_id is null then -- corrida: alguém inseriu a mesma nota ao mesmo tempo
    select id into v_id from public.notas where lower(numero)=lower(v_numero) and lower(fornecedor)=lower(v_forn);
    return jsonb_build_object('resultado','existente','id',v_id);
  end if;

  insert into public.movements (nota_id, from_status, to_status, moved_by, method, note)
  values (v_id, null, 'entradas', null, 'estoque', 'Recebida no sistema de Estoque por '||v_usuario);
  insert into public.audit_log (user_id,user_name,action,entity_type,entity_id,details)
  values (null, 'Estoque: '||v_usuario, 'nota_cadastrada_estoque','nota_fiscal', v_id::text, p);

  return jsonb_build_object('resultado','criada','id',v_id,'obraVinculada',v_obra_id is not null);
end;
$function$;

-- só o servidor (API) pode chamar
revoke execute on function public.api_receber_nota_estoque(jsonb) from public, anon, authenticated;
grant execute on function public.api_receber_nota_estoque(jsonb) to service_role;
