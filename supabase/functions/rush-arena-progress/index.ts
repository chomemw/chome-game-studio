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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply(405, { error: "Method not allowed." });

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return reply(500, { error: "Rush Arena service is not configured." });

  const authorization = req.headers.get("Authorization") || "";
  const token = authorization.replace(/^Bearer\s+/i, "");
  if (!token || token === authorization) return reply(401, { error: "Sign in to save Rush Arena progress." });

  const authClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const { data: authData, error: authError } = await authClient.auth.getUser(token);
  if (authError || !authData.user) return reply(401, { error: "Your sign-in session is invalid. Please sign in again." });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return reply(400, { error: "Invalid request body." }); }

  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const userId = authData.user.id;
  const { data: access, error: accessError } = await admin.rpc("service_get_player_access", { p_user_id: userId });
  if (accessError) return reply(503, { error: "Account access could not be verified." });
  if (access?.status === "restricted") return reply(403, { error: "Your CHOME account is restricted.", reason: access.reason || "", resolution_steps: access.resolution_steps || "" });

  if (body.action === "list") {
    const { data, error } = await admin.rpc("service_rush_arena_progress", { p_user_id: userId });
    if (error || !data) return reply(500, { error: "Rush Arena progress could not be loaded." });
    return reply(200, { ok: true, progress: data });
  }

  if (body.action === "start") {
    const level = Number(body.level);
    if (!Number.isInteger(level) || level < 1 || level > 250) return reply(400, { error: "Invalid Rush Arena level." });
    const { data, error } = await admin.rpc("service_rush_arena_start", { p_user_id: userId, p_level: level });
    if (error) return reply(500, { error: "A verified Rush Arena session could not be started." });
    if (!data?.ok) return reply(403, { error: data?.error || "This level is not unlocked." });
    return reply(200, data);
  }

  if (body.action === "progress") {
    const sessionId = String(body.session_id || "");
    const distance = Number(body.distance);
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(sessionId)
      || !Number.isFinite(distance)) return reply(400, { error: "Invalid Rush Arena progress checkpoint." });
    const { data, error } = await admin.rpc("service_rush_arena_checkpoint", {
      p_user_id: userId, p_session_id: sessionId, p_distance: distance,
    });
    if (error) return reply(500, { error: "Rush Arena progress could not be saved." });
    if (!data?.ok) return reply(400, { error: data?.error || "Progress checkpoint was rejected." });
    return reply(200, data);
  }

  if (body.action === "finish") {
    const sessionId = String(body.session_id || "");
    const elapsed = Number(body.elapsed_seconds);
    const obstacles = Number(body.obstacles_passed);
    const score = Number(body.score);
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(sessionId)
      || !Number.isInteger(elapsed) || !Number.isInteger(obstacles) || !Number.isInteger(score)) {
      return reply(400, { error: "Invalid Rush Arena completion data." });
    }
    const { data, error } = await admin.rpc("service_rush_arena_finish", {
      p_user_id: userId,
      p_session_id: sessionId,
      p_elapsed_seconds: elapsed,
      p_obstacles_passed: obstacles,
      p_score: score,
    });
    if (error) return reply(500, { error: "Rush Arena rewards could not be settled." });
    if (!data?.ok) return reply(400, { error: data?.error || "Rush Arena completion was rejected." });
    return reply(200, data);
  }

  return reply(400, { error: "Unknown Rush Arena action." });
});
