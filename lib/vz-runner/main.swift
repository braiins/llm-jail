import Darwin
import Foundation
import Virtualization

struct Share {
  let tag: String
  let path: String
  let readOnly: Bool
}

struct Options {
  var cpuCount = 0
  var memoryMiB = 0
  var kernel = ""
  var initrd = ""
  var commandLineFile = ""
  var disk: String?
  var supervisorSocket: String?
  var winsizeInput: String?
  var shares: [Share] = []
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("llm-jail-vz: \(message)\n".utf8))
  exit(1)
}

func nextValue(_ arguments: [String], _ index: inout Int, _ option: String) -> String {
  index += 1
  guard index < arguments.count else { fail("\(option) requires a value") }
  return arguments[index]
}

func parseShare(_ value: String) -> Share {
  let fields = value.split(separator: ":", omittingEmptySubsequences: false)
  guard fields.count == 3, !fields[0].isEmpty, !fields[1].isEmpty else {
    fail("share must be TAG:PATH:MODE")
  }
  let mode = String(fields[2])
  guard mode == "ro" || mode == "rw" else { fail("share mode must be ro or rw") }
  return Share(tag: String(fields[0]), path: String(fields[1]), readOnly: mode == "ro")
}

func parseOptions() -> Options {
  let arguments = Array(CommandLine.arguments.dropFirst())
  var options = Options()
  var index = 0
  while index < arguments.count {
    let option = arguments[index]
    switch option {
    case "--cpus":
      options.cpuCount = Int(nextValue(arguments, &index, option)) ?? 0
    case "--memory":
      options.memoryMiB = Int(nextValue(arguments, &index, option)) ?? 0
    case "--kernel":
      options.kernel = nextValue(arguments, &index, option)
    case "--initrd":
      options.initrd = nextValue(arguments, &index, option)
    case "--cmdline-file":
      options.commandLineFile = nextValue(arguments, &index, option)
    case "--disk":
      options.disk = nextValue(arguments, &index, option)
    case "--share":
      options.shares.append(parseShare(nextValue(arguments, &index, option)))
    case "--supervisor-socket":
      options.supervisorSocket = nextValue(arguments, &index, option)
    case "--winsize-input":
      options.winsizeInput = nextValue(arguments, &index, option)
    default:
      fail("unknown option \(option)")
    }
    index += 1
  }
  guard options.cpuCount > 0 else { fail("--cpus must be positive") }
  guard options.memoryMiB > 0 else { fail("--memory must be positive") }
  guard !options.kernel.isEmpty else { fail("--kernel is required") }
  guard !options.initrd.isEmpty else { fail("--initrd is required") }
  guard !options.commandLineFile.isEmpty else { fail("--cmdline-file is required") }
  return options
}

func openForReading(_ path: String) -> FileHandle {
  guard let handle = FileHandle(forReadingAtPath: path) else { fail("cannot read \(path)") }
  return handle
}

func connectUnixSocket(_ path: String) -> (reading: FileHandle, writing: FileHandle) {
  guard path.hasPrefix("/") else { fail("supervisor socket path must be absolute") }

  let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else {
    fail("cannot create supervisor socket: \(String(cString: strerror(errno)))")
  }

  var address = sockaddr_un()
  let pathBytes = Array(path.utf8) + [UInt8(0)]
  let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
  guard pathBytes.count <= pathCapacity else {
    Darwin.close(descriptor)
    fail("supervisor socket path is too long")
  }

  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  address.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &address.sun_path) { destination in
    destination.copyBytes(from: pathBytes)
  }

  let result = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
      Darwin.connect(
        descriptor,
        socketAddress,
        socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  guard result == 0 else {
    let code = errno
    Darwin.close(descriptor)
    fail("cannot connect supervisor socket: \(String(cString: strerror(code)))")
  }

  let readingDescriptor = Darwin.dup(descriptor)
  guard readingDescriptor >= 0 else {
    let code = errno
    Darwin.close(descriptor)
    fail("cannot duplicate supervisor socket: \(String(cString: strerror(code)))")
  }
  let writingDescriptor = Darwin.dup(descriptor)
  guard writingDescriptor >= 0 else {
    let code = errno
    Darwin.close(readingDescriptor)
    Darwin.close(descriptor)
    fail("cannot duplicate supervisor socket: \(String(cString: strerror(code)))")
  }
  Darwin.close(descriptor)

  return (
    FileHandle(fileDescriptor: readingDescriptor, closeOnDealloc: true),
    FileHandle(fileDescriptor: writingDescriptor, closeOnDealloc: true))
}

func serialPort(reading: FileHandle?, writing: FileHandle?) -> VZSerialPortConfiguration {
  let port = VZVirtioConsoleDeviceSerialPortConfiguration()
  port.attachment = VZFileHandleSerialPortAttachment(
    fileHandleForReading: reading,
    fileHandleForWriting: writing)
  return port
}

final class ConsoleRelay {
  // Virtualization.framework transfers serial attachments to an XPC process
  // outside this runner's process group. Keep the host terminal here so job
  // control can suspend all terminal access during a trusted host prompt.
  private let guestInput = Pipe()
  private let guestOutput = Pipe()
  private var inputThread: Thread?
  private var outputThread: Thread?

  var guestReadingHandle: FileHandle {
    guestInput.fileHandleForReading
  }

