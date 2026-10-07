-- Revisão de segurança (06/10/2026)

-- 1) Arquivos do bucket "anexos" seguem a visibilidade das notas.
--    Antes: qualquer usuário logado (até inativo) listava, baixava e apagava qualquer arquivo.
--    As regras duplicadas (anexos_* e anexos_storage_*) recebem a mesma condição.
alter policy anexos_select on storage.objects to authenticated
using (bucket_id = 'anexos' and public.current_is_active() and (
    public."current_role"() = 'admin' or owner_id = auth.uid()::text
    or exists (select 1 from public.anexos a where a.storage_path = storage.objects.name)));
alter policy anexos_storage_select on storage.objects to authenticated
using (bucket_id = 'anexos' and public.current_is_active() and (
    public."current_role"() = 'admin' or owner_id = auth.uid()::text
    or exists (select 1 from public.anexos a where a.storage_path = storage.objects.name)));
alter policy anexos_insert on storage.objects to authenticated
with check (bucket_id = 'anexos' and public.current_is_active()
  and exists (select 1 from public.notas n where 'nota_' || n.id::text = split_part(storage.objects.name, '/', 1)));
alter policy anexos_storage_insert on storage.objects to authenticated
with check (bucket_id = 'anexos' and public.current_is_active()
  and exists (select 1 from public.notas n where 'nota_' || n.id::text = split_part(storage.objects.name, '/', 1)));
alter policy anexos_delete on storage.objects to authenticated
using (bucket_id = 'anexos' and public.current_is_active()
  and (public."current_role"() = 'admin' or owner_id = auth.uid()::text));
alter policy anexos_storage_delete on storage.objects to authenticated
using (bucket_id = 'anexos' and public.current_is_active()
  and (public."current_role"() = 'admin' or owner_id = auth.uid()::text));

-- 2) Nenhuma função do schema public pode ser chamada sem login (anon).
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.prokind='f' loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
  end loop;
end $$;
revoke execute on function public.api_receber_nota_estoque(jsonb) from authenticated;
alter default privileges in schema public revoke execute on functions from public, anon;

-- 3) search_path fixo nas funções que não tinham
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.prokind='f'
             and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%') loop
    execute format('alter function %s set search_path = public, pg_temp', f.sig);
  end loop;
end $$;

-- 4) Auditoria: cada usuário só grava registro em seu próprio nome
alter policy audit_log_insert on public.audit_log to authenticated
with check (public.current_is_active() and user_id = auth.uid()
  and user_name is not distinct from public.profile_name(auth.uid()));
