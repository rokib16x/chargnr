import ChargnrCore
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import os

// chargnr-helper: the root daemon that owns every SMC write. launchd starts it
// (KeepAlive), it serves the app and CLI over XPC, and it runs the charge loop
// so limits hold even when the app is closed.

let log = Logger(subsystem: Chargnr.helperID, category: "helper")

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("chargnr-helper must run as root (it is started by launchd)\n".utf8))
    exit(77)
}

let smc: AppleSMC
do { smc = try AppleSMC() } catch {
    log.fault("cannot open the SMC: \(String(describing: error), privacy: .public)")
    exit(69)
}
let caps = Capabilities.detect(smc)
log.notice("chargnr-helper \(Chargnr.version, privacy: .public): \(caps.charging.rawValue, privacy: .public), adapter \(caps.adapterKey?.description ?? "none", privacy: .public)")

/// Every controller call runs on this queue.
let queue = DispatchQueue(label: "\(Chargnr.helperID).control")
let historyStore = HistoryStore()
let controller = Controller(actuator: Actuator(smc: smc, caps: caps), history: historyStore,
                            readBattery: { BatteryReading.read(smc) })
// Best effort: macOS's own limit belongs to the user, so this may be refused
// for root. The app and CLI re-sync it too.
controller.onNativeTargetChanged = { target in
    guard caps.charging == .gated || caps.charging == .unsupported else { return }
    do { try NativeChargeLimit.set(target) } catch {
        log.notice("could not set macOS limit to \(target, privacy: .public)%: \(String(describing: error), privacy: .public)")
    }
}

// MARK: - Loop

let timer = DispatchSource.makeTimerSource(queue: queue)
/// Held while force discharging so idle sleep does not pause it.
nonisolated(unsafe) var awakeAssertion: IOPMAssertionID = 0

@Sendable func schedule(_ seconds: TimeInterval) {
    // Keep the Mac awake exactly while a discharge is running.
    if controller.isDischarging, awakeAssertion == 0 {
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "chargnr force discharge" as CFString, &awakeAssertion)
    } else if !controller.isDischarging, awakeAssertion != 0 {
        IOPMAssertionRelease(awakeAssertion)
        awakeAssertion = 0
    }
    // Leeway lets macOS batch our wakeups with others.
    timer.schedule(deadline: .now() + seconds, leeway: .seconds(max(1, Int(seconds / 10))))
}
timer.setEventHandler { schedule(controller.tick()) }

queue.sync {
    try? FileManager.default.createDirectory(at: HelperPaths.directory, withIntermediateDirectories: true)
    controller.start()
    schedule(controller.interval)
}
timer.resume()

// Plugging in, unplugging and percentage changes trigger an immediate check.
let powerSource = IOPSNotificationCreateRunLoopSource({ _ in
    queue.async { schedule(controller.tick()) }
}, nil).takeRetainedValue()
CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .defaultMode)

// MARK: - Sleep and wake

// iokit_common_msg values; the C macros do not import into Swift.
let canSystemSleep: UInt32 = 0xE000_0270
let systemWillSleep: UInt32 = 0xE000_0280
let systemHasPoweredOn: UInt32 = 0xE000_0300

var rootPort: io_connect_t = 0
var notifier: io_object_t = 0
var notifyPort: IONotificationPortRef?
rootPort = IORegisterForSystemPower(nil, &notifyPort, { _, _, messageType, argument in
    let token = Int(bitPattern: argument)
    switch messageType {
    case canSystemSleep:
        // Never veto sleep; act only once sleep is certain.
        IOAllowPowerChange(rootPort, token)
    case systemWillSleep:
        queue.sync { controller.willSleep() }
        IOAllowPowerChange(rootPort, token)
    case systemHasPoweredOn:
        queue.async { schedule(controller.tick()) }
    default:
        break
    }
}, &notifier)
if rootPort != 0, let notifyPort {
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .defaultMode)
} else {
    log.error("could not register for sleep notifications")
}

// MARK: - Lid

// Closing the lid in clamshell mode with the charger cut would make macOS sleep,
// so re-check the moment the lid state changes instead of at the next tick.
let clamshellStateChange: UInt32 = 0xE003_4100 // kIOPMMessageClamshellStateChange
var lidNotifier: io_object_t = 0
let lidPort = IONotificationPortCreate(kIOMainPortDefault)
let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
if let lidPort, rootDomain != IO_OBJECT_NULL {
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(lidPort).takeUnretainedValue(), .defaultMode)
    let result = IOServiceAddInterestNotification(lidPort, rootDomain, kIOGeneralInterest, { _, _, messageType, _ in
        guard messageType == clamshellStateChange else { return }
        queue.async { schedule(controller.tick()) }
    }, nil, &lidNotifier)
    if result != KERN_SUCCESS { log.error("could not watch the lid: \(result, privacy: .public)") }
}

// MARK: - Exit

// launchd sends SIGTERM on uninstall, shutdown and restart: put everything back.
let signalSources = [SIGTERM, SIGINT, SIGHUP].map { sig in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
    source.setEventHandler {
        controller.restore()
        log.notice("signal \(sig, privacy: .public): restored normal charging, exiting")
        exit(0)
    }
    source.resume()
    return source
}

// MARK: - XPC

final class Service: NSObject, HelperProtocol {
    func status(reply: @escaping @Sendable (Data?) -> Void) {
        queue.async { reply(try? JSONEncoder().encode(controller.status())) }
    }

    func setConfig(_ json: Data, reply: @escaping @Sendable (String?) -> Void) {
        guard let config = try? JSONDecoder().decode(ChargeConfig.self, from: json) else {
            reply("invalid config")
            return
        }
        queue.async {
            do {
                try controller.setConfig(config)
                schedule(controller.interval)
                reply(nil)
            } catch {
                reply("could not save the config: \(error.localizedDescription)")
            }
        }
    }

    func history(since: Double, reply: @escaping @Sendable (Data?) -> Void) {
        queue.async { reply(HistoryCSV.encode(historyStore.samples(since: Date(timeIntervalSince1970: since)))) }
    }

    func restoreNormal(reply: @escaping @Sendable (String?) -> Void) {
        queue.async {
            do {
                try controller.setConfig(ChargeConfig(limit: 100))
                controller.restore()
                reply(controller.status().lastError)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    let policy = CallerPolicy.current()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        switch policy {
        case .team(let requirement):
            // The kernel checks the caller's audit token against this on every message.
            connection.setCodeSigningRequirement(requirement)
        case .consoleUser:
            guard CallerPolicy.isRootOrConsoleUser(connection.effectiveUserIdentifier) else {
                log.notice("refused uid \(connection.effectiveUserIdentifier, privacy: .public): not root or the console user")
                return false
            }
        }
        connection.exportedInterface = HelperService.interface()
        connection.exportedObject = Service()
        connection.resume()
        return true
    }
}

let delegate = Listener()
let listener = NSXPCListener(machServiceName: HelperService.name)
listener.delegate = delegate
listener.resume()
log.notice("listening as \(HelperService.name, privacy: .public), callers: \(String(describing: delegate.policy), privacy: .public)")

withExtendedLifetime((timer, powerSource, signalSources, listener, lidPort)) {
    RunLoop.main.run()
}
