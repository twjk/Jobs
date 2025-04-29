import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import '../services/xiaozhi_websocket_manager.dart';
import '../utils/audio_util.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../services/ota_service.dart';

/// 小智服务事件类型
enum XiaozhiServiceEventType {
  connected,
  disconnected,
  textMessage,
  audioData,
  error,
  voiceCallStart,
  voiceCallEnd,
  userMessage,
  activationCode,
  activationRequired,
}

/// 小智服务事件
class XiaozhiServiceEvent {
  final XiaozhiServiceEventType type;
  final dynamic data;

  XiaozhiServiceEvent(this.type, this.data);
}

/// 小智服务监听器
typedef XiaozhiServiceListener = void Function(XiaozhiServiceEvent event);

/// 消息监听器
typedef MessageListener = void Function(dynamic message);

class XiaozhiService {
  static const String TAG = "XiaozhiService";
  static const String DEFAULT_SERVER = "wss://ws.xiaozhi.ai";

  final String websocketUrl;
  late String macAddress;
  final String token;
  final String otaUrl;
  final String _deviceId; // 设备ID
  String? _sessionId; // 会话ID将由服务器提供

  XiaozhiWebSocketManager? _webSocketManager;
  bool _isConnected = false;
  bool _isMuted = false;
  final List<XiaozhiServiceListener> _listeners = [];
  StreamSubscription? _audioStreamSubscription;
  bool _isVoiceCallActive = false;
  WebSocketChannel? _ws;
  bool _hasStartedCall = false;
  MessageListener? _messageListener;

  XiaozhiService({
    required this.websocketUrl,
    required String macAddress,
    required this.token,
    String? sessionId,
    required this.otaUrl,
  }) : _deviceId = macAddress {
    // 强制格式化macAddress为单播
    this.macAddress = OtaService.formatMacAddress(macAddress);
    _sessionId = sessionId;
    _init();
  }

  /// 切换到语音通话模式
  Future<void> switchToVoiceCallMode() async {
    // 如果已经在语音通话模式，直接返回
    if (_isVoiceCallActive) return;

    try {
      print('$TAG: 正在切换到语音通话模式');

      // 简化初始化流程，确保干净状态
      await AudioUtil.stopPlaying();
      await AudioUtil.initRecorder();
      await AudioUtil.initPlayer();

      _isVoiceCallActive = true;
      print('$TAG: 已切换到语音通话模式');
    } catch (e) {
      print('$TAG: 切换到语音通话模式失败: $e');
      rethrow;
    }
  }

  /// 切换到普通聊天模式
  Future<void> switchToChatMode() async {
    // 如果已经在普通聊天模式，直接返回
    if (!_isVoiceCallActive) return;

    try {
      print('$TAG: 正在切换到普通聊天模式');

      // 停止语音通话相关的活动
      await stopListeningCall();

      // 确保播放器停止
      await AudioUtil.stopPlaying();

      _isVoiceCallActive = false;
      print('$TAG: 已切换到普通聊天模式');
    } catch (e) {
      print('$TAG: 切换到普通聊天模式失败: $e');
      _isVoiceCallActive = false;
    }
  }

  /// 初始化
  Future<void> _init() async {
    try {
      print('$TAG: 初始化小智服务...');
      print('$TAG: WebSocket URL: $websocketUrl');
      print('$TAG: OTA URL: $otaUrl');
      print('$TAG: 设备ID: $macAddress');

      // 初始化音频工具
      await AudioUtil.initRecorder();
      await AudioUtil.initPlayer();

      // 检查OTA状态和设备激活
      final otaService = OtaService(baseUrl: Uri.parse(otaUrl).origin);
      final otaResult = await otaService.checkOtaStatus(macAddress);

      // 如果需要激活设备
      if (otaResult.needsActivation) {
        print('$TAG: 设备需要激活');
        print('$TAG: 激活消息: ${otaResult.activationMessage}');
        _dispatchEvent(
          XiaozhiServiceEvent(
            XiaozhiServiceEventType.activationRequired,
            otaResult.activationMessage,
          ),
        );
        return;
      }

      // 使用OTA返回的WebSocket URL
      final effectiveWebsocketUrl = otaResult.websocketUrl;
      print('$TAG: 使用WebSocket URL: $effectiveWebsocketUrl');

      // 连接服务器
      await connect(websocketUrl: effectiveWebsocketUrl);

      // 等待连接建立后发送第一条消息触发激活流程
      if (_isConnected) {
        print('$TAG: 发送初始消息以触发激活流程');
        await Future.delayed(Duration(milliseconds: 500));
        if (_isConnected) {
          await sendTextMessage("您好");
        }
      } else {
        throw Exception("服务连接失败");
      }
    } catch (e) {
      print('$TAG: 初始化失败: $e');
      _dispatchEvent(
        XiaozhiServiceEvent(XiaozhiServiceEventType.error, e.toString()),
      );
      rethrow;
    }
  }

