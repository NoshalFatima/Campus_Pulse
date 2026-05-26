// lib/services/onesignal_web_impl.dart
// Web pe yeh file use hogi — dart:js_interop yahan hai

import 'dart:js_interop';

@JS('oneSignalWebLogin')
external JSPromise _jsLogin(JSString uid);

@JS('oneSignalWebLogout')
external JSPromise _jsLogout();

@JS('_osWebSubId')
external JSString? get _jsSubId;

Future<void> oneSignalWebLogin(String uid) async {
  try {
    await _jsLogin(uid.toJS).toDart;
  } catch (e) {
    // ignore
  }
}

Future<void> oneSignalWebLogout() async {
  try {
    await _jsLogout().toDart;
  } catch (e) {
    // ignore
  }
}

Future<String> getWebSubId() async {
  await Future.delayed(const Duration(seconds: 2));
  return _jsSubId?.toDart ?? '';
}