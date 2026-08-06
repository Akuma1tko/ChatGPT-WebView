import { createClient } from "@supabase/supabase-js";

type JsonRecord = Record<string, unknown>;

type MemoryRequest = {
  action: string;
  project_id?: string;
  session_id?: string;
  name?: string;
  title?: string;
  content?: string;
  summary?: string;
  raw_context?: string;
  source?: string;
  query?: string;
  tags?: string[];
  decisions?: string[];
  open_tasks?: string[];
  files_discussed?: string[];
  next_steps?: string[];
  importance?: number;
  is_pinned?: boolean;
  metadata?: JsonRecord;
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};

const allowedSessionSources = new Set(["app", "chatgpt_web", "github", "document", "manual"]);
const rawChunkSize = 7000;
const memoryPreviewLimit = 60000;
const summaryPreviewLimit = 1800;

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json"
    }
  });
}

function requireString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`Missing required field: ${field}`);
  }
  return value.trim();
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value
    .filter((item): item is string => typeof item === "string")
    .map((item) => item.trim())
    .filter((item) => item.length > 0);
}

function clampImportance(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return 3;
  }
  return Math.min(Math.max(Math.round(value), 1), 5);
}

function uniqueTags(value: unknown, requiredTags: string[] = []): string[] {
  const tags = asStringArray(value).map((tag) => tag.toLowerCase());
  for (const required of requiredTags) {
    if (!tags.includes(required)) {
      tags.push(required);
    }
  }
  return [...new Set(tags)].slice(0, 12);
}

function normalizeSessionSource(value: unknown): string {
  if (typeof value !== "string") {
    return "chatgpt_web";
  }
  const source = value.trim().toLowerCase();
  return allowedSessionSources.has(source) ? source : "chatgpt_web";
}

function truncateText(value: string, limit: number): string {
  if (value.length <= limit) {
    return value;
  }
  return `${value.slice(0, limit)}\n\n[truncated; full context stored in memory_messages chunks]`;
}

function chunkText(value: string, chunkSize = rawChunkSize): string[] {
  const chunks: string[] = [];
  for (let index = 0; index < value.length; index += chunkSize) {
    chunks.push(value.slice(index, index + chunkSize));
  }
  return chunks.length > 0 ? chunks : [value];
}

function appendSection(sections: string[], title: string, values: string[]) {
  if (values.length === 0) return;
  sections.push(`${title}:\n${values.map((item) => `- ${item}`).join("\n")}`);
}

function approvedContextContent(body: MemoryRequest, importance: number): string {
  const sections: string[] = [];
  sections.push(requireString(body.summary ?? body.content, "summary"));
  appendSection(sections, "Decisions", asStringArray(body.decisions));
  appendSection(sections, "Open tasks", asStringArray(body.open_tasks));
  appendSection(sections, "Files discussed", asStringArray(body.files_discussed));
  appendSection(sections, "Next steps", asStringArray(body.next_steps));
  sections.push(`Importance: ${importance}/5`);
  sections.push("Source: mcp.save_context_after_approval");
  return sections.join("\n\n");
}

function importedContextSummary(title: string, importedText: string, source: string, chunkCount: number): string {
  const preview = truncateText(importedText, summaryPreviewLimit);
  return [
    `Imported approved context for: ${title}`,
    `Source: ${source}`,
    `Imported context length: ${importedText.length} characters`,
    `Stored chunks: ${chunkCount}`,
    "",
    "Preview:",
    preview
  ].join("\n");
}

function importedMemoryContent(importedText: string, source: string, chunkCount: number, importance: number): string {
  return [
    "Imported session context approved by the user.",
    `Source: ${source}`,
    `Stored chunks: ${chunkCount}`,
    `Importance: ${importance}/5`,
    "Source: mcp.import_session_after_approval",
    "",
    "Context:",
    truncateText(importedText, memoryPreviewLimit)
  ].join("\n");
}

