import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};
function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}
const FIXED_LEVELS = [{target:400,ice:0,bombs:0},{target:700,ice:3,bombs:0},{target:1100,ice:4,bombs:2},{target:1600,ice:6,bombs:3},{target:2200,ice:8,bombs:4}];
function levelConfig(level:number) {
  if (level >= 1 && level <= FIXED_LEVELS.length) return FIXED_LEVELS[level-1];
  if (!Number.isInteger(level) || level < 1 || level > 10000) return null;
  return {target:Math.min(138000,Math.ceil(2200*Math.pow(1.20,level-5))),
    ice:Math.min(18,8+Math.floor((level-5)/2)),
    bombs:Math.min(12,4+Math.floor((level-5)/2))};
}
const N = 6;
type Cell = { fruit:number; ice:boolean; bomb:boolean };
type Pos = {r:number;c:number};
type Event = {type:string;path?:Pos[]};

function makeRng(seed:number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6D2B79F5) | 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
function replayFruitFancy(seed:number, level:number, events:Event[]) {
  const cfg = levelConfig(level);
  if (!cfg || !Number.isInteger(seed) || seed < 1 || seed > 2147483647) throw new Error("Invalid session seed or level.");
  const rnd = makeRng(seed);
  const fruit = () => Math.floor(rnd()*7);
  const board:Cell[][] = Array.from({length:N},()=>Array.from({length:N},()=>({fruit:fruit(),ice:false,bomb:false})));
  const place = (key:"ice"|"bomb", count:number) => {
    let n=0,guard=0;
    while(n<count && guard++<10000) {
      const r=Math.floor(rnd()*N), c=Math.floor(rnd()*N), cell=board[r][c];
      if(!cell[key] && !(key==="bomb" && cell.ice)) { cell[key]=true; n++; }
    }
    if(n!==count) throw new Error("Could not reproduce initial board.");
  };
  place("ice",cfg.ice); place("bomb",cfg.bombs);

  const hasMove = () => {
    for(let r=0;r<N;r++) for(let c=0;c<N;c++) {
      const first=board[r][c]; if(first.ice||first.bomb) continue;
      const type=first.fruit, used=new Set([r*N+c]);
      const extend=(rr:number,cc:number):boolean=>{
        if(used.size>=3)return true;
        for(let dr=-1;dr<=1;dr++)for(let dc=-1;dc<=1;dc++){
          if(!dr&&!dc)continue;
          const nr=rr+dr,nc=cc+dc,k=nr*N+nc;
          if(nr<0||nr>=N||nc<0||nc>=N||used.has(k))continue;
          const cell=board[nr][nc];
          if(cell.ice||(!cell.bomb&&cell.fruit!==type))continue;
          used.add(k); if(extend(nr,nc))return true; used.delete(k);
        }
        return false;
      };
      if(extend(r,c))return true;
    }
    return false;
  };
  const findTriple = ():Pos[] => {
    for(let r=0;r<N;r++)for(let c=0;c<N;c++){
      if(board[r][c].ice||board[r][c].bomb)continue;
      const chain:Pos[]=[{r,c}];
      const walk=():boolean=>{
        if(chain.length===3)return true;
        const last=chain[chain.length-1];
        for(let dr=-1;dr<=1;dr++)for(let dc=-1;dc<=1;dc++){
          if(!dr&&!dc)continue;
          const nr=last.r+dr,nc=last.c+dc;
          if(nr<0||nr>=N||nc<0||nc>=N||board[nr][nc].ice||chain.some(p=>p.r===nr&&p.c===nc))continue;
          chain.push({r:nr,c:nc}); if(walk())return true; chain.pop();
        }
        return false;
      };
      if(walk())return chain.slice();
    }
    return [];
  };
  const shuffle = (force:boolean) => {
    if(!force&&hasMove())return false;
    const cells=board.flat().filter(cell=>!cell.ice);
    for(let attempt=0;attempt<300;attempt++){
      const fruits=cells.map(cell=>cell.fruit);
      for(let i=fruits.length-1;i>0;i--){const j=Math.floor(rnd()*(i+1));[fruits[i],fruits[j]]=[fruits[j],fruits[i]];}
      cells.forEach((cell,i)=>cell.fruit=fruits[i]);
      if(hasMove())return true;
    }
    const triple=findTriple();
    if(triple.length===3){const chosen=fruit();triple.forEach(p=>board[p.r][p.c].fruit=chosen);}
    if(!hasMove())throw new Error("Could not reproduce a playable board.");
    return true;
  };
  shuffle(false);
  let score=0,moves=0,won=false;
  for(const ev of events){
    if(won)throw new Error("Events were submitted after the level was already cleared.");
    if(ev?.type==="refresh"){shuffle(true);continue;}
    if(ev?.type!=="move"||!Array.isArray(ev.path)||ev.path.length<3||ev.path.length>N*N)throw new Error("Malformed move event.");
    const path=ev.path;
    const seen=new Set<string>();
    for(let i=0;i<path.length;i++){
      const p=path[i];
      if(!p||!Number.isInteger(p.r)||!Number.isInteger(p.c)||p.r<0||p.r>=N||p.c<0||p.c>=N)throw new Error("Move contains an invalid tile.");
      const key=p.r+","+p.c,cell=board[p.r][p.c];
      if(seen.has(key)||cell.ice)throw new Error("Move repeats or crosses a blocked tile.");
      seen.add(key);
      if(i===0){if(cell.ice)throw new Error("Move starts on a blocked tile.");}
      else {
        const prev=path[i-1],dr=Math.abs(p.r-prev.r),dc=Math.abs(p.c-prev.c);
        if(dr>1||dc>1||(!dr&&!dc))throw new Error("Move path is not connected.");
        const first=board[path[0].r][path[0].c];
        if(!cell.bomb&&cell.fruit!==first.fruit)throw new Error("Move combines different fruits.");
      }
    }
    const length=path.length,blast=length>=7,points=length*10+(blast?100:0);
    score+=points;moves++;
    const remove=new Set<string>(path.map(p=>p.r+","+p.c));
    for(const p of path){
      const cell=board[p.r][p.c];
      if(cell.bomb)for(let dr=-1;dr<=1;dr++)for(let dc=-1;dc<=1;dc++){
        const rr=p.r+dr,cc=p.c+dc;if(rr>=0&&rr<N&&cc>=0&&cc<N)remove.add(rr+","+cc);
      }
      for(const [rr,cc] of [[p.r-1,p.c],[p.r+1,p.c],[p.r,p.c-1],[p.r,p.c+1]]){
        if(rr>=0&&rr<N&&cc>=0&&cc<N&&board[rr][cc].ice)board[rr][cc].ice=false;
      }
    }
    for(const key of remove){const [r,c]=key.split(",").map(Number);board[r][c]=null as unknown as Cell;}
    for(let c=0;c<N;c++){
      let dest=N-1;
      for(let r=N-1;r>=0;r--)if(board[r][c]){
        board[dest][c]=board[r][c];if(dest!==r)board[r][c]=null as unknown as Cell;dest--;
      }
      for(let r=dest;r>=0;r--)board[r][c]={fruit:fruit(),ice:false,bomb:rnd()<0.08};
    }
    if(score>=cfg.target)won=true;
    else shuffle(false);
  }
  return {score,moves,won};
}

