-- =====================================================================
--  Barbearia do Maycão — banco de dados (Supabase)
--  Cole TUDO isto no Supabase: SQL Editor → New query → Run.
--  Pode rodar de novo sem perder dados (só recria as funções e regras).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- Tabelas ----------

-- Informações que aparecem no site (preços, horários, barbeiros, contato).
-- Qualquer pessoa LÊ; só o Maycão ALTERA (pela função salvar_config, com o PIN dele).
create table if not exists public.config_publica (
  id int primary key default 1 check (id = 1),
  dados jsonb not null default '{}'::jsonb,
  atualizado timestamptz not null default now()
);

-- Informações internas (comissões). Só a equipe logada lê; só o Maycão altera.
create table if not exists public.config_privada (
  id int primary key default 1 check (id = 1),
  dados jsonb not null default '{}'::jsonb,
  atualizado timestamptz not null default now()
);

-- Agendamentos, clientes, financeiro, estoque e pagamentos de comissão.
-- colecao: 'appts' | 'clients' | 'tx' | 'products' | 'payouts'
create table if not exists public.registros (
  colecao text not null check (colecao in ('appts','clients','tx','products','payouts')),
  id text not null check (length(id) between 1 and 64),
  dados jsonb not null,
  atualizado timestamptz not null default now(),
  primary key (colecao, id)
);
create index if not exists registros_appts_data on public.registros ((dados->>'date')) where colecao = 'appts';
create index if not exists registros_clients_fone on public.registros ((regexp_replace(coalesce(dados->>'phone',''), '\D', '', 'g'))) where colecao = 'clients';

-- PIN de cada pessoa da equipe (guardado só como "hash", ninguém consegue ler).
create table if not exists public.pins (
  barber_id text primary key,
  hash text not null,
  troca_obrigatoria boolean not null default true,
  falhas int not null default 0,
  bloqueado_ate timestamptz
);

-- Contas de login dos aparelhos da barbearia (Supabase Auth).
create table if not exists public.contas (
  user_id uuid primary key,
  apelido text
);

-- ---------- Quem é da equipe ----------
create or replace function public.eh_equipe() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.contas where user_id = auth.uid());
$$;

-- ---------- Regras de acesso (RLS) ----------
alter table public.config_publica enable row level security;
alter table public.config_privada enable row level security;
alter table public.registros      enable row level security;
alter table public.pins           enable row level security;
alter table public.contas         enable row level security;

drop policy if exists "site le config" on public.config_publica;
create policy "site le config" on public.config_publica for select to anon, authenticated using (true);

drop policy if exists "equipe le config privada" on public.config_privada;
create policy "equipe le config privada" on public.config_privada for select to authenticated using (public.eh_equipe());

drop policy if exists "equipe le registros" on public.registros;
drop policy if exists "equipe cria registros" on public.registros;
drop policy if exists "equipe altera registros" on public.registros;
drop policy if exists "equipe apaga registros" on public.registros;
create policy "equipe le registros"     on public.registros for select to authenticated using (public.eh_equipe());
create policy "equipe cria registros"   on public.registros for insert to authenticated with check (public.eh_equipe());
create policy "equipe altera registros" on public.registros for update to authenticated using (public.eh_equipe()) with check (public.eh_equipe());
create policy "equipe apaga registros"  on public.registros for delete to authenticated using (public.eh_equipe());
-- pins e contas: sem regra = ninguém acessa direto (só pelas funções abaixo).

