import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rfb/flutter_rfb.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:viam_sdk/protos/app/app.dart';
import 'package:viam_sdk/src/utils.dart';
import 'package:viam_sdk/viam_sdk.dart';
import 'package:window_manager/window_manager.dart';

import '../helpers.dart';

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

enum _State { init, connecting, connected, error }

class _RobotState extends State<RobotScreen> with WindowListener {
  _State _state = _State.init;

  bool _useExternalVNC = true;
  bool _debugMode = false;

  final List<_Log> logs = [];
  final ScrollController _logsController = ScrollController();
  bool _scrolled = false;

  String? tunnelCmd;
  Process? tunnelProc;
  Process? vncProc;

  String _vncPassword = "";

  Future<void> start() async {
    setState(() {
      _state = _State.connecting;
    });
    if (_debugMode) {
      stdLog("DEBUG: Getting Viam CLI...");
    }
    final viamCLI = await getCLI();
    if (_debugMode) {
      stdLog("DEBUG: Done! Viam CLI located at: $viamCLI");
    }

    if (_debugMode) {
      stdLog(
        "DEBUG: Getting main part for machine with ID: ${widget.robot.id} ...",
      );
    }
    final parts = await widget._viam.appClient.listRobotParts(widget.robot.id);
    if (_debugMode) {
      stdLog("DEBUG: Got all parts, filtering for main...");
    }
    final mainPart = parts.firstWhere((part) => part.mainPart);
    if (_debugMode) {
      stdLog("DEBUG: Found main part!");
    }

    if (_debugMode) {
      stdLog("DEBUG: Destructuring machine config...");
    }
    final robotConfig = StructUtils(mainPart.robotConfig).toMap();
    if (_debugMode) {
      stdLog("DEBUG: Done!");
    }

    if (_debugMode) {
      stdLog("DEBUG: Obtaining VNC password...");
    }
    try {
      final password = await getVNCPassword(robotConfig);
      if (_debugMode) {
        stdLog("DEBUG: Done!");
      }
      setState(() {
        _vncPassword = password;
      });
    } catch (err) {
      errLog(err.toString());
      setState(() {
        _state = _State.error;
      });
      return;
    }

    await startTunnel(viamCLI, mainPart);
    while (_state != _State.connected) {
      await Future.delayed(Duration(milliseconds: 100));
    }

    stdLog("Connected! Starting VNC viewer...");

    if (_useExternalVNC) {
      launchVNC();
    }
  }

