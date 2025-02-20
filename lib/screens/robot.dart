import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rfb/flutter_rfb.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:viam_sdk/protos/app/app.dart';
import 'package:viam_sdk/src/utils.dart';
import 'package:viam_sdk/viam_sdk.dart';
import 'package:window_manager/window_manager.dart';

import '../cli_downloader.dart';

class RobotScreen extends StatefulWidget {
  final Viam _viam;
  final Robot robot;

  const RobotScreen(this._viam, this.robot, {super.key});

  @override
  State<StatefulWidget> createState() => _RobotState();
}

// ignore: constant_identifier_names
enum _LogType { STD_OUT, STD_ERR }

class _Log {
  final _LogType type;
  final String message;

  const _Log(this.type, this.message);
}

enum _State { init, connecting, connected }

class _RobotState extends State<RobotScreen> with WindowListener {
  _State _state = _State.init;

  bool _useExternalVNC = false;
  bool _debugMode = false;

  final List<_Log> logs = [];
  final ScrollController _logsController = ScrollController();

  Process? tunnelProc;
  Process? vncProc;

  String _vncPassword = "";

  Future<void> start() async {
    setState(() {
      _state = _State.connecting;
    });
    final viamCLI = await getCLI();

    final parts = await widget._viam.appClient.listRobotParts(widget.robot.id);
    final mainPart = parts.firstWhere((part) => part.mainPart);
    final robotConfig = StructUtils(mainPart.robotConfig).toMap();
    final password = await getVNCPassword(robotConfig);
    setState(() {
      _vncPassword = password;
    });

    List<String> args = _debugMode ? ["--debug"] : [];
    args.addAll([
      "machine",
      "part",
      "tunnel",
      "--part",
      mainPart.id,
      "--destination-port",
      "5900",
      "--local-port",
      "5901",
    ]);
    tunnelProc = await Process.start(viamCLI, args);
    tunnelProc!.stdout.transform(utf8.decoder).forEach((log) {
      if (log.contains("tunneling connections from local port")) {
        setState(() {
          _state = _State.connected;
        });
      } else if (log.contains("tunnel to client closed")) {
        setState(() {
          _state = _State.init;
        });
      }
      setState(() {
        stdLog(log);
        _logsController.animateTo(
          _logsController.position.maxScrollExtent,
          duration: Duration(milliseconds: 100),
          curve: Curves.decelerate,
        );
      });
    });
    tunnelProc!.stderr
        .transform(utf8.decoder)
        .forEach(
          (log) => setState(() {
            errLog(log);
            _logsController.animateTo(
              _logsController.position.maxScrollExtent,
              duration: Duration(milliseconds: 100),
              curve: Curves.decelerate,
            );
          }),
        );
    while (_state != _State.connected) {
      await Future.delayed(Duration(milliseconds: 100));
    }

    stdLog("Connected! Starting VNC viewer...");

    if (_useExternalVNC) {
      launchVNC();
    }
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    releaseResources();
  }

  @override
  void dispose() {
    releaseResources();
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    super.onWindowClose();
    releaseResources();
  }

  void releaseResources() {
    tunnelProc?.kill();
    vncProc?.kill();
  }

  Future<void> launchVNC() async {
    final url = "vnc://:$_vncPassword@127.0.0.1:5901";
    if (await canLaunchUrlString(url)) {
      await launchUrlString(url);
    } else if (Platform.isWindows) {
      final vncExe = "assets\\exe\\vncviewer.exe";
      vncProc = await Process.start(vncExe, [
        "-connect",
        "127.0.0.1:5901",
        "-password",
        _vncPassword,
      ]);
      vncProc!.stdout.transform(utf8.decoder).forEach((log) {
        stdLog(log);
        _logsController.animateTo(
          _logsController.position.maxScrollExtent,
          duration: Duration(milliseconds: 100),
          curve: Curves.decelerate,
        );
      });
      vncProc!.stderr.transform(utf8.decoder).forEach((log) {
        errLog(log);
        _logsController.animateTo(
          _logsController.position.maxScrollExtent,
          duration: Duration(milliseconds: 100),
          curve: Curves.decelerate,
        );
      });
    } else {
      errLog("Could not launch external VNC viewer");
    }
  }

  Widget logsContainer(Widget logsList) {
    if (_state == _State.connected && _useExternalVNC) {
      return Expanded(child: logsList);
    } else {
      return SizedBox(height: 200, child: logsList);
    }
  }

  Future<String> getVNCPassword(Map<String, dynamic> config) async {
    final components = config["components"] as List<dynamic>;
    final vncComponent = components.firstWhere(
      (component) => component["model"] == "viam:tightvnc:server",
    );
    final attrs = vncComponent["attributes"];
    final password = attrs["password"] as String;
    return password;
  }

  void stdLog(String log) {
    setState(() {
      logs.add(_Log(_LogType.STD_OUT, log));
    });
  }

  void errLog(String log) {
    setState(() {
      logs.add(_Log(_LogType.STD_ERR, log));
    });
  }

  @override
  Widget build(BuildContext context) {
    String title = "Connect to ${widget.robot.name}";
    switch (_state) {
      case _State.connecting:
        title = "Connecting to ${widget.robot.name}";
      case _State.connected:
        title = "Connected to ${widget.robot.name}";
      default:
        title = "Connect to ${widget.robot.name}";
    }

    List<Widget> body = [];
    switch (_state) {
      case _State.init:
        body = [
          Table(
            columnWidths: {
              0: IntrinsicColumnWidth(),
              1: IntrinsicColumnWidth(),
            },
            children: [
              TableRow(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Use external VNC viewer"),
                      Text(
                        "This may be faster, but will open an additional program on your device.",
                        style: TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
                  Switch.adaptive(
                    value: _useExternalVNC,
                    onChanged:
                        (isOn) => setState(() {
                          _useExternalVNC = isOn;
                        }),
                  ),
                ],
              ),
              TableRow(
                children: [
                  Text("Enable debug logs"),
                  Switch.adaptive(
                    value: _debugMode,
                    onChanged:
                        (isOn) => setState(() {
                          _debugMode = isOn;
                        }),
                  ),
                ],
              ),
            ],
          ),
          TextButton(onPressed: start, child: Text("Connect")),
        ];
      case _State.connecting:
        body = [Expanded(child: CircularProgressIndicator.adaptive())];
      case _State.connected:
        if (!_useExternalVNC) {
          body = [
            Expanded(
              child: InteractiveViewer(
                constrained: true,
                maxScale: 10,
                child: RemoteFrameBufferWidget(
                  connectingWidget: CircularProgressIndicator.adaptive(),
                  hostName: "127.0.0.1",
                  port: 5901,
                  password: _vncPassword,
                  onError: (error) => errLog("VNC Error: ${error.toString()}"),
                ),
              ),
            ),
          ];
        }
    }
    body.add(
      logsContainer(
        ListView.builder(
          controller: _logsController,
          itemCount: logs.length,
          itemBuilder: (_, index) {
            final l = logs[index];
            return ListTile(
              title: Text(
                l.message,
                style: TextStyle(
                  color: l.type == _LogType.STD_ERR ? Colors.red : Colors.black,
                ),
              ),
            );
          },
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (_state == _State.connected && _useExternalVNC)
            TextButton(
              onPressed: launchVNC,
              child: const Text("Relaunch VNC Viewer"),
            ),
        ],
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: body,
      ),
    );
  }
}