  /// 设置消息监听器
  void setMessageListener(MessageListener? listener) {
    _messageListener = listener;
  }

  /// 添加事件监听器
  void addListener(XiaozhiServiceListener listener) {
    _listeners.remove(listener); // 防止重复
    _listeners.add(listener);
  }

  /// 移除事件监听器
  void removeListener(XiaozhiServiceListener listener) {
    _listeners.remove(listener);
  }

  /// 分发事件到所有监听器
  void _dispatchEvent(XiaozhiServiceEvent event) {
    // Create a copy of the listeners list to prevent concurrent modification
    final listenersCopy = List<XiaozhiServiceListener>.from(_listeners);
    for (var listener in listenersCopy) {
      listener(event);
    }
  }

  /// 连接到小智服务
  Future<void> connect({String? websocketUrl}) async {
    if (_isConnected) {
      print('$TAG: 已经连接，跳过重复连接');
      return;
    }

    try {
      print('$TAG: 开始连接服务器...');
      print('$TAG: WebSocket URL: ${websocketUrl ?? this.websocketUrl}');
      print('$TAG: OTA URL: $otaUrl');
      print('$TAG: 设备ID: $macAddress');

      // 从otaUrl中提取baseUrl
      final baseUrl = Uri.parse(otaUrl).origin;
      print('$TAG: 使用基础URL: $baseUrl');

      // 创建WebSocket管理器
      _webSocketManager = XiaozhiWebSocketManager(
        deviceId: macAddress,
        enableToken: true,
        baseUrl: baseUrl,
        onMessage: (message) {
          _handleWebSocketMessage(message);
        },
        onError: (error) {
          print('$TAG: 发生错误: $error');
          _dispatchEvent(
            XiaozhiServiceEvent(XiaozhiServiceEventType.error, error),
          );
        },
        onConnected: () {
          print('$TAG: WebSocket已连接');
          _isConnected = true;
          _dispatchEvent(
            XiaozhiServiceEvent(XiaozhiServiceEventType.connected, null),
          );
          // 连接成功后发送hello消息
          _sendHelloMessage();
        },
        onDisconnected: () {
          print('$TAG: WebSocket已断开');
          _isConnected = false;
          _dispatchEvent(
            XiaozhiServiceEvent(XiaozhiServiceEventType.disconnected, null),
          );
        },
      );

      // 添加WebSocket事件监听
      _webSocketManager!.addListener(_onWebSocketEvent);

      try {
        // 初始化WebSocket管理器
        await _webSocketManager!.initialize(websocketUrl: websocketUrl);
      } catch (e) {
        print('$TAG: WebSocket初始化失败: $e');
        _isConnected = false;
        _dispatchEvent(
          XiaozhiServiceEvent(
            XiaozhiServiceEventType.error,
            'WebSocket初始化失败: $e',
          ),
        );
        rethrow;
      }
    } catch (e) {
      print('$TAG: 连接失败: $e');
      rethrow;
    }
  }

  /// 断开小智服务连接
  Future<void> disconnect() async {
    if (!_isConnected || _webSocketManager == null) return;

    try {
      // 取消音频流订阅
      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;

      // 停止音频录制
      if (AudioUtil.isRecording) {
        await AudioUtil.stopRecording();
      }

      // 断开WebSocket连接
      _webSocketManager!.disconnect();
      _webSocketManager = null;
      _isConnected = false;
    } catch (e) {
      print('$TAG: 断开连接失败: $e');
    }
  }

