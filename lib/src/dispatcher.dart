// Copyright 2019 Google Inc. Use of this source code is governed by an
// MIT-style license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:protobuf/protobuf.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:stream_channel/stream_channel.dart';

import 'embedded_sass.pb.dart';
import 'utils.dart';
import 'mailbox.dart';

const _responseTypeFor = <OutboundMessage_Message, InboundMessage_Message>{
  OutboundMessage_Message.canonicalizeRequest:
      InboundMessage_Message.canonicalizeResponse,
  OutboundMessage_Message.importRequest: InboundMessage_Message.importResponse,
  OutboundMessage_Message.fileImportRequest:
      InboundMessage_Message.fileImportResponse,
  OutboundMessage_Message.functionCallRequest:
      InboundMessage_Message.functionCallResponse,
};

/// A class that dispatches messages to and from the host.
class MainDispatcher {
  int _isolates = 0;

  /// The channel of encoded protocol buffers, connected to the host.
  final StreamChannel<Uint8List> _channel;

  /// Completers awaiting responses to outbound requests.
  ///
  /// The completers are located at indexes in this list matching the request
  /// IDs. `null` elements indicate IDs whose requests have been responded to,
  /// and which are therefore free to re-use.
  final _outstandingRequests = <_OutstandingRequest?>[];

  /// Creates a [Dispatcher] that sends and receives encoded protocol buffers
  /// over [channel].
  MainDispatcher(this._channel);

  /// Listens for incoming `CompileRequests` and passes them to [callback].
  ///
  /// The callback must return a `CompileResponse` which is sent to the host.
  /// The callback may throw [ProtocolError]s, which will be sent back to the
  /// host. Neither `CompileResponse`s nor [ProtocolError]s need to set their
  /// `id` fields; the [Dispatcher] will take care of that.
  ///
  /// This may only be called once.
  void listen(
      FutureOr<OutboundMessage_CompileResponse> callback(
          Dispatcher dispatcher, InboundMessage_CompileRequest request)) {
    _channel.stream.listen((binaryMessage) async {
      InboundMessage? message;
      try {
        try {
          message = InboundMessage.fromBuffer(binaryMessage);
        } on InvalidProtocolBufferException catch (error) {
          throw _parseError(error.message);
        }

        switch (message.whichMessage()) {
          case InboundMessage_Message.versionRequest:
            var request = message.versionRequest;
            var response = versionResponse();
            response.id = request.id;
            _send(OutboundMessage()..versionResponse = response);
            break;

          case InboundMessage_Message.compileRequest:
            await _incrementConcurrency();

            final responseMailbox = Mailbox();

            final requestPort = ReceivePort();
            requestPort.listen((request) async {
              final bytes = request as Uint8List;
              final message = OutboundMessage.fromBuffer(bytes);

              switch (message.whichMessage()) {
                case OutboundMessage_Message.error:
                case OutboundMessage_Message.logEvent:
                  _channel.sink.add(bytes);
                  return;

                case OutboundMessage_Message.canonicalizeRequest:
                case OutboundMessage_Message.importRequest:
                case OutboundMessage_Message.fileImportRequest:
                case OutboundMessage_Message.functionCallRequest:
                  final response = await _sendRequest(
                      message, _responseTypeFor[message.whichMessage()]!);
                  responseMailbox.send(response);
                  break;

                default:
                  break;
              }
            });

            _channel.sink.add(await _runCompilationInNewIsolate(
                callback,
                binaryMessage,
                responseMailbox.rawAddress,
                requestPort.sendPort));
            _decrementConcurrency();
            break;

          case InboundMessage_Message.canonicalizeResponse:
            var response = message.canonicalizeResponse;
            _dispatchResponse(response.id,
                InboundMessage_Message.canonicalizeResponse, binaryMessage);
            break;

          case InboundMessage_Message.importResponse:
            var response = message.importResponse;
            _dispatchResponse(response.id,
                InboundMessage_Message.importResponse, binaryMessage);
            break;

          case InboundMessage_Message.fileImportResponse:
            var response = message.fileImportResponse;
            _dispatchResponse(response.id,
                InboundMessage_Message.fileImportResponse, binaryMessage);
            break;

          case InboundMessage_Message.functionCallResponse:
            var response = message.functionCallResponse;
            _dispatchResponse(response.id,
                InboundMessage_Message.functionCallResponse, binaryMessage);
            break;

          case InboundMessage_Message.notSet:
            throw _parseError("InboundMessage.message is not set.");

          default:
            throw _parseError(
                "Unknown message type: ${message.toDebugString()}");
        }
      } on ProtocolError catch (error) {
        error.id = _inboundId(message) ?? errorId;
        stderr.write("Host caused ${error.type.name.toLowerCase()} error");
        if (error.id != errorId) stderr.write(" with request ${error.id}");
        stderr.writeln(": ${error.message}");
        sendError(error);
        // PROTOCOL error from https://bit.ly/2poTt90
        exitCode = 76;
        _channel.sink.close();
      } catch (error, stackTrace) {
        var errorMessage = "$error\n${Chain.forTrace(stackTrace)}";
        stderr.write("Internal compiler error: $errorMessage");
        sendError(ProtocolError()
          ..type = ProtocolErrorType.INTERNAL
          ..id = _inboundId(message) ?? errorId
          ..message = errorMessage);
        _channel.sink.close();
      }
    });
  }

