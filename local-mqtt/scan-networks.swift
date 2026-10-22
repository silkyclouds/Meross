import CoreWLAN
import Foundation

// Lists visible Wi-Fi networks as "rssi<TAB>ssid", strongest first.
//
// macOS removed the airport command line tool and system_profiler hides
// network names, so CoreWLAN is the only way left to scan from a script.
// Scanning needs Location Services granted to the calling terminal.

guard let interface = CWWiFiClient.shared().interface() else {
    FileHandle.standardError.write("No Wi-Fi interface available\n".data(using: .utf8)!)
    exit(1)
}

do {
    let networks = try interface.scanForNetworks(withSSID: nil)
    var seen = Set<String>()

    for network in networks.sorted(by: { $0.rssiValue > $1.rssiValue }) {
        guard let ssid = network.ssid, !ssid.isEmpty, !seen.contains(ssid) else { continue }
        seen.insert(ssid)
        print("\(network.rssiValue)\t\(ssid)")
    }
} catch {
    FileHandle.standardError.write(
        "Scan refused: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(2)
}
