-- ✅ Validar o lançamento do card de CT-e encerrado pelo vínculo
-- (aplicar depois de 20261023_cte_encerrar_card_rpc_call.sql).
--
-- A exceção em notas_concluido_exige_titulo reconhecia o card do CT-e encerrado pelo
-- vínculo só pela observação da validação ("CT-e vinculado à(s) NF …"). O card encerrado
-- pela carga da 20261023, rodada no SQL Editor, ficou sem quem validou e aparece como
-- "Aguardando validação do lançamento"; ao validar, rpc_validar_lancamento troca essa
-- observação pela do usuário e a restrição barrava ("violates check constraint
-- notas_concluido_exige_titulo"). A exceção passa a aceitar também a marca que
-- cte_encerrar_card deixa nas observações do card (descricao).

do $migracao$
declare
  v_def text;
  v_antes text := '(COALESCE(lancamento_validado_obs, ''''::text) ~~ ''CT-e vinculado à(s) NF %''::text)';
  v_depois text;
begin
  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c
   where c.conrelid = 'public.notas'::regclass and c.conname = 'notas_concluido_exige_titulo';
  if v_def is null or v_def like '%descricao%' then
    return;
  end if;
  if position(v_antes in v_def) = 0 then
    raise exception 'Definição inesperada de notas_concluido_exige_titulo: %', v_def;
  end if;
  v_depois := replace(v_def, v_antes,
    '(' || v_antes || ' OR (COALESCE(descricao, ''''::text) ~~ ''%CT-e vinculado à(s) NF %''::text))');
  v_depois := regexp_replace(regexp_replace(v_depois, '^CHECK\s*', ''), '\s*NOT VALID\s*$', '');
  alter table public.notas drop constraint notas_concluido_exige_titulo;
  execute 'alter table public.notas add constraint notas_concluido_exige_titulo check ' || v_depois;
end
$migracao$;