  var guestWritingHandle: FileHandle {
    guestOutput.fileHandleForWriting
  }

  func start(onFailure: @escaping (String) -> Void) {
    let guestInputDescriptor = guestInput.fileHandleForWriting.fileDescriptor
    let guestOutputDescriptor = guestOutput.fileHandleForReading.fileDescriptor
    let inputThread = Thread {
      switch relayBytes(from: STDIN_FILENO, to: guestInputDescriptor) {
      case .endOfFile:
        onFailure("console input closed")
      case .failure(let operation, let code):
        onFailure(
          "console input relay failed during \(operation): "
          + String(cString: strerror(code)))
      }
    }
    let outputThread = Thread {
      if case .failure(let operation, let code) =
          relayBytes(from: guestOutputDescriptor, to: STDOUT_FILENO) {
        onFailure(
          "console output relay failed during \(operation): "
          + String(cString: strerror(code)))
      }
    }

    inputThread.name = "llm-jail-vz-console-input"
    outputThread.name = "llm-jail-vz-console-output"
    self.inputThread = inputThread
    self.outputThread = outputThread
    inputThread.start()
    outputThread.start()
  }
}

let options = parseOptions()
let fileManager = FileManager.default
for path in [options.kernel, options.initrd, options.commandLineFile] {
  guard fileManager.fileExists(atPath: path) else { fail("file not found: \(path)") }
}
for share in options.shares {
  var isDirectory: ObjCBool = false
  guard fileManager.fileExists(atPath: share.path, isDirectory: &isDirectory),
        isDirectory.boolValue else {
    fail("shared directory not found: \(share.path)")
  }
}

let commandLine: String
do {
  commandLine = try String(contentsOfFile: options.commandLineFile, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
} catch {
  fail("cannot read kernel command line: \(error.localizedDescription)")
}

let configuration = VZVirtualMachineConfiguration()
configuration.cpuCount = options.cpuCount
configuration.memorySize = UInt64(options.memoryMiB) * 1024 * 1024

let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: options.kernel))
bootLoader.initialRamdiskURL = URL(fileURLWithPath: options.initrd)
bootLoader.commandLine = commandLine
configuration.bootLoader = bootLoader

configuration.directorySharingDevices = options.shares.map { share in
  let device = VZVirtioFileSystemDeviceConfiguration(tag: share.tag)
  device.share = VZSingleDirectoryShare(
    directory: VZSharedDirectory(
      url: URL(fileURLWithPath: share.path),
      readOnly: share.readOnly))
  return device
}

if let disk = options.disk {
  do {
    let attachment = try VZDiskImageStorageDeviceAttachment(
      url: URL(fileURLWithPath: disk),
      readOnly: false,
      cachingMode: .automatic,
      synchronizationMode: .fsync)
    configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
  } catch {
    fail("cannot attach disk: \(error.localizedDescription)")
  }
}

let network = VZVirtioNetworkDeviceConfiguration()
network.attachment = VZNATNetworkDeviceAttachment()
configuration.networkDevices = [network]
configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

let consoleRelay = ConsoleRelay()
var serialPorts: [VZSerialPortConfiguration] = [
  serialPort(
    reading: consoleRelay.guestReadingHandle,
    writing: consoleRelay.guestWritingHandle)
]
if let socket = options.supervisorSocket {
  let handles = connectUnixSocket(socket)
  serialPorts.append(serialPort(reading: handles.reading, writing: handles.writing))
}
if let input = options.winsizeInput {
  serialPorts.append(serialPort(reading: openForReading(input), writing: nil))
}
configuration.serialPorts = serialPorts

do {
  try configuration.validate()
} catch {
  fail("invalid VM configuration: \(error.localizedDescription)")
}

enum Terminal {
  static var saved: termios?

  static func makeRaw() {
    guard isatty(STDIN_FILENO) == 1 else { return }
    var current = termios()
    guard tcgetattr(STDIN_FILENO, &current) == 0 else { return }
    saved = current
    cfmakeraw(&current)
    tcsetattr(STDIN_FILENO, TCSANOW, &current)
  }

  static func restore() {
    guard var previous = saved else { return }
    tcsetattr(STDIN_FILENO, TCSANOW, &previous)
    saved = nil
  }
}

final class Delegate: NSObject, VZVirtualMachineDelegate {
  func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    Terminal.restore()
    exit(0)
  }

  func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
    Terminal.restore()
    fail("guest stopped: \(error.localizedDescription)")
  }
}

let queue = DispatchQueue(label: "org.llm-jail.vz")
let virtualMachine = VZVirtualMachine(configuration: configuration, queue: queue)
let delegate = Delegate()
virtualMachine.delegate = delegate
Terminal.makeRaw()

var signalSources: [DispatchSourceSignal] = []
signal(SIGPIPE, SIG_IGN)
for signalNumber in [SIGINT, SIGTERM] {
  signal(signalNumber, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
  source.setEventHandler {
    queue.async {
      virtualMachine.stop { _ in
        Terminal.restore()
        exit(0)
      }
    }
  }
  source.resume()
  signalSources.append(source)
}

consoleRelay.start { message in
  DispatchQueue.main.async {
    Terminal.restore()
    fail(message)
  }
}
queue.async {
  virtualMachine.start { result in
    if case .failure(let error) = result {
      Terminal.restore()
      fail("cannot start VM: \(error.localizedDescription)")
    }
  }
}
dispatchMain()
