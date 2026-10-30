import {calculateProvinceEconomy, calculateProvinceValue, calculateProvinceEstateTaxes, calculateStateProduction, calculateStatePolitics, calculateInternalTradeForecast, calculateTradeZoneForecast, distributeTradeZoneIncome, getEconomyConfig, GROUP_STATUS_EFFECTS, setEconomyConfig} from './economy.js';
import {buildFinanceProjection} from './finance-projection.js';

const headers = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Content-Type': 'application/json; charset=utf-8',
};

const json = (status, body) => new Response(JSON.stringify(body), {status, headers});

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, {status: 204, headers});
  if (request.method !== 'POST') return json(405, {error: 'Метод не поддерживается'});
  const authorization = request.headers.get('authorization');
  const apikey = request.headers.get('apikey');
  if (!authorization?.startsWith('Bearer ') || !apikey) return json(401, {error: 'Нужна авторизация'});

  let provinceId, stateId, view;
  try {
    const payload = await request.json();
    provinceId = Number(payload?.province_id);
    stateId = Number(payload?.state_id);
    view = payload?.view || 'provinces';
  } catch {
    return json(400, {error: 'Некорректный запрос'});
  }
  const provinceMode = Number.isSafeInteger(provinceId) && provinceId > 0 && provinceId < 16777216;
  const stateMode = Number.isSafeInteger(stateId) && stateId > 0 && stateId < 16777216;
  if (provinceMode === stateMode) {
    return json(400, {error: 'Укажите ID провинции или государства'});
  }
  if (stateMode && !['provinces','politics','trade','finance'].includes(view)) return json(400, {error: 'Неизвестный вид расчёта'});

  try {
    const url = Deno.env.get('SUPABASE_URL');
    if (!url) throw new Error('Не настроен адрес базы');
    const read = async path => {
      const response = await fetch(`${url}/rest/v1/rpc/fauxlore_api`, {
      method: 'POST',
      headers: {authorization, apikey, 'Content-Type': 'application/json'},
      body: JSON.stringify({path, method: 'GET', body: {}, request_id: null}),
      });
      if (!response.ok) throw new Error(`RPC ${path}: ${response.status}`);
      return response.json();
    };
    const readRpc = async (name,args) => {
      const response=await fetch(`${url}/rest/v1/rpc/${name}`,{
        method:'POST',headers:{authorization,apikey,'Content-Type':'application/json'},body:JSON.stringify(args),
      });
      if(!response.ok)throw new Error(`RPC ${name}: ${response.status}`);
      return response.json();
    };
    const [map, identity] = stateMode
      ? await Promise.all([read('map'), read('auth/me')])
      : [await read('map'), null];
    setEconomyConfig(map.economy_config);
    if (stateMode) {
      const administrator = identity?.user?.role === 'admin';
      const prefix = administrator ? 'admin' : 'my';
      const states = await read(administrator ? 'admin/states' : 'my/states');
      const state = states.find(item => Number(item.id) === stateId);
      if (!state) return json(403, {error: 'Нет доступа к государству'});
      const indicators = await read(`${prefix}/states/${stateId}/indicators`);
      const context = {...state, permanent_modifiers: indicators.permanent_modifiers || []};
      if (view === 'trade' || view === 'finance') {
        const secret = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
        if (!secret) throw new Error('Не настроен серверный ключ прогнозов');
        const [sourceResponse, overview, duty, estateRates] = await Promise.all([
          fetch(`${url}/rest/v1/rpc/projection_source_api`, {
            method: 'POST',
            headers: {authorization: `Bearer ${secret}`, apikey: secret, 'Content-Type': 'application/json'},
            body: '{}',
          }),
          read(`${prefix}/states/${stateId}/trade-overview`),
          read(`${prefix}/states/${stateId}/trade-duty`),
          read(`${prefix}/states/${stateId}/estate-tax-rates`),
        ]);
        if (!sourceResponse.ok) throw new Error(`Private projection source: ${sourceResponse.status}`);
        const source = await sourceResponse.json();
        setEconomyConfig(source.economy_config);
        const allProvinces = source.provinces || [];
        const owned = allProvinces.filter(province => province.kind === 'land' &&
          (Number(province.layers?.states?.id) === stateId || province.occupation === state.name));
        const production = calculateStateProduction(owned, state.name, context);
        const previousStatePrices = new Map((overview.resources || []).map(row => [row.resource_name, Number(row.dynamic_price)]));
        const internal = calculateInternalTradeForecast(production, Number(duty.rate) || 15, previousStatePrices);
        const rates = Object.fromEntries((estateRates.groups || []).map(group => [group.estate, Number(group.rate)]));
        const buckets = ['Корона','Знать','Духовенство','Горожане','Крестьяне'];
        const taxForecast = {total: 0, buckets: Object.fromEntries(buckets.map(name => [name, 0]))};
        const estateOrder = ['Знать','Духовенство','Горожане','Крестьяне'];
        const authorityStatus = {Династия:['Ключевое','Значимое','Бесправное','Бесправное'],Магистрат:['Значимое','Ключевое','Ключевое','Бесправное'],Клир:['Бесправное','Ключевое','Бесправное','Бесправное'],Диктат:['Бесправное','Значимое','Бесправное','Бесправное'],Вече:['Бесправное','Значимое','Значимое','Ключевое']};
        const economyStatus = {Крепостничество:['Ключевое','—','—','Бесправное'],Гильдии:['—','—','Ключевое','—'],Адмиралтейство:['—','—','Ключевое','—'],Корсарство:['—','—','Значимое','—'],Работорговля:['—','—','—','Бесправное']};
        for (const province of owned) {
          const ownerMatch = Number(province.layers?.states?.id) === stateId;
          const layers = {...province.layers};
          if (ownerMatch) layers.states = {...layers.states, estate_tax_rates: rates};
          const adjusted = {...province, layers, ...(!ownerMatch ? {occupation_estate_tax_rates: rates} : {})};
          const lines = calculateProvinceEstateTaxes(adjusted, state.name, context);
          if (!lines) continue;
          for (const [estate, line] of Object.entries(lines)) {
            taxForecast.total += line.net;
            const index = estateOrder.indexOf(estate);
            const economic = economyStatus[context.principles?.economy]?.[index];
            const status = economic && economic !== '—' ? economic : (authorityStatus[context.principles?.authority]?.[index] || '—');
            const greed = Number(getEconomyConfig().estateTaxGreed?.[`${status}|${estate}`] ?? 0);
            const center = Math.floor(line.net * (1 - greed));
            taxForecast.buckets['Корона'] += center;
            taxForecast.buckets[estate] += line.net - center;
          }
        }
        taxForecast.total = Math.floor(taxForecast.total);
        for (const name of buckets) taxForecast.buckets[name] = Math.floor(taxForecast.buckets[name]);
        const previousZonePrices = new Map((overview.zones || []).map(zone =>
          [Number(zone.id), new Map((zone.resources || []).map(row => [row.resource_name, Number(row.dynamic_price)]))]));
        const zones = calculateTradeZoneForecast(allProvinces, previousZonePrices)
          .filter(zone => (zone.participants || []).some(participant => Number(participant.state_id) === stateId || participant.state_name === state.name))
          .map(zone => ({...zone, participants: (zone.participants || []).map(participant =>
            Number(participant.state_id) === stateId || participant.state_name === state.name
              ? participant
              : {...participant, local_income: null, export_income: null})}));
        const modifierTotal = key => (indicators.permanent_modifiers || [])
          .filter(item => item.key === key && item.scope === 'Государство')
          .reduce((sum, item) => sum + Number(item.value || 0), 0);
        const internalFactor = Math.max(0, 1 + modifierTotal('internal_trade_income'));
        const zoneFactor = Math.max(0, 1 + modifierTotal('trade_zone_income'));
        const marketIncome = Math.floor(zones.reduce((sum, zone) => sum + (zone.participants || [])
          .filter(participant => Number(participant.state_id) === stateId || participant.state_name === state.name)
          .reduce((income, participant) => income + Number(participant.local_income || 0) + Number(participant.export_income || 0), 0), 0) * zoneFactor);
        const adjustedEstateIncome = Object.fromEntries(Object.entries(internal.estateIncomeByName || {})
          .map(([name, value]) => [name, Math.floor(Number(value || 0) * internalFactor)]));
        const projection={state_id: stateId, data_revision: source.data_revision,
          live_revision: source.live_revision, resources: internal.resources,
          internal_income: internal.internalIncome, estate_income: internal.estateIncomeByName,
          adjusted_internal_income: Math.floor(internal.internalIncome * internalFactor),
          adjusted_estate_income: adjustedEstateIncome,
          market_income: marketIncome, zone_income_by_estate: distributeTradeZoneIncome(marketIncome),
          tax_forecast: taxForecast, zones};
        if(view==='finance'){
          const [taxRates,agreements,garrisonData,colonyData]=await Promise.all([
            read(`${prefix}/states/${stateId}/tax-rates`),read('my/trade-agreements'),
            readRpc('garrison_api',{action:'snapshot',target_state:stateId,province_key:null,payload:{}}),
            readRpc('colonization_api',{action:'snapshot',target_state:stateId,payload:{}}),
          ]);
          projection.finance=buildFinanceProjection({stateId,taxForecast,tradeProjection:projection,
            agreements,garrisonData,colonyData,taxRates,indicators});
        }
        return json(200,projection);
      }
      const stateProvinces = map.provinces.filter(province =>
        province.kind === 'land' && (Number(province.layers?.states?.id) === stateId || province.occupation === state.name)
      );
      if (view === 'politics') {
        const politics = await read(`${prefix}/states/${stateId}/politics`);
        const derived = calculateStatePolitics(stateProvinces, politics, state.name,
          {...context, corruption: indicators.corruption});
        for (const breakdown of [derived.raceModifierBreakdown, derived.religionModifierBreakdown]) {
          for (const group of Object.values(breakdown)) group.statusEffects = GROUP_STATUS_EFFECTS[group.status] || GROUP_STATUS_EFFECTS.Невмешательство;
        }
        const effects = getEconomyConfig().stateEffects || {};
        const crime = Number(indicators.crime || 0), corruption = Number(indicators.corruption || 0);
        const peasant = derived.estateModifierBreakdown['Крестьяне'];
        const systemEffects = {
          crimeTaxPenalty: Number(effects.crimeTaxPenalty ?? .25),
          crimePopulationPenalty: Number(effects.crimePopulationPenalty ?? .5),
          crimeRecruitBonus: Number(effects.crimeRecruitBonus ?? .5),
          corruptionTaxPenalty: Number(effects.corruptionTaxPenalty ?? 1),
          productionMultiplier: 1 - crime,
          crimeTaxMultiplier: 1 - crime * Number(effects.crimeTaxPenalty ?? .25),
          crimePopulationMultiplier: 1 - crime * Number(effects.crimePopulationPenalty ?? .5),
          crimeRecruitMultiplier: 1 + crime * Number(effects.crimeRecruitBonus ?? .5),
          corruptionTaxMultiplier: 1 - corruption * Number(effects.corruptionTaxPenalty ?? 1),
          corruptionLoyaltyBonus: Math.min(Number(effects.corruptionLoyaltyCap ?? .15), corruption / Number(effects.corruptionLoyaltyDivisor ?? 6)),
          urbanGrowthMultiplier: Number(indicators.urbanization_growth_multiplier ?? 1),
          peasantRawLoyalty: peasant ? peasant.baseLoyalty + peasant.influence - peasant.ambition - peasant.taxAdjustment + peasant.corruptionBonus + peasant.principleLoyalty : 0,
        };
        return json(200, {state_id: stateId, data_revision: map.data_revision,
          live_revision: map.live_revision, politics, indicators, derived, system_effects: systemEffects});
      }
      const projections = stateProvinces.map(province => ({
        id: province.id,
        ...calculateProvinceEconomy(province, state.name, context),
        value: calculateProvinceValue(province, state.name, context),
      }));
      return json(200, {state_id: stateId, data_revision: map.data_revision,
        live_revision: map.live_revision, provinces: projections,
        production_rows: calculateStateProduction(stateProvinces, state.name, context)});
    }
    const province = map.provinces?.find((item) => Number(item.id) === provinceId);
    if (!province || province.kind !== 'land') return json(404, {error: 'Провинция не найдена'});
    const occupied = province.occupation && province.occupation !== province.layers?.states?.name;
    const permitted = occupied
      ? province.occupation_estate_tax_rates != null
      : province.layers?.states?.estate_tax_rates != null;
    if (!permitted) return json(403, {error: 'Нет доступа к экономике провинции'});

    const economy = calculateProvinceEconomy(province);
    const value = calculateProvinceValue(province);
    return json(200, {
      province_id: provinceId,
      data_revision: map.data_revision,
      live_revision: map.live_revision,
      populationGrowth: economy.populationGrowth,
      taxes: economy.taxes,
      production: economy.production,
      tradeInfluence: economy.tradeInfluence,
      recruitGrowth: economy.recruitGrowth,
      recruitLimit: economy.recruitLimit,
      value,
    });
  } catch (error) {
    console.error('province-projection', error);
    return json(500, {error: 'Не удалось рассчитать показатели провинции'});
  }
});