  /// 发送文本消息
  Future<String> sendTextMessage(String message) async {
    if (!_isConnected && _webSocketManager == null) {
      await connect();
    }

    try {
      // 创建一个Completer来等待响应
      final completer = Completer<String>();
      bool hasResponse = false;

      print('$TAG: 开始发送文本消息: $message');

      // 添加消息监听器，监听所有可能的回复
      void onceListener(XiaozhiServiceEvent event) {
        if (event.type == XiaozhiServiceEventType.textMessage) {
          // 忽略echo消息（即我们发送的消息）
          if (event.data == message) {
            print('$TAG: 忽略echo消息: ${event.data}');
            return;
          }

          print('$TAG: 收到服务器响应: ${event.data}');
          if (!completer.isCompleted) {
            hasResponse = true;
            completer.complete(event.data as String);
            removeListener(onceListener);
          }
        } else if (event.type == XiaozhiServiceEventType.error &&
            !completer.isCompleted) {
          print('$TAG: 收到错误响应: ${event.data}');
          completer.completeError(event.data.toString());
          removeListener(onceListener);
        }
      }

      // 先添加监听器，确保不会错过任何消息
      addListener(onceListener);

      // 发送文本请求
      print('$TAG: 发送文本请求: $message');
      _webSocketManager!.sendTextRequest(message);

      // 设置超时，15秒比10秒更宽松一些
      final timeoutTimer = Timer(const Duration(seconds: 15), () {
        if (!completer.isCompleted) {
          print('$TAG: 请求超时，15秒内没有收到响应');
          completer.completeError('请求超时');
          removeListener(onceListener);
        }
      });

      // 等待响应
      try {
        final result = await completer.future;
        // 取消超时定时器
        timeoutTimer.cancel();
        return result;
      } catch (e) {
        // 取消超时定时器
        timeoutTimer.cancel();
        rethrow;
      }
    } catch (e) {
      print('$TAG: 发送消息失败: $e');
      rethrow;
    }
  }

  /// 连接语音通话
  Future<void> connectVoiceCall() async {
    try {
      // 简化流程，确保权限和音频准备就绪
      if (Platform.isIOS || Platform.isAndroid) {
        final status = await Permission.microphone.request();
        if (status != PermissionStatus.granted) {
          print('$TAG: 麦克风权限被拒绝');
          _dispatchEvent(
            XiaozhiServiceEvent(XiaozhiServiceEventType.error, '麦克风权限被拒绝'),
          );
          return;
        }
      }

      // 初始化音频系统
      await AudioUtil.stopPlaying();
      await AudioUtil.initRecorder();
      await AudioUtil.initPlayer();

      print('$TAG: 正在连接 $websocketUrl');
      print('$TAG: 设备ID: $_deviceId');
      print('$TAG: Token启用: true');
      print('$TAG: 使用Token: $token');

      // 从otaUrl中提取baseUrl
      final baseUrl = Uri.parse(otaUrl).origin;
      print('$TAG: 使用基础URL: $baseUrl');

      // 使用 WebSocketManager 连接
      _webSocketManager = XiaozhiWebSocketManager(
        deviceId: _deviceId,
        enableToken: true,
        baseUrl: baseUrl,
        onMessage: (message) {
          print('$TAG: 收到消息: $message');
          _handleWebSocketMessage(message);
        },
        onError: (error) {
          print('$TAG: 发生错误: $error');
          _dispatchEvent(
            XiaozhiServiceEvent(XiaozhiServiceEventType.error, error),
          );
        },
        onConnected: () {
          print('$TAG: WebSocket已连接');
          _isConnected = true;
          _dispatchEvent(
            XiaozhiServiceEvent(XiaozhiServiceEventType.connected, null),
          );
        },
        onDisconnected: () {
          print('$TAG: WebSocket已断开');
          _isConnected = false;
          _dispatchEvent(
            XiaozhiServiceEvent(XiaozhiServiceEventType.disconnected, null),
          );
        },
      );
      _webSocketManager!.addListener(_onWebSocketEvent);
      await _webSocketManager!.initialize();
    } catch (e) {
      print('$TAG: 连接失败: $e');
      rethrow;
    }
  }

