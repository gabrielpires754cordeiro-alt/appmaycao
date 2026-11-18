-- =====================================================================
--  Barbearia do Maycão — MENSALIDADES (planos) + conta do cliente
--  Cole TUDO isto no Supabase: SQL Editor → New query → Run.
--  Pode rodar de novo sem perder dados.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- mensalidades ficam junto dos outros registros (colecao 'subs')
alter table public.registros drop constraint if exists registros_colecao_check;
alter table public.registros add constraint registros_colecao_check
  check (colecao in ('appts','clients','tx','products','payouts','subs'));
create index if not exists registros_subs_cliente on public.registros ((dados->>'clientId')) where colecao = 'subs';
create index if not exists registros_appts_cliente on public.registros ((dados->>'clientId')) where colecao = 'appts';

-- login do cliente (celular + senha). Ninguém lê direto: só pelas funções abaixo.
create table if not exists public.clientes_login (
  fone text primary key,
  cliente_id text not null,
  hash text not null,
  falhas int not null default 0,
  bloqueado_ate timestamptz,
  criado timestamptz not null default now()
);
create table if not exists public.sessoes_cliente (
  token_hash text primary key,
  fone text not null references public.clientes_login(fone) on delete cascade,
  expira timestamptz not null
);
alter table public.clientes_login  enable row level security;
alter table public.sessoes_cliente enable row level security;
revoke all on public.clientes_login, public.sessoes_cliente from anon, authenticated;

-- ---------- auxiliares ----------
create or replace function public._fone(p text) returns text
language sql immutable as $$
  select case when length(d) >= 12 and d like '55%' then substr(d, 3) else d end
    from (select regexp_replace(coalesce(p,''), '\D', '', 'g') d) x;
$$;

create or replace function public._novo_id(p text) returns text
language sql volatile as $$ select p || substr(md5(random()::text || clock_timestamp()::text), 1, 9) $$;

create or replace function public._hoje() returns date
language sql stable as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

create or replace function public._cliente_por_fone(p_fone text) returns text
language sql stable security definer set search_path = public as $$
  select r.id from public.registros r
   where r.colecao = 'clients' and public._fone(r.dados->>'phone') = public._fone(p_fone)
   order by r.atualizado limit 1;
$$;

create or replace function public._sessao(p_token text) returns public.clientes_login
language plpgsql stable security definer set search_path = public, extensions as $$
declare r public.clientes_login;
begin
  select l.* into r from public.sessoes_cliente s join public.clientes_login l on l.fone = s.fone
   where s.token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex') and s.expira > now();
  return r;
end $$;

