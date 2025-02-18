import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:viam_sdk/viam_sdk.dart';

import '../cli_downloader.dart';
import 'list_orgs.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<StatefulWidget> createState() => _LoginState();
}

class _LoginState extends State<LoginScreen> {
  bool _isLoading = true;
  late String viamCLI;
  String loginText = "";
  bool _isLoggingIn = false;

  @override
  void initState() {
    super.initState();
    _initState();
  }

  Future<void> _initState() async {
    viamCLI = await getCLI(forceDownload: false);

    final process = await Process.run(viamCLI, ["login", "print-access-token"]);
    if (process.exitCode != 0) {
      setState(() {
        _isLoading = false;
      });
    } else {
      navigateToOrgs();
    }
  }

  Future<void> onPressed() async {
    setState(() {
      _isLoggingIn = true;
    });
    final process = await Process.start(viamCLI, ["login"]);
    process.stdout.transform(utf8.decoder).listen((event) {
      setState(() {
        loginText += event;
      });
    });
    if (await process.exitCode == 0) {
      navigateToOrgs();
    } else {
      _isLoading = false;
    }
  }

  void navigateToOrgs() {
    final process = Process.runSync(viamCLI, ["login", "print-access-token"]);
    final accessToken = process.stdout.toString();
    final viam = Viam.withAccessToken(accessToken);
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => ListOrgsScreen(viam)));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child:
              _isLoading
                  ? CircularProgressIndicator.adaptive()
                  : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(loginText.replaceAll("Info: ", "")),
                      TextButton(
                        onPressed: _isLoggingIn ? null : onPressed,
                        child: Text("Login"),
                      ),
                    ],
                  ),
        ),
      ),
    );
  }
}
