import 'dart:convert';

class OtaRequest {
  final int version;
  final String uuid;
  final Application application;
  final Ota ota;
  final Board board;
  final int flashSize;
  final int minimumFreeHeapSize;
  final String macAddress;
  final String chipModelName;
  final ChipInfo chipInfo;
  final List<PartitionTable> partitionTable;

  OtaRequest({
    this.version = 0,
    this.uuid = '',
    required this.application,
    required this.ota,
    required this.board,
    this.flashSize = 0,
    this.minimumFreeHeapSize = 0,
    required this.macAddress,
    this.chipModelName = '',
    required this.chipInfo,
    required this.partitionTable,
  });

  Map<String, dynamic> toJson() => {
    'version': version,
    'uuid': uuid,
    'application': application.toJson(),
    'ota': ota.toJson(),
    'board': board.toJson(),
    'flash_size': flashSize,
    'minimum_free_heap_size': minimumFreeHeapSize,
    'mac_address': macAddress,
    'chip_model_name': chipModelName,
    'chip_info': chipInfo.toJson(),
    'partition_table': partitionTable.map((x) => x.toJson()).toList(),
  };

  String toString() => json.encode(toJson());
}

class Application {
  final String name;
  final String version;
  final String compileTime;
  final String idfVersion;
  final String elfSha256;

  Application({
    this.name = 'web_test_client',
    this.version = '1.0.0',
    this.compileTime = '2025-04-16 10:00:00',
    this.idfVersion = '4.4.3',
    this.elfSha256 = '1234567890abcdef1234567890abcdef1234567890abcdef',
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'version': version,
    'compile_time': compileTime,
    'idf_version': idfVersion,
    'elf_sha256': elfSha256,
  };
}

class Ota {
  final String label;

  Ota({this.label = 'web_test_client'});

  Map<String, dynamic> toJson() => {'label': label};
}

class Board {
  final String type;
  final String ssid;
  final int rssi;
  final int channel;
  final String ip;
  final String mac;

  Board({
    this.type = 'web_test_client',
    this.ssid = 'web_test_client',
    this.rssi = 0,
    this.channel = 0,
    this.ip = '192.168.1.1',
    required this.mac,
  });

  Map<String, dynamic> toJson() => {
    'type': type,
    'ssid': ssid,
    'rssi': rssi,
    'channel': channel,
    'ip': ip,
    'mac': mac,
  };
}

class ChipInfo {
  final int model;
  final int cores;
  final int revision;
  final int features;

  ChipInfo({
    this.model = 0,
    this.cores = 0,
    this.revision = 0,
    this.features = 0,
  });

  Map<String, dynamic> toJson() => {
    'model': model,
    'cores': cores,
    'revision': revision,
    'features': features,
  };
}

class PartitionTable {
  final String label;
  final int type;
  final int subtype;
  final int address;
  final int size;

  PartitionTable({
    this.label = '',
    this.type = 0,
    this.subtype = 0,
    this.address = 0,
    this.size = 0,
  });

  Map<String, dynamic> toJson() => {
    'label': label,
    'type': type,
    'subtype': subtype,
    'address': address,
    'size': size,
  };
}
