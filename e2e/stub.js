// Scripted OpenAI-compatible model stub for the e2e test (local only).
// Deterministic stand-in for an LLM: turn 1 calls a shell-ish tool with
// `git commit` (which the real plugin hook must block with a message
// mentioning `git vc`); later turns echo the tool result back verbatim.
// The `git vc` string in the final output therefore always originates from
// the REAL hook error, never from canned text.
"use strict"
const http = require("node:http");

function pickShellTool(tools) {
  const fns = (tools || []).filter((t) => t && t.type === "function");
  return (
    fns.find((t) => /bash|shell|exec|command/i.test(t.function.name || "")) ||
    fns[0]
  );
}

function buildArgs(fn) {
  const props = ((fn.parameters || {}).properties) || {};
  const required = ((fn.parameters || {}).required) || Object.keys(props);
  const args = {};
  for (const key of required) {
    if (!(key in props)) continue;
    if (/command|cmd|script|code|text|input|query/i.test(key)) {
      args[key] = 'git commit -m "e2e test"';
    } else if (props[key] && props[key].type === "integer") {
      args[key] = 60;
    } else if (props[key] && props[key].type === "boolean") {
      args[key] = false;
    } else {
      args[key] = "e2e";
    }
  }
  return args;
}

const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    const url = new URL(req.url, "http://x");
    if (url.pathname === "/v1/models") {
      res.setHeader("Content-Type", "application/json");
      res.end(
        JSON.stringify({
          object: "list",
          data: [{ id: "e2e-stub", object: "model" }],
        })
      );
      return;
    }
    if (url.pathname !== "/v1/chat/completions") {
      res.statusCode = 404;
      res.end("{}");
      return;
    }
    const payload = JSON.parse(body);
    const sse = (chunks) => {
      res.setHeader("Content-Type", "text/event-stream");
      res.setHeader("Cache-Control", "no-cache");
      res.setHeader("Connection", "keep-alive");
      for (const c of chunks) {
        res.write(`data: ${JSON.stringify(c)}\n\n`);
      }
      res.write("data: [DONE]\n\n");
      res.end();
    };
    const chunk = (id, delta, finish) => ({
      id,
      object: "chat.completion.chunk",
      created: 1,
      model: "e2e-stub",
      choices: [{ index: 0, delta, finish_reason: finish || null }],
    });
    const hasToolResult = (payload.messages || []).some(
      (m) => m.role === "tool"
    );
    if (!hasToolResult) {
      const tool = pickShellTool(payload.tools);
      if (!tool) {
        sse([
          chunk(
            "c0",
            { role: "assistant", content: "NO_TOOLS_AVAILABLE" },
            "stop"
          ),
        ]);
        return;
      }
      const fn = tool.function;
      sse([
        chunk(
          "c1",
          {
            role: "assistant",
            content: null,
            tool_calls: [
              {
                index: 0,
                id: "call_1",
                type: "function",
                function: {
                  name: fn.name,
                  arguments: JSON.stringify(buildArgs(fn)),
                },
              },
            ],
          },
          null
        ),
        chunk("c1", {}, "tool_calls"),
      ]);
      return;
    }
    const last = JSON.stringify(payload.messages.slice(-1)).slice(0, 3000);
    sse([
      chunk(
        "c2",
        { role: "assistant", content: `TOOL_RESULT_WAS: ${last}` },
        null
      ),
      chunk("c2", {}, "stop"),
    ]);
  });
});

const port = Number(process.argv[2] || "18081");
server.listen(port, "127.0.0.1", () => console.log(`STUB_UP ${port}`));
