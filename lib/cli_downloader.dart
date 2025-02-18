import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

Future<String> getCLI({bool forceDownload = false}) async {
  final (os, arch) = _archString();
  final dir = await getApplicationSupportDirectory();
  String path = "${dir.path}${Platform.pathSeparator}viam-cli";
  if (os == "windows") {
    path += ".exe";
  }
  final file = File(path);
  if (!forceDownload && await file.exists()) {
    return path;
  }
  await _downloadCLI(file);
  await _makeExecutable(file);
  return path;
}

Future<void> _downloadCLI(File downloadFile) async {
  final (os, arch) = _archString();
  String url =
      "https://storage.googleapis.com/packages.viam.com/apps/viam-cli/viam-cli-latest-$os-$arch";
  if (os == "windows") {
    url += ".exe";
  }
  final client = HttpClient();
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close();
  if (response.statusCode != 200) {
    throw Exception("Failed to download CLI: ${response.statusCode}");
  }
  var bytes = await consolidateHttpClientResponseBytes(response);
  await downloadFile.writeAsBytes(bytes);
}

(String, String) _archString() {
  final abi = Abi.current();
  switch (abi) {
    case Abi.windowsX64:
      return ("windows", "amd64");
    case Abi.linuxArm64:
      return ("linux", "arm64");
    case Abi.linuxX64:
      return ("linux", "amd64");
    case Abi.macosArm64:
      return ("darwin", "arm64");
    case Abi.macosX64:
      return ("darwin", "amd64");
    default:
      throw UnsupportedError("Unsupported ABI: $abi");
  }
}

Future<void> _makeExecutable(File file) async {
  if (file.path.contains(".exe")) {
    return;
  }
  final process = await Process.run("chmod", ["+x", file.path]);
  final exitCode = process.exitCode;
  if (exitCode != 0) {
    throw Exception("Failed to make file executable: $exitCode");
  }
}
