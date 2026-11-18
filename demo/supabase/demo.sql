-- =====================================================================
--  Barbearia do Maycão — DADOS DE DEMONSTRAÇÃO
--  ⚠️ RODE SÓ NO PROJETO DE TESTE (maycao-demo), NUNCA NO REAL!
--  Rode depois do schema.sql, mensalidade.sql e slot.sql.
--  Pode rodar de novo: apaga os dados de teste e cria tudo de novo.
--
--  Senhas (PIN) da demonstração:  Maycão 1234 · Rafa 1111 · Diego 2222
--  Cliente de teste no app: celular (47) 99999-0000, senha 1234
-- =====================================================================

do $$
declare
  d date; t int; abre int; fecha int; b text; s jsonb; cli text; st text; pay text; aid text; preco numeric;
  nomes text[] := array['Lucas Hoffmann','Bruno Schmitt','Felipe Krüger','Matheus Ramos','André Wolff','Gustavo Pereira','Thiago Becker',
                        'Rodrigo Souza','Leonardo Zimmermann','Vinícius Costa','Eduardo Müller','Caio Fernandes','Henrique Weber','Pedro Alves','João Pedro Lima','Marcelo Hering'];
  pays text[] := array['Pix','Pix','Dinheiro','Débito','Crédito'];
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  agora int := extract(hour from now() at time zone 'America/Sao_Paulo')::int*60 + extract(minute from now() at time zone 'America/Sao_Paulo')::int;
  svcs jsonb; h jsonb; i int; sid text;