  /// 结束语音通话
  Future<void> disconnectVoiceCall() async {
    if (_webSocketManager == null) return;

    try {
      // 停止音频录制
      if (AudioUtil.isRecording) {
        await AudioUtil.stopRecording();
      }

      // 停止音频播放
      await AudioUtil.stopPlaying();

      // 取消音频流订阅
      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;

      // 直接断开连接
      await disconnect();
    } catch (e) {
      // 忽略断开连接时的错误
      print('$TAG: 结束语音通话时发生错误: $e');
    }
  }

  /// 开始说话
  Future<void> startSpeaking() async {
    try {
      final message = {'type': 'speak', 'state': 'start', 'mode': 'auto'};
      _webSocketManager?.sendMessage(jsonEncode(message));
      print('$TAG: 已发送开始说话消息');
    } catch (e) {
      print('$TAG: 开始说话失败: $e');
    }
  }

  /// 停止说话
  Future<void> stopSpeaking() async {
    try {
      final message = {'type': 'speak', 'state': 'stop', 'mode': 'auto'};
      _webSocketManager?.sendMessage(jsonEncode(message));
      print('$TAG: 已发送停止说话消息');
    } catch (e) {
      print('$TAG: 停止说话失败: $e');
    }
  }

  /// 发送listen消息
  void _sendListenMessage() async {
    try {
      final listenMessage = {
        'type': 'listen',
        'session_id': _sessionId,
        'state': 'start',
        'mode': 'auto',
      };
      _webSocketManager?.sendMessage(jsonEncode(listenMessage));
      print('$TAG: 已发送listen消息');

      // 开始录音
      _isVoiceCallActive = true;
      await AudioUtil.startRecording();
    } catch (e) {
      print('$TAG: 发送listen消息失败: $e');
      _dispatchEvent(
        XiaozhiServiceEvent(XiaozhiServiceEventType.error, '发送listen消息失败: $e'),
      );
    }
  }

  /// 开始听说（语音通话模式）
  Future<void> startListeningCall() async {
    try {
      // 确保已经有会话ID
      if (_sessionId == null) {
        print('$TAG: 没有会话ID，无法开始监听，等待会话ID初始化...');
        // 等待短暂时间，然后重新检查会话ID
        await Future.delayed(const Duration(milliseconds: 500));
        if (_sessionId == null) {
          print('$TAG: 会话ID仍然为空，放弃开始监听');
          throw Exception('会话ID为空，无法开始录音');
        }
      }

      print('$TAG: 使用会话ID开始录音: $_sessionId');

      // 请求麦克风权限
      if (Platform.isIOS) {
        final micStatus = await Permission.microphone.status;
        if (micStatus != PermissionStatus.granted) {
          final result = await Permission.microphone.request();
          if (result != PermissionStatus.granted) {
            print('$TAG: 麦克风权限被拒绝');
            _dispatchEvent(
              XiaozhiServiceEvent(XiaozhiServiceEventType.error, '麦克风权限被拒绝'),
            );
            return;
          }
        }

        // 确保音频会话已初始化
        await AudioUtil.initRecorder();
      } else {
        // Android权限请求
        final status = await Permission.microphone.request();
        if (status.isDenied) {
          print('$TAG: 麦克风权限被拒绝');
          _dispatchEvent(
            XiaozhiServiceEvent(XiaozhiServiceEventType.error, '麦克风权限被拒绝'),
          );
          return;
        }
      }

      // 开始录音
      await AudioUtil.startRecording();

      // 设置音频流订阅
      _audioStreamSubscription = AudioUtil.audioStream.listen((opusData) {
        // 发送音频数据
        _webSocketManager?.sendBinaryMessage(opusData);
      });

      // 发送开始监听命令
      final message = {
        'session_id': _sessionId,
        'type': 'listen',
        'state': 'start',
        'mode': 'auto',
      };
      _webSocketManager?.sendMessage(jsonEncode(message));
      print('$TAG: 已发送开始监听消息 (语音通话模式)');
    } catch (e) {
      print('$TAG: 开始监听失败: $e');
      throw Exception('开始语音输入失败: $e');
    }
  }

