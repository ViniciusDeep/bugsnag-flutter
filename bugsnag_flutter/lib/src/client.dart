import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:bugsnag_flutter/src/bugsnag_stacktrace.dart';
import 'package:bugsnag_flutter/src/error_factory.dart';
import 'package:flutter/services.dart';

import 'model.dart';

typedef OnErrorCallback = FutureOr<bool> Function(Event);
typedef OnSessionCallback = FutureOr<bool> Function(Session);
typedef OnBreadcrumbCallback = FutureOr<bool> Function(Breadcrumb);

abstract class Client {
  Future<void> setUser({String? id, String? name, String? email});

  Future<User> getUser();

  Future<void> setContext(String? context);

  Future<String?> getContext();

  Future<void> notify(
    dynamic error, {
    StackTrace? stackTrace,
    OnErrorCallback? callback,
  });

  void addOnError(OnErrorCallback onError);

  void removeOnError(OnErrorCallback onError);
}

class DelegateClient implements Client {
  Client? _client;

  Client get client {
    final localClient = _client;
    if (localClient == null) {
      throw Exception(
          'You must start or attach bugsnag before calling any other methods');
    }

    return localClient;
  }

  set client(Client client) {
    _client = client;
  }

  @override
  Future<User> getUser() => client.getUser();

  @override
  Future<void> setUser({String? id, String? name, String? email}) =>
      client.setUser(id: id, name: name, email: email);

  @override
  Future<void> setContext(String? context) => client.setContext(context);

  @override
  Future<String?> getContext() => client.getContext();

  @override
  Future<void> notify(
    dynamic error, {
    StackTrace? stackTrace,
    OnErrorCallback? callback,
  }) =>
      client.notify(error, stackTrace: stackTrace, callback: callback);

  @override
  void addOnError(OnErrorCallback onError) => client.addOnError(onError);

  @override
  void removeOnError(OnErrorCallback onError) => client.removeOnError(onError);
}

class ChannelClient implements Client {
  static const MethodChannel _channel =
      MethodChannel('com.bugsnag/client', JSONMethodCodec());

  final Set<OnErrorCallback> _onErrorCallbacks = {};

  @override
  Future<User> getUser() async =>
      User.fromJson(await _channel.invokeMethod('getUser'));

  @override
  Future<void> setUser({String? id, String? name, String? email}) =>
      _channel.invokeMethod(
        'setUser',
        User(id: id, name: name, email: email),
      );

  @override
  Future<void> setContext(String? context) =>
      _channel.invokeMethod('setContext', {'context': context});

  @override
  Future<String?> getContext() => _channel.invokeMethod('getContext');

  @override
  void addOnError(OnErrorCallback onError) {
    _onErrorCallbacks.add(onError);
  }

  @override
  void removeOnError(OnErrorCallback onError) {
    _onErrorCallbacks.remove(onError);
  }

  @override
  Future<void> notify(
    dynamic error, {
    StackTrace? stackTrace,
    OnErrorCallback? callback,
  }) async {
    final errorPayload = ErrorFactory.instance.createError(error, stackTrace);
    final event = await _createEvent(errorPayload, unhandled: false);

    // The Platform doesn't "know" about the `Isolate` "thread" - so we add it
    event.threads.add(
      _createIsolateThread(Isolate.current, StackTrace.current),
    );

    for (final callback in _onErrorCallbacks) {
      if (!await callback(event)) {
        return;
      }
    }

    if (callback != null && !await callback(event)) {
      return;
    }

    await _deliverEvent(event);
  }

  Future<Event> _createEvent(
    Error error, {
    required bool unhandled,
  }) async {
    final eventJson = await _channel.invokeMethod(
      'createEvent',
      {
        'error': error,
        'unhandled': unhandled,
      },
    );

    return Event.fromJson(eventJson);
  }

  Future<void> _deliverEvent(Event event) =>
      _channel.invokeMethod('deliverEvent', event);

  Thread _createIsolateThread(Isolate isolate, StackTrace stackTrace) {
    return Thread(
      id: null,
      name: isolate.debugName,
      state: 'RUNNING',
      isErrorReportingThread: true,
      stacktrace: parseStackTraceString(stackTrace.toString())!,
    );
  }
}

class Bugsnag extends Client with DelegateClient {
  /// Attach Bugsnag to an already initialised native notifier, optionally
  /// adding to its existing configuration. Use [start] if your application
  /// is entirely built in Flutter.
  ///
  /// Use this method to initialize Flutter when developing a Hybrid app,
  /// where Bugsnag is being started by the native part of the app. For more
  /// information on starting Bugsnag natively, see our platform guides for:
  ///
  /// * Android: <https://docs.bugsnag.com/platforms/android/>
  /// * iOS: <https://docs.bugsnag.com/platforms/ios/>
  ///
  /// See also:
  ///
  /// * [start]
  /// * [setUser]
  /// * [setContext]
  /// * [addFeatureFlags]
  Future<void> attach({
    User? user,
    String? context,
    List<FeatureFlag>? featureFlags,
    List<OnSessionCallback> onSession = const [],
    List<OnBreadcrumbCallback> onBreadcrumb = const [],
    List<OnErrorCallback> onError = const [],
  }) async {
    final client = ChannelClient();
    bool attached = await ChannelClient._channel.invokeMethod('attach', {
      if (user != null) 'user': user,
      if (context != null) 'context': context,
      if (featureFlags != null) 'featureFlags': featureFlags,
    });

    if (!attached) {
      final platformStart =
          Platform.isAndroid ? 'Bugsnag.start()' : '[Bugsnag start]';
      final platformName = Platform.isAndroid ? 'Android' : 'iOS';

      throw Exception(
        'bugsnag.attach can only be called when the native layer has already been started, have you called $platformStart in your $platformName code?',
      );
    }

    client._onErrorCallbacks.addAll(onError);

    this.client = client;
  }
}

final Bugsnag bugsnag = Bugsnag();
