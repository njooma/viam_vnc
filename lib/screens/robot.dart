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
  final bool _useNativeVNC;

  const RobotScreen(this._viam, this.robot, this._useNativeVNC, {super.key});

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

class _RobotState extends State<RobotScreen> with WindowListener {
  final List<_Log> logs = [];
  final ScrollController _logsController = ScrollController();

  Process? tunnelProc;
  bool tunnelReady = false;

  String _vncPassword = "";

  Future<void> start() async {
    final viamCLI = await getCLI();

    final parts = await widget._viam.appClient.listRobotParts(widget.robot.id);
    final mainPart = parts.firstWhere((part) => part.mainPart);
    final robotConfig = StructUtils(mainPart.robotConfig).toMap();
    final password = await getVNCPassword(robotConfig);
    setState(() {
      _vncPassword = password;
    });

    tunnelProc = await Process.start(viamCLI, [
      "--debug",
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
    tunnelProc!.stdout.transform(utf8.decoder).forEach((log) {
      if (log.contains("tunneling connections from local port")) {
        setState(() {
          tunnelReady = true;
        });
      } else if (log.contains("tunnel to client closed")) {
        setState(() {
          tunnelReady = false;
        });
      }
      setState(() {
        logs.add(_Log(_LogType.STD_OUT, log));
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
            logs.add(_Log(_LogType.STD_ERR, log));
            _logsController.animateTo(
              _logsController.position.maxScrollExtent,
              duration: Duration(milliseconds: 100),
              curve: Curves.decelerate,
            );
          }),
        );
    while (!tunnelReady) {
      await Future.delayed(Duration(milliseconds: 100));
    }

    setState(() {
      logs.add(_Log(_LogType.STD_OUT, "Connected! Starting VNC viewer..."));
    });

    if (widget._useNativeVNC) {
      launchVNC();
    }
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    releaseResources();
    start();
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
  }

  Future<void> launchVNC() async {
    await launchUrlString("vnc://:$_vncPassword@localhost:5901");
  }

  Widget logsContainer(Widget logsList) {
    if (tunnelReady && widget._useNativeVNC) {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Connected to ${widget.robot.name}"),
        actions: [
          if (tunnelReady && widget._useNativeVNC)
            TextButton(
              onPressed: launchVNC,
              child: const Text("Relaunch VNC Viewer"),
            ),
        ],
      ),
      body: Column(
        children: [
          if (!tunnelReady)
            Expanded(child: CircularProgressIndicator.adaptive()),
          if (tunnelReady && !widget._useNativeVNC)
            Expanded(
              child: InteractiveViewer(
                constrained: true,
                child: RemoteFrameBufferWidget(
                  hostName: "localhost",
                  port: 5901,
                  password: _vncPassword,
                ),
              ),
            ),
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
                      color:
                          l.type == _LogType.STD_ERR
                              ? Colors.red
                              : Colors.black,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
