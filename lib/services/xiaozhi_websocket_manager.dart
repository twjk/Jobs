import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
// 尝试导入io.dart，但在web平台会抛出异常
import 'package:web_socket_channel/io.dart'
    if (dart.library.html) 'package:web_socket_channel/html.dart';
import '../utils/device_util.dart';
import '../services/ota_service.dart';
import 'package:http/http.dart' as http;

/// 小智WebSocket事件类型
enum XiaozhiEventType { connected, disconnected, message, error, binaryMessage }

/// 小智WebSocket事件
class XiaozhiEvent {
  final XiaozhiEventType type;
  final dynamic data;

  const XiaozhiEvent({required this.type, this.data});
}

/// 小智WebSocket监听器接口
typedef XiaozhiWebSocketListener = void Function(XiaozhiEvent event);

/// 小智WebSocket管理器
class XiaozhiWebSocketManager {
  static const String TAG = "XiaozhiWebSocket";
  final String deviceId;
  final String deviceName;
  final bool enableToken;
  final String baseUrl;
  final Function(dynamic)? onMessage;
  final Function(String)? onError;
  final Function()? onConnected;
  final Function()? onDisconnected;
  WebSocketChannel? _channel;
  bool _isConnected = false;
  final List<XiaozhiWebSocketListener> _listeners = [];
  Timer? _pingTimer;
  String? _sessionId;
  bool _isInitializing = false;
  String? _websocketUrl;

  XiaozhiWebSocketManager({
    required this.deviceId,
    this.deviceName = 'Flutter设备',
    this.enableToken = false,
    required this.baseUrl,
    this.onMessage,
    this.onError,
    this.onConnected,
    this.onDisconnected,
  });

  bool get isConnected => _isConnected;

  Future<void> initialize({String? websocketUrl}) async {
    if (_isInitializing) {
      print('$TAG: 初始化已在进行中，跳过重复初始化');
      return;
    }

    // 如果已经连接，先断开
    if (_isConnected) {
      print('$TAG: 已经连接，先断开现有连接');
      await disconnect();
      await Future.delayed(const Duration(milliseconds: 500));
    }

    _isInitializing = true;
    _websocketUrl = websocketUrl;

    try {
      await _checkOtaStatus();
      await _connectWebSocket();
    } catch (e) {
      print('$TAG: 初始化失败: $e');
      _isConnected = false;
      if (onError != null) {
        onError!(e.toString());
      }
    } finally {
      _isInitializing = false;
    }
  }

  Future<void> _checkOtaStatus() async {
    print('正在检查OTA状态...');
    final otaUrl = '$baseUrl/xiaozhi/ota/';

    // 尝试获取验证码
    // try {
    //   final verifyResponse = await http.get(
    //     Uri.parse('$baseUrl/xiaozhi/device/verify'),
    //     headers: {'Accept': 'application/json', 'X-Device-ID': deviceId},
    //   );

    //   if (verifyResponse.statusCode == 200) {
    //     print('验证码响应: ${verifyResponse.body}');
    //   }
    // } catch (e) {
    //   print('获取验证码失败: $e');
    // }

    // final otaCheckUrl =
    //     Uri.parse(
    //       otaUrl,
    //     ).replace(queryParameters: {'device-id': deviceId}).toString();
    // print('OTA检查URL: $otaCheckUrl');

    final response = await http.get(
      Uri.parse(otaUrl),
      headers: {
        'Accept': 'application/json',
        'X-Device-ID': deviceId,
        'X-Request-Verify': 'true',
      },
    );
    print('OTA检查状态码: ${response.statusCode}');

    if (response.statusCode == 200) {
      // 尝试解码响应内容
      String responseBody;
      try {
        responseBody = utf8.decode(response.bodyBytes);
      } catch (e) {
        // 如果UTF-8解码失败，尝试使用GBK解码
        responseBody = response.body;
        if (responseBody.contains('OTA') && responseBody.contains('正常')) {
          print('OTA服务正常运行，使用默认配置');
          print('$TAG: OTA检查成功');
          print('$TAG: 设备ID: $deviceId');
          print('$TAG: 设备名称: $deviceName');
          print('$TAG: 固件版本: 1.0.0');
          print('$TAG: OTA URL: $otaUrl');
          print('$TAG: WebSocket URL: ws://62.234.36.202:8000/xiaozhi/v1/');
          return;
        }
      }
      print('OTA检查响应: $responseBody');

      if (responseBody.contains('OTA') && responseBody.contains('正常')) {
        print('OTA服务正常运行，使用默认配置');
        print('$TAG: OTA检查成功');
        print('$TAG: 设备ID: $deviceId');
        print('$TAG: 设备名称: $deviceName');
        print('$TAG: 固件版本: 1.0.0');
        print('$TAG: OTA URL: $otaUrl');
        print('$TAG: WebSocket URL: ws://62.234.36.202:8000/xiaozhi/v1/');
      } else {
        throw Exception('OTA服务响应异常: $responseBody');
      }
    } else {
      throw Exception('OTA检查失败: ${response.statusCode}');
    }
  }

