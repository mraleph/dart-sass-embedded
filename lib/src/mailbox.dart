// @dart=3.0

import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:sass_embedded/src/synchronization_primitives.dart';

//
// Single producer single consumer mailbox for synchronous communication
// between two isolates.
//

final class _MailboxRepr extends Struct {
  external Pointer<Uint8> buffer;

  @Int32()
  external int bufferLength;

  @Int32()
  external int state;
}

typedef SendableMailbox = (int, int, int);

/// Simple one message mailbox.
class Mailbox {
  final Pointer<_MailboxRepr> _mailbox;
  final Mutex mutex;
  final ConditionVariable condVar;

  bool isRunning = true;

  static const stateEmpty = 0;
  static const stateFull = 1;

  static final finalizer = Finalizer((Pointer<_MailboxRepr> mailbox) {
    calloc.free(mailbox.ref.buffer);
    calloc.free(mailbox);
  });

  Mailbox()
      : _mailbox = calloc.allocate(sizeOf<_MailboxRepr>()),
        mutex = Mutex(),
        condVar = ConditionVariable() {
    finalizer.attach(this, _mailbox);
  }

  /// Create a mailbox pointing to an already existing mailbox.
  Mailbox.fromAddresses(SendableMailbox addresses)
      : _mailbox = Pointer.fromAddress(addresses.$1),
        mutex = Mutex.fromAddress(addresses.$2),
        condVar = ConditionVariable.fromAddress(addresses.$3);

  SendableMailbox toAddresses() =>
      (_mailbox.address, mutex.rawAddress, condVar.rawAddress);

  void send(Uint8List? message) {
    if (_mailbox.ref.state != stateEmpty) {
      throw 'Invalid state: ${_mailbox.ref.state}';
    }

    final buffer = message != null ? _toBuffer(message) : nullptr;

    mutex.holdingLock(() {
      if (_mailbox.ref.state != stateEmpty) {
        throw 'Invalid state: ${_mailbox.ref.state}';
      }

      _mailbox.ref.state = stateFull;
      _mailbox.ref.buffer = buffer;
      _mailbox.ref.bufferLength = message?.length ?? 0;

      condVar.notify();
    });
  }

  static final _emptyResponse = Uint8List(0);

  Uint8List receive() => mutex.holdingLock(() {
        // Wait for request to arrive.
        while (_mailbox.ref.state != stateFull) {
          condVar.wait(mutex);
        }

        final result = _toList(
            (buffer: _mailbox.ref.buffer, length: _mailbox.ref.bufferLength));

        _mailbox.ref.state = stateEmpty;
        _mailbox.ref.buffer = nullptr;
        _mailbox.ref.bufferLength = 0;
        return result;
      });

  int get rawAddress => _mailbox.address;

  static Uint8List _toList(({Pointer<Uint8> buffer, int length}) data) {
    if (data.length == 0) {
      return _emptyResponse;
    }

    // Ideally we would like just to do `buffer.asTypedList(length)` and
    // have finaliser take care of freeing, but we currently can't express
    // this in pure Dart in a reliable way without some hacks - because
    // [Finalizer] only runs callbacks at the top of the event loop and
    // [NativeFinalizer] does not accept Dart functions as a finalizer.
    final list = Uint8List(data.length);
    for (var i = 0; i < data.length; i++) list[i] = data.buffer[i];
    malloc.free(data.buffer);
    return list;
  }

  static Pointer<Uint8> _toBuffer(Uint8List list) {
    final buffer = malloc.allocate<Uint8>(list.length);
    for (var i = 0; i < list.length; i++) buffer[i] = list[i];
    return buffer;
  }
}