  /// Sends [event] to the host.
  void sendLog(OutboundMessage_LogEvent event) =>
      _send(OutboundMessage()..logEvent = event);

  /// Sends [error] to the host.
  void sendError(ProtocolError error) =>
      _send(OutboundMessage()..error = error);

  /// Sends [request] to the host and returns the message sent in response.
  Future<Uint8List> _sendRequest(
      OutboundMessage request, InboundMessage_Message expectedResponse) {
    var id = _nextRequestId();
    _setOutboundId(request, id);
    _send(request);

    var completer = Completer<Uint8List>();
    _outstandingRequests[id] = _OutstandingRequest(completer, expectedResponse);
    return completer.future;
  }

  /// Returns an available request ID, and guarantees that its slot is available
  /// in [_outstandingRequests].
  int _nextRequestId() {
    for (var i = 0; i < _outstandingRequests.length; i++) {
      if (_outstandingRequests[i] == null) return i;
    }

    // If there are no empty slots, add another one.
    _outstandingRequests.add(null);
    return _outstandingRequests.length - 1;
  }

  /// Dispatches [response] to the appropriate outstanding request.
  ///
  /// Throws an error if there's no outstanding request with the given [id] or
  /// if that request is expecting a different type of response.
  void _dispatchResponse(
      int id, InboundMessage_Message responseType, Uint8List binaryMessage) {
    _OutstandingRequest? request;
    if (id < _outstandingRequests.length) {
      request = _outstandingRequests[id];
      _outstandingRequests[id] = null;
    }

    if (request == null) {
      throw paramsError(
          "Response ID $id doesn't match any outstanding requests.");
    } else if (responseType != request.expected) {
      throw paramsError("Request ID $id doesn't match response type "
          "$responseType.");
    }

    request.completer.complete(binaryMessage);
  }

  /// Sends [message] to the host.
  void _send(OutboundMessage message) =>
      _channel.sink.add(message.writeToBuffer());

  /// Returns a [ProtocolError] with type `PARSE` and the given [message].
  ProtocolError _parseError(String message) => ProtocolError()
    ..type = ProtocolErrorType.PARSE
    ..message = message;

  /// Returns the id for [message] if it it's a request, or `null`
  /// otherwise.
  int? _inboundId(InboundMessage? message) {
    if (message == null) return null;
    switch (message.whichMessage()) {
      case InboundMessage_Message.compileRequest:
        return message.compileRequest.id;
      default:
        return null;
    }
  }

  /// Sets the id for [message] to [id].
  ///
  /// Throws an [ArgumentError] if [message] doesn't have an id field.
  void _setOutboundId(OutboundMessage message, int id) {
    switch (message.whichMessage()) {
      case OutboundMessage_Message.compileResponse:
        message.compileResponse.id = id;
        break;
      case OutboundMessage_Message.canonicalizeRequest:
        message.canonicalizeRequest.id = id;
        break;
      case OutboundMessage_Message.importRequest:
        message.importRequest.id = id;
        break;
      case OutboundMessage_Message.fileImportRequest:
        message.fileImportRequest.id = id;
        break;
      case OutboundMessage_Message.functionCallRequest:
        message.functionCallRequest.id = id;
        break;
      case OutboundMessage_Message.versionResponse:
        message.versionResponse.id = id;
        break;
      default:
        throw ArgumentError("Unknown message type: ${message.toDebugString()}");
    }
  }

