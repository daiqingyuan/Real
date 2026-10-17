import SwiftUI

/// Renders measured FFT data only. Creating this view never starts audio capture.
struct SpectrumView: View {
    @ObservedObject var service: AudioSpectrumService
    var colored: Bool

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(service.levels.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(colored ? Color(hue: Double(index) / Double(max(1, service.levels.count)) * 0.75, saturation: 0.7, brightness: 1) : Color.white.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .frame(height: service.isRunning ? max(0, geometry.size.height * CGFloat(service.levels[index])) : 0)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("系统音频频谱"))
        .accessibilityValue(tr(service.status))
        .help(tr("显示系统混音的频率强度，不限于当前播放器。"))
    }
}