  /// 停止听说（语音通话模式）
  Future<void> stopListeningCall() async {
    try {
      // 取消音频流订阅
      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;

      // 停止录音
      await AudioUtil.stopRecording();

      // 发送停止监听命令
      if (_sessionId != null && _webSocketManager != null) {
        final message = {
          'session_id': _sessionId,
          'type': 'listen',
          'state': 'stop',
          'mode': 'auto',
        };
        _webSocketManager?.sendMessage(jsonEncode(message));
        print('$TAG: 已发送停止监听消息 (语音通话模式)');
      }
    } catch (e) {
      print('$TAG: 停止监听失败: $e');
    }
  }

  /// 取消发送（上滑取消）
  Future<void> abortListening() async {
    try {
      // 取消音频流订阅
      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;

      // 停止录音
      await AudioUtil.stopRecording();

      // 发送中止命令
      if (_sessionId != null && _webSocketManager != null) {
        final message = {'session_id': _sessionId, 'type': 'abort'};
        _webSocketManager?.sendMessage(jsonEncode(message));
        print('$TAG: 已发送中止消息');
      }
    } catch (e) {
      print('$TAG: 中止监听失败: $e');
    }
  }

  /// 切换静音状态
  void toggleMute() {
    _isMuted = !_isMuted;

    if (_webSocketManager == null || !_webSocketManager!.isConnected) return;

    try {
      final request = {'type': _isMuted ? 'voice_mute' : 'voice_unmute'};

      _webSocketManager!.sendMessage(jsonEncode(request));
    } catch (e) {
      print('$TAG: 切换静音状态失败: $e');
    }
  }

  /// 处理WebSocket事件
  void _onWebSocketEvent(XiaozhiEvent event) {
    switch (event.type) {
      case XiaozhiEventType.connected:
        _isConnected = true;
        _dispatchEvent(
          XiaozhiServiceEvent(XiaozhiServiceEventType.connected, null),
        );
        break;

      case XiaozhiEventType.disconnected:
        _isConnected = false;
        _dispatchEvent(
          XiaozhiServiceEvent(XiaozhiServiceEventType.disconnected, null),
        );
        break;

      case XiaozhiEventType.message:
        _handleTextMessage(event.data as String);
        break;

      case XiaozhiEventType.binaryMessage:
        // 处理二进制音频数据 - 简化直接播放
        final audioData = event.data as List<int>;
        AudioUtil.playOpusData(Uint8List.fromList(audioData));
        break;

      case XiaozhiEventType.error:
        _dispatchEvent(
          XiaozhiServiceEvent(XiaozhiServiceEventType.error, event.data),
        );
        break;
    }
  }

  /// 处理WebSocket消息
  void _handleWebSocketMessage(dynamic message) {
    try {
      if (message is String && !message.startsWith('[')) {
        _handleTextMessage(message);
      } else if (message is List) {
        // 二进制音频数据直接处理
        if (message.isNotEmpty && message.every((e) => e is int)) {
          AudioUtil.playOpusData(Uint8List.fromList(message.cast<int>()));
        }
      }
    } catch (e, stackTrace) {
      print('$TAG: 处理消息失败: $e\n$stackTrace');
    }
  }

  /// 发送hello消息
  void _sendHelloMessage() {
    if (_webSocketManager == null) return;

    final helloMessage = {
      "type": "hello",
      "device_id": macAddress, // 使用原始 MAC 地址
      "device_name": "Flutter设备",
      "device_mac": macAddress, // 使用原始 MAC 地址
      "token": token,
    };

    print('$TAG: 发送hello消息: ${json.encode(helloMessage)}');
    _webSocketManager?.sendMessage(json.encode(helloMessage));
  }

