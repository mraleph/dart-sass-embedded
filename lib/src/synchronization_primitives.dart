// @dart=3.0

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

sealed class Mutex {
  Mutex._();

  factory Mutex() => Platform.isWindows ? WindowsMutex() : PosixMutex();

  factory Mutex.fromAddress(int address) => Platform.isWindows
      ? WindowsMutex.fromAddress(address)
      : PosixMutex.fromAddress(address);

  int get rawAddress;

  void lock();

  void unlock();

  R holdingLock<R>(R Function() action) {
    lock();
    try {
      return action();
    } finally {
      unlock();
    }
  }
}

sealed class ConditionVariable {
  factory ConditionVariable() => Platform.isWindows
      ? WindowsConditionVariable()
      : PosixConditionVariable();

  factory ConditionVariable.fromAddress(int address) => Platform.isWindows
      ? WindowsConditionVariable.fromAddress(address)
      : PosixConditionVariable.fromAddress(address);

  int get rawAddress;

  void wait(Mutex mut);

  void notify();
}

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

class PosixMutex extends Mutex {
  static const _sizeInBytes = 64;

  final Pointer<PthreadMutex> _impl;

  // TODO(@mraleph) this should be a native finalizer, also we probably want to
  // do reference counting on the mutex so that the last owner destroys it.
  static final _finalizer = Finalizer<Pointer<PthreadMutex>>((ptr) {
    pthread_mutex_destroy(ptr);
    calloc.free(ptr);
  });

  PosixMutex()
      : _impl = calloc.allocate(PosixMutex._sizeInBytes),
        super._() {
    if (pthread_mutex_init(_impl, nullptr) != 0) {
      calloc.free(_impl);
      throw StateError('failed to initialize mutex');
    }
    _finalizer.attach(this, _impl);
  }

  PosixMutex.fromAddress(int address)
      : _impl = Pointer.fromAddress(address),
        super._();

  @override
  void lock() {
    if (pthread_mutex_lock(_impl) != 0) {
      throw StateError('failed to lock mutex');
    }
  }

  @override
  void unlock() {
    if (pthread_mutex_unlock(_impl) != 0) {
      throw StateError('failed to unlock mutex');
    }
  }

  @override
  int get rawAddress => _impl.address;
}

class PosixConditionVariable implements ConditionVariable {
  static const _sizeInBytes = 64;

  final Pointer<PthreadCond> _impl;

  // TODO(@mraleph) this should be a native finalizer, also we probably want to
  // do reference counting on the mutex so that the last owner destroys it.
  static final _finalizer = Finalizer<Pointer<PthreadCond>>((ptr) {
    pthread_cond_destroy(ptr);
    calloc.free(ptr);
  });

  PosixConditionVariable()
      : _impl = calloc.allocate(PosixConditionVariable._sizeInBytes) {
    if (pthread_cond_init(_impl, nullptr) != 0) {
      calloc.free(_impl);
      throw StateError('failed to initialize condition variable');
    }
    _finalizer.attach(this, _impl);
  }

  PosixConditionVariable.fromAddress(int address)
      : _impl = Pointer.fromAddress(address);

  @override
  void notify() {
    if (pthread_cond_signal(_impl) != 0) {
      throw StateError('failed to signal condition variable');
    }
  }

  @override
  void wait(covariant PosixMutex mutex) {
    if (pthread_cond_wait(_impl, mutex._impl) != 0) {
      throw StateError('failed to wait on a condition variable');
    }
  }

  @override
  int get rawAddress => _impl.address;
}

//
// WinAPI implementation of the synchronization primitives
//

final class SRWLOCK extends Opaque {}

final class CONDITION_VARIABLE extends Opaque {}

@Native<Void Function(Pointer<SRWLOCK>)>()
external void InitializeSRWLock(Pointer<SRWLOCK> lock);

@Native<Void Function(Pointer<SRWLOCK>)>()
external void AcquireSRWLockExclusive(Pointer<SRWLOCK> lock);

@Native<Void Function(Pointer<SRWLOCK>)>()
external void ReleaseSRWLockExclusive(Pointer<SRWLOCK> mutex);

@Native<Void Function(Pointer<CONDITION_VARIABLE>)>()
external void InitializeConditionVariable(Pointer<CONDITION_VARIABLE> condVar);

@Native<
    Int Function(
        Pointer<CONDITION_VARIABLE>, Pointer<SRWLOCK>, Uint32, Uint32)>()
external int SleepConditionVariableSRW(Pointer<CONDITION_VARIABLE> condVar,
    Pointer<SRWLOCK> srwLock, int timeOut, int flags);

@Native<Void Function(Pointer<CONDITION_VARIABLE>)>()
external void WakeConditionVariable(Pointer<CONDITION_VARIABLE> condVar);

class WindowsMutex extends Mutex {
  static const _sizeInBytes = 8;

  final Pointer<SRWLOCK> _impl;

  // TODO(@mraleph) this should be a native finalizer, also we probably want to
  // do reference counting on the mutex so that the last owner destroys it.
  static final _finalizer = Finalizer<Pointer<SRWLOCK>>((ptr) {
    calloc.free(ptr);
  });

  WindowsMutex()
      : _impl = calloc.allocate(WindowsMutex._sizeInBytes),
        super._() {
    InitializeSRWLock(_impl);
    _finalizer.attach(this, _impl);
  }

  WindowsMutex.fromAddress(int address)
      : _impl = Pointer.fromAddress(address),
        super._();

  @override
  void lock() => AcquireSRWLockExclusive(_impl);

  @override
  void unlock() => ReleaseSRWLockExclusive(_impl);

  @override
  int get rawAddress => _impl.address;
}

class WindowsConditionVariable implements ConditionVariable {
  static const _sizeInBytes = 8;

  final Pointer<CONDITION_VARIABLE> _impl;

  // TODO(@mraleph) this should be a native finalizer, also we probably want to
  // do reference counting on the mutex so that the last owner destroys it.
  static final _finalizer = Finalizer<Pointer<CONDITION_VARIABLE>>((ptr) {
    calloc.free(ptr);
  });

  WindowsConditionVariable()
      : _impl = calloc.allocate(WindowsConditionVariable._sizeInBytes) {
    InitializeConditionVariable(_impl);
    _finalizer.attach(this, _impl);
  }

  WindowsConditionVariable.fromAddress(int address)
      : _impl = Pointer.fromAddress(address);

  @override
  void notify() {
    WakeConditionVariable(_impl);
  }

  @override
  void wait(covariant WindowsMutex mutex) {
    const infinite = 0xFFFFFFFF;
    const exclusive = 0;
    if (SleepConditionVariableSRW(_impl, mutex._impl, infinite, exclusive) !=
        0) {
      throw StateError('failed to wait on a condition variable');
    }
  }

  @override
  int get rawAddress => _impl.address;
}