async function insertToolEvent(
  supabase: ReturnType<typeof createClient>,
  body: MemoryRequest,
  status: "ok" | "error",
  response: JsonRecord,
  error?: string
) {
  const textLength = typeof body.raw_context === "string"
    ? body.raw_context.length
    : typeof body.content === "string" ? body.content.length : 0;

  const { data } = await supabase
    .from("memory_tool_events")
    .insert({
      project_id: body.project_id ?? null,
      session_id: body.session_id ?? null,
      action: body.action,
      status,
      request: {
        title: body.title ?? null,
        tags: body.tags ?? [],
        source: body.source ?? null,
        importance: body.importance ?? null,
        has_summary: typeof body.summary === "string" && body.summary.trim().length > 0,
        imported_text_length: textLength,
        decisions_count: asStringArray(body.decisions).length,
        open_tasks_count: asStringArray(body.open_tasks).length,
        files_discussed_count: asStringArray(body.files_discussed).length,
        next_steps_count: asStringArray(body.next_steps).length
      },
      response,
      error: error ?? null
    })
    .select("id,project_id,session_id,action,status,created_at")
    .single();

  return data ?? null;
}

async function importApprovedSession(
  supabase: ReturnType<typeof createClient>,
  body: MemoryRequest
): Promise<Response> {
  const project_id = requireString(body.project_id, "project_id");
  const title = requireString(body.title, "title");
  const importedText = requireString(body.raw_context ?? body.content, "content");
  const source = normalizeSessionSource(body.source);
  const importance = clampImportance(body.importance);
  const tags = uniqueTags(body.tags, ["session-import", "approved-import"]);
  const chunks = chunkText(importedText);
  const metadata = {
    ...(body.metadata ?? {}),
    approved: true,
    source,
    tool_name: "import_session_after_approval",
    imported_text_length: importedText.length,
    chunk_count: chunks.length
  };

  const { data: session, error: sessionError } = await supabase
    .from("memory_sessions")
    .insert({
      project_id,
      title,
      source,
      metadata
    })
    .select("id,project_id,title,source,external_ref,started_at,ended_at")
    .single();

  if (sessionError) throw sessionError;

  const messageRows = chunks.map((chunk, index) => ({
    project_id,
    session_id: session.id,
    role: "note",
    content: chunk,
    token_estimate: Math.ceil(chunk.length / 4),
    metadata: {
      chunk_index: index,
      chunk_count: chunks.length,
      source,
      tool_name: "import_session_after_approval"
    }
  }));

  const { data: messages, error: messagesError } = await supabase
    .from("memory_messages")
    .insert(messageRows)
    .select("id");

  if (messagesError) throw messagesError;

  const memoryContent = importedMemoryContent(importedText, source, chunks.length, importance);
  const { data: memory, error: memoryError } = await supabase
    .from("memory_items")
    .insert({
      project_id,
      source_session_id: session.id,
      title,
      content: memoryContent,
      tags,
      importance,
      is_pinned: body.is_pinned === true,
      metadata
    })
    .select("id,project_id,title,content,tags,importance,is_pinned,created_at,updated_at")
    .single();

  if (memoryError) throw memoryError;

  const summary = typeof body.summary === "string" && body.summary.trim().length > 0
    ? body.summary.trim()
    : importedContextSummary(title, importedText, source, chunks.length);

  const { data: sessionSummary, error: summaryError } = await supabase
    .from("memory_session_summaries")
    .insert({
      project_id,
      session_id: session.id,
      summary,
      decisions: asStringArray(body.decisions),
      open_tasks: asStringArray(body.open_tasks),
      files_discussed: asStringArray(body.files_discussed),
      next_steps: asStringArray(body.next_steps),
      importance,
      metadata
    })
    .select("id,project_id,session_id,summary,decisions,open_tasks,files_discussed,next_steps,importance,created_at")
    .single();

  if (summaryError) throw summaryError;

  const response = {
    saved: true,
    project_id,
    session_id: session.id,
    message_count: messages?.length ?? chunks.length,
    memory_item_id: memory.id,
    session_summary_id: sessionSummary.id,
    tool_name: "import_session_after_approval"
  };
  const toolEvent = await insertToolEvent(
    supabase,
    { ...body, session_id: session.id },
    "ok",
    response
  );

  return jsonResponse({
    ...response,
    session,
    memory,
    session_summary: sessionSummary,
    tool_event: toolEvent
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Use POST" }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const authorization = req.headers.get("Authorization");

  if (!supabaseUrl || !supabaseAnonKey) {
    return jsonResponse({ error: "Supabase environment is not configured" }, 500);
  }

  if (!authorization) {
    return jsonResponse({ error: "Missing Authorization header" }, 401);
  }

  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: {
      headers: {
        Authorization: authorization
      }
    }
  });

  const body = (await req.json()) as MemoryRequest;
  const action = requireString(body.action, "action");

  const { data: userData, error: userError } = await supabase.auth.getUser();
  if (userError || !userData.user) {
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  try {
    switch (action) {
      case "create_project": {
        const name = requireString(body.name, "name");
        const { data, error } = await supabase
          .from("memory_projects")
          .insert({
            name,
            description: typeof body.content === "string" ? body.content : null,
            metadata: body.metadata ?? {}
          })
          .select()
          .single();

        if (error) throw error;
        return jsonResponse({ project: data });
      }

      case "list_projects": {
        const { data, error } = await supabase
          .from("memory_projects")
          .select("id,name,description,status,repo_url,metadata,created_at,updated_at")
          .order("updated_at", { ascending: false });

        if (error) throw error;
        return jsonResponse({ projects: data ?? [] });
      }

      case "create_session": {
        const project_id = requireString(body.project_id, "project_id");
        const title = requireString(body.title ?? body.name, "title");
        const { data, error } = await supabase
          .from("memory_sessions")
          .insert({
            project_id,
            title,
            source: "app",
            metadata: body.metadata ?? {}
          })
          .select()
          .single();

        if (error) throw error;
        return jsonResponse({ session: data });
      }

      case "save_memory": {
        const project_id = requireString(body.project_id, "project_id");
        const title = requireString(body.title, "title");
        const content = requireString(body.content, "content");
        const { data, error } = await supabase
          .from("memory_items")
          .insert({
            project_id,
            source_session_id: body.session_id ?? null,
            title,
            content,
            tags: asStringArray(body.tags),
            importance: clampImportance(body.importance),
            is_pinned: body.is_pinned === true,
            metadata: body.metadata ?? {}
          })
          .select()
          .single();

        if (error) throw error;
        return jsonResponse({ memory: data });
      }

      case "save_context_after_approval": {
        const project_id = requireString(body.project_id, "project_id");
        const title = requireString(body.title, "title");
        const summary = requireString(body.summary ?? body.content, "summary");
        const importance = clampImportance(body.importance);
        const tags = uniqueTags(body.tags, ["mcp", "approved-save"]);
        const content = approvedContextContent(body, importance);
        const metadata = {
          ...(body.metadata ?? {}),
          approved: true,
          source: "mcp",
          tool_name: "save_context_after_approval"
        };

        const { data: memory, error: memoryError } = await supabase
          .from("memory_items")
          .insert({
            project_id,
            source_session_id: body.session_id ?? null,
            title,
            content,
            tags,
            importance,
            is_pinned: body.is_pinned === true,
            metadata
          })
          .select("id,project_id,title,content,tags,importance,is_pinned,created_at,updated_at")
          .single();

        if (memoryError) throw memoryError;

        const { data: sessionSummary, error: summaryError } = await supabase
          .from("memory_session_summaries")
          .insert({
            project_id,
            session_id: body.session_id ?? null,
            summary,
            decisions: asStringArray(body.decisions),
            open_tasks: asStringArray(body.open_tasks),
            files_discussed: asStringArray(body.files_discussed),
            next_steps: asStringArray(body.next_steps),
            importance,
            metadata
          })
          .select("id,project_id,session_id,summary,decisions,open_tasks,files_discussed,next_steps,importance,created_at")
          .single();

        if (summaryError) throw summaryError;

        const response = {
          saved: true,
          project_id,
          memory_item_id: memory.id,
          session_summary_id: sessionSummary.id,
          tool_name: "save_context_after_approval"
        };
        const toolEvent = await insertToolEvent(supabase, body, "ok", response);

        return jsonResponse({
          ...response,
          memory,
          session_summary: sessionSummary,
          tool_event: toolEvent
        });
      }

      case "ingest_context_after_approval":
      case "import_session_after_approval": {
        return await importApprovedSession(supabase, body);
      }

      case "search_memory": {
        const project_id = requireString(body.project_id, "project_id");
        const query = requireString(body.query, "query");
        const pattern = `%${query.replaceAll("%", "\\%").replaceAll("_", "\\_")}%`;

        const { data, error } = await supabase
          .from("memory_items")
          .select("id,project_id,title,content,tags,importance,is_pinned,created_at,updated_at")
          .eq("project_id", project_id)
          .or(`title.ilike.${pattern},content.ilike.${pattern}`)
          .order("is_pinned", { ascending: false })
          .order("importance", { ascending: false })
          .order("updated_at", { ascending: false })
          .limit(20);

        if (error) throw error;
        return jsonResponse({ memories: data ?? [] });
      }

      case "save_session_summary": {
        const project_id = requireString(body.project_id, "project_id");
        const summary = requireString(body.summary ?? body.content, "summary");
        const { data, error } = await supabase
          .from("memory_session_summaries")
          .insert({
            project_id,
            session_id: body.session_id ?? null,
            summary,
            decisions: asStringArray(body.decisions),
            open_tasks: asStringArray(body.open_tasks),
            files_discussed: asStringArray(body.files_discussed),
            next_steps: asStringArray(body.next_steps),
            importance: clampImportance(body.importance),
            metadata: body.metadata ?? {}
          })
          .select()
          .single();

        if (error) throw error;
        return jsonResponse({ session_summary: data });
      }

      case "get_project_context": {
        const project_id = requireString(body.project_id, "project_id");

        const [projectResult, summariesResult, memoriesResult, artifactsResult] = await Promise.all([
          supabase
            .from("memory_projects")
            .select("id,name,description,status,repo_url,metadata,updated_at")
            .eq("id", project_id)
            .single(),
          supabase
            .from("memory_session_summaries")
            .select("id,summary,decisions,open_tasks,files_discussed,next_steps,importance,created_at")
            .eq("project_id", project_id)
            .order("created_at", { ascending: false })
            .limit(5),
          supabase
            .from("memory_items")
            .select("id,title,content,tags,importance,is_pinned,updated_at")
            .eq("project_id", project_id)
            .order("is_pinned", { ascending: false })
            .order("importance", { ascending: false })
            .order("updated_at", { ascending: false })
            .limit(25),
          supabase
            .from("memory_artifacts")
            .select("id,name,artifact_type,url_or_path,notes,created_at")
            .eq("project_id", project_id)
            .order("created_at", { ascending: false })
            .limit(10)
        ]);

        if (projectResult.error) throw projectResult.error;
        if (summariesResult.error) throw summariesResult.error;
        if (memoriesResult.error) throw memoriesResult.error;
        if (artifactsResult.error) throw artifactsResult.error;

        return jsonResponse({
          project: projectResult.data,
          summaries: summariesResult.data ?? [],
          memories: memoriesResult.data ?? [],
          artifacts: artifactsResult.data ?? []
        });
      }

      default:
        return jsonResponse({ error: `Unknown action: ${action}` }, 400);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown error";
    try {
      await insertToolEvent(supabase, body, "error", {}, message);
    } catch {
      // Do not hide the original error if audit logging fails.
    }
    return jsonResponse({ error: message }, 400);
  }
});