  /// 处理文本消息
  void _handleTextMessage(String message) {
    try {
      final Map<String, dynamic> jsonData = json.decode(message);
      final String type = jsonData['type'] ?? '';
      final String text = jsonData['text'] ?? '';

      print('$TAG: 收到文本消息: $message');

      // 只在会话ID变化时更新并打印
      final String? newSessionId = jsonData['session_id'];
      if (newSessionId != null && newSessionId != _sessionId) {
        _sessionId = newSessionId;
        print('$TAG: 更新会话ID: $_sessionId');
      }

      // 检查激活码
      if (text.contains('请登录控制面板') && text.contains('绑定设备')) {
        final RegExp activationCodeRegex = RegExp(r'输入(\d{6})');
        final Match? match = activationCodeRegex.firstMatch(text);
        if (match != null) {
          final String activationCode = match.group(1)!;
          print('$TAG: 检测到激活码: $activationCode');
          _dispatchEvent(
            XiaozhiServiceEvent(
              XiaozhiServiceEventType.activationCode,
              activationCode,
            ),
          );
          return;
        }
      }

      // 处理错误消息
      if (text.contains('没有找到该设备的版本信息')) {
        print('$TAG: 设备版本信息未找到，尝试重新初始化连接...');
        disconnect().then((_) {
          Future.delayed(Duration(seconds: 1), () {
            connect();
          });
        });
        return;
      }

      // 根据消息类型处理
      switch (type) {
        case 'hello':
          print('$TAG: 收到hello消息，会话ID: ${jsonData['session_id']}');
          if (_isVoiceCallActive && !_hasStartedCall) {
            _hasStartedCall = true;
            startSpeaking();
          }
          break;

        case 'start':
          if (_isVoiceCallActive) {
            _sendListenMessage();
          }
          break;

        case 'stt':
          if (text.isNotEmpty && text != '您好') {
            // 忽略echo消息
            _dispatchEvent(
              XiaozhiServiceEvent(XiaozhiServiceEventType.userMessage, text),
            );
          }
          break;

        case 'llm':
          if (text.isNotEmpty) {
            _dispatchEvent(
              XiaozhiServiceEvent(XiaozhiServiceEventType.textMessage, text),
            );
          }
          break;

        case 'tts':
          // TTS消息只在sentence_start状态且有文本时处理
          final String state = jsonData['state'] ?? '';
          if (state == 'sentence_start' && text.isNotEmpty) {
            // 过滤掉注释和配置语气等内容
            String filteredText =
                text
                    .replaceAll(
                      RegExp(
                        r'(//.*|#.*|【.*?】|（.*?）|\(.*?\)|\[.*?\]|\{.*?\}|<.*?>)',
                      ),
                      '',
                    )
                    .trim();
            if (filteredText.isNotEmpty) {
              _dispatchEvent(
                XiaozhiServiceEvent(
                  XiaozhiServiceEventType.textMessage,
                  filteredText,
                ),
              );
            }
          }
          break;

        case 'emotion':
          final String emotion = jsonData['emotion'] ?? '';
          if (emotion.isNotEmpty) {
            print('$TAG: 收到表情消息: $emotion');
            _dispatchEvent(
              XiaozhiServiceEvent(
                XiaozhiServiceEventType.textMessage,
                '表情: $emotion',
              ),
            );
          }
          break;
      }

      // 确保消息监听器在事件分发之后调用
      if (_messageListener != null) {
        _messageListener!(jsonData);
      }
    } catch (e, stackTrace) {
      print('$TAG: 解析消息失败: $e\n$stackTrace');
    }
  }

  /// 开始通话
  void _startCall() {
    try {
      // 发送开始通话消息
      final startMessage = {
        'type': 'start',
        'mode': 'auto',
        'audio_params': {
          'format': 'opus',
          'sample_rate': 16000,
          'channels': 1,
          'frame_duration': 60,
        },
      };
      _webSocketManager?.sendMessage(jsonEncode(startMessage));
      print('$TAG: 已发送开始通话消息');
    } catch (e) {
      print('$TAG: 开始通话失败: $e');
    }
  }

  /// 中断音频播放
  Future<void> stopPlayback() async {
    try {
      print('$TAG: 正在停止音频播放');

      // 简单直接地停止播放
      await AudioUtil.stopPlaying();

      print('$TAG: 音频播放已停止');
    } catch (e) {
      print('$TAG: 停止音频播放失败: $e');
    }
  }

  /// 判断是否已连接
  bool get isConnected =>
      _isConnected &&
      _webSocketManager != null &&
      _webSocketManager!.isConnected;

  /// 判断是否静音
  bool get isMuted => _isMuted;

  /// 判断语音通话是否活跃
  bool get isVoiceCallActive => _isVoiceCallActive;

