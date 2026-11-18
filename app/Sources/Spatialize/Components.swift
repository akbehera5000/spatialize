import CoreImage
import SwiftUI

/// A Liquid Glass panel with a titled header.
struct GlassCard<Content: View>: View {
    var title: String
    var symbol: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if let trailing { trailing }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous), darkness: 0.32)
    }
}

extension View {
    /// Looks like the cards' Liquid Glass but doesn't re-sample the window behind it on every
    /// frame, which made scrolling jittery. The backdrop is already a still blur, so the
    /// difference is barely visible.
    func staticGlass<S: InsettableShape>(in shape: S, darkness: Double) -> some View {
        background {
            shape.fill(Color(white: 0.16).opacity(0.38))
                .overlay(shape.fill(.black.opacity(darkness)))
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.05)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
    }
}

/// A label on the left, a control on the right, an optional explanation underneath.
struct SettingRow<Control: View>: View {
    var title: String
    var detail: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 16)
                control
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A slider with its value shown live, and minimum/maximum labels.
struct ValueSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String
    var minLabel: String
    var maxLabel: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(format(value))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.snappy, value: value)
            }
            Slider(value: $value, in: range, step: step) {
                EmptyView()
            } minimumValueLabel: {
                Text(minLabel).font(.system(size: 10.5)).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(maxLabel).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            if let detail {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Small information capsule. `state` colours only the outline (green = good, red = needs work).
struct Chip: View {
    enum Tone { case neutral, good, warn }
    var text: String
    var symbol: String? = nil
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: Capsule())
        .overlay {
            switch tone {
            case .neutral: EmptyView()
            case .good: Capsule().strokeBorder(.green.opacity(0.75), lineWidth: 1.2)
            case .warn: Capsule().strokeBorder(Color(red: 0.85, green: 0.35, blue: 0.35).opacity(0.8), lineWidth: 1.2)
            }
        }
    }
}

/// A title and explanation on the left, a switch pinned to the right edge.
struct SwitchRow: View {
    var title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var small = false
    var enabled = true

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: small ? 12.5 : 13, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: small ? 11 : 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(small ? .small : .regular)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// Switch row used inside track lists.
struct TrackToggle: View {
    var title: String
    var subtitle: String
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        SwitchRow(title: title, detail: subtitle, isOn: $isOn, small: true, enabled: enabled)
            .padding(.leading, 26)
    }
}

/// The blurred movie frame (or a calm gradient) that the glass sits on. The blur is made once
/// per movie from a small copy of the frame, so nothing is re-blurred while scrolling.
struct Backdrop: View {
    var image: NSImage?
    @State private var blurred: NSImage?

    nonisolated private static func blur(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let k = 320 / CGFloat(cg.width)
        let small = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: k, y: k))
        let out = small.clampedToExtent().applyingGaussianBlur(sigma: 22).cropped(to: small.extent)
        guard let res = CIContext().createCGImage(out, from: small.extent) else { return nil }
        return NSImage(cgImage: res, size: NSSize(width: res.width, height: res.height))
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.16), Color(red: 0.13, green: 0.10, blue: 0.20),
                                    Color(red: 0.05, green: 0.12, blue: 0.16)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                // overlay on a flexible Color so the fill-sized image can't widen the layout
                Color.clear
                    .overlay {
                        Image(nsImage: blurred ?? image)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fill)
                            .saturation(0.95)
                            .opacity(blurred == nil ? 0 : 0.8)
                    }
                    .clipped()
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.42), .black.opacity(0.68)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: blurred != nil)
        .task(id: image.map(ObjectIdentifier.init)) {
            guard let image else { blurred = nil; return }
            let img = image
            blurred = await Task.detached(priority: .utility) { Backdrop.blur(img) }.value
        }
    }
}
