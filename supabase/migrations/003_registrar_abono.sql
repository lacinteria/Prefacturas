-- Registro transaccional de abonos: actualiza cotización, abono y cliente en una sola operación.
create or replace function public.registrar_abono_cotizacion(
  p_id_documento text,
  p_valor numeric,
  p_forma_pago text,
  p_usuario text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_doc public.remisiones%rowtype;
  v_rol text := public.mi_rol();
  v_nombre text := public.mi_nombre();
  v_area text := public.mi_area();
  v_abonado numeric(14,2);
  v_saldo numeric(14,2);
  v_pagada boolean;
  v_numero integer;
  v_fecha date := (now() at time zone 'America/Bogota')::date;
  v_fecha_hora timestamptz := now();
  v_abono_id uuid := gen_random_uuid();
  v_abono jsonb;
begin
  if coalesce(v_rol,'') not in ('admin','asesor','caja') then
    raise exception 'No autorizado para registrar abonos';
  end if;
  if p_valor is null or p_valor <= 0 then
    raise exception 'El valor del abono debe ser mayor que cero';
  end if;
  if p_forma_pago not in ('EFECTIVO','TRANSFERENCIA','005 TRANSFERENCIA','SAS TRANSFERENCIA') then
    raise exception 'Forma de pago no válida';
  end if;

  select * into v_doc from public.remisiones where id_documento = p_id_documento for update;
  if not found then raise exception 'La cotización ya no existe'; end if;
  if v_doc.tipo_doc <> 'Cotización' then raise exception 'El documento no es una cotización'; end if;
  if v_rol = 'asesor' and v_doc.asesor <> v_nombre then raise exception 'No autorizado para esta cotización'; end if;
  if v_rol = 'caja' and v_doc.area <> v_area then raise exception 'No autorizado para esta cotización'; end if;
  if v_doc.estado not in ('Pendiente','Abonada') then raise exception 'La cotización ya no está pendiente de pago'; end if;

  v_abonado := coalesce((v_doc.datos->>'totalAbonado')::numeric,0) + p_valor;
  v_saldo := coalesce(v_doc.total,0) - v_abonado;
  if p_valor > coalesce(v_doc.total,0) - coalesce((v_doc.datos->>'totalAbonado')::numeric,0) + 0.001 then
    raise exception 'El abono supera el saldo pendiente';
  end if;
  v_pagada := v_abonado >= coalesce(v_doc.total,0) - 0.001;
  v_numero := coalesce((v_doc.datos->>'numeroAbonos')::integer,0) + 1;

  perform pg_catalog.set_config('app.registrar_abono','on',true);

  update public.remisiones
  set estado = case when v_pagada then 'Pagada' else 'Abonada' end,
      forma_pago = p_forma_pago,
      updated_at = v_fecha_hora,
      datos = datos || jsonb_build_object(
        'totalAbonado',v_abonado,
        'numeroAbonos',v_numero,
        'estado',case when v_pagada then 'Pagada' else 'Abonada' end,
        'formaPago',p_forma_pago,
        'fechaUltimoAbono',v_fecha,
        'fechaActualizacion',v_fecha_hora
      )
  where id_documento = p_id_documento;

  v_abono := jsonb_build_object(
    'id',v_abono_id,'idDocumento',p_id_documento,'tipoDoc','Cotización',
    'docCliente',coalesce(v_doc.documento_cliente,''),'nomCliente',coalesce(v_doc.datos->>'nomCliente',''),
    'telCliente',coalesce(v_doc.datos->>'telCliente',''),'asesor',v_doc.asesor,'area',v_doc.area,
    'fecha',v_fecha,'fechaHora',v_fecha_hora,'valor',p_valor,'formaPago',p_forma_pago,
    'estado',case when v_pagada then 'Pagada' else 'Abonada' end,'numeroAbono',v_numero,
    'totalMeta',p_valor,'saldo',greatest(v_saldo,0),'registradoPor',v_nombre
  );
  insert into public.abonos_cotizaciones (id,id_documento,fecha,asesor,area,forma_pago,valor,datos)
  values (v_abono_id,p_id_documento,v_fecha,v_doc.asesor,v_doc.area,p_forma_pago,p_valor,v_abono);

  if v_pagada and coalesce(v_doc.documento_cliente,'') <> '' then
    insert into public.clientes (documento,nombre,telefono,total_compras,total_invertido,fecha_registro,ultima_actualizacion,datos)
    values (
      v_doc.documento_cliente,
      coalesce(v_doc.datos->>'nomCliente',''),
      coalesce(v_doc.datos->>'telCliente',''),
      1,coalesce(v_doc.total,0),v_fecha_hora,v_fecha_hora,
      jsonb_build_object('docCliente',v_doc.documento_cliente,'nomCliente',coalesce(v_doc.datos->>'nomCliente',''),
        'telCliente',coalesce(v_doc.datos->>'telCliente',''),'totalCompras',1,'totalInvertido',coalesce(v_doc.total,0),
        'primeraCompra',v_fecha,'ultimaCompra',v_fecha,'fechaRegistro',v_fecha_hora,'ultimaActualizacion',v_fecha_hora)
    )
    on conflict (documento) do update set
      nombre = excluded.nombre,
      telefono = excluded.telefono,
      total_compras = public.clientes.total_compras + 1,
      total_invertido = public.clientes.total_invertido + excluded.total_invertido,
      ultima_actualizacion = v_fecha_hora,
      datos = public.clientes.datos || excluded.datos || jsonb_build_object(
        'totalCompras',public.clientes.total_compras + 1,
        'totalInvertido',public.clientes.total_invertido + excluded.total_invertido,
        'ultimaCompra',v_fecha,'ultimaActualizacion',v_fecha_hora
      );
  end if;

  return jsonb_build_object('abono',v_abono,'abonado',v_abonado,'pagada',v_pagada);
end;
$$;

revoke all on function public.registrar_abono_cotizacion(text,numeric,text,text) from public;
grant execute on function public.registrar_abono_cotizacion(text,numeric,text,text) to authenticated;

-- Activa los eventos necesarios para que la pantalla de Caja reciba cambios.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.remisiones; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.abonos_cotizaciones; exception when duplicate_object then null; end;
  end if;
end;
$$;