  /// 释放资源
  Future<void> dispose() async {
    await disconnect();
    await AudioUtil.dispose();
    _listeners.clear();
    print('$TAG: 资源已释放');
  }

  /// 开始监听（按住说话模式）
  Future<void> startListening({String mode = 'manual'}) async {
    if (!_isConnected || _webSocketManager == null) {
      await connect();
    }

    try {
      // 确保已经有会话ID
      if (_sessionId == null) {
        print('$TAG: 没有会话ID，无法开始监听');
        return;
      }

      // 开始录音
      await AudioUtil.startRecording();

      // 发送开始监听命令
      final message = {
        'session_id': _sessionId,
        'type': 'listen',
        'state': 'start',
        'mode': mode,
      };
      _webSocketManager?.sendMessage(jsonEncode(message));
      print('$TAG: 已发送开始监听消息 (按住说话)');

      // 设置音频流订阅
      _audioStreamSubscription = AudioUtil.audioStream.listen((opusData) {
        // 发送音频数据
        _webSocketManager?.sendBinaryMessage(opusData);
      });
    } catch (e) {
      print('$TAG: 开始监听失败: $e');
      throw Exception('开始语音输入失败: $e');
    }
  }

  /// 停止监听（按住说话模式）
  Future<void> stopListening() async {
    try {
      // 取消音频流订阅
      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;

      // 停止录音
      await AudioUtil.stopRecording();

      // 发送停止监听命令
      if (_sessionId != null && _webSocketManager != null) {
        final message = {
          'session_id': _sessionId,
          'type': 'listen',
          'state': 'stop',
        };
        _webSocketManager?.sendMessage(jsonEncode(message));
        print('$TAG: 已发送停止监听消息');
      }
    } catch (e) {
      print('$TAG: 停止监听失败: $e');
    }
  }

  /// 发送中断消息
  Future<void> sendAbortMessage() async {
    try {
      if (_webSocketManager != null && _isConnected && _sessionId != null) {
        final abortMessage = {
          'session_id': _sessionId,
          'type': 'abort',
          'reason': 'wake_word_detected',
        };
        _webSocketManager?.sendMessage(jsonEncode(abortMessage));
        print('$TAG: 发送中断消息: $abortMessage');

        // 如果当前正在录音，短暂停顿后继续
        if (_isSpeaking) {
          await stopListeningCall();
          await Future.delayed(const Duration(milliseconds: 500));
          await startListeningCall();
        }
      }
    } catch (e) {
      print('$TAG: 发送中断消息失败: $e');
    }
  }

  /// 判断是否正在说话
  bool get _isSpeaking => _audioStreamSubscription != null;

  void _handleMessage(dynamic message) {
    try {
      // 连接成功事件
      if (message == 'connected') {
        _dispatchEvent(
          XiaozhiServiceEvent(XiaozhiServiceEventType.connected, null),
        );
        return;
      }

      // 断开连接事件
      if (message == 'disconnected') {
        _dispatchEvent(
          XiaozhiServiceEvent(XiaozhiServiceEventType.disconnected, null),
        );
        return;
      }

      // 处理二进制消息
      if (message is List<int>) {
        _handleBinaryMessage(message);
        return;
      }

      // 处理文本消息
      try {
        final Map<String, dynamic> jsonData = jsonDecode(message);
        final String messageType = jsonData['type'];
        _dispatchEvent(
          XiaozhiServiceEvent(XiaozhiServiceEventType.textMessage, jsonData),
        );
      } catch (e) {
        _dispatchEvent(
          XiaozhiServiceEvent(XiaozhiServiceEventType.error, '消息解析失败: $e'),
        );
      }
    } catch (e) {
      _dispatchEvent(
        XiaozhiServiceEvent(XiaozhiServiceEventType.error, '消息处理失败: $e'),
      );
    }
  }

  /// 处理二进制消息
  void _handleBinaryMessage(List<int> message) {
    try {
      if (message.isNotEmpty) {
        AudioUtil.playOpusData(Uint8List.fromList(message));
      }
    } catch (e) {
      _dispatchEvent(
        XiaozhiServiceEvent(XiaozhiServiceEventType.error, '处理二进制消息失败: $e'),
      );
    }
  }
}
