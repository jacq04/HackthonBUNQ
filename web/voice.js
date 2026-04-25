/* =========================================================
   pod. — realtime voice tour, powered by Gemini 2.5 Live
   - mints ephemeral auth token via /api/voice-token
   - opens a WebSocket directly to generativelanguage.googleapis.com
   - mic in: 16 kHz mono PCM (linear-16) sent in real time
   - audio out: 24 kHz mono PCM streamed via WebAudio
   - optional screen share: getDisplayMedia → JPEG frames @ 1 fps
   - tool calls: scrollToSection / openTheApp / endCall
   ========================================================= */

(() => {
  const TOOLS = [
    {
      name: "scrollToSection",
      description:
        "Scroll the page to one of pod.'s landing-page sections. Call this whenever the user wants to see a specific part of the site.",
      parameters: {
        type: "OBJECT",
        properties: {
          section: {
            type: "STRING",
            description:
              "Section anchor — one of: problem, planes, how, agents, ledger, safety, cta.",
          },
        },
        required: ["section"],
      },
    },
    {
      name: "openTheApp",
      description:
        "Move the user to the call-to-action section so they can open the app.",
      parameters: { type: "OBJECT", properties: {} },
    },
    {
      name: "endCall",
      description:
        "End the voice call. Only call this when the user clearly wants to stop.",
      parameters: { type: "OBJECT", properties: {} },
    },
  ];

  // ----------------- audio helpers -----------------

  // Float32 [-1,1] → Int16 PCM little-endian
  function float32ToPCM16(input) {
    const out = new Int16Array(input.length);
    for (let i = 0; i < input.length; i++) {
      const s = Math.max(-1, Math.min(1, input[i]));
      out[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
    }
    return out;
  }

  // ArrayBuffer → base64
  function abToBase64(ab) {
    const bytes = new Uint8Array(ab);
    let binary = "";
    const chunk = 0x8000;
    for (let i = 0; i < bytes.length; i += chunk) {
      binary += String.fromCharCode.apply(
        null,
        bytes.subarray(i, i + chunk)
      );
    }
    return btoa(binary);
  }

  // base64 → ArrayBuffer
  function base64ToAb(b64) {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out.buffer;
  }

  // ----------------- the client -----------------

  class PodVoice {
    constructor() {
      this.ws = null;
      this.state = "idle"; // idle | connecting | listening | speaking | error
      this.muted = false;

      // running buffers for streamed transcription deltas; flushed at turn end
      this.outBuf = "";
      this.inBuf = "";

      // mic capture
      this.micCtx = null;
      this.micStream = null;
      this.micNode = null;
      this.micSource = null;

      // audio playback (24 kHz mono PCM)
      this.outCtx = null;
      this.outQueueTime = 0;
      this.outAnalyser = null;
      this.levelRaf = 0;

      // screen share
      this.shareStream = null;
      this.shareTimer = 0;
      this.shareCanvas = null;
      this.shareCtx2d = null;
      this.shareVideo = null;

      this.listeners = {
        state: [],
        transcript: [],
        partial: [],
        level: [],
        share: [],
      };
    }

    on(event, fn) {
      if (this.listeners[event]) this.listeners[event].push(fn);
    }
    emit(event, payload) {
      (this.listeners[event] || []).forEach((fn) => fn(payload));
    }
    setState(s) {
      this.state = s;
      this.emit("state", s);
    }

    async start() {
      if (this.state !== "idle" && this.state !== "error") return;
      this.setState("connecting");
      try {
        // 1. fetch model + system prompt + proxy path from our CF function.
        //    The API key never reaches the browser — the proxy applies it
        //    server-side when opening the upstream Gemini Live WebSocket.
        const tokRes = await fetch("/api/voice-token", { method: "POST" });
        if (!tokRes.ok) {
          const txt = await tokRes.text();
          throw new Error(`token endpoint ${tokRes.status}: ${txt}`);
        }
        const session = await tokRes.json();
        const model = session.model;
        const proxyPath = session.proxy || "/api/voice-ws";
        this._systemInstructions = session.instructions || "";

        // 2. connect to our same-origin WebSocket proxy
        const wsScheme = location.protocol === "https:" ? "wss" : "ws";
        const wsUrl = `${wsScheme}://${location.host}${proxyPath}`;

        this.ws = new WebSocket(wsUrl);
        this.ws.onopen = () => this.onWsOpen(model);
        this.ws.onmessage = (e) => this.onWsMessage(e);
        this.ws.onerror = (e) => {
          console.warn("[PodVoice] ws error", e);
        };
        this.ws.onclose = (e) => {
          if (this.state !== "idle") {
            console.warn("[PodVoice] ws closed", e.code, e.reason);
            this.cleanup();
            if (e.code !== 1000) this.setState("error");
          }
        };
      } catch (err) {
        console.error("[PodVoice] start failed", err);
        this.emit("transcript", {
          role: "system",
          text: `couldn't connect: ${err.message}`,
        });
        this.setState("error");
        this.cleanup();
      }
    }

    async onWsOpen(model) {
      // setup message — most fields were pinned at token mint time, but the
      // server still expects a setup frame. We pass tools here.
      this.send({
        setup: {
          model: `models/${model}`,
          generation_config: {
            response_modalities: ["AUDIO"],
            speech_config: {
              voice_config: {
                prebuilt_voice_config: { voice_name: "Charon" },
              },
            },
          },
          tools: [{ function_declarations: TOOLS }],
          system_instruction: {
            parts: [{ text: this._systemInstructions || "" }],
          },
          input_audio_transcription: {},
          output_audio_transcription: {},
        },
      });

      // start mic capture
      try {
        await this.startMic();
        // ask the model to greet first
        this.send({
          client_content: {
            turns: [
              {
                role: "user",
                parts: [
                  {
                    text:
                      "Greet the user briefly as pod.'s voice tour and invite them to ask how a circle works or to share their screen.",
                  },
                ],
              },
            ],
            turn_complete: true,
          },
        });
        this.setState("listening");
      } catch (err) {
        console.error("[PodVoice] mic failed", err);
        this.emit("transcript", {
          role: "system",
          text: `mic blocked: ${err.message}`,
        });
        this.setState("error");
      }
    }

    onWsMessage(e) {
      // Live API sends Blob frames in the browser
      const handle = (text) => {
        let msg;
        try {
          msg = JSON.parse(text);
        } catch {
          return;
        }
        this.handleServerMessage(msg);
      };
      if (typeof e.data === "string") {
        handle(e.data);
      } else if (e.data instanceof Blob) {
        e.data.text().then(handle);
      }
    }

    handleServerMessage(msg) {
      // setupComplete — handshake done
      if (msg.setupComplete) {
        return;
      }

      // serverContent — turns from the model
      const sc = msg.serverContent;
      if (sc) {
        if (sc.modelTurn && Array.isArray(sc.modelTurn.parts)) {
          for (const part of sc.modelTurn.parts) {
            if (part.inlineData && part.inlineData.data) {
              // audio chunk — base64 PCM @ 24 kHz mono
              this.playPcmChunk(part.inlineData.data);
              this.setState("speaking");
            }
            // text parts on modelTurn are not used for native-audio voice,
            // but if a future model variant returns them, surface as a row.
            if (part.text) {
              this.emit("transcript", { role: "assistant", text: part.text });
            }
          }
        }
        // streamed transcription deltas — accumulate, flush on turn complete
        if (sc.outputTranscription && sc.outputTranscription.text) {
          this.outBuf += sc.outputTranscription.text;
          this.emit("partial", { role: "assistant", text: this.outBuf });
        }
        if (sc.inputTranscription && sc.inputTranscription.text) {
          this.inBuf += sc.inputTranscription.text;
          this.emit("partial", { role: "user", text: this.inBuf });
        }
        if (sc.turnComplete) {
          this.flushTranscriptBuffers();
          this.setState("listening");
        }
        if (sc.interrupted) {
          this.flushPlayback();
          this.flushTranscriptBuffers();
          this.setState("listening");
        }
      }

      // toolCall — function calls from the model
      if (msg.toolCall && Array.isArray(msg.toolCall.functionCalls)) {
        for (const fc of msg.toolCall.functionCalls) {
          this.handleToolCall(fc);
        }
      }
    }

    flushTranscriptBuffers() {
      if (this.inBuf.trim()) {
        this.emit("transcript", { role: "user", text: this.inBuf.trim() });
        this.inBuf = "";
      }
      if (this.outBuf.trim()) {
        this.emit("transcript", { role: "assistant", text: this.outBuf.trim() });
        this.outBuf = "";
      }
      this.emit("partial", null);
    }

    handleToolCall(fc) {
      const args = fc.args || {};
      let result = "ok";

      if (fc.name === "scrollToSection") {
        const target = document.getElementById(args.section);
        if (target) {
          target.scrollIntoView({ behavior: "smooth", block: "start" });
          result = `scrolled the user to ${args.section}`;
        } else {
          result = `section ${args.section} not found`;
        }
      } else if (fc.name === "openTheApp") {
        const cta = document.getElementById("cta");
        if (cta) cta.scrollIntoView({ behavior: "smooth", block: "start" });
        result = "opened the call-to-action section";
      } else if (fc.name === "endCall") {
        setTimeout(() => this.stop(), 800);
        result = "ending the call";
      } else {
        result = `unknown tool ${fc.name}`;
      }

      this.send({
        tool_response: {
          function_responses: [
            {
              id: fc.id,
              name: fc.name,
              response: { result },
            },
          ],
        },
      });
    }

    send(obj) {
      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify(obj));
      }
    }

    // ----------------- mic capture (16 kHz mono PCM) -----------------

    async startMic() {
      this.micStream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
          channelCount: 1,
        },
      });

      // AudioContext at 16 kHz lets the browser do native resampling.
      const Ctx = window.AudioContext || window.webkitAudioContext;
      this.micCtx = new Ctx({ sampleRate: 16000 });
      if (this.micCtx.state === "suspended") await this.micCtx.resume();

      this.micSource = this.micCtx.createMediaStreamSource(this.micStream);

      // ScriptProcessor is deprecated but ubiquitous; works for short demos.
      // 4096-sample buffer @ 16 kHz ≈ 256 ms — well within the 100 ms+ window
      // Live expects.
      const bufSize = 4096;
      this.micNode = this.micCtx.createScriptProcessor(bufSize, 1, 1);
      this.micNode.onaudioprocess = (e) => {
        if (this.muted) return;
        const input = e.inputBuffer.getChannelData(0);
        const pcm = float32ToPCM16(input);
        const b64 = abToBase64(pcm.buffer);
        this.send({
          realtime_input: {
            media_chunks: [{ mime_type: "audio/pcm;rate=16000", data: b64 }],
          },
        });
      };
      this.micSource.connect(this.micNode);
      this.micNode.connect(this.micCtx.destination); // required to flow
    }

    // ----------------- model audio playback (24 kHz mono PCM) -----------------

    ensureOutCtx() {
      if (this.outCtx) return;
      const Ctx = window.AudioContext || window.webkitAudioContext;
      this.outCtx = new Ctx({ sampleRate: 24000 });
      this.outQueueTime = 0;
      this.outAnalyser = this.outCtx.createAnalyser();
      this.outAnalyser.fftSize = 256;
      this.outAnalyser.connect(this.outCtx.destination);

      const buf = new Uint8Array(this.outAnalyser.frequencyBinCount);
      const tick = () => {
        if (!this.outAnalyser) return;
        this.outAnalyser.getByteFrequencyData(buf);
        let sum = 0;
        for (let i = 0; i < buf.length; i++) sum += buf[i];
        this.emit("level", Math.min(1, sum / buf.length / 80));
        this.levelRaf = requestAnimationFrame(tick);
      };
      tick();
    }

    playPcmChunk(b64) {
      this.ensureOutCtx();
      const ab = base64ToAb(b64);
      const view = new DataView(ab);
      const sampleCount = ab.byteLength / 2;
      const audioBuf = this.outCtx.createBuffer(1, sampleCount, 24000);
      const ch = audioBuf.getChannelData(0);
      for (let i = 0; i < sampleCount; i++) {
        const s = view.getInt16(i * 2, true);
        ch[i] = s / 0x8000;
      }
      const src = this.outCtx.createBufferSource();
      src.buffer = audioBuf;
      src.connect(this.outAnalyser);

      const now = this.outCtx.currentTime;
      const startAt = Math.max(now, this.outQueueTime);
      src.start(startAt);
      this.outQueueTime = startAt + audioBuf.duration;
    }

    flushPlayback() {
      if (this.outCtx) {
        try {
          this.outCtx.close();
        } catch {}
        this.outCtx = null;
        this.outAnalyser = null;
        cancelAnimationFrame(this.levelRaf);
        this.levelRaf = 0;
      }
    }

    // ----------------- screen share (JPEG @ 1 fps) -----------------

    async startScreenShare(videoEl) {
      if (this.shareStream) return true;
      try {
        this.shareStream = await navigator.mediaDevices.getDisplayMedia({
          video: { frameRate: 4 },
          audio: false,
        });
      } catch (err) {
        console.warn("[PodVoice] screen share denied", err);
        this.emit("transcript", {
          role: "system",
          text: "screen share was cancelled",
        });
        return false;
      }

      // user can stop sharing from the browser chrome
      const track = this.shareStream.getVideoTracks()[0];
      track.addEventListener("ended", () => this.stopScreenShare());

      this.shareVideo = videoEl;
      this.shareVideo.srcObject = this.shareStream;
      try {
        await this.shareVideo.play();
      } catch {}

      this.shareCanvas = document.createElement("canvas");
      this.shareCtx2d = this.shareCanvas.getContext("2d");

      this.shareTimer = setInterval(() => this.captureFrame(), 1000);
      this.emit("share", true);

      // tell the model
      this.send({
        client_content: {
          turns: [
            {
              role: "user",
              parts: [
                {
                  text:
                    "I just started sharing my screen. From now on you'll receive a frame every second. Use what you see when answering.",
                },
              ],
            },
          ],
          turn_complete: false,
        },
      });
      return true;
    }

    captureFrame() {
      if (!this.shareVideo || this.shareVideo.videoWidth === 0) return;
      // downscale to ~640px wide to keep payload small
      const targetW = 640;
      const ratio = this.shareVideo.videoWidth / this.shareVideo.videoHeight;
      const w = targetW;
      const h = Math.round(targetW / ratio);
      this.shareCanvas.width = w;
      this.shareCanvas.height = h;
      this.shareCtx2d.drawImage(this.shareVideo, 0, 0, w, h);
      const dataUrl = this.shareCanvas.toDataURL("image/jpeg", 0.7);
      const b64 = dataUrl.split(",")[1];
      this.send({
        realtime_input: {
          media_chunks: [{ mime_type: "image/jpeg", data: b64 }],
        },
      });
    }

    stopScreenShare() {
      if (this.shareTimer) {
        clearInterval(this.shareTimer);
        this.shareTimer = 0;
      }
      if (this.shareStream) {
        this.shareStream.getTracks().forEach((t) => t.stop());
        this.shareStream = null;
      }
      if (this.shareVideo) {
        this.shareVideo.srcObject = null;
      }
      this.shareCanvas = null;
      this.shareCtx2d = null;
      this.emit("share", false);
    }

    toggleMute() {
      this.muted = !this.muted;
      if (this.micStream) {
        for (const t of this.micStream.getAudioTracks())
          t.enabled = !this.muted;
      }
      return this.muted;
    }

    stop() {
      try {
        this.send({ client_content: { turn_complete: true } });
      } catch {}
      try {
        if (this.ws && this.ws.readyState === WebSocket.OPEN) this.ws.close(1000);
      } catch {}
      this.cleanup();
      this.setState("idle");
    }

    cleanup() {
      this.stopScreenShare();
      if (this.levelRaf) cancelAnimationFrame(this.levelRaf);
      this.levelRaf = 0;
      try {
        if (this.micNode) this.micNode.disconnect();
      } catch {}
      try {
        if (this.micSource) this.micSource.disconnect();
      } catch {}
      try {
        if (this.micCtx && this.micCtx.state !== "closed") this.micCtx.close();
      } catch {}
      try {
        if (this.outCtx && this.outCtx.state !== "closed") this.outCtx.close();
      } catch {}
      try {
        if (this.micStream) this.micStream.getTracks().forEach((t) => t.stop());
      } catch {}
      this.micNode = null;
      this.micSource = null;
      this.micCtx = null;
      this.outCtx = null;
      this.outAnalyser = null;
      this.micStream = null;
      this.ws = null;
    }
  }

  /* =========================================================
     UI wiring
     ========================================================= */
  function $(sel) {
    return document.querySelector(sel);
  }

  function init() {
    const btn = $("#voiceBtn");
    const modal = $("#voiceModal");
    const closeBtn = $("#voiceClose");
    const muteBtn = $("#voiceMute");
    const hangBtn = $("#voiceHang");
    const shareBtn = $("#voiceShare");
    const stateEl = $("#voiceState");
    const transcriptEl = $("#voiceTranscript");
    const orb = $("#voiceOrb");
    const shareVideo = $("#voiceShareVideo");

    if (!btn || !modal) return;

    const pv = new PodVoice();
    window.__podVoice = pv;

    function open() {
      modal.classList.add("is-open");
      document.body.classList.add("voice-locked");
      transcriptEl.innerHTML = "";
      pv.start();
    }
    function close() {
      modal.classList.remove("is-open");
      document.body.classList.remove("voice-locked");
      pv.stop();
    }

    btn.addEventListener("click", open);
    closeBtn.addEventListener("click", close);
    hangBtn.addEventListener("click", close);
    muteBtn.addEventListener("click", () => {
      const muted = pv.toggleMute();
      muteBtn.dataset.muted = muted ? "1" : "0";
      muteBtn.textContent = muted ? "unmute" : "mute";
    });

    shareBtn.addEventListener("click", async () => {
      if (shareBtn.dataset.sharing === "1") {
        pv.stopScreenShare();
      } else {
        await pv.startScreenShare(shareVideo);
      }
    });

    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && modal.classList.contains("is-open")) close();
    });

    pv.on("state", (s) => {
      const labels = {
        idle: "ready",
        connecting: "connecting…",
        listening: "listening",
        speaking: "speaking",
        error: "couldn't connect",
      };
      stateEl.textContent = labels[s] || s;
      modal.dataset.state = s;
    });

    pv.on("share", (active) => {
      shareBtn.dataset.sharing = active ? "1" : "0";
      shareBtn.textContent = active ? "stop sharing" : "share screen";
      modal.dataset.sharing = active ? "1" : "0";
    });

    function roleLabel(r) {
      return r === "assistant" ? "pod." : r === "user" ? "you" : "system";
    }

    // Track the live in-flight partial row per role so streamed deltas update
    // a single bubble instead of stacking new rows. On turn-complete the
    // committed `transcript` event removes the partial and appends a final row.
    const partials = { user: null, assistant: null };

    pv.on("transcript", (t) => {
      // commit: remove any open partial for this role; append a final row.
      if (partials[t.role] && partials[t.role].parentNode) {
        partials[t.role].remove();
      }
      partials[t.role] = null;

      const row = document.createElement("div");
      row.className = `vt vt--${t.role}`;
      row.innerHTML = `<span class="vt__role">${roleLabel(
        t.role
      )}</span><span class="vt__text"></span>`;
      row.querySelector(".vt__text").textContent = t.text;
      transcriptEl.appendChild(row);
      transcriptEl.scrollTop = transcriptEl.scrollHeight;
    });

    pv.on("partial", (p) => {
      if (p === null) {
        // turn ended — handled in 'transcript' commit
        return;
      }
      let row = partials[p.role];
      if (!row) {
        row = document.createElement("div");
        row.className = `vt vt--${p.role} vt--partial`;
        row.innerHTML = `<span class="vt__role">${roleLabel(
          p.role
        )}</span><span class="vt__text"></span>`;
        transcriptEl.appendChild(row);
        partials[p.role] = row;
      }
      row.querySelector(".vt__text").textContent = p.text;
      transcriptEl.scrollTop = transcriptEl.scrollHeight;
    });

    pv.on("level", (lvl) => {
      if (orb) orb.style.setProperty("--lvl", lvl.toFixed(3));
    });
  }

  if (document.readyState === "loading")
    document.addEventListener("DOMContentLoaded", init);
  else init();
})();
