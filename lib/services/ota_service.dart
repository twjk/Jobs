import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/ota_request.dart';

class OtaCheckResult {
  final String websocketUrl;
  final String firmwareVersion;
  final String firmwareUrl;
  final String activationCode;
  final String activationMessage;
  final String deviceId;
  final bool needsActivation;

  OtaCheckResult({
    required this.websocketUrl,
    required this.firmwareVersion,
    required this.firmwareUrl,
    required this.activationCode,
    this.activationMessage = '',
    required this.deviceId,
    this.needsActivation = false,
  });

  factory OtaCheckResult.fromJson(Map<String, dynamic> json) {
    final activation = json['activation'];
    final firmware = json['firmware'];
    final websocket = json['websocket'];

    return OtaCheckResult(
      websocketUrl: websocket?['url'] ?? 'ws://62.234.36.202:8000/xiaozhi/v1/',
      firmwareVersion: firmware?['version'] ?? '1.0.0',
      firmwareUrl: firmware?['url'] ?? '',
      activationCode: activation?['code'] ?? '',
      activationMessage: activation?['message'] ?? '',
      deviceId: activation?['challenge'] ?? '',
      needsActivation: activation != null,
    );
  }

  factory OtaCheckResult.defaultValues(String deviceId) {
    return OtaCheckResult(
      websocketUrl: 'ws://62.234.36.202:8000/xiaozhi/v1/',
      firmwareVersion: '1.0.0',
      firmwareUrl: 'http://62.234.36.202:8002/xiaozhi/ota/',
      activationCode: '',
      deviceId: deviceId,
    );
  }
}

class OtaService {
  final String baseUrl;
  String? _cachedDeviceId;
  static const String DEFAULT_MAC = "00:11:22:33:44:55";

  OtaService({required this.baseUrl});

  static String formatMacAddress(String mac) {
    if (mac.contains(':')) {
      // 拆分为字节
      List<String> parts = mac.split(':');
      if (parts[0].length == 2) {
        int firstByte = int.parse(parts[0], radix: 16);
        firstByte = firstByte & 0xFE; // 清除最低位，确保为单播
        parts[0] = firstByte.toRadixString(16).padLeft(2, '0');
      }
      return parts.join(':');
    }
    if (mac.length != 12) {
      mac = mac.padRight(12, '0').substring(0, 12);
    }
    // 处理无冒号格式
    String firstByteStr = mac.substring(0, 2);
    int firstByte = int.parse(firstByteStr, radix: 16);
    firstByte = firstByte & 0xFE; // 清除最低位，确保为单播
    String newFirstByteStr = firstByte.toRadixString(16).padLeft(2, '0');
    mac = newFirstByteStr + mac.substring(2);
    return mac
        .replaceAllMapped(RegExp(r'(.{2})'), (match) => '${match.group(1)}:')
        .substring(0, 17); // Remove trailing colon
  }

  String _formatMacAddress(String mac) {
    return OtaService.formatMacAddress(mac);
  }

  Future<OtaCheckResult> checkOtaStatus(String deviceId) async {
    try {
      print('正在检查OTA状态...');

      // 确保设备ID是正确的MAC地址格式
      final formattedDeviceId = _formatMacAddress(deviceId);
      _cachedDeviceId = formattedDeviceId;

      // 构建OTA请求体
      final otaRequest = OtaRequest(
        macAddress: formattedDeviceId,
        application: Application(),
        ota: Ota(),
        board: Board(mac: formattedDeviceId),
        chipInfo: ChipInfo(),
        partitionTable: [PartitionTable()],
      );

      // 发送OTA请求
      final uri = Uri.parse('$baseUrl/xiaozhi/ota/');
      final requestBody = otaRequest.toJson();
      final headers = {
        'Accept': '*/*',
        'Content-Type': 'application/json',
        'Device-Id': formattedDeviceId,
        'Client-Id': 'web_test_client',
      };

      print('OTA检查URL: $uri');
      print('OTA请求头: $headers');

      final response = await http.post(
        uri,
        headers: headers,
        body: json.encode(requestBody),
        encoding: Encoding.getByName('utf-8'),
      );
      print('OTA请求体: ${json.encode(requestBody)}');
      print('OTA检查状态码: ${response.statusCode}');
      print('OTA接口返回数据: ${response.body}');

      if (response.statusCode == 404) {
        print('OTA服务未找到，使用默认配置');
        return OtaCheckResult.defaultValues(formattedDeviceId);
      }

      if (response.statusCode != 200) {
        print('OTA检查失败，使用默认配置');
        return OtaCheckResult.defaultValues(formattedDeviceId);
      }

      // 尝试解码响应内容
      String responseBody;
      try {
        responseBody = utf8.decode(response.bodyBytes);
      } catch (e) {
        responseBody = response.body;
      }
      print('OTA检查响应: $responseBody');

      try {
        final Map<String, dynamic> jsonData = json.decode(responseBody);

        // 检查是否需要激活
        if (jsonData.containsKey('activation')) {
          print('设备需要激活，激活码: ${jsonData['activation']['code']}');
          return OtaCheckResult(
            websocketUrl: jsonData['websocket']['url'],
            firmwareVersion: jsonData['firmware']['version'],
            firmwareUrl: jsonData['firmware']['url'],
            activationCode: jsonData['activation']['code'],
            activationMessage: jsonData['activation']['message'],
            deviceId: jsonData['activation']['challenge'],
            needsActivation: true,
          );
        }

        return OtaCheckResult.fromJson(jsonData);
      } catch (e) {
        print('解析OTA响应失败: $e，使用默认配置');
        return OtaCheckResult.defaultValues(formattedDeviceId);
      }
    } catch (e) {
      print('OTA检查异常: $e，使用默认配置');
      return OtaCheckResult.defaultValues(_cachedDeviceId ?? DEFAULT_MAC);
    }
  }
}