  Future<void> startTunnel(String viamCLI, RobotPart mainPart) async {
    setState(() {
      _state = _State.connecting;
    });
    tunnelProc?.kill();

    bool needsHostUpdate = false;

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
    setState(() {
      tunnelCmd = "$viamCLI ${args.join(" ")}";
    });
    stdLog("Starting tunnel to machine...");
    stdLog(tunnelCmd!);

    tunnelProc = await Process.start(viamCLI, args, runInShell: false);
    setState(() {
      tunnelProc = tunnelProc;
    });
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
      stdLog(log);
    });
    tunnelProc!.stderr.transform(utf8.decoder).forEach((log) {
      errLog(log);
      if (log.contains(
            "Failed to create listener listen tcp: lookup localhost",
          ) &&
          Platform.isWindows) {
        if (_debugMode) {
          stdLog("DEBUG: Adding localhost to hosts file");
        }
        needsHostUpdate = true;
      }
    });

    while (_state == _State.connecting) {
      if (needsHostUpdate) {
        try {
          await updateHosts();
          return await startTunnel(viamCLI, mainPart);
        } catch (err) {
          setState(() {
            _state = _State.error;
          });
          return;
        }
      }
      await Future.delayed(Duration(milliseconds: 100));
    }
  }

  Future<void> updateHosts() async {
    await setupHostsUpdater();
    final path = await getHostsUpdaterPath();
    if (path == null) {
      return;
    }
    final process = await Process.run(path, [], runInShell: true);
    if (process.exitCode == 0) {
      if (_debugMode) {
        stdLog("DEBUG: Successfully updated hosts file");
      }
      return;
    }
    errLog(process.stderr.toString());
    throw Exception("Could not update hosts");
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
      final vncExe = await getVNCPath();
      if (vncExe == null) {
        return errLog("Could not load external Windows VNC viewer executable");
      }
      vncProc = await Process.start(vncExe, [
        "-connect",
        "127.0.0.1:5901",
        "-password",
        _vncPassword,
        "-autoscaling",
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

  Future<String> getVNCPassword(Map<String, dynamic> config) async {
    if (_debugMode) {
      stdLog(
        "DEBUG: Extracting list of components from machine's configuration...",
      );
    }
    final components =
        config.putIfAbsent("components", () => []) as List<dynamic>;
    String? password = _getVNCPasswordFromComponents(components);
    if (password != null) {
      return password;
    }

    if (_debugMode) {
      stdLog(
        "DEBUG: No tight-vnc-server found on the main part. Checking fragments...",
      );
    }
    final fragments =
        config.putIfAbsent("fragments", () => []) as List<dynamic>;
    for (final fragment in fragments) {
      final frag = fragment as String;
      if (_debugMode) {
        stdLog("DEBUG: Checking fragment $frag");
      }
      final components = await _getFragmentComponents(frag);
      String? password = _getVNCPasswordFromComponents(components);
      if (password != null) {
        return password;
      }
    }

    if (_debugMode) {
      stdLog("DEBUG: No tight-vnc-server with password found in fragments");
    }
    throw Exception("No VNC component/password found");
  }

  Future<List<dynamic>> _getFragmentComponents(String id) async {
    final fragment = await widget._viam.appClient.getFragment(id);
    final configStruct = fragment.fragment;
    final config = StructUtils(configStruct).toMap();
    final components = config["components"] as List<dynamic>;
    return components;
  }

  String? _getVNCPasswordFromComponents(List<dynamic> components) {
    if (_debugMode) {
      stdLog("DEBUG: Finding first tight-vnc-server component...");
    }
    final vncComponent = components.firstWhere(
      (component) => component["model"] == "viam:tightvnc:server",
      orElse: () => {},
    );
    if (vncComponent.isEmpty) {
      if (_debugMode) {
        stdLog("DEBUG: No tight-vnc-server component found!");
      }
      return null;
    }
    if (_debugMode) {
      stdLog(
        "DEBUG: Done! Found tight-vnc-server component! Getting component's attributes...",
      );
    }
    final attrs = vncComponent["attributes"];
    if (_debugMode) {
      stdLog("DEBUG: Done! Getting password from attributes...");
    }
    final password = attrs["password"] as String;
    if (_debugMode) {
      stdLog("DEBUG: Done! Returning password...");
    }
    return password;
  }

  void stdLog(String log) {
    setState(() {
      logs.add(_Log(_LogType.STD_OUT, log));
    });
    if (!_scrolled) {
      _scrollLogsToEnd();
    }
  }

  void errLog(String log) {
    setState(() {
      logs.add(_Log(_LogType.STD_ERR, log));
    });
    if (!_scrolled) {
      _scrollLogsToEnd();
    }
  }

  void _scrollLogsToEnd() {
    _logsController.animateTo(
      _logsController.position.maxScrollExtent + 100,
      duration: Duration(milliseconds: 100),
      curve: Curves.decelerate,
    );
  }

  Widget logsContainer(BuildContext context, Widget logsList) {
    if (_state == _State.connected && _useExternalVNC) {
      return Expanded(child: SelectionArea(child: logsList));
    } else {
      return Container(
        height: 200,
        decoration:
            (_state != _State.init)
                ? BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                )
                : null,
        child: SelectionArea(child: logsList),
      );
    }
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
        body = [
          Expanded(child: Center(child: CircularProgressIndicator.adaptive())),
          Padding(
            padding: EdgeInsets.all(4),
            child: Row(
              children: [
                Text("Tunnel command: "),
                Flexible(
                  child: Container(
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.all(Radius.circular(8)),
                    ),
                    child: Text(
                      "viam-cli ${(tunnelCmd?.split("viam-cli")?..removeAt(0))?.join("") ?? ""}",
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final viamCli = await getCLI();
                    Clipboard.setData(
                      ClipboardData(
                        text: tunnelCmd!.replaceAll(viamCli, '"$viamCli"'),
                      ),
                    );
                  },
                  child: Text("Copy"),
                ),
              ],
            ),
          ),
        ];
      case _State.connected:
        if (!_useExternalVNC) {
          body = [
            Expanded(
              child: InteractiveViewer(
                constrained: true,
                maxScale: 10,
                child: RemoteFrameBufferWidget(
                  connectingWidget: Center(
                    child: CircularProgressIndicator.adaptive(),
                  ),
                  hostName: "127.0.0.1",
                  port: 5901,
                  password: _vncPassword,
                  onError: (error) => errLog("VNC Error: ${error.toString()}"),
                ),
              ),
            ),
          ];
        }
      case _State.error:
        body = [
          Expanded(
            child: Center(
              child: Text(
                "Encountered error trying to connect.\nPlease check the logs for more info.",
                style: TextStyle(color: Theme.of(context).colorScheme.error),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ];
    }
    body.add(
      logsContainer(
        context,
        NotificationListener<UserScrollNotification>(
          onNotification: (notification) {
            setState(() {
              _scrolled = true;
            });
            return false;
          },
          child: ListView.builder(
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
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).textTheme.bodyMedium?.color ??
                                Colors.black,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    Widget? pinLogsButton;
    if (_scrolled) {
      pinLogsButton = FloatingActionButton(
        onPressed: () {
          setState(() {
            _scrolled = false;
          });
          _scrollLogsToEnd();
        },
        child: Icon(Icons.arrow_downward_rounded),
      );
    }

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
      floatingActionButton: pinLogsButton,
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: body,
      ),
    );
  }
}