begin
  -- equipe e configuração
  update public.config_publica set dados = dados || jsonb_build_object('barbers', '[
      {"id":"b1","name":"Maycão","slug":"maycao","color":"#A87622"},
      {"id":"b2","name":"Rafa","slug":"rafa","color":"#2F5E8C"},
      {"id":"b3","name":"Diego","slug":"diego","color":"#B03434"}]'::jsonb) where id = 1;
  update public.config_privada set dados = '{"comm":{"b1":0,"b2":45,"b3":45}}'::jsonb where id = 1;
  insert into public.pins (barber_id, hash, troca_obrigatoria) values
    ('b1', public._hash('1234'), false), ('b2', public._hash('1111'), false), ('b3', public._hash('2222'), false)
  on conflict (barber_id) do update set hash = excluded.hash, troca_obrigatoria = false, falhas = 0, bloqueado_ate = null;

  -- limpa dados antigos de teste
  delete from public.registros;
  delete from public.clientes_login;

  -- clientes
  for i in 1..array_length(nomes,1) loop
    insert into public.registros (colecao, id, dados) values ('clients', 'c'||i, jsonb_build_object(
      'id','c'||i,'name',nomes[i],'phone','(47) 9'||(8100+i*37)||'-'||lpad(((1000+i*413)%9000)::text,4,'0'),
      'birth', lpad((1+(i*7)%27)::text,2,'0')||'/'||lpad((1+(i*5)%12)::text,2,'0')));
  end loop;
  insert into public.registros (colecao, id, dados) values ('clients','cdemo','{"id":"cdemo","name":"Cliente Teste","phone":"(47) 99999-0000","birth":"—"}');
  insert into public.clientes_login (fone, cliente_id, hash) values ('47999990000','cdemo', extensions.crypt('1234', extensions.gen_salt('bf',8)));

  -- produtos
  insert into public.registros (colecao, id, dados) values
    ('products','p1','{"id":"p1","name":"Pomada modeladora matte","cat":"Finalizador","qty":9,"min":5,"cost":22,"price":45}'),
    ('products','p2','{"id":"p2","name":"Óleo para barba","cat":"Barba","qty":3,"min":4,"cost":18,"price":39}'),
    ('products','p3','{"id":"p3","name":"Shampoo anticaspa","cat":"Cabelo","qty":7,"min":3,"cost":16,"price":32}'),
    ('products','p4','{"id":"p4","name":"Balm pós-barba","cat":"Barba","qty":0,"min":3,"cost":20,"price":42}'),
    ('products','p5','{"id":"p5","name":"Refrigerante lata","cat":"Bar","qty":24,"min":12,"cost":2.8,"price":6}');

  select dados->'services' into svcs from public.config_publica where id = 1;

  -- agenda: 30 dias para trás e 7 para frente
  for d in select g::date from generate_series(hoje - 30, hoje + 7, '1 day') g loop
    select dados->'hours'->(extract(dow from d)::int::text) into h from public.config_publica where id = 1;
    continue when h is null or jsonb_typeof(h) <> 'array';
    abre := split_part(h->>0,':',1)::int*60 + split_part(h->>0,':',2)::int;
    fecha := split_part(h->>1,':',1)::int*60 + split_part(h->>1,':',2)::int;
    foreach b in array array['b1','b2','b3'] loop
      t := abre;
      while t + 30 <= fecha loop
        if random() < (case when d > hoje then 0.35 else 0.6 end) then
          s := svcs -> (floor(random()*least(5, jsonb_array_length(svcs))))::int;
          exit when t + (s->>'dur')::int > fecha;
          cli := 'c'||(1+floor(random()*16))::int;
          if d < hoje or (d = hoje and t + (s->>'dur')::int <= agora) then
            st := case when random() < 0.07 then 'faltou' else 'concluido' end;
          else st := case when random() < 0.5 then 'confirmado' else 'agendado' end; end if;
          aid := 'a'||substr(md5(random()::text),1,9);
          preco := (s->>'price')::numeric;
          pay := case when st = 'concluido' then pays[1+floor(random()*5)::int] else null end;
          insert into public.registros (colecao, id, dados) values ('appts', aid, jsonb_build_object(
            'id',aid,'date',d::text,'time',lpad((t/60)::text,2,'0')||':'||lpad((t%60)::text,2,'0'),'barberId',b,'serviceId',s->>'id',
            'clientId',cli,'status',st,'price',preco,'pay',pay,'origin','balcão'));
          if st = 'concluido' then
            insert into public.registros (colecao, id, dados) values ('tx', 't'||aid, jsonb_build_object(
              'id','t'||aid,'date',d::text,'type','in','cat','Serviço','desc',(s->>'name')||' · '||split_part(nomes[substr(cli,2)::int],' ',1),
              'value',preco,'method',pay,'barberId',b,'apptId',aid));
          end if;
          t := t + (s->>'dur')::int;
        else t := t + 30; end if;
      end loop;
    end loop;
    -- vendas de produto
    if d <= hoje and random() < 0.6 then
      insert into public.registros (colecao, id, dados) values ('tx','tp'||to_char(d,'YYYYMMDD'), jsonb_build_object(
        'id','tp'||to_char(d,'YYYYMMDD'),'date',d::text,'type','in','cat','Produto','desc','Pomada modeladora matte','value',45,'method','Pix'));
    end if;
  end loop;

  -- despesas do mês
  insert into public.registros (colecao, id, dados) values
    ('tx','e1',jsonb_build_object('id','e1','date',(hoje-25)::text,'type','out','cat','Aluguel','desc','Aluguel do ponto','value',2200,'method','Pix')),
    ('tx','e2',jsonb_build_object('id','e2','date',(hoje-20)::text,'type','out','cat','Contas','desc','Energia elétrica','value',386,'method','Pix')),
    ('tx','e3',jsonb_build_object('id','e3','date',(hoje-15)::text,'type','out','cat','Produtos','desc','Reposição de produtos','value',640,'method','Pix')),
    ('tx','e4',jsonb_build_object('id','e4','date',(hoje-5)::text,'type','out','cat','Insumos','desc','Lâminas e álcool','value',154,'method','Pix'));

  -- mensalidades: 3 em dia, 2 pendentes, 1 vencida
  for i in 1..6 loop
    sid := 'm'||i;
    insert into public.registros (colecao, id, dados) values ('subs', sid, jsonb_build_object(
      'id',sid,'clientId','c'||i,'planId',case when i%2=0 then 'p2' else 'p1' end,'planName',case when i%2=0 then 'Plano Corte + Barba' else 'Plano Corte' end,
      'price',case when i%2=0 then 200 else 120 end,'dias',30,'criado',to_char(now() - make_interval(days => 40-i),'YYYY-MM-DD"T"HH24:MI:SS'))
      || case
         when i <= 3 then jsonb_build_object('status','ativo','inicio',(hoje-10+i)::text,'fim',(hoje+20+i)::text,'pagoEm',(hoje-10+i)::text,'pay','Pix')
         when i <= 5 then jsonb_build_object('status','pendente')
         else jsonb_build_object('status','ativo','inicio',(hoje-35)::text,'fim',(hoje-5)::text,'pagoEm',(hoje-35)::text,'pay','Dinheiro') end);
    if i <= 3 then
      insert into public.registros (colecao, id, dados) values ('tx','tm'||i, jsonb_build_object('id','tm'||i,'date',(hoje-10+i)::text,'type','in',
        'cat','Mensalidade','desc','Mensalidade · '||split_part(nomes[i],' ',1),'value',case when i%2=0 then 200 else 120 end,'method','Pix','subId',sid));
    end if;
  end loop;
end $$;

select 'Pronto! Dados de demonstração criados.' as resultado;