Deno.serve(async (req: Request) => {
  if(req.method==="OPTIONS")return new Response("ok",{headers:corsHeaders});
  if(req.method!=="POST")return reply(405,{error:"Method not allowed."});
  const url=Deno.env.get("SUPABASE_URL"),anonKey=Deno.env.get("SUPABASE_ANON_KEY"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!url||!anonKey||!serviceKey)return reply(500,{error:"Game verification service is not configured."});
  const authHeader=req.headers.get("Authorization")||"",token=authHeader.replace(/^Bearer\s+/i,"");
  if(!token||token===authHeader)return reply(401,{error:"Sign in to submit a game result."});
  const authClient=createClient(url,anonKey,{auth:{persistSession:false,autoRefreshToken:false},global:{headers:{Authorization:`Bearer ${token}`}}});
  const {data:userData,error:userError}=await authClient.auth.getUser(token);
  if(userError||!userData.user)return reply(401,{error:"Your sign-in session is invalid. Please sign in again."});
  let body:Record<string,unknown>;
  try{body=await req.json();}catch{return reply(400,{error:"Invalid request body."});}
  const admin=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:access,error:accessError}=await admin.rpc("service_get_player_access",{p_user_id:userData.user.id});
  if(accessError)return reply(503,{error:"Account access could not be verified. Please try again."});
  if(access?.status==="restricted")return reply(403,{error:"Your CHOME account is restricted.",reason:access.reason||"",resolution_steps:access.resolution_steps||""});
  if(body.action==="continue"){
    // Rewarded ads are not connected yet. Never trust a client-supplied
    // "ad watched" flag; only a provider-verified server callback may grant moves.
    return reply(503,{ok:false,error:"Rewarded ads are not connected yet. No extra moves were granted."});
  }
  if(body.action==="fail"){
    const sessionId=String(body.session_id||"");
    if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(sessionId))
      return reply(400,{ok:false,error:"Invalid game session."});
    const {data,error}=await admin.rpc("fail_fruit_fancy_session",{p_session_id:sessionId,p_user_id:userData.user.id});
    if(error)return reply(500,{ok:false,error:"Lost-game reward could not be recorded."});
    if(!data?.ok)return reply(400,data||{ok:false,error:"Lost-game reward was rejected."});
    return reply(200,data);
  }
  if(body.action==="start"){
    const gameId=body.game_id,level=Number(body.level);
    if(gameId!=="fruit-fancy"||!Number.isInteger(level)||level<1||level>10000)return reply(400,{error:"This game or level is not enabled for verified sessions."});
    const {data,error}=await admin.rpc("start_game_session",{p_user_id:userData.user.id,p_game_id:gameId,p_level:level});
    if(error)return reply(500,{error:"Could not start a verified game session."});
    if(!data?.ok)return reply(429,{error:data?.error||"Game session could not start."});
    return reply(200,data);
  }
  if(body.action==="progress"||body.action==="complete"){
    const isComplete=body.action==="complete";
    const sessionId=String(body.session_id||""),score=Number(body.score),moves=Number(body.moves),events=body.events;
    if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(sessionId)
      ||!Number.isInteger(score)||!Number.isInteger(moves)||!Array.isArray(events)||events.length>300)
      return reply(400,{error:"Invalid game progress or event history."});
    const {data:session,error:sessionError}=await admin.rpc("get_game_session_seed",{p_session_id:sessionId,p_user_id:userData.user.id});
    if(sessionError||!session?.ok)return reply(400,{error:session?.error||"Verified session could not be loaded."});
    const safeEvents:Event[]=[];
    for(const raw of events as unknown[]){
      if(!raw||typeof raw!=="object")return reply(400,{error:"Malformed gameplay event."});
      const item=raw as Record<string,unknown>;
      if(item.type==="refresh"){safeEvents.push({type:"refresh"});continue;}
      if(item.type!=="move"||!Array.isArray(item.path)||item.path.length<3||item.path.length>N*N)
        return reply(400,{error:"Malformed gameplay move."});
      const safePath:Pos[]=[];
      for(const point of item.path as unknown[]){
        if(!point||typeof point!=="object")return reply(400,{error:"Malformed tile coordinate."});
        const tile=point as Record<string,unknown>;
        safePath.push({r:Number(tile.r),c:Number(tile.c)});
      }
      safeEvents.push({type:"move",path:safePath});
    }
    let replay;
    try{replay=replayFruitFancy(Number(session.board_seed),Number(session.level),safeEvents);}
    catch(error){return reply(400,{error:error instanceof Error?error.message:"Gameplay replay failed."});}
    if(replay.score!==score||replay.moves!==moves)
      return reply(400,{error:"The submitted progress does not match the server replay.",verified_score:replay.score,verified_moves:replay.moves});
    if(isComplete&&!replay.won)
      return reply(400,{error:"The server replay has not reached the level target yet."});
    const {data,error}=await admin.rpc("record_fruit_fancy_progress",{
      p_session_id:sessionId,p_user_id:userData.user.id,p_events:safeEvents,
      p_score:replay.score,p_moves:replay.moves,p_complete:isComplete,
    });
    if(error)return reply(500,{error:"Verified CHOX progress could not be recorded."});
    if(!data?.ok)return reply(400,{error:data?.error||"Verified progress was rejected."});
    // CHOX and Game Points are settled atomically by record_fruit_fancy_progress.
    if(isComplete){
      return reply(200,{ok:true,result:data.result,replay:{score:replay.score,moves:replay.moves},
        rewards:{move_chox_credited:data.move_chox_credited,game_points_credited:data.game_points_credited,stage_chox_credited:data.stage_chox_credited,
          stage_bonus_first_completion:data.stage_bonus_first_completion,daily_move_cap:data.daily_move_cap}});
    }
    return reply(200,{ok:true,progress:{new_move_events:data.new_move_events,
      move_chox_credited:data.move_chox_credited,daily_move_cap:data.daily_move_cap}});
  }
  return reply(400,{error:"Unknown game-session action."});
});