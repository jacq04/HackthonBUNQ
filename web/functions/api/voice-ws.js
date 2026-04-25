// Cloudflare Pages Function — WebSocket proxy for Gemini Live API.
//
// The browser connects to wss://<host>/api/voice-ws.
// We open the upstream Gemini Live WebSocket on the server side using the
// long-lived GEMINI_API_KEY (so it never reaches the client) and pipe
// frames bidirectionally between the two sockets.
//
// Required env var: GEMINI_API_KEY

// Cloudflare's fetch() requires https:// (not wss://) for outbound WebSocket
// upgrades. The runtime detects the Upgrade header and switches protocols.
const UPSTREAM =
  "https://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent";

export async function onRequest({ request, env }) {
  if (request.headers.get("Upgrade") !== "websocket") {
    return new Response("expected websocket upgrade", { status: 426 });
  }

  const apiKey = env.GEMINI_API_KEY;
  if (!apiKey) {
    return new Response("GEMINI_API_KEY not configured", { status: 500 });
  }

  // 1. Open the upstream WebSocket to Gemini
  const upstreamUrl = `${UPSTREAM}?key=${encodeURIComponent(apiKey)}`;
  let upstreamResp;
  try {
    upstreamResp = await fetch(upstreamUrl, {
      headers: { Upgrade: "websocket" },
    });
  } catch (err) {
    // never echo the URL back — it contains the API key
    return new Response(
      `upstream fetch failed: ${String(err).split("?")[0]}`,
      { status: 502 }
    );
  }

  const upstream = upstreamResp.webSocket;
  if (!upstream) {
    return new Response(
      `upstream did not upgrade (status ${upstreamResp.status})`,
      { status: 502 }
    );
  }
  upstream.accept();

  // 2. Create the downstream pair for our caller
  const pair = new WebSocketPair();
  const client = pair[0];
  const server = pair[1];
  server.accept();

  // 3. Pipe both ways. Both sides forward strings as strings and binary as
  //    ArrayBuffers. The CF runtime sometimes hands us Blob/Buffer-like
  //    objects whose default string coercion is literally "[object Blob]" —
  //    so we have to unwrap them explicitly before forwarding.
  async function forward(target, data) {
    try {
      if (typeof data === "string") {
        target.send(data);
      } else if (data instanceof ArrayBuffer) {
        target.send(data);
      } else if (data && typeof data.arrayBuffer === "function") {
        target.send(await data.arrayBuffer());
      } else if (data && typeof data.text === "function") {
        target.send(await data.text());
      } else if (ArrayBuffer.isView(data)) {
        target.send(data.buffer);
      } else {
        // last resort
        target.send(String(data));
      }
    } catch (err) {
      // swallow; the close handler will cascade
    }
  }

  upstream.addEventListener("message", (e) => {
    forward(server, e.data);
  });
  upstream.addEventListener("close", (e) => {
    try {
      server.close(e.code, e.reason);
    } catch {}
  });
  upstream.addEventListener("error", () => {
    try {
      server.close(1011, "upstream error");
    } catch {}
  });

  server.addEventListener("message", (e) => {
    forward(upstream, e.data);
  });
  server.addEventListener("close", (e) => {
    try {
      upstream.close(e.code, e.reason);
    } catch {}
  });
  server.addEventListener("error", () => {
    try {
      upstream.close(1011, "client error");
    } catch {}
  });

  // 4. Return 101 with the client side of the pair
  return new Response(null, { status: 101, webSocket: client });
}
