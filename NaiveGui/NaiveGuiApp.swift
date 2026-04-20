import SwiftUI

@main
struct NaiveGuiApp: App {
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(appState)
                .environmentObject(appState.globalSettings)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.globalSettings)
        }

        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(appState)
        } label: {
            MenuBarStatusIcon(isConnected: appState.isRunning)
        }
    }
}

private struct MenuBarStatusIcon: View {
    let isConnected: Bool

    var body: some View {
        ZStack {
            if isConnected {
                Circle()
                    .fill(Color(red: 0.19, green: 0.76, blue: 0.39))
                    .frame(width: 10, height: 10)

                ShieldShape()
                    .stroke(.white, lineWidth: 1.75)
                    .frame(width: 9, height: 11)
            } else {
                ShieldShape()
                    .stroke(Color.white.opacity(0.88), lineWidth: 1.75)
                    .frame(width: 11, height: 13)
            }
        }
        .frame(width: 18, height: 16)
    }
}

private struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let top = CGPoint(x: rect.midX, y: rect.minY + height * 0.06)
        let topRight = CGPoint(x: rect.minX + width * 0.82, y: rect.minY + height * 0.18)
        let bottomRight = CGPoint(x: rect.minX + width * 0.78, y: rect.minY + height * 0.62)
        let bottom = CGPoint(x: rect.midX, y: rect.maxY - height * 0.06)
        let bottomLeft = CGPoint(x: rect.minX + width * 0.22, y: rect.minY + height * 0.62)
        let topLeft = CGPoint(x: rect.minX + width * 0.18, y: rect.minY + height * 0.18)

        var path = Path()
        path.move(to: top)
        path.addLine(to: topRight)
        path.addCurve(to: bottomRight,
                      control1: CGPoint(x: rect.minX + width * 0.82, y: rect.minY + height * 0.34),
                      control2: CGPoint(x: rect.minX + width * 0.80, y: rect.minY + height * 0.48))
        path.addQuadCurve(to: bottom, control: CGPoint(x: rect.minX + width * 0.72, y: rect.minY + height * 0.86))
        path.addQuadCurve(to: bottomLeft, control: CGPoint(x: rect.minX + width * 0.28, y: rect.minY + height * 0.86))
        path.addCurve(to: topLeft,
                      control1: CGPoint(x: rect.minX + width * 0.20, y: rect.minY + height * 0.48),
                      control2: CGPoint(x: rect.minX + width * 0.18, y: rect.minY + height * 0.34))
        path.closeSubpath()
        return path
    }
}
