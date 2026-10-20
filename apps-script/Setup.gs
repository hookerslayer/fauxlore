// The editor only lists public functions. This bootstrap is owner-only even
// when invoked through google.script.run; it never grants a game role.
function setupFauxlore(){
  const active=Session.getActiveUser().getEmail(),effective=Session.getEffectiveUser().getEmail();
  if(!active||active!==effective)fail_(403,'Настройка доступна только владельцу скрипта в редакторе');
  configureFauxlore_();
}
function configureFauxlore_(){
  const p=properties_();
  if(!p.getProperty('DATABASE_SPREADSHEET_ID'))p.setProperty('DATABASE_SPREADSHEET_ID','16_DFnKy-TopNq6suwlW_13o5k4haU1JJt5YjqbGly6M');
  if(!p.getProperty('SITE_URL'))p.setProperty('SITE_URL','http://127.0.0.1:8003');
  if(!p.getProperty('SITE_URLS'))p.setProperty('SITE_URLS',JSON.stringify([site_(),'http://127.0.0.1:8003','https://hookerslayer.github.io/fauxlore'].filter((value,index,array)=>array.indexOf(value)===index)));
  const db=new Store_();
  console.log(JSON.stringify({database:'google-sheets',provinces:db.rows('provinces').length,accounts:db.rows('accounts').length,markers:db.rows('map_markers').length}));
}
