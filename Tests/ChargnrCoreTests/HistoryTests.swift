@testable import ChargnrCore
import Foundation
import Testing

@Suite struct HistoryTests {
    func store() -> (HistoryStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".csv")
        return (HistoryStore(url: url), url)
    }

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func csvRoundTrips() {
        let sample = HistorySample(time: t0, percent: 81, pluggedIn: true, charging: false,
                                   temperatureC: 33.4, batteryMW: -1250, held: true)
        #expect(HistoryCSV.decode(HistoryCSV.encode([sample])) == [sample])
        let bare = HistorySample(time: t0, percent: 50, pluggedIn: false, charging: false)
        #expect(HistoryCSV.decode(HistoryCSV.encode([bare])) == [bare])
    }

    @Test func recordsOnlyChangesAndHeartbeats() {
        let (store, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        store.record(HistorySample(time: t0, percent: 80, pluggedIn: true, charging: true))
        store.record(HistorySample(time: t0 + 60, percent: 80, pluggedIn: true, charging: true))
        store.record(HistorySample(time: t0 + 120, percent: 81, pluggedIn: true, charging: true))
        store.record(HistorySample(time: t0 + 120 + HistoryStore.heartbeat, percent: 81, pluggedIn: true, charging: true))
        #expect(store.samples(since: .distantPast).map(\.percent) == [80, 81, 81])
    }

    @Test func survivesReopen() {
        let (store, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        store.record(HistorySample(time: t0, percent: 70, pluggedIn: true, charging: true))
        let reopened = HistoryStore(url: url)
        reopened.record(HistorySample(time: t0 + 1, percent: 70, pluggedIn: true, charging: true))
        #expect(reopened.samples(since: .distantPast).count == 1, "remembers the last sample across restarts")
    }

    @Test func trimsOldSamples() {
        let (store, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        store.record(HistorySample(time: t0, percent: 50, pluggedIn: false, charging: false))
        let later = t0 + HistoryStore.retention + 2 * 24 * 3600
        store.record(HistorySample(time: later, percent: 60, pluggedIn: true, charging: true))
        #expect(store.samples(since: .distantPast).map(\.percent) == [60])
    }

    @Test func filtersBySince() {
        let (store, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        for i in 0..<5 { store.record(HistorySample(time: t0 + Double(i) * 3600, percent: 50 + i, pluggedIn: true, charging: true)) }
        #expect(store.samples(since: t0 + 2 * 3600).map(\.percent) == [52, 53, 54])
    }

    @Test func summaryIsTimeWeighted() {
        let samples = [
            HistorySample(time: t0, percent: 96, pluggedIn: true, charging: false, temperatureC: 30),
            HistorySample(time: t0 + 3 * 3600, percent: 60, pluggedIn: false, charging: false, temperatureC: 36, held: true),
        ]
        let summary = HistorySummary(samples, until: t0 + 4 * 3600)
        #expect(summary?.pluggedShare == 0.75)
        #expect(summary?.nearFullShare == 0.75)
        #expect(summary?.heldShare == 0.25)
        #expect(summary?.minPercent == 60)
        #expect(summary?.maxTemperatureC == 36)
    }

    @Test func controllerRecords() throws {
        let rig = try Rig(.tahoe, config: ChargeConfig(limit: 80))
        let (store, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        let battery = rig.battery
        let controller = Controller(actuator: Actuator(smc: rig.smc, caps: Capabilities.detect(rig.smc)),
                                    configFile: JSONFile(rig.dir.appendingPathComponent("config.json")),
                                    marker: JSONFile(rig.dir.appendingPathComponent("m.json")),
                                    log: .quiet, history: store, readBattery: { battery.reading })
        battery.reading = BatteryReading(percent: 85, pluggedIn: true)
        controller.start()
        let last = store.samples(since: .distantPast).last
        #expect(last?.percent == 85)
        #expect(last?.held == true)
    }
}
