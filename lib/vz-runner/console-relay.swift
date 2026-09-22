import Darwin

enum RelayTermination: Equatable {
  case endOfFile
  case failure(operation: String, code: Int32)
}

private func descriptorWouldBlock(_ code: Int32) -> Bool {
  code == EAGAIN || code == EWOULDBLOCK
}

private func waitForDescriptor(_ descriptor: Int32, events: Int16) -> Int32? {
  var state = pollfd(fd: descriptor, events: events, revents: 0)

  while true {
    state.revents = 0
    let result = Darwin.poll(&state, 1, -1)
    if result > 0 {
      if state.revents & Int16(POLLNVAL) != 0 {
        return EBADF
      }
      return nil
    }
    if result < 0 {
      let code = errno
      if code == EINTR {
        continue
      }
      return code
    }
  }
}

@discardableResult
func relayBytes(from source: Int32, to destination: Int32) -> RelayTermination {
  var buffer = [UInt8](repeating: 0, count: 64 * 1024)

  while true {
    let count = buffer.withUnsafeMutableBytes { bytes in
      Darwin.read(source, bytes.baseAddress, bytes.count)
    }
    if count == 0 {
      return .endOfFile
    }
    if count < 0 {
      let code = errno
      if code == EINTR {
        continue
      }
      if descriptorWouldBlock(code) {
        if let waitCode = waitForDescriptor(source, events: Int16(POLLIN)) {
          return .failure(operation: "poll for read", code: waitCode)
        }
        continue
      }
      return .failure(operation: "read", code: code)
    }

    var offset = 0
    while offset < count {
      let written = buffer.withUnsafeBytes { bytes in
        Darwin.write(
          destination,
          bytes.baseAddress!.advanced(by: offset),
          count - offset)
      }
      if written > 0 {
        offset += written
      } else if written < 0 {
        let code = errno
        if code == EINTR {
          continue
        }
        if descriptorWouldBlock(code) {
          if let waitCode = waitForDescriptor(destination, events: Int16(POLLOUT)) {
            return .failure(operation: "poll for write", code: waitCode)
          }
          continue
        }
        return .failure(operation: "write", code: code)
      } else {
        return .failure(operation: "write", code: EIO)
      }
    }
  }
}
