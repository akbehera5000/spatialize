import Foundation

/// One virtual speaker of the 7.1.4 bed. Azimuth is degrees counter-clockwise from straight
/// ahead (left positive, as in ambisonics); elevation is degrees above ear level.
struct Speaker: Codable, Identifiable, Hashable {
    var id: Int            // channel index in Apple's Atmos 7.1.4 order
    var short: String
    var name: String
    var az: Double
    var el: Double

    var isHeight: Bool { id >= 8 }
    var azText: String {
        let a = Int(az.rounded())
        return a == 0 ? "Front" : abs(a) == 180 ? "Behind" : "\(abs(a))° \(a > 0 ? "left" : "right")"
    }
    var elText: String {
        let e = Int(el.rounded())
        return e == 0 ? "Ear level" : e == 90 ? "Overhead" : e > 0 ? "\(e)° up" : "\(-e)° down"
    }
}

struct SpeakerLayout: Codable, Equatable {
    var speakers: [Speaker]   // the 11 directional speakers (no LFE)

    static let elevationRange: ClosedRange<Double> = -30...90

    static func standard(height: Double = 45) -> SpeakerLayout {
        SpeakerLayout(speakers: [
            Speaker(id: 0, short: "L", name: "Front Left", az: 30, el: 0),
            Speaker(id: 2, short: "C", name: "Center", az: 0, el: 0),
            Speaker(id: 1, short: "R", name: "Front Right", az: -30, el: 0),
            Speaker(id: 4, short: "Ls", name: "Side Left", az: 90, el: 0),
            Speaker(id: 5, short: "Rs", name: "Side Right", az: -90, el: 0),
            Speaker(id: 6, short: "Lb", name: "Rear Left", az: 150, el: 0),
            Speaker(id: 7, short: "Rb", name: "Rear Right", az: -150, el: 0),
            Speaker(id: 8, short: "Ltf", name: "Top Front Left", az: 45, el: height),
            Speaker(id: 9, short: "Rtf", name: "Top Front Right", az: -45, el: height),
            Speaker(id: 10, short: "Ltr", name: "Top Rear Left", az: 135, el: height),
            Speaker(id: 11, short: "Rtr", name: "Top Rear Right", az: -135, el: height),
        ])
    }

    struct Preset: Identifiable {
        var id: String { name }
        var name: String
        var detail: String
        var layout: SpeakerLayout
    }

    static let presets: [Preset] = [
        Preset(name: "Standard 7.1.4", detail: "Height speakers at 45°", layout: .standard(height: 45)),
        Preset(name: "Raised Heights", detail: "Height speakers at 60°", layout: .standard(height: 60)),
        Preset(name: "Steep Heights", detail: "Height speakers at 75°", layout: .standard(height: 75)),
        Preset(name: "Wide Surround", detail: "Wider fronts, sides slightly behind, heights at 55°", layout: {
            var l = SpeakerLayout.standard(height: 55)
            l.set("L", az: 40); l.set("R", az: -40); l.set("Ls", az: 105); l.set("Rs", az: -105)
            l.set("Lb", az: 140); l.set("Rb", az: -140)
            return l
        }()),
        Preset(name: "Cinema Dome", detail: "Height speakers close together, nearly overhead", layout: {
            var l = SpeakerLayout.standard(height: 70)
            l.set("Ltf", az: 30); l.set("Rtf", az: -30); l.set("Ltr", az: 150); l.set("Rtr", az: -150)
            return l
        }()),
    ]

    mutating func set(_ short: String, az: Double? = nil, el: Double? = nil) {
        guard let i = speakers.firstIndex(where: { $0.short == short }) else { return }
        if let az { speakers[i].az = az }
        if let el { speakers[i].el = el }
    }

    /// The speaker mirrored left↔right (Center has none).
    func partner(of s: Speaker) -> Int? {
        let pairs = [0: 1, 1: 0, 4: 5, 5: 4, 6: 7, 7: 6, 8: 9, 9: 8, 10: 11, 11: 10]
        return pairs[s.id]
    }

    /// Engine argument: 12 "az:el" pairs in Apple 7.1.4 order (LFE gets 0:0).
    var engineArgument: String {
        (0..<12).map { ch -> String in
            guard let s = speakers.first(where: { $0.id == ch }) else { return "0:0" }
            return String(format: "%.1f:%.1f", s.az, s.el)
        }.joined(separator: ",")
    }

    // MARK: persistence

    var json: String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "" }

    init(speakers: [Speaker]) { self.speakers = speakers }

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SpeakerLayout.self, from: data),
              decoded.speakers.count == 11 else { return nil }
        self = decoded
    }
}

/// Wraps an angle into -180...180.
func wrapDegrees(_ a: Double) -> Double {
    var x = a.truncatingRemainder(dividingBy: 360)
    if x > 180 { x -= 360 }
    if x < -180 { x += 360 }
    return x
}