  /// Creates a [OutboundMessage_VersionResponse]
  static OutboundMessage_VersionResponse versionResponse() {
    return OutboundMessage_VersionResponse()
      ..protocolVersion = const String.fromEnvironment("protocol-version")
      ..compilerVersion = const String.fromEnvironment("compiler-version")
      ..implementationVersion =
          const String.fromEnvironment("implementation-version")
      ..implementationName = "Dart Sass";
  }

  Future<Uint8List> _runCompilationInNewIsolate(
      FutureOr<OutboundMessage_CompileResponse> Function(
              Dispatcher dispatcher, InboundMessage_CompileRequest request)
          callback,
      Uint8List binaryMessage,
      int mailboxAddr,
      SendPort sendPort) {
    return Isolate.run<Uint8List>(() async {
      var dispatcher = Dispatcher(mailboxAddr, sendPort);
      var request = InboundMessage.fromBuffer(binaryMessage).compileRequest;
      var response = await callback(dispatcher, request);
      response.id = request.id;
      return (OutboundMessage()..compileResponse = response).writeToBuffer();
    });
  }

  // Prevent too many concurrent compilations which might cause us to get
  // stuck due to limits on the number of concurrently executing isolates
  // within the isolate group.
  final List<Completer<void>> _pending = [];

  Future<void> _incrementConcurrency() async {
    if (_isolates > 10) {
      final completer = Completer<void>();
      _pending.add(completer);
      await completer.future;
    }
    _isolates++;
  }

  void _decrementConcurrency() {
    _isolates--;
    if (_pending.isNotEmpty) {
      _pending.removeLast().complete();
    }
  }
}

class Dispatcher {
  final Mailbox responseMailbox;
  final SendPort requestPort;

  Dispatcher(int mailboxAddr, this.requestPort)
      : responseMailbox = Mailbox.fromAddress(mailboxAddr);

  InboundMessage_CanonicalizeResponse sendCanonicalizeRequest(
          OutboundMessage_CanonicalizeRequest request) =>
      _sendRequest<InboundMessage_CanonicalizeResponse>(
          OutboundMessage()..canonicalizeRequest = request);

  InboundMessage_ImportResponse sendImportRequest(
          OutboundMessage_ImportRequest request) =>
      _sendRequest<InboundMessage_ImportResponse>(
          OutboundMessage()..importRequest = request);

  InboundMessage_FileImportResponse sendFileImportRequest(
          OutboundMessage_FileImportRequest request) =>
      _sendRequest<InboundMessage_FileImportResponse>(
          OutboundMessage()..fileImportRequest = request);

  InboundMessage_FunctionCallResponse sendFunctionCallRequest(
          OutboundMessage_FunctionCallRequest request) =>
      _sendRequest<InboundMessage_FunctionCallResponse>(
          OutboundMessage()..functionCallRequest = request);

  void sendError(ProtocolError error) =>
      _send(OutboundMessage()..error = error);

  void sendLog(OutboundMessage_LogEvent event) =>
      _send(OutboundMessage()..logEvent = event);

  void _send(OutboundMessage message) {
    requestPort.send(message.writeToBuffer());
  }

  /// Sends [request] to the host and returns the message sent in response.
  T _sendRequest<T extends GeneratedMessage>(OutboundMessage request) {
    _send(request);
    return unwrap(InboundMessage.fromBuffer(responseMailbox.receive()));
  }

  T unwrap<T extends GeneratedMessage>(InboundMessage message) {
    GeneratedMessage? unwrapped;
    switch (message.whichMessage()) {
      case InboundMessage_Message.canonicalizeResponse:
        unwrapped = message.canonicalizeResponse;
        break;

      case InboundMessage_Message.importResponse:
        unwrapped = message.importResponse;
        break;

      case InboundMessage_Message.fileImportResponse:
        unwrapped = message.fileImportResponse;
        break;

      case InboundMessage_Message.functionCallResponse:
        unwrapped = message.functionCallResponse;
        break;

      default:
        break;
    }

    if (unwrapped is! T) {
      throw paramsError("Request doesn't match response type "
          "${unwrapped.runtimeType}.");
    }

    return unwrapped;
  }
}

class _OutstandingRequest {
  final Completer<Uint8List> completer;
  final InboundMessage_Message expected;

  _OutstandingRequest(this.completer, this.expected);
}
