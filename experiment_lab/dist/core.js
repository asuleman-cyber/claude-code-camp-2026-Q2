(function(root){
const defaults={orchestration:true,navigator:true,memory:'persistent',replan:true,checkpoint:3,turns:24,seed:42,sessions:3,model:'claude-haiku-4-5',goal:'Explore Midgaard and return safely',character:'dummy'};
function simulate(config,prior=[]){
 const c={...defaults,...config};let seed=Number(c.seed)>>>0;const rand=()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed/4294967296};
 const events=[],lessons=[],rooms=new Set();let turn=0,t=0;const emit=(phase,extra={})=>events.push({phase,turn,mono_ms:t+=100+Math.round(rand()*400),...extra});
 const response=(task,text)=>emit('response',{task,model:c.model,text,usage:{input_tokens:250+Math.floor(rand()*500),output_tokens:60+Math.floor(rand()*120)},cost_usd:0.0008+rand()*.001});
 emit('session_start',{model:c.model,config:c,source:'simulation'});
 for(let session=1;session<=c.sessions;session++){
 if(c.orchestration){emit('plan',{task:'planner',session,text:`Explore from Temple; survey known routes; return safely.${c.memory==='persistent'&& (session>1||prior.length)?' Prior lessons inform this plan.':''}`});response('planner','Plan composed; stop when exploration budget is reached.');}
 for(let n=1;n<=c.turns;n++){
 turn++;emit('turn',{n:turn,session});let risky=rand()<.22;
 if(c.navigator&&risky){emit('navigator',{task:'navigator',session,text:'Read-only route advice from walked edges. Unexplored exits remain frontiers.'});response('navigator','Use a known route; avoid the unvisited shortcut.');}
 const reuse=c.memory==='persistent'&&(session>1||prior.length>0);const room=Math.floor(rand()*(reuse?18:12));rooms.add(room);
 emit('tool_call',{name:'tbamud__move',args:{direction:['north','east','south','west'][room%4]},session});
 emit('tool_result',{name:'tbamud__move',ok:!(risky&&!c.navigator&&!reuse),elapsed_ms:80+Math.floor(rand()*300),session,result:`Room ${room}: ${['Temple of Midgaard','Market Square','City Gate','Narrow Alley'][room%4]}`,room_id:room,...(risky&&!c.navigator&&!reuse?{error:'Blocked route; action could not complete.'}:{})});
 response('player',`Survey room ${room}; ${reuse?'apply remembered strategy':'observe available exits'}.`);
 if(c.orchestration&&(n%c.checkpoint===0||risky)){
 const verdict=risky?(c.replan?'replan':'flag'):'continue';emit('orchestrator',{role:'judge',event:'verdict',detail:verdict,session,text:risky?'Route uncertainty at checkpoint.':'Progress remains aligned with plan.'});response('judge',`VERDICT: ${verdict}`);
 if(verdict!=='continue'&&c.memory!=='off'){const l={category:risky?'Mistakes':'Strategies',text:'Check the known route before taking an unfamiliar shortcut.',session,turn};lessons.push(l);emit('remember',{task:'chronicler',session,text:l.text,category:l.category});response('chronicler','Merge lesson into bounded digest.');}
 if(verdict==='replan'){emit('plan',{task:'planner',session,text:'Replan for the next turn: prefer a walked route.'});response('planner','Revised plan composed for the next turn.');}
 }
 emit('turn_end',{reason:'completed',session});
 }
 if(c.memory!=='off'){const l={category:'Strategies',text:`Session ${session}: preserve safe return routes and revisit unresolved frontiers.`,session,turn};lessons.push(l);emit('remember',{task:'chronicler',session,text:l.text,category:l.category});response('chronicler','Session boundary: persist discoveries, mistakes, strategies and open threads.');}
 }
 return {id:'sim-'+Date.now()+'-'+Math.floor(rand()*1e6),name:c.orchestration?'Orchestrated exploration':'Week 2 · simulated control',source:'simulation',created:new Date().toISOString(),config:c,events,lessons,rooms:rooms.size,notes:'',outcome:'unrated'};
}
function parseJSONL(text,name){let errors=[],events=[];text.split(/\r?\n/).forEach((line,i)=>{if(!line.trim())return;try{const e=JSON.parse(line);if(!e||typeof e!=='object'||Array.isArray(e))throw Error('Expected event object');events.push({...e,_line:i+1});}catch(e){errors.push({line:i+1,message:e.message});}});if(!events.length)throw Error('No valid JSONL event objects found.');let turn=0;events=events.map(e=>{if(e.phase==='turn')turn=e.n;return {...e,turn:e.turn??turn}});const snap=events.find(e=>e.phase==='session_start')||{};return {id:'import-'+Date.now(),name,source:'imported',created:snap.at||new Date().toISOString(),config:snap.config||{model:snap.model,goal:'Imported log — annotate goal',seed:'unknown',turns:'unknown',sessions:1},events,lessons:events.filter(e=>e.phase==='remember'||e.phase==='orchestrator'&&e.role==='chronicler'&&e.event==='written').map(e=>({text:e.text,category:e.category||'Recorded digest',turn:e.turn,session:e.session||e.at||'unknown'})),parseErrors:errors,notes:'',outcome:'unrated'};}
function metrics(run){const es=run.events,res=es.filter(e=>e.phase==='response'),priced=res.filter(e=>Number.isFinite(e.cost_usd));return {turns:es.filter(e=>e.phase==='turn').length,input:res.reduce((a,e)=>a+Number(e.input_tokens??e.usage?.input_tokens??0),0),output:res.reduce((a,e)=>a+Number(e.output_tokens??e.usage?.output_tokens??0),0),cost:priced.reduce((a,e)=>a+e.cost_usd,0),costKnown:res.length>0&&priced.length===res.length,priced:priced.length,responses:res.length,errors:es.filter(e=>e.error||e.ok===false||e.event==='error').length,replans:es.filter(e=>e.phase==='orchestrator'&&e.detail==='replan').length,tools:es.filter(e=>e.phase==='tool_result'||e.tool&&e.elapsed_ms!=null).length};}
function stage(e){if(e.phase==='plan'||e.task==='planner')return 'Plan';if(e.phase==='remember'||e.task==='chronicler'||e.role==='chronicler')return 'Remember';if(e.role==='judge'||e.task==='judge')return 'Check';if(e.phase==='navigator'||e.task==='navigator'||e.role==='navigator')return 'Navigate';return 'Play';}
const api={defaults,simulate,parseJSONL,metrics,stage};if(typeof module!=='undefined')module.exports=api;root.Lab=api;
})(globalThis);