-- ---------- Funções auxiliares ----------
create or replace function public._pin_ok(p_barber text, p_pin text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare r public.pins;
begin
  select * into r from public.pins where barber_id = p_barber for update;
  if not found then return false; end if;
  if r.bloqueado_ate is not null and r.bloqueado_ate > now() then return false; end if;
  if r.hash = extensions.crypt(coalesce(p_pin,''), r.hash) then
    update public.pins set falhas = 0, bloqueado_ate = null where barber_id = p_barber;
    return true;
  end if;
  update public.pins
     set bloqueado_ate = case when falhas + 1 >= 8 then now() + interval '10 minutes' else null end,
         falhas = case when falhas + 1 >= 8 then 0 else falhas + 1 end
   where barber_id = p_barber;
  return false;
end $$;

create or replace function public._hash(p_pin text) returns text
language sql volatile set search_path = public, extensions as $$
  select extensions.crypt(p_pin, extensions.gen_salt('bf', 8));
$$;

-- ---------- Login por PIN (equipe) ----------
-- Retorna 'ok', 'trocar' (precisa criar senha nova), 'errado' ou 'bloqueado'.
create or replace function public.entrar_pin(p_barber text, p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare r public.pins; ok boolean;
begin
  if not public.eh_equipe() then raise exception 'sem permissão'; end if;
  select * into r from public.pins where barber_id = p_barber;
  if not found then return 'errado'; end if;
  if r.bloqueado_ate is not null and r.bloqueado_ate > now() then return 'bloqueado'; end if;
  ok := public._pin_ok(p_barber, p_pin);
  if not ok then
    select * into r from public.pins where barber_id = p_barber;
    return case when r.bloqueado_ate is not null and r.bloqueado_ate > now() then 'bloqueado' else 'errado' end;
  end if;
  return case when r.troca_obrigatoria then 'trocar' else 'ok' end;
end $$;

create or replace function public.trocar_pin(p_barber text, p_atual text, p_novo text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.eh_equipe() then raise exception 'sem permissão'; end if;
  if p_novo !~ '^\d{4,6}$' or p_novo = '123' then return false; end if;
  if not public._pin_ok(p_barber, p_atual) then return false; end if;
  update public.pins set hash = public._hash(p_novo), troca_obrigatoria = false where barber_id = p_barber;
  return true;
end $$;

-- Quem ainda precisa criar a senha (para mostrar no app).
create or replace function public.equipe_status() returns table(barber_id text, troca_obrigatoria boolean)
language sql stable security definer set search_path = public as $$
  select p.barber_id, p.troca_obrigatoria from public.pins p where public.eh_equipe();
$$;

-- ---------- Alterações do dono ----------
create or replace function public.salvar_config(p_pin_dono text, p_publica jsonb, p_privada jsonb) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare b jsonb;
begin
  if not public.eh_equipe() then raise exception 'sem permissão'; end if;
  if not public._pin_ok('b1', p_pin_dono) then return false; end if;
  if jsonb_typeof(p_publica->'barbers') <> 'array' or jsonb_typeof(p_publica->'services') <> 'array' then
    raise exception 'dados inválidos';
  end if;
  insert into public.config_publica (id, dados, atualizado) values (1, p_publica, now())
    on conflict (id) do update set dados = excluded.dados, atualizado = now();
  insert into public.config_privada (id, dados, atualizado) values (1, coalesce(p_privada, '{}'::jsonb), now())
    on conflict (id) do update set dados = excluded.dados, atualizado = now();
  -- barbeiro novo começa com a senha 123
  for b in select * from jsonb_array_elements(p_publica->'barbers') loop
    insert into public.pins (barber_id, hash, troca_obrigatoria)
      values (b->>'id', public._hash('123'), true)
      on conflict (barber_id) do nothing;
  end loop;
  return true;
end $$;

create or replace function public.resetar_pin(p_pin_dono text, p_barber text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.eh_equipe() then raise exception 'sem permissão'; end if;
  if not public._pin_ok('b1', p_pin_dono) then return false; end if;
  update public.pins set hash = public._hash('123'), troca_obrigatoria = true, falhas = 0, bloqueado_ate = null
   where barber_id = p_barber;
  return found;
end $$;

-- ---------- Agendamento pelo cliente (sem login) ----------
-- Horários ocupados a partir de uma data (sem nome nem telefone de ninguém).
create or replace function public.ocupados(p_desde date)
returns table(barber_id text, data text, hora text, dur int)
language sql stable security definer set search_path = public as $$
  select r.dados->>'barberId', r.dados->>'date', r.dados->>'time',
         coalesce((select (s->>'dur')::int from public.config_publica c, jsonb_array_elements(c.dados->'services') s
                    where c.id = 1 and s->>'id' = r.dados->>'serviceId' limit 1), 30)
    from public.registros r
   where r.colecao = 'appts'
     and r.dados->>'date' >= greatest(p_desde, (now() at time zone 'America/Sao_Paulo')::date)::text
     and r.dados->>'date' <= ((now() at time zone 'America/Sao_Paulo')::date + 62)::text
     and coalesce(r.dados->>'status','agendado') in ('agendado','confirmado','concluido');
$$;

create or replace function public.agendar(p_barber text, p_servico text, p_data date, p_hora text, p_nome text, p_fone text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  cfg jsonb; svc jsonb; h jsonb; v_dur int; ini int; abre int; fecha int;
  bid text; cand text; fone text; nome text; cli_id text; ap_id text; agora timestamp;
begin
  nome := btrim(coalesce(p_nome,''));
  fone := regexp_replace(coalesce(p_fone,''), '\D', '', 'g');
  if length(nome) < 2 or length(nome) > 80 then return jsonb_build_object('erro','nome'); end if;
  if length(fone) < 10 or length(fone) > 13 then return jsonb_build_object('erro','telefone'); end if;
  if p_hora !~ '^\d{2}:\d{2}$' then return jsonb_build_object('erro','horario'); end if;

  perform pg_advisory_xact_lock(hashtext('maycao-agendar'));

  select dados into cfg from public.config_publica where id = 1;
  if cfg is null then return jsonb_build_object('erro','config'); end if;
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
     where coalesce((b->>'off')::boolean, false) = false
       and (p_barber = 'any' or b->>'id' = p_barber)
  loop
    if not exists (
      select 1 from public.ocupados(p_data) o
       where o.barber_id = cand and o.data = p_data::text
         and (split_part(o.hora,':',1)::int*60 + split_part(o.hora,':',2)::int) < ini + v_dur
         and ini < (split_part(o.hora,':',1)::int*60 + split_part(o.hora,':',2)::int) + o.dur
    ) then bid := cand; exit; end if;
  end loop;
  if bid is null then return jsonb_build_object('erro','ocupado'); end if;

  select r.id into cli_id from public.registros r
   where r.colecao = 'clients' and regexp_replace(coalesce(r.dados->>'phone',''), '\D', '', 'g') in (fone, regexp_replace(fone, '^55', ''))
   limit 1;
  if cli_id is null then
    cli_id := 'c' || substr(md5(random()::text || clock_timestamp()::text), 1, 9);
    insert into public.registros (colecao, id, dados)
      values ('clients', cli_id, jsonb_build_object('id', cli_id, 'name', nome, 'phone', p_fone, 'birth', '—'));
  end if;

  ap_id := 'a' || substr(md5(random()::text || clock_timestamp()::text), 1, 9);
  insert into public.registros (colecao, id, dados) values ('appts', ap_id, jsonb_build_object(
    'id', ap_id, 'date', p_data::text, 'time', p_hora, 'barberId', bid, 'serviceId', p_servico,
    'clientId', cli_id, 'status', 'agendado', 'price', (svc->>'price')::numeric, 'pay', null, 'origin', 'online'));

  return jsonb_build_object('id', ap_id, 'barberId', bid);
end $$;

-- ---------- Permissões das funções ----------
revoke all on function public._pin_ok(text, text) from public, anon, authenticated;
revoke all on function public._hash(text) from public, anon, authenticated;
revoke all on function public.entrar_pin(text, text) from public, anon;
revoke all on function public.trocar_pin(text, text, text) from public, anon;
revoke all on function public.equipe_status() from public, anon;
revoke all on function public.salvar_config(text, jsonb, jsonb) from public, anon;
revoke all on function public.resetar_pin(text, text) from public, anon;
grant execute on function public.entrar_pin(text, text) to authenticated;
grant execute on function public.trocar_pin(text, text, text) to authenticated;
grant execute on function public.equipe_status() to authenticated;
grant execute on function public.salvar_config(text, jsonb, jsonb) to authenticated;
grant execute on function public.resetar_pin(text, text) to authenticated;
grant execute on function public.ocupados(date) to anon, authenticated;
grant execute on function public.agendar(text, text, date, text, text, text) to anon, authenticated;
grant execute on function public.eh_equipe() to anon, authenticated;

-- ---------- Acesso das tabelas pela internet (projetos novos do Supabase exigem isso) ----------
grant usage on schema public to anon, authenticated;
grant select on public.config_publica to anon, authenticated;
grant select on public.config_privada to authenticated;
grant select, insert, update, delete on public.registros to authenticated;
revoke all on public.pins, public.contas from anon, authenticated;

-- ---------- Atualização ao vivo (app e site) ----------
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.registros;      exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.config_publica; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.config_privada; exception when duplicate_object then null; end;
  end if;
end $$;

-- ---------- Dados iniciais (só na primeira vez) ----------
insert into public.config_publica (id, dados) values (1, '{
  "barbers": [{"id":"b1","name":"Maycão","slug":"maycao","color":"#A87622"}],
  "services": [
    {"id":"s1","name":"Corte","price":60,"dur":30},
    {"id":"s2","name":"Barba","price":35,"dur":30},
    {"id":"s3","name":"Corte + Barba","price":70,"dur":60},
    {"id":"s4","name":"Pezinho","price":15,"dur":30},
    {"id":"s5","name":"Sobrancelha","price":20,"dur":30},
    {"id":"s6","name":"Pigmentação","price":60,"dur":60},
    {"id":"s7","name":"Corte infantil","price":35,"dur":30}
  ],
  "hours": {"0":null,"1":null,"2":["09:00","20:00"],"3":["09:00","20:00"],"4":["09:00","20:00"],"5":["09:00","20:00"],"6":["09:00","16:00"]},
  "info": {
    "insta":"https://instagram.com/barbeariadomaycao",
    "whats":"https://wa.me/5547988229178",
    "end":"R. Philipp Bauler, 1955 - Testo Salto, Blumenau - SC",
    "slogan":"Degradê na régua, freestyle, barba alinhada e aquele papo bom.",
    "sobre":"Aberta desde 2023 e com mais de 5 mil clientes atendidos, na Barbearia do Maycão cada corte é feito com calma e capricho — do degradê ao freestyle, da barba ao corte da criançada. Ambiente tranquilo no Testo Salto, atendimento com hora marcada e aquele cuidado de quem ama o que faz.",
    "nota":"5,0 ★","clientes":"5 mil+","desde":"2023"
  }
}'::jsonb) on conflict (id) do nothing;

insert into public.config_privada (id, dados) values (1, '{"comm":{"b1":0}}'::jsonb) on conflict (id) do nothing;

-- PIN inicial do Maycão: 123 (o app pede para ele criar o dele no primeiro acesso)
insert into public.pins (barber_id, hash, troca_obrigatoria) values ('b1', public._hash('123'), true)
  on conflict (barber_id) do nothing;
