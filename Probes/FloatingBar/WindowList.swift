import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
var byLayer: [Int: Int] = [:]
for w in list {
    let layer = w[kCGWindowLayer as String] as? Int ?? -999
    byLayer[layer, default: 0] += 1
    guard layer >= 20 && layer <= 30 else { continue }
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let alpha = w[kCGWindowAlpha as String] as? Double ?? -1
    let on = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    let num = w[kCGWindowNumber as String] as? Int ?? 0
    let name = w[kCGWindowName as String] as? String ?? ""
    print("L\(layer) \(owner)[\(pid)] #\(num) \(b["X"] ?? 0),\(b["Y"] ?? 0) \(b["Width"] ?? 0)x\(b["Height"] ?? 0) alpha=\(alpha) on=\(on) \(name)")
}
print("layers:", byLayer.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))
// Pelmet's own windows, any layer
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Pelmet" {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("PELMET L\(w[kCGWindowLayer as String] ?? -1) #\(w[kCGWindowNumber as String] ?? 0) \(b["X"] ?? 0),\(b["Y"] ?? 0) \(b["Width"] ?? 0)x\(b["Height"] ?? 0) on=\(w[kCGWindowIsOnscreen as String] ?? false) \(w[kCGWindowName as String] ?? "")")
}
