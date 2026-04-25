// pod. — realtime voice tour, powered by Gemini 2.5 Live.
//
// This is the mobile counterpart of web/voice.js. It connects to the same
// CloudFlare Pages WebSocket proxy the website uses
// (wss://<host>/api/voice-ws), so the long-lived GEMINI_API_KEY never
// reaches the device. We mint nothing client-side — the server gives us
// back the model name + system prompt + proxy path; we open the WS and
// drive Gemini over it.
//
// Audio formats:
//   - Mic out → 16 kHz mono PCM-16 LE, base64 in `realtime_input.media_chunks`
//   - Model in → 24 kHz mono PCM-16 LE, base64 in `serverContent.modelTurn.parts[].inlineData.data`

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'env.dart';

/// One row of the live transcript.
class TranscriptRow {
  TranscriptRow({required this.role, required this.text, this.partial = false});
  final String role; // "assistant" | "user" | "system"
  final String text;
  final bool partial;
}

enum VoiceState { idle, connecting, listening, speaking, error }

class PodVoice extends ChangeNotifier {
  // ------- public observable state -------
  VoiceState state = VoiceState.idle;
  String? lastError;
  bool muted = false;

  /// Committed transcript rows in order of arrival.
  final List<TranscriptRow> transcript = [];

  /// Live in-flight rows by role — overwritten on each delta, removed on
  /// turnComplete (and the final text moved into [transcript]).
  TranscriptRow? partialAssistant;
  TranscriptRow? partialUser;

  /// 0..1 amplitude estimate of the model's outbound audio. Drives the orb.
  double level = 0;

  // ------- private wiring -------
  WebSocketChannel? _ws;
  StreamSubscription<dynamic>? _wsSub;
  String? _model;
  String? _instructions;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;

  bool _pcmInited = false;
  Timer? _levelDecay;

  // streaming buffers for transcription deltas
  final StringBuffer _outBuf = StringBuffer();
  final StringBuffer _inBuf = StringBuffer();

  void _setState(VoiceState s, {String? error}) {
    state = s;
    lastError = error;
    notifyListeners();
  }

  // ============================================================
  // start / stop
  // ============================================================

  Future<void> start() async {
    if (state != VoiceState.idle && state != VoiceState.error) return;
    _setState(VoiceState.connecting);

    try {
      // 1. fetch model + system prompt + proxy path
      final dio = Dio();
      final tokRes = await dio.post<Map<String, dynamic>>(
        '${Env.voiceBaseUrl}/api/voice-token',
        options: Options(
          responseType: ResponseType.json,
          validateStatus: (_) => true,
        ),
      );
      if (tokRes.statusCode != 200) {
        throw 'token endpoint ${tokRes.statusCode}: ${tokRes.data}';
      }
      final body = tokRes.data ?? <String, dynamic>{};
      _model = body['model'] as String?;
      _instructions = (body['instructions'] as String?) ?? '';
      final proxy = (body['proxy'] as String?) ?? '/api/voice-ws';
      if (_model == null) throw 'no model in token response';

      // 2. open the WebSocket. Force wss scheme.
      final base = Uri.parse(Env.voiceBaseUrl);
      final wsUri = Uri(
        scheme: base.scheme == 'http' ? 'ws' : 'wss',
        host: base.host,
        port: base.hasPort ? base.port : null,
        path: proxy,
      );
      _ws = WebSocketChannel.connect(wsUri);

      // 3. wait for the connection to be ready before sending setup
      await _ws!.ready;

      _wsSub = _ws!.stream.listen(
        _onWsMessage,
        onError: (e, _) {
          debugPrint('[PodVoice] ws error: $e');
        },
        onDone: () {
          debugPrint(
            '[PodVoice] ws closed: ${_ws?.closeCode} ${_ws?.closeReason}',
          );
          if (state != VoiceState.idle) {
            _setState(
              VoiceState.error,
              error: _ws?.closeReason ?? 'connection closed',
            );
            _cleanup();
          }
        },
      );

      // 4. setup frame — same shape as the web client
      _send({
        'setup': {
          'model': 'models/${_model!}',
          'generation_config': {
            'response_modalities': ['AUDIO'],
            'speech_config': {
              'voice_config': {
                'prebuilt_voice_config': {'voice_name': 'Charon'}
              }
            }
          },
          'tools': [
            {
              'function_declarations': [
                {
                  'name': 'navigateTo',
                  'description':
                      'Navigate the pod. mobile app to a route. Call this when the user asks to see a part of the app.',
                  'parameters': {
                    'type': 'OBJECT',
                    'properties': {
                      'route': {
                        'type': 'STRING',
                        'description':
                            'go_router path. One of: "/" (wallet), "/circles" (savings pods list), "/admin" (admin tools), "/find-circle" (matchmaker).'
                      }
                    },
                    'required': ['route']
                  }
                },
                {
                  'name': 'endCall',
                  'description':
                      'End the voice call. Only when the user clearly wants to stop talking.',
                  'parameters': {'type': 'OBJECT', 'properties': {}}
                },
              ]
            }
          ],
          'system_instruction': {
            'parts': [
              {'text': _instructions ?? ''}
            ]
          },
          'input_audio_transcription': <String, dynamic>{},
          'output_audio_transcription': <String, dynamic>{},
        }
      });

      // 5. provoke a first response so the model greets immediately
      _send({
        'client_content': {
          'turns': [
            {
              'role': 'user',
              'parts': [
                {
                  'text':
                      "Greet the user briefly as pod.'s voice tour and invite them to ask how a pod works."
                }
              ]
            }
          ],
          'turn_complete': true
        }
      });

      // 6. start mic + start PCM playback engine
      await _startMic();
      await _initPcmOut();

      _setState(VoiceState.listening);
    } catch (err) {
      debugPrint('[PodVoice] start failed: $err');
      _appendSystem("couldn't connect: $err");
      _setState(VoiceState.error, error: err.toString());
      await _cleanup();
    }
  }

