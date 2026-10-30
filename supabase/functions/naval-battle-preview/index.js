import {simulateNavalBattle, NAVAL_SHIP_PROFILES} from './militaryEngine.js';

const headers={
  'Access-Control-Allow-Origin':'*',
  'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info',
  'Content-Type':'application/json; charset=utf-8',
};
const json=(status,body)=>new Response(JSON.stringify(body),{status,headers});
const navalBattleSide=(participants,stateId)=>{
  const formations=participants.filter(p=>Number(p.state_id)===stateId),ships=[];
  for(const formation of formations)for(const unit of formation.units||[]){
    const savedShips=(formation.naval_state||[]).filter(item=>Number(item.unit_id)===Number(unit.unit_id));
    const profile=NAVAL_SHIP_PROFILES[unit.name]||NAVAL_SHIP_PROFILES['Ладья'];
    for(let index=0;index<Number(unit.quantity||0);index++){
      const saved=savedShips[index]||{};
      ships.push({id:String(saved.id||`${formation.formation_id}:${unit.unit_id}:${index+1}`),
        formation_id:Number(formation.formation_id),unit_id:Number(unit.unit_id),ship_no:Number(saved.ship_no||index+1),
        type:unit.name,crew:Number(saved.crew??profile.crew),hull:Number(saved.hull??profile.hull),
        morale:Number(saved.morale??100),maxCrew:Number(profile.crew),passengers:[]});
    }
  }
  const skills=formations.map(p=>p.leader_skills||{}),keys=[...new Set(skills.flatMap(value=>Object.keys(value)))];
  const commanderSkills=Object.fromEntries(keys.map(key=>[key,
    skills.reduce((sum,value)=>sum+Number(value[key]||0),0)/Math.max(1,skills.length)]));
  return {id:stateId,ships,morale:ships.length?ships.reduce((sum,ship)=>sum+ship.morale,0)/ships.length:100,
    commanderSkills,formationIds:formations.map(p=>Number(p.formation_id))};
};
const shipState=ship=>({id:ship.id,unit_id:Number(ship.unit_id),ship_no:Number(ship.ship_no),type:ship.type,
  crew:Math.max(0,Math.floor(Number(ship.crew)||0)),hull:Number(ship.hull)||0,morale:Number(ship.morale)||0});