  Future<void> _connectWebSocket() async {
    if (_channel != null) {
      print('$TAG: 断开现有连接');
      await disconnect();
      await Future.delayed(Duration(milliseconds: 500));
    }

    try {
      final wsUrl = _websocketUrl ?? 'ws://62.234.36.202:8000/xiaozhi/v1/';
      print('正在连接WebSocket: $wsUrl');

      final clientId = 'flutter_${DateTime.now().millisecondsSinceEpoch}';
      final fullUrl = '$wsUrl?device-id=$deviceId&client-id=$clientId';
      print('完整WebSocket URL: $fullUrl');

      final wsUri = Uri.parse(fullUrl);
      _channel = WebSocketChannel.connect(wsUri);

      await _channel?.ready;
      _isConnected = true;
      print('WebSocket连接成功');

      _channel?.stream.listen(
        (message) {
          _handleMessage(message);
        },
        onError: (error) {
          print('WebSocket错误: $error');
          if (onError != null) {
            onError!(error.toString());
          }
          _handleDisconnect();
        },
        onDone: () {
          print('WebSocket连接关闭');
          _handleDisconnect();
        },
      );

      // 等待确保连接稳定
      await Future.delayed(Duration(milliseconds: 100));

      // 发送设备注册消息
      final registerMessage = {
        'type': 'hello',
        'device_id': deviceId,
        'device_mac': deviceId,
        'device_name': deviceName,
        'token': 'test-token',
        'firmware_version': '1.0.0',
        'capabilities': ['text', 'voice', 'image'],
      };

      print('$TAG: 发送设备注册消息: ${json.encode(registerMessage)}');
      _channel?.sink.add(json.encode(registerMessage));

      if (onConnected != null) {
        onConnected!();
      }

      _startPingTimer();
    } catch (e) {
      _isConnected = false;
      print('WebSocket连接失败: $e');
      if (onError != null) {
        onError!(e.toString());
      }
      rethrow;
    }
  }

  void _handleMessage(dynamic message) {
    try {
      if (message is List) {
        // 二进制消息直接通过事件系统分发
        if (message.isNotEmpty && message.every((e) => e is int)) {
          _dispatchEvent(
            XiaozhiEvent(type: XiaozhiEventType.binaryMessage, data: message),
          );
        }
        return;
      }

      final Map<String, dynamic> data = json.decode(message.toString());
      print('$TAG: 收到消息: ${json.encode(data)}');

      final String messageType = data['type'] as String;

      // 处理会话ID更新
      if (messageType == 'hello' &&
          data['session_id'] != null &&
          _sessionId != data['session_id']) {
        _sessionId = data['session_id'];
        print('$TAG: 收到服务器hello响应，会话ID: $_sessionId');
      }

      // 检查错误消息
      if (messageType == 'stt') {
        final String text = data['text'] as String;
        if (text.contains('没有找到该设备的版本信息')) {
          print('$TAG: 设备版本信息未找到，请检查固件版本配置');
          _dispatchEvent(
            XiaozhiEvent(
              type: XiaozhiEventType.error,
              data: '设备版本信息未找到，请检查固件版本配置',
            ),
          );
          return;
        }
      }

      // 根据消息类型分发事件
      switch (messageType) {
        case 'hello':
          _dispatchEvent(
            XiaozhiEvent(type: XiaozhiEventType.message, data: message),
          );
          break;

        case 'stt':
        case 'llm':
        case 'tts':
        case 'emotion':
          // 这些消息类型由 XiaozhiService 处理，这里只转发原始消息
          _dispatchEvent(
            XiaozhiEvent(type: XiaozhiEventType.message, data: message),
          );
          break;

        default:
          // 其他消息类型直接转发
          _dispatchEvent(
            XiaozhiEvent(type: XiaozhiEventType.message, data: message),
          );
          break;
      }
    } catch (e) {
      print('$TAG: 处理消息失败: $e');
      _dispatchEvent(
        XiaozhiEvent(type: XiaozhiEventType.error, data: e.toString()),
      );
    }
  }