  Future<void> stop() async {
    try {
      _send({
        'client_content': {'turn_complete': true}
      });
    } catch (_) {}
    try {
      await _ws?.sink.close(1000, 'client closed');
    } catch (_) {}
    await _cleanup();
    _setState(VoiceState.idle);
  }

  Future<void> _cleanup() async {
    _levelDecay?.cancel();
    _levelDecay = null;
    await _micSub?.cancel();
    _micSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    await _wsSub?.cancel();
    _wsSub = null;
    _ws = null;
    if (_pcmInited) {
      try {
        await FlutterPcmSound.release();
      } catch (_) {}
      _pcmInited = false;
    }
    _outBuf.clear();
    _inBuf.clear();
    partialAssistant = null;
    partialUser = null;
    level = 0;
  }

  // ============================================================
  // mic in (16 kHz PCM-16 → base64 → realtime_input)
  // ============================================================

  Future<void> _startMic() async {
    final hasPerm = await _recorder.hasPermission();
    if (!hasPerm) {
      throw 'microphone permission denied';
    }
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        // good defaults for voice
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
      ),
    );
    _micSub = stream.listen((chunk) {
      if (muted) return;
      if (_ws == null) return;
      final b64 = base64Encode(chunk);
      _send({
        'realtime_input': {
          'media_chunks': [
            {'mime_type': 'audio/pcm;rate=16000', 'data': b64}
          ]
        }
      });
    });
  }

  // ============================================================
  // model audio out (24 kHz PCM)
  // ============================================================

  Future<void> _initPcmOut() async {
    if (_pcmInited) return;
    await FlutterPcmSound.setup(sampleRate: 24000, channelCount: 1);
    _pcmInited = true;
  }

  Future<void> _playPcmChunk(String b64) async {
    if (!_pcmInited) await _initPcmOut();
    final bytes = base64Decode(b64);
    await FlutterPcmSound.feed(
      PcmArrayInt16(bytes: ByteData.sublistView(bytes)),
    );
    _bumpLevelFromBytes(bytes);
  }

  void _bumpLevelFromBytes(Uint8List bytes) {
    // crude RMS over the chunk to drive the orb
    final view = ByteData.sublistView(bytes);
    final n = bytes.length ~/ 2;
    if (n == 0) return;
    int sumSq = 0;
    for (var i = 0; i < n; i++) {
      final s = view.getInt16(i * 2, Endian.little);
      sumSq += s * s;
    }
    final rms = (sumSq / n);
    final lvl = (rms / 1.0e7).clamp(0.0, 1.0);
    level = (level * 0.4 + lvl * 0.6);
    _levelDecay?.cancel();
    _levelDecay = Timer(const Duration(milliseconds: 250), () {
      level *= 0.5;
      notifyListeners();
    });
    notifyListeners();
  }

  // ============================================================
  // server → client messages
  // ============================================================

  void _onWsMessage(dynamic data) {
    String text;
    if (data is String) {
      text = data;
    } else if (data is List<int>) {
      text = utf8.decode(data, allowMalformed: true);
    } else {
      text = data.toString();
    }

    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    if (msg['setupComplete'] != null) return;

    final sc = msg['serverContent'] as Map<String, dynamic>?;
    if (sc != null) {
      // model audio chunks
      final modelTurn = sc['modelTurn'] as Map<String, dynamic>?;
      if (modelTurn != null) {
        final parts = modelTurn['parts'] as List?;
        if (parts != null) {
          for (final p in parts) {
            final part = p as Map<String, dynamic>;
            final inline = part['inlineData'] as Map<String, dynamic>?;
            if (inline != null && inline['data'] is String) {
              _playPcmChunk(inline['data'] as String);
              if (state != VoiceState.speaking) {
                _setState(VoiceState.speaking);
              }
            }
          }
        }
      }

      // streamed transcription deltas
      final outT = sc['outputTranscription'] as Map<String, dynamic>?;
      if (outT != null && outT['text'] is String) {
        _outBuf.write(outT['text'] as String);
        partialAssistant = TranscriptRow(
          role: 'assistant',
          text: _outBuf.toString(),
          partial: true,
        );
        notifyListeners();
      }

      final inT = sc['inputTranscription'] as Map<String, dynamic>?;
      if (inT != null && inT['text'] is String) {
        _inBuf.write(inT['text'] as String);
        partialUser = TranscriptRow(
          role: 'user',
          text: _inBuf.toString(),
          partial: true,
        );
        notifyListeners();
      }

      if (sc['turnComplete'] == true) {
        _flushPartials();
        if (state == VoiceState.speaking) {
          _setState(VoiceState.listening);
        }
      }
      if (sc['interrupted'] == true) {
        _flushPartials();
        if (state == VoiceState.speaking) {
          _setState(VoiceState.listening);
        }
      }
    }

    // tool calls
    final toolCall = msg['toolCall'] as Map<String, dynamic>?;
    if (toolCall != null) {
      final calls = toolCall['functionCalls'] as List?;
      if (calls != null) {
        for (final c in calls) {
          _handleToolCall(c as Map<String, dynamic>);
        }
      }
    }
  }

  void _flushPartials() {
    if (_inBuf.toString().trim().isNotEmpty) {
      transcript.add(TranscriptRow(role: 'user', text: _inBuf.toString().trim()));
      _inBuf.clear();
    }
    if (_outBuf.toString().trim().isNotEmpty) {
      transcript.add(
        TranscriptRow(role: 'assistant', text: _outBuf.toString().trim()),
      );
      _outBuf.clear();
    }
    partialAssistant = null;
    partialUser = null;
    notifyListeners();
  }

  void _appendSystem(String text) {
    transcript.add(TranscriptRow(role: 'system', text: text));
    notifyListeners();
  }

  // ============================================================
  // tool dispatch
  // ============================================================

  void _handleToolCall(Map<String, dynamic> fc) {
    final name = fc['name'] as String?;
    final args = (fc['args'] as Map?)?.cast<String, dynamic>() ?? {};
    final id = fc['id'] as String?;
    String result = 'ok';

    switch (name) {
      case 'navigateTo':
        final route = args['route'] as String?;
        if (route == null || route.isEmpty) {
          result = 'no route provided';
        } else {
          final handler = onNavigate;
          if (handler != null) {
            handler(route);
            result = 'navigated to $route';
          } else {
            result = 'no navigation handler attached';
          }
        }
        break;
      case 'endCall':
        // schedule a clean stop after we acknowledge the call
        Future.delayed(const Duration(milliseconds: 600), stop);
        result = 'ending call';
        break;
      default:
        result = 'unknown tool $name';
    }

    _send({
      'tool_response': {
        'function_responses': [
          {
            'id': id,
            'name': name,
            'response': {'result': result},
          }
        ]
      }
    });
  }

  /// Wired by the UI: voice modal sets this so the navigateTo tool can
  /// drive go_router from inside this service without a tight coupling.
  void Function(String route)? onNavigate;

  // ============================================================
  // helpers
  // ============================================================

  void toggleMute() {
    muted = !muted;
    notifyListeners();
  }

  void _send(Map<String, dynamic> obj) {
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.sink.add(jsonEncode(obj));
    } catch (e) {
      debugPrint('[PodVoice] send failed: $e');
    }
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }
}
