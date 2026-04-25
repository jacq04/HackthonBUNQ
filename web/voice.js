/* =========================================================
   Kitty — realtime voice tour
   Browser-side WebRTC client for OpenAI Realtime API.
   - mints ephemeral token via /api/voice-token
   - opens RTCPeerConnection directly to OpenAI
   - mic in, model audio out
   - data channel for transcripts + tool calls
   ========================================================= */

(() => {
  const TOOLS = [
    {
      type: "function",
      name: "scrollToSection",
      description:
        "Scroll the page to one of Kitty's landing-page sections. Call this whenever the user wants to see a specific part of the site.",
      parameters: {
        type: "object",
        properties: {
          section: {
            type: "string",
            enum: [
              "problem",
              "planes",
              "how",
              "agents",
              "ledger",
              "safety",
              "cta",
            ],
            description:
              "The section anchor: problem (60% fail rate), planes (bunq/TigerBeetle/Claude), how (6-step lifecycle), agents (the crew), ledger (the live tape), safety (FaceID + atomic), cta (open the app).",
          },
        },
        required: ["section"],
      },
    },
    {
      type: "function",
      name: "openTheApp",
      description:
        "Move the user to the call-to-action section so they can open the app.",
      parameters: { type: "object", properties: {} },
    },
    {
      type: "function",
      name: "endCall",
      description:
        "End the voice call. Call this only when the user clearly wants to stop talking.",
      parameters: { type: "object", properties: {} },
    },
  ];

  class KittyVoice {
    constructor() {
      this.pc = null;
      this.dc = null;
      this.audioEl = null;
      this.localStream = null;
      this.muted = false;
      this.state = "idle"; // idle | connecting | listening | speaking | error
      this.listeners = { state: [], transcript: [], level: [] };
      this.audioCtx = null;
      this.analyser = null;
      this.levelRaf = 0;
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
        // 1. Mint ephemeral session token from our CF Pages function
        const tokRes = await fetch("/api/voice-token", { method: "POST" });
        if (!tokRes.ok) {
          const txt = await tokRes.text();
          throw new Error(`token endpoint ${tokRes.status}: ${txt}`);
        }
        const session = await tokRes.json();
        const ephemeralKey = session?.client_secret?.value;
        const model = session?.model || "gpt-realtime";
        if (!ephemeralKey) throw new Error("no client_secret in session");

        // 2. Peer connection
        this.pc = new RTCPeerConnection();

        // 3. Remote audio sink
        this.audioEl = document.createElement("audio");
        this.audioEl.autoplay = true;
        this.audioEl.playsInline = true;
        this.pc.ontrack = (e) => {
          this.audioEl.srcObject = e.streams[0];
          this.attachLevelMeter(e.streams[0]);
        };

        // 4. Local mic
        this.localStream = await navigator.mediaDevices.getUserMedia({
          audio: {
            echoCancellation: true,
            noiseSuppression: true,
            autoGainControl: true,
          },
        });
        for (const track of this.localStream.getTracks()) {
          this.pc.addTrack(track, this.localStream);
        }

        // 5. Data channel for events (must be created BEFORE the offer)
        this.dc = this.pc.createDataChannel("oai-events");
        this.dc.onopen = () => this.onChannelOpen();
        this.dc.onmessage = (e) => this.onChannelEvent(e);

        // 6. SDP exchange directly with OpenAI
        const offer = await this.pc.createOffer();
        await this.pc.setLocalDescription(offer);

        const sdpRes = await fetch(
          `https://api.openai.com/v1/realtime?model=${encodeURIComponent(
            model
          )}`,
          {
            method: "POST",
            body: offer.sdp,
            headers: {
              Authorization: `Bearer ${ephemeralKey}`,
              "Content-Type": "application/sdp",
            },
          }
        );
        if (!sdpRes.ok) {
          const errText = await sdpRes.text();
          throw new Error(`sdp ${sdpRes.status}: ${errText}`);
        }
        const answer = { type: "answer", sdp: await sdpRes.text() };
        await this.pc.setRemoteDescription(answer);

        // wait for the data channel to open before declaring connected
      } catch (err) {
        console.error("[KittyVoice] start failed", err);
        this.emit("transcript", {
          role: "system",
          text: `couldn't connect: ${err.message}`,
        });
        this.setState("error");
        this.cleanup();
      }
    }

    onChannelOpen() {
      // Configure session: register our tools, ask for user transcripts
      this.send({
        type: "session.update",
        session: {
          tools: TOOLS,
          tool_choice: "auto",
        },
      });
      // Kick off the model so it greets first
      this.send({
        type: "response.create",
        response: {
          modalities: ["audio", "text"],
          instructions:
            "Greet the user briefly as Kitty's voice tour and invite them to ask how it works.",
        },
      });
      this.setState("listening");
    }

    onChannelEvent(e) {
      let ev;
      try {
        ev = JSON.parse(e.data);
      } catch {
        return;
      }
      switch (ev.type) {
        case "session.created":
        case "session.updated":
          break;

        case "input_audio_buffer.speech_started":
          this.setState("listening");
          break;
        case "input_audio_buffer.speech_stopped":
          // model will respond
          break;

        case "response.created":
          this.setState("speaking");
          break;
        case "response.done":
          this.setState("listening");
          break;

        case "response.audio_transcript.delta":
          // streaming partial — could show live; we wait for done
          break;
        case "response.audio_transcript.done":
          if (ev.transcript)
            this.emit("transcript", {
              role: "assistant",
              text: ev.transcript,
            });
          break;

        case "conversation.item.input_audio_transcription.completed":
          if (ev.transcript)
            this.emit("transcript", { role: "user", text: ev.transcript });
          break;

        case "response.function_call_arguments.done":
          this.handleToolCall(ev);
          break;

        case "error":
          console.warn("[KittyVoice] server error", ev);
          this.emit("transcript", {
            role: "system",
            text: `(${ev.error?.message || "server error"})`,
          });
          break;
      }
    }

    handleToolCall(ev) {
      let args = {};
      try {
        args = JSON.parse(ev.arguments || "{}");
      } catch {}
      let result = "ok";

      if (ev.name === "scrollToSection") {
        const target = document.getElementById(args.section);
        if (target) {
          target.scrollIntoView({ behavior: "smooth", block: "start" });
          result = `scrolled the user to ${args.section}`;
        } else {
          result = `section ${args.section} not found on the page`;
        }
      } else if (ev.name === "openTheApp") {
        const cta = document.getElementById("cta");
        if (cta) cta.scrollIntoView({ behavior: "smooth", block: "start" });
        result = "opened the call-to-action section";
      } else if (ev.name === "endCall") {
        setTimeout(() => this.stop(), 800);
        result = "ending the call";
      } else {
        result = `unknown tool ${ev.name}`;
      }

      // send result back
      this.send({
        type: "conversation.item.create",
        item: {
          type: "function_call_output",
          call_id: ev.call_id,
          output: JSON.stringify(result),
        },
      });
      this.send({ type: "response.create" });
    }

    send(obj) {
      if (this.dc && this.dc.readyState === "open")
        this.dc.send(JSON.stringify(obj));
    }

    toggleMute() {
      this.muted = !this.muted;
      if (this.localStream) {
        for (const t of this.localStream.getAudioTracks())
          t.enabled = !this.muted;
      }
      return this.muted;
    }

    /* visualize remote audio level for the orb */
    attachLevelMeter(stream) {
      try {
        if (!this.audioCtx)
          this.audioCtx = new (window.AudioContext ||
            window.webkitAudioContext)();
        if (this.audioCtx.state === "suspended") this.audioCtx.resume();
        const src = this.audioCtx.createMediaStreamSource(stream);
        this.analyser = this.audioCtx.createAnalyser();
        this.analyser.fftSize = 256;
        src.connect(this.analyser);
        const buf = new Uint8Array(this.analyser.frequencyBinCount);
        const tick = () => {
          if (!this.analyser) return;
          this.analyser.getByteFrequencyData(buf);
          let sum = 0;
          for (let i = 0; i < buf.length; i++) sum += buf[i];
          const lvl = Math.min(1, sum / buf.length / 80);
          this.emit("level", lvl);
          this.levelRaf = requestAnimationFrame(tick);
        };
        tick();
      } catch (e) {
        console.warn("[KittyVoice] level meter failed", e);
      }
    }

    stop() {
      this.cleanup();
      this.setState("idle");
    }

    cleanup() {
      if (this.levelRaf) cancelAnimationFrame(this.levelRaf);
      this.levelRaf = 0;
      this.analyser = null;
      try {
        if (this.localStream)
          this.localStream.getTracks().forEach((t) => t.stop());
      } catch {}
      try {
        if (this.dc) this.dc.close();
      } catch {}
      try {
        if (this.pc) this.pc.close();
      } catch {}
      this.localStream = null;
      this.dc = null;
      this.pc = null;
      if (this.audioEl) {
        this.audioEl.srcObject = null;
        this.audioEl = null;
      }
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
    const stateEl = $("#voiceState");
    const transcriptEl = $("#voiceTranscript");
    const orb = $("#voiceOrb");

    if (!btn || !modal) return;

    const kv = new KittyVoice();
    window.__kittyVoice = kv;

    function open() {
      modal.classList.add("is-open");
      document.body.classList.add("voice-locked");
      transcriptEl.innerHTML = "";
      kv.start();
    }
    function close() {
      modal.classList.remove("is-open");
      document.body.classList.remove("voice-locked");
      kv.stop();
    }

    btn.addEventListener("click", open);
    closeBtn.addEventListener("click", close);
    hangBtn.addEventListener("click", close);
    muteBtn.addEventListener("click", () => {
      const muted = kv.toggleMute();
      muteBtn.dataset.muted = muted ? "1" : "0";
      muteBtn.textContent = muted ? "unmute" : "mute";
    });
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && modal.classList.contains("is-open")) close();
    });

    kv.on("state", (s) => {
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

    kv.on("transcript", (t) => {
      const row = document.createElement("div");
      row.className = `vt vt--${t.role}`;
      row.innerHTML = `<span class="vt__role">${
        t.role === "assistant" ? "kitty" : t.role === "user" ? "you" : "system"
      }</span><span class="vt__text"></span>`;
      row.querySelector(".vt__text").textContent = t.text;
      transcriptEl.appendChild(row);
      transcriptEl.scrollTop = transcriptEl.scrollHeight;
    });

    kv.on("level", (lvl) => {
      if (orb) orb.style.setProperty("--lvl", lvl.toFixed(3));
    });
  }

  if (document.readyState === "loading")
    document.addEventListener("DOMContentLoaded", init);
  else init();
})();