  void _handleDisconnect() {
    _isConnected = false;
    _pingTimer?.cancel();
    if (onDisconnected != null) {
      onDisconnected!();
    }
    _dispatchEvent(
      XiaozhiEvent(type: XiaozhiEventType.disconnected, data: null),
    );
  }

  Future<void> disconnect() async {
    _pingTimer?.cancel();
    _pingTimer = null;

    if (_channel != null) {
      print('$TAG: 主动断开WebSocket连接');
      try {
        await _channel?.sink.close(status.normalClosure);
      } catch (e) {
        print('$TAG: 关闭连接时出错: $e');
      } finally {
        _channel = null;
        _isConnected = false;
        _sessionId = null;
        _isInitializing = false;

        // 通知断开连接
        if (onDisconnected != null) {
          onDisconnected!();
        }
        _dispatchEvent(
          XiaozhiEvent(type: XiaozhiEventType.disconnected, data: null),
        );
      }
    }
  }

  void addListener(XiaozhiWebSocketListener listener) {
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  void removeListener(XiaozhiWebSocketListener listener) {
    _listeners.remove(listener);
  }

  void _dispatchEvent(XiaozhiEvent event) {
    for (var listener in List<XiaozhiWebSocketListener>.from(_listeners)) {
      listener(event);
    }
  }

  void sendMessage(String message) {
    if (!_isConnected || _channel == null) {
      final error = 'WebSocket未连接';
      print('$TAG: $error');
      if (onError != null) {
        onError!(error);
      }
      return;
    }

    try {
      print('$TAG: 发送消息: $message');
      _channel?.sink.add(message);
    } catch (e) {
      print('$TAG: 发送消息失败: $e');
      if (onError != null) {
        onError!(e.toString());
      }
    }
  }

  void sendBinaryMessage(List<int> data) {
    if (!_isConnected || _channel == null) {
      print('无法发送二进制消息：WebSocket未连接');
      if (onError != null) {
        onError!('WebSocket未连接');
      }
      return;
    }

    try {
      _channel?.sink.add(data);
    } catch (e) {
      print('发送二进制消息失败: $e');
      if (onError != null) {
        onError!(e.toString());
      }
    }
  }

  void sendTextRequest(String text) {
    if (!_isConnected) {
      print('无法发送文本请求：WebSocket未连接');
      return;
    }

    final request = {
      'type': 'listen',
      'state': 'detect',
      'text': text,
      'source': 'text',
    };

    print('$TAG: 发送文本请求: ${json.encode(request)}');
    sendMessage(json.encode(request));
  }

  /// 提交验证码
  void submitVerificationCode(String code) {
    if (!_isConnected || _channel == null) {
      final error = 'WebSocket未连接';
      print('$TAG: $error');
      if (onError != null) {
        onError!(error);
      }
      return;
    }

    final request = {
      'type': 'verify',
      'code': code,
      'device_id': deviceId,
      'device_mac': deviceId,
    };

    print('$TAG: 提交验证码: ${json.encode(request)}');
    sendMessage(json.encode(request));
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = null;

    if (!_isConnected || _channel == null) return;

    _pingTimer = Timer.periodic(Duration(seconds: 30), (timer) {
      if (!_isConnected || _channel == null) {
        timer.cancel();
        _pingTimer = null;
        return;
      }

      try {
        final pingMessage = {'type': 'ping'};
        //print('$TAG: 发送ping消息');
        _channel?.sink.add(json.encode(pingMessage));
      } catch (e) {
        print('$TAG: 发送ping消息失败: $e');
        if (onError != null) {
          onError!(e.toString());
        }
      }
    });
  }
}