create or replace function public._nova_sessao(p_fone text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare t text;
begin
  t := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.sessoes_cliente values (encode(extensions.digest(t, 'sha256'), 'hex'), p_fone, now() + interval '180 days');
  delete from public.sessoes_cliente where expira < now();
  return t;
end $$;

-- mensalidade atual do cliente (a mais recente que não foi cancelada)
create or replace function public._sub_atual(p_cli text) returns jsonb
language sql stable security definer set search_path = public as $$
  select r.dados from public.registros r
   where r.colecao = 'subs' and r.dados->>'clientId' = p_cli and coalesce(r.dados->>'status','') <> 'cancelado'
   order by coalesce(r.dados->>'criado','') desc, r.atualizado desc limit 1;
$$;

create or replace function public._plano(p_id text) returns jsonb
language sql stable security definer set search_path = public as $$
  select p from public.config_publica c, jsonb_array_elements(coalesce(c.dados->'plans','[]'::jsonb)) p
   where c.id = 1 and p->>'id' = p_id limit 1;
$$;

-- situação: 'ativo' | 'vencido' | 'pendente' | null
create or replace function public._situacao(s jsonb) returns text
language sql stable as $$
  select case
    when s is null then null
    when s->>'status' = 'pendente' then 'pendente'
    when s->>'status' = 'ativo' and (s->>'fim')::date > public._hoje() then 'ativo'
    when s->>'status' = 'ativo' then 'vencido'
    else null end;
$$;

create or replace function public._usados(p_sub text) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.registros r
   where r.colecao = 'appts' and r.dados->>'subId' = p_sub and coalesce(r.dados->>'status','') not in ('cancelado');
$$;

-- reserva um horário (valida expediente, data e conflito) — usada pelo cliente logado
create or replace function public._reservar(p_barber text, p_servico text, p_data date, p_hora text, p_cli text, p_preco numeric, p_extra jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  cfg jsonb; svc jsonb; h jsonb; v_dur int; ini int; abre int; fecha int;
  bid text; cand text; ap_id text; agora timestamp;
begin
  if p_hora !~ '^\d{2}:\d{2}$' then return jsonb_build_object('erro','horario'); end if;
  select dados into cfg from public.config_publica where id = 1;
  select s into svc from jsonb_array_elements(cfg->'services') s where s->>'id' = p_servico limit 1;
  if svc is null then return jsonb_build_object('erro','servico'); end if;
  v_dur := coalesce((svc->>'dur')::int, 30);
  h := cfg->'hours'->(extract(dow from p_data)::int::text);
  if h is null or jsonb_typeof(h) <> 'array' then return jsonb_build_object('erro','fechado'); end if;
  abre  := split_part(h->>0, ':', 1)::int * 60 + split_part(h->>0, ':', 2)::int;
  fecha := split_part(h->>1, ':', 1)::int * 60 + split_part(h->>1, ':', 2)::int;
  ini   := split_part(p_hora, ':', 1)::int * 60 + split_part(p_hora, ':', 2)::int;
  if ini < abre or ini + v_dur > fecha then return jsonb_build_object('erro','fora_do_horario'); end if;
  agora := now() at time zone 'America/Sao_Paulo';
  if p_data < agora::date or p_data > agora::date + 62
     or (p_data = agora::date and ini <= extract(hour from agora)::int * 60 + extract(minute from agora)::int) then
    return jsonb_build_object('erro','data');
  end if;
  for cand in
    select b->>'id' from jsonb_array_elements(cfg->'barbers') b
     where coalesce((b->>'off')::boolean, false) = false and (p_barber = 'any' or b->>'id' = p_barber)
  loop
    if not exists (
      select 1 from public.ocupados(p_data) o
       where o.barber_id = cand and o.data = p_data::text
         and (split_part(o.hora,':',1)::int*60 + split_part(o.hora,':',2)::int) < ini + v_dur
         and ini < (split_part(o.hora,':',1)::int*60 + split_part(o.hora,':',2)::int) + o.dur
    ) then bid := cand; exit; end if;
  end loop;
  if bid is null then return jsonb_build_object('erro','ocupado'); end if;
  ap_id := public._novo_id('a');
  insert into public.registros (colecao, id, dados) values ('appts', ap_id, jsonb_build_object(
    'id', ap_id, 'date', p_data::text, 'time', p_hora, 'barberId', bid, 'serviceId', p_servico,
    'clientId', p_cli, 'status', 'agendado', 'price', p_preco, 'pay', null, 'origin', 'online') || coalesce(p_extra, '{}'::jsonb));
  return jsonb_build_object('id', ap_id, 'barberId', bid);
end $$;

-- ---------- conta do cliente ----------
create or replace function public.cliente_cadastrar(p_nome text, p_fone text, p_senha text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare f text; nome text; cli text;
begin
  f := public._fone(p_fone); nome := btrim(coalesce(p_nome,''));
  if length(nome) < 2 or length(nome) > 80 then return jsonb_build_object('erro','nome'); end if;
  if length(f) < 10 or length(f) > 11 then return jsonb_build_object('erro','telefone'); end if;
  if length(coalesce(p_senha,'')) < 4 or length(p_senha) > 40 then return jsonb_build_object('erro','senha'); end if;
  perform pg_advisory_xact_lock(hashtext('maycao-cliente-' || f));
  if exists (select 1 from public.clientes_login where fone = f) then return jsonb_build_object('erro','ja_existe'); end if;
  cli := public._cliente_por_fone(f);
  if cli is null then
    cli := public._novo_id('c');
    insert into public.registros (colecao, id, dados)
      values ('clients', cli, jsonb_build_object('id', cli, 'name', nome, 'phone', p_fone, 'birth', '—'));
  end if;
  insert into public.clientes_login (fone, cliente_id, hash) values (f, cli, extensions.crypt(p_senha, extensions.gen_salt('bf', 8)));
  return jsonb_build_object('token', public._nova_sessao(f));
end $$;

create or replace function public.cliente_entrar(p_fone text, p_senha text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare f text; r public.clientes_login;
begin
  f := public._fone(p_fone);
  select * into r from public.clientes_login where fone = f for update;
  if not found then return jsonb_build_object('erro','nao_existe'); end if;
  if r.bloqueado_ate is not null and r.bloqueado_ate > now() then return jsonb_build_object('erro','bloqueado'); end if;
  if r.hash <> extensions.crypt(coalesce(p_senha,''), r.hash) then
    update public.clientes_login
       set bloqueado_ate = case when falhas + 1 >= 8 then now() + interval '10 minutes' else null end,
           falhas = case when falhas + 1 >= 8 then 0 else falhas + 1 end
     where fone = f;
    return jsonb_build_object('erro','senha');
  end if;
  update public.clientes_login set falhas = 0, bloqueado_ate = null where fone = f;
  return jsonb_build_object('token', public._nova_sessao(f));
end $$;

create or replace function public.cliente_sair(p_token text) returns boolean
language sql security definer set search_path = public, extensions as $$
  delete from public.sessoes_cliente where token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex') returning true;
$$;

create or replace function public.cliente_painel(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l public.clientes_login; cli jsonb; s jsonb; plano jsonb; sit text;
begin
  l := public._sessao(p_token);
  if l.fone is null then return jsonb_build_object('erro','sessao'); end if;
  select dados into cli from public.registros where colecao = 'clients' and id = l.cliente_id;
  s := public._sub_atual(l.cliente_id);
  sit := public._situacao(s);
  if s is not null then plano := public._plano(s->>'planId'); end if;
  return jsonb_build_object(
    'nome', coalesce(cli->>'name', ''), 'fone', coalesce(cli->>'phone', l.fone),
    'assinatura', case when s is null then null else s || jsonb_build_object(
        'situacao', sit, 'usados', public._usados(s->>'id'),
        'plano', coalesce(plano, jsonb_build_object('id', s->>'planId', 'name', coalesce(s->>'planName','Plano'), 'price', s->'price')))
      end,
    'agendamentos', coalesce((select jsonb_agg(r.dados order by r.dados->>'date', r.dados->>'time') from public.registros r
        where r.colecao = 'appts' and r.dados->>'clientId' = l.cliente_id and r.dados->>'date' >= public._hoje()::text
          and coalesce(r.dados->>'status','') in ('agendado','confirmado')), '[]'::jsonb),
    'pagamentos', coalesce((select jsonb_agg(jsonb_build_object('plano', r.dados->>'planName', 'valor', r.dados->'price',
          'pagoEm', r.dados->>'pagoEm', 'inicio', r.dados->>'inicio', 'fim', r.dados->>'fim') order by r.dados->>'pagoEm' desc)
        from public.registros r where r.colecao = 'subs' and r.dados->>'clientId' = l.cliente_id and r.dados->>'pagoEm' is not null), '[]'::jsonb)
  );
end $$;

create or replace function public.cliente_escolher_plano(p_token text, p_plano text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.clientes_login; s jsonb; p jsonb; sid text;
begin
  l := public._sessao(p_token);
  if l.fone is null then return jsonb_build_object('erro','sessao'); end if;
  p := public._plano(p_plano);
  if p is null or coalesce((p->>'off')::boolean, false) then return jsonb_build_object('erro','plano'); end if;
  perform pg_advisory_xact_lock(hashtext('maycao-sub-' || l.cliente_id));
  s := public._sub_atual(l.cliente_id);
  if public._situacao(s) = 'ativo' then return jsonb_build_object('erro','ativo'); end if;
  if public._situacao(s) = 'pendente' then
    if public._usados(s->>'id') > 0 and s->>'planId' <> p_plano then return jsonb_build_object('erro','pendente_em_uso'); end if;
    update public.registros set dados = dados || jsonb_build_object('planId', p->>'id', 'planName', p->>'name', 'price', p->'price', 'dias', coalesce(p->'dias','30'::jsonb)),
           atualizado = now()
     where colecao = 'subs' and id = s->>'id';
    return jsonb_build_object('id', s->>'id');
  end if;
  sid := public._novo_id('m');
  insert into public.registros (colecao, id, dados) values ('subs', sid, jsonb_build_object(
    'id', sid, 'clientId', l.cliente_id, 'planId', p->>'id', 'planName', p->>'name', 'price', p->'price',
    'dias', coalesce(p->'dias','30'::jsonb), 'status', 'pendente', 'criado', to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD"T"HH24:MI:SS')));
  return jsonb_build_object('id', sid);
end $$;

-- agendar com a conta: usa o plano quando dá; senão, preço normal
create or replace function public.cliente_agendar(p_token text, p_barber text, p_servico text, p_data date, p_hora text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.clientes_login; s jsonb; p jsonb; sit text; usados int; total int; intervalo int; res jsonb; preco numeric; extra jsonb := '{}'::jsonb;
begin
  l := public._sessao(p_token);
  if l.fone is null then return jsonb_build_object('erro','sessao'); end if;
  perform pg_advisory_xact_lock(hashtext('maycao-agendar'));
  select (s2->>'price')::numeric into preco from public.config_publica c, jsonb_array_elements(c.dados->'services') s2
   where c.id = 1 and s2->>'id' = p_servico limit 1;
  if preco is null then return jsonb_build_object('erro','servico'); end if;

  s := public._sub_atual(l.cliente_id);
  sit := public._situacao(s);
  if s is not null then p := public._plano(s->>'planId'); end if;

  if p is not null and coalesce(p->'servicos', '[]'::jsonb) ? p_servico then
    -- plano vencido: abre uma renovação pendente do mesmo plano
    if sit = 'vencido' then
      s := jsonb_build_object('id', public._novo_id('m'), 'clientId', l.cliente_id, 'planId', p->>'id', 'planName', p->>'name',
             'price', p->'price', 'dias', coalesce(p->'dias','30'::jsonb), 'status', 'pendente',
             'criado', to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD"T"HH24:MI:SS'), 'renovacao', true);
      insert into public.registros (colecao, id, dados) values ('subs', s->>'id', s);
      sit := 'pendente';
    end if;
    total := coalesce((p->>'cortes')::int, 4);
    intervalo := coalesce((p->>'intervalo')::int, 7);
    usados := public._usados(s->>'id');
    if sit = 'ativo' and p_data >= (s->>'fim')::date then
      return jsonb_build_object('erro','depois_do_vencimento', 'fim', s->>'fim');
    end if;
    if usados >= total then return jsonb_build_object('erro','limite', 'total', total); end if;
    if jsonb_typeof(p->'diasSemana') = 'array' and jsonb_array_length(p->'diasSemana') > 0
       and not (p->'diasSemana' @> to_jsonb(extract(dow from p_data)::int)) then
      return jsonb_build_object('erro','dia_plano', 'dias', p->'diasSemana');
    end if;
    if intervalo > 0 and exists (
      select 1 from public.registros r where r.colecao = 'appts' and r.dados->>'subId' = s->>'id'
         and coalesce(r.dados->>'status','') <> 'cancelado'
         and abs((r.dados->>'date')::date - p_data) < intervalo) then
      return jsonb_build_object('erro','intervalo', 'dias', intervalo);
    end if;
    extra := jsonb_build_object('subId', s->>'id', 'plano', true);
    preco := 0;
  end if;

  res := public._reservar(p_barber, p_servico, p_data, p_hora, l.cliente_id, preco, extra);
  if res ? 'erro' then
    -- não deixa renovação vazia para trás
    if (s->>'renovacao')::boolean is true and public._usados(s->>'id') = 0 then
      delete from public.registros where colecao = 'subs' and id = s->>'id';
    end if;
    return res;
  end if;
  return res || jsonb_build_object('plano', extra ? 'subId', 'pendente', sit = 'pendente' and extra ? 'subId', 'preco', preco,
                                   'valorPlano', case when sit = 'pendente' and extra ? 'subId' then s->'price' else null end);
end $$;

create or replace function public.cliente_cancelar(p_token text, p_appt text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.clientes_login;
begin
  l := public._sessao(p_token);
  if l.fone is null then return jsonb_build_object('erro','sessao'); end if;
  update public.registros set dados = dados || '{"status":"cancelado"}'::jsonb, atualizado = now()
   where colecao = 'appts' and id = p_appt and dados->>'clientId' = l.cliente_id
     and dados->>'date' >= public._hoje()::text and coalesce(dados->>'status','') in ('agendado','confirmado');
  if not found then return jsonb_build_object('erro','nao_pode'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- equipe: apaga o login do cliente para ele criar senha nova
create or replace function public.cliente_resetar_senha(p_fone text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_equipe() then raise exception 'sem permissão'; end if;
  delete from public.clientes_login where fone = public._fone(p_fone);
  return found;
end $$;

-- equipe: quais clientes têm conta
create or replace function public.clientes_com_conta() returns table(cliente_id text)
language sql stable security definer set search_path = public as $$
  select l.cliente_id from public.clientes_login l where public.eh_equipe();
$$;

-- ---------- permissões ----------
revoke all on function public._fone(text) from public, anon, authenticated;
revoke all on function public._novo_id(text) from public, anon, authenticated;
revoke all on function public._cliente_por_fone(text) from public, anon, authenticated;
revoke all on function public._sessao(text) from public, anon, authenticated;
revoke all on function public._nova_sessao(text) from public, anon, authenticated;
revoke all on function public._sub_atual(text) from public, anon, authenticated;
revoke all on function public._plano(text) from public, anon, authenticated;
revoke all on function public._usados(text) from public, anon, authenticated;
revoke all on function public._reservar(text, text, date, text, text, numeric, jsonb) from public, anon, authenticated;
revoke all on function public.cliente_resetar_senha(text) from public, anon;
revoke all on function public.clientes_com_conta() from public, anon;
grant execute on function public._hoje() to anon, authenticated;
grant execute on function public._situacao(jsonb) to anon, authenticated;
grant execute on function public.cliente_cadastrar(text, text, text) to anon, authenticated;
grant execute on function public.cliente_entrar(text, text) to anon, authenticated;
grant execute on function public.cliente_sair(text) to anon, authenticated;
grant execute on function public.cliente_painel(text) to anon, authenticated;
grant execute on function public.cliente_escolher_plano(text, text) to anon, authenticated;
grant execute on function public.cliente_agendar(text, text, text, date, text) to anon, authenticated;
grant execute on function public.cliente_cancelar(text, text) to anon, authenticated;
grant execute on function public.cliente_resetar_senha(text) to authenticated;
grant execute on function public.clientes_com_conta() to authenticated;

-- planos de exemplo (só se ainda não existir nenhum) — o Maycão edita no app
update public.config_publica
   set dados = dados || jsonb_build_object('plans', '[
     {"id":"p1","name":"Plano Corte","price":120,"cortes":4,"intervalo":7,"dias":30,"servicos":["s1"]},
     {"id":"p2","name":"Plano Corte + Barba","price":200,"cortes":4,"intervalo":7,"dias":30,"servicos":["s1","s2","s3"]}
   ]'::jsonb)
 where id = 1 and not (dados ? 'plans');
