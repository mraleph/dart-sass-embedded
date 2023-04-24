// @dart=3.0

import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

//
// POSIX threading primitives
//

/// Represents `pthread_mutex_t`
final class PthreadMutex extends Opaque {}

/// Represents `pthread_cond_t`
final class PthreadCond extends Opaque {}

@Native<Int Function(Pointer<PthreadMutex>, Pointer<Void>)>()
external int pthread_mutex_init(
    Pointer<PthreadMutex> mutex, Pointer<Void> attrs);

@Native<Int Function(Pointer<PthreadMutex>)>()
external int pthread_mutex_lock(Pointer<PthreadMutex> mutex);

@Native<Int Function(Pointer<PthreadMutex>)>()
external int pthread_mutex_unlock(Pointer<PthreadMutex> mutex);

@Native<Int Function(Pointer<PthreadMutex>)>()
external int pthread_mutex_destroy(Pointer<PthreadMutex> cond);

@Native<Int Function(Pointer<PthreadCond>, Pointer<Void>)>()
external int pthread_cond_init(Pointer<PthreadCond> cond, Pointer<Void> attrs);

@Native<Int Function(Pointer<PthreadCond>, Pointer<PthreadMutex>)>()
external int pthread_cond_wait(
    Pointer<PthreadCond> cond, Pointer<PthreadMutex> mutex);

@Native<Int Function(Pointer<PthreadCond>)>()
external int pthread_cond_destroy(Pointer<PthreadCond> cond);

@Native<Int Function(Pointer<PthreadCond>)>()
external int pthread_cond_signal(Pointer<PthreadCond> cond);

/// Runs [body] with [mutex] locked.
R lock<R>(Pointer<PthreadMutex> mutex, R Function() body) {
  check(pthread_mutex_lock(mutex));
  try {
    return body();
  } finally {
    check(pthread_mutex_unlock(mutex));
  }
}

void check(int retval) {
  if (retval != 0) throw 'operaton failed';
}

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

extension on Pointer<_MailboxRepr> {
  Pointer<PthreadMutex> get mutex =>
      Pointer<PthreadMutex>.fromAddress(address + Mailbox.mutexOffs);
  Pointer<PthreadCond> get cond =>
      Pointer<PthreadCond>.fromAddress(address + Mailbox.condOffs);
}

/// Simple one message mailbox.
class Mailbox {
  static final int mutexSize = 64;
  static final int condSize = 64;
  static final int headerSize = sizeOf<_MailboxRepr>();
  static final int mutexOffs = headerSize;
  static final int condOffs = mutexOffs + mutexSize;
  static final int totalSize = condOffs + condSize;

  final Pointer<_MailboxRepr> _mailbox;
  bool isRunning = true;

  static const stateEmpty = 0;
  static const stateFull = 1;

  static final finalizer = Finalizer((Pointer<_MailboxRepr> mailbox) {
    calloc.free(mailbox.ref.buffer);
    pthread_mutex_destroy(mailbox.mutex);
    pthread_cond_destroy(mailbox.cond);
    calloc.free(mailbox);
  });

  Mailbox() : _mailbox = calloc.allocate(Mailbox.totalSize) {
    check(pthread_mutex_init(_mailbox.mutex, nullptr));
    check(pthread_cond_init(_mailbox.cond, nullptr));
    finalizer.attach(this, _mailbox);
  }

  /// Create a mailbox pointing to an already existing mailbox.
  Mailbox.fromAddress(int address) : _mailbox = Pointer.fromAddress(address);

  void send(Uint8List? message) {
    if (_mailbox.ref.state != stateEmpty) {
      throw 'Invalid state: ${_mailbox.ref.state}';
    }

    final buffer = message != null ? _toBuffer(message) : nullptr;
    lock(_mailbox.mutex, () {
      if (_mailbox.ref.state != stateEmpty) {
        throw 'Invalid state: ${_mailbox.ref.state}';
      }

      _mailbox.ref.state = stateFull;
      _mailbox.ref.buffer = buffer;
      _mailbox.ref.bufferLength = message?.length ?? 0;
      pthread_cond_signal(_mailbox.cond);
    });
  }

  static final _emptyResponse = Uint8List(0);

  Uint8List receive() => lock(_mailbox.mutex, () {
        // Wait for request to arrive.
        while (_mailbox.ref.state != stateFull) {
          pthread_cond_wait(_mailbox.cond, _mailbox.mutex);
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
