// A short log of what the call does, shown in the call screen (the 🐞 button), like the web
// app's ?debug: for checking the mic, the voice and the live connection on a phone.
import AVFoundation
import SwiftUI

@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()
    @Published private(set) var lines: [String] = []
    private let started = Date()

    func log(_ text: String) {
        let t = String(format: "%6.1fs", Date().timeIntervalSince(started))
        lines.append("\(t) \(text)")
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    }

    func clear() { lines = [] }

    /// Where sound goes and comes from right now.
    func logRoute(_ why: String) {
        let s = AVAudioSession.sharedInstance()
        let outs = s.currentRoute.outputs.map { "\($0.portType.rawValue)" }.joined(separator: ",")
        let ins = s.currentRoute.inputs.map { "\($0.portType.rawValue)" }.joined(separator: ",")
        log("\(why): route out=[\(outs)] in=[\(ins)] category=\(s.category.rawValue) mode=\(s.mode.rawValue) volume=\(String(format: "%.2f", s.outputVolume)) mic=\(AVAudioApplication.shared.recordPermission == .granted ? "allowed" : "NOT allowed")")
    }
}

/// Logs from anywhere.
@MainActor func debug(_ text: String) { DebugLog.shared.log(text) }

struct DebugLogView: View {
    @ObservedObject private var log = DebugLog.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(log.lines.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(size: 11, design: .monospaced)).id(i)
                        }
                    }
                    .padding(8)
                    .textSelection(.enabled)
                }
                .onAppear { proxy.scrollTo(log.lines.count - 1, anchor: .bottom) }
            }
            .navigationTitle("Debug log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy") { UIPasteboard.general.string = log.lines.joined(separator: "\n") }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
