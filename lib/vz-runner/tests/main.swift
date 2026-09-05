import Darwin
import Dispatch
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    FileHandle.standardError.write(Data("console-relay-test: \(message)\n".utf8))
    exit(1)
  }
}

func makePipe() -> (reading: Int32, writing: Int32) {
  var descriptors = [Int32](repeating: -1, count: 2)
  require(Darwin.pipe(&descriptors) == 0, "cannot create pipe")
  return (descriptors[0], descriptors[1])
}

func setNonblocking(_ descriptor: Int32) {
  let flags = fcntl(descriptor, F_GETFL)
  require(flags >= 0, "cannot read descriptor flags")
  require(fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
          "cannot set descriptor nonblocking")
}

final class RelayTerminationBox {
  private let lock = NSLock()
  private var termination: RelayTermination?

  func store(_ value: RelayTermination) {
    lock.lock()
    termination = value
    lock.unlock()
  }

  func load() -> RelayTermination? {
    lock.lock()
    defer { lock.unlock() }
    return termination
  }
}

func testDelayedNonblockingInput() {
  let source = makePipe()
  let destination = makePipe()
  let completion = DispatchSemaphore(value: 0)
  let termination = RelayTerminationBox()

  setNonblocking(source.reading)
  Thread {
    termination.store(relayBytes(from: source.reading, to: destination.writing))
    completion.signal()
  }.start()

  require(completion.wait(timeout: .now() + .milliseconds(100)) == .timedOut,
          "relay exited while nonblocking input was temporarily empty")

  var expected: UInt8 = 0x6b
  require(Darwin.write(source.writing, &expected, 1) == 1,
          "cannot write delayed input")

  var ready = pollfd(fd: destination.reading, events: Int16(POLLIN), revents: 0)
  require(Darwin.poll(&ready, 1, 1000) == 1,
          "relay did not forward delayed input")

  var actual: UInt8 = 0
  require(Darwin.read(destination.reading, &actual, 1) == 1,
          "cannot read relayed input")
  require(actual == expected, "relay changed delayed input")

  Darwin.close(source.writing)
  require(completion.wait(timeout: .now() + .seconds(1)) == .success,
          "relay did not stop at end of input")
  require(termination.load() == .endOfFile,
          "input relay did not report end of input")

  Darwin.close(source.reading)
  Darwin.close(destination.reading)
  Darwin.close(destination.writing)
}

func fillNonblockingPipe(_ descriptor: Int32) -> Int {
  setNonblocking(descriptor)
  let buffer = [UInt8](repeating: 0x66, count: 4096)
  var total = 0

  while true {
    let written = buffer.withUnsafeBytes { bytes in
      Darwin.write(descriptor, bytes.baseAddress, bytes.count)
    }
    if written > 0 {
      total += written
      continue
    }
    if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
      return total
    }
    require(false, "cannot fill nonblocking pipe")
  }
}

func testDelayedNonblockingOutput() {
  let source = makePipe()
  let destination = makePipe()
  let completion = DispatchSemaphore(value: 0)
  let termination = RelayTerminationBox()
  let fillerCount = fillNonblockingPipe(destination.writing)
  require(fillerCount > 0, "nonblocking output pipe accepted no filler")

  var expected: UInt8 = 0x6b
  require(Darwin.write(source.writing, &expected, 1) == 1,
          "cannot write source byte")
  Darwin.close(source.writing)

  Thread {
    termination.store(relayBytes(from: source.reading, to: destination.writing))
    completion.signal()
  }.start()

  require(completion.wait(timeout: .now() + .milliseconds(100)) == .timedOut,
          "relay exited while nonblocking output was temporarily full")

  var remaining = fillerCount
  var buffer = [UInt8](repeating: 0, count: 4096)
  while remaining > 0 {
    let count = buffer.withUnsafeMutableBytes { bytes in
      Darwin.read(destination.reading, bytes.baseAddress, min(bytes.count, remaining))
    }
    require(count > 0, "cannot drain output pipe")
    remaining -= count
  }

  var ready = pollfd(fd: destination.reading, events: Int16(POLLIN), revents: 0)
  require(Darwin.poll(&ready, 1, 1000) == 1,
          "relay did not resume after output became writable")

  var actual: UInt8 = 0
  require(Darwin.read(destination.reading, &actual, 1) == 1,
          "cannot read relayed output")
  require(actual == expected, "relay changed delayed output")
  require(completion.wait(timeout: .now() + .seconds(1)) == .success,
          "output relay did not stop at end of input")
  require(termination.load() == .endOfFile,
          "output relay did not report end of input")

  Darwin.close(source.reading)
  Darwin.close(destination.reading)
  Darwin.close(destination.writing)
}

signal(SIGPIPE, SIG_IGN)
testDelayedNonblockingInput()
testDelayedNonblockingOutput()