Deno.serve(async request=>{
  if(request.method==='OPTIONS')return new Response(null,{status:204,headers});
  if(request.method!=='POST')return json(405,{error:'Метод не поддерживается'});
  const authorization=request.headers.get('authorization'),apikey=request.headers.get('apikey');
  if(!authorization?.startsWith('Bearer ')||!apikey)return json(401,{error:'Нужна авторизация'});
  let battleId,settings;
  try{
    const payload=await request.json();battleId=Number(payload?.battle_id);settings=payload?.settings;
    if(!Number.isSafeInteger(battleId)||battleId<=0||!settings||typeof settings!=='object'||Array.isArray(settings))
      return json(400,{error:'Некорректные параметры боя'});
  }catch{return json(400,{error:'Некорректный запрос'});}
  try{
    const url=Deno.env.get('SUPABASE_URL'),secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if(!url||!secret)throw new Error('Не настроена серверная функция боя');
    const identityResponse=await fetch(`${url}/rest/v1/rpc/fauxlore_api`,{
      method:'POST',headers:{authorization,apikey,'Content-Type':'application/json'},
      body:JSON.stringify({path:'auth/me',method:'GET',body:{},request_id:null}),
    });
    if(!identityResponse.ok)return json(401,{error:'Нужна авторизация'});
    const identity=await identityResponse.json();
    if(identity?.user?.role!=='admin')return json(403,{error:'Расчёт доступен только судье'});
    const sourceResponse=await fetch(`${url}/rest/v1/rpc/naval_battle_source_api`,{
      method:'POST',headers:{authorization:`Bearer ${secret}`,apikey:secret,'Content-Type':'application/json'},
      body:JSON.stringify({battle_key:battleId}),
    });
    if(!sourceResponse.ok)throw new Error(`Источник боя: ${sourceResponse.status}`);
    const battle=await sourceResponse.json();
    if(!battle||battle.status!=='pending'||battle.domain!=='naval')return json(404,{error:'Ожидающий морской бой не найден'});
    const participants=Array.isArray(battle.participants)?battle.participants:[];
    const stateIds=[...new Set(participants.map(p=>Number(p.state_id)))];
    if(stateIds.length!==2)return json(400,{error:'Автоматический расчёт поддерживает бой двух государств'});
    const attackerId=Number(settings.attacker_state_id),defenderId=stateIds.find(id=>id!==attackerId);
    if(!stateIds.includes(attackerId))return json(400,{error:'Некорректная сторона атаки'});
    const selected=(key,id)=>settings[key]?.[String(id)]===true;
    const attacker=navalBattleSide(participants,attackerId),defender=navalBattleSide(participants,defenderId);
    const simulation=simulateNavalBattle({battleId:String(battleId),randomSeed:String(battleId),attacker,defender,
      poorVisibility:settings.poor_visibility===true,
      safeRetreat:{attacker:selected('safe',attackerId),defender:selected('safe',defenderId)},
      adverseConditions:{attacker:selected('adverse',attackerId),defender:selected('adverse',defenderId)},
      requestWithdrawal:{attacker:selected('withdraw',attackerId),defender:selected('withdraw',defenderId)},
      pursue:{attacker:selected('pursue',attackerId),defender:selected('pursue',defenderId)}});
    const winnerId=simulation.outcome==='attacker'?attackerId:simulation.outcome==='defender'?defenderId:null;
    const lossMap=new Map();
    for(const side of ['attacker','defender'])for(const ship of simulation.fleets[side].ships)
      if(ship.sunk||ship.captured){const key=`${Number(ship.formation_id)}:${Number(ship.unit_id)}`;lossMap.set(key,(lossMap.get(key)||0)+1);}
    const losses=participants.flatMap(p=>(p.units||[]).map(unit=>({formation_id:Number(p.formation_id),
      unit_id:Number(unit.unit_id),losses:lossMap.get(`${Number(p.formation_id)}:${Number(unit.unit_id)}`)||0})));
    const sideByState={[attackerId]:'attacker',[defenderId]:'defender'};
    const navalStates=participants.map(p=>({formation_id:Number(p.formation_id),
      ships:simulation.fleets[sideByState[Number(p.state_id)]].ships
        .filter(ship=>!ship.sunk&&!ship.captured&&Number(ship.formation_id)===Number(p.formation_id)).map(shipState)}));
    const navalCaptures=[];
    for(const sideName of ['attacker','defender'])for(const ship of simulation.fleets[sideName].ships.filter(item=>item.captured)){
      const receiverState=ship.capturedBy==='attacker'?attackerId:defenderId;
      const targetFormation=participants.find(p=>Number(p.state_id)===receiverState)?.formation_id;
      if(targetFormation)navalCaptures.push({target_formation_id:Number(targetFormation),unit_id:Number(ship.unit_id),
        ship:{...shipState(ship),id:`capture:${battleId}:${ship.id}`}});
    }
    const report={outcome:simulation.outcome,cycles:simulation.cycles,withdrawals:simulation.withdrawals,
      pursuit:simulation.pursuit,random_seed:simulation.randomSeed};
    const cycleText=simulation.cycles.map(c=>`Цикл ${c.cycle}: экипаж потерял ${(c.casualties.attacker||[]).reduce((sum,item)=>sum+Number(item.crewLost||0),0)} / ${(c.casualties.defender||[]).reduce((sum,item)=>sum+Number(item.crewLost||0),0)}; потоплено или захвачено ${(c.casualties.attacker||[]).filter(item=>item.sunk||item.captured).length} / ${(c.casualties.defender||[]).filter(item=>item.sunk||item.captured).length} судов.`).join(' ');
    return json(200,{battle_id:battleId,winner_state_id:winnerId,losses,naval_states:navalStates,
      naval_captures:navalCaptures,naval_report:report,summary:cycleText});
  }catch(error){return json(500,{error:error?.message||'Не удалось рассчитать морской бой'});}
});
