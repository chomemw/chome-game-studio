import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.49.1";

const headers={ "Access-Control-Allow-Origin":"*", "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods":"POST, OPTIONS", "Content-Type":"application/json" };
const reply=(status:number,body:Record<string,unknown>)=>new Response(JSON.stringify(body),{status,headers});
Deno.serve(async(req:Request)=>{
  if(req.method==="OPTIONS")return new Response("ok",{headers});
  if(req.method!=="POST")return reply(405,{error:"Method not allowed."});
  const url=Deno.env.get("SUPABASE_URL"),anon=Deno.env.get("SUPABASE_ANON_KEY"),service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!url||!anon||!service)return reply(500,{error:"Candy Trail rewards are not configured."});
  const auth=req.headers.get("Authorization")||"",token=auth.replace(/^Bearer\s+/i,"");
  if(!token||token===auth)return reply(401,{error:"Sign in to earn CHOX."});
  const userClient=createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false},global:{headers:{Authorization:"Bearer "+token}}});
  const {data:userData,error:userError}=await userClient.auth.getUser(token);
  if(userError||!userData.user)return reply(401,{error:"Your sign-in session is invalid."});
  let body:Record<string,unknown>;try{body=await req.json();}catch{return reply(400,{error:"Invalid request body."});}
  const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:access,error:accessError}=await admin.rpc("service_get_player_access",{p_user_id:userData.user.id});
  if(accessError)return reply(503,{error:"Account access could not be verified."});
  if(access?.status==="restricted")return reply(403,{error:"Your CHOME account is restricted.",reason:access.reason||""});
  if(body.action==="start"){
    const level=Number(body.level),moves=Number(body.initial_moves),target=Number(body.target_score);
    if(!Number.isInteger(level)||!Number.isInteger(moves)||!Number.isInteger(target))return reply(400,{error:"Invalid Candy Trail run settings."});
    const {data,error}=await userClient.rpc("start_candy_trail_session",{p_level:level,p_initial_moves:moves,p_target_score:target});
    if(error)return reply(500,{error:"Could not start a verified Candy Trail run."});
    if(!data?.ok)return reply(429,data||{ok:false,error:"Candy Trail run could not start."});
    return reply(200,data);
  }
  if(body.action==="complete"){
    const id=String(body.session_id||""),score=Number(body.score),moves=Number(body.moves),events=body.events;
    if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)
      ||!Number.isInteger(score)||!Number.isInteger(moves)||!Array.isArray(events)||events.length>500)
      return reply(400,{error:"Invalid Candy Trail completion payload."});
    const {data,error}=await admin.rpc("finish_candy_trail_session",{p_session_id:id,p_user_id:userData.user.id,p_score:score,p_moves:moves,p_events:events});
    if(error)return reply(500,{error:"Verified Candy Trail CHOX could not be posted."});
    if(!data?.ok)return reply(400,data||{ok:false,error:"Candy Trail result was rejected."});
    return reply(200,{ok:true,rewards:data});
  }
  return reply(400,{error:"Unknown Candy Trail rewards action."});
});