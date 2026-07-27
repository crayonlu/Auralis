//
//  Auralis
//
//  Created by Elsa on 2024/4/19.
//

import AVFoundation
import Combine
import WebKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
func initUserData(userInfo: UserInfo) async {
    if let profile = loadDecodableState(
        forKey: "profile", type: CloudMusicApi.Profile.self)
    {
        userInfo.profile = profile
    } else {
        userInfo.profile = nil
    }

    if let playlists = loadDecodableState(
        forKey: "playlists", type: [CloudMusicApi.PlayListItem].self)
    {
        userInfo.playlists = playlists
    }

    if let likelist = loadDecodableState(
        forKey: "likelist", type: Set<UInt64>.self)
    {
        userInfo.likelist = likelist
    }

    if let profile = await CloudMusicApi().login_status() {
        userInfo.profile = profile
        saveEncodableState(forKey: "profile", data: profile)

        if let playlists = try? await CloudMusicApi().user_playlist(uid: profile.userId) {
            userInfo.playlists = playlists
            saveEncodableState(forKey: "playlists", data: playlists)
        }

        if let likelist = await CloudMusicApi().likelist(userId: profile.userId) {
            userInfo.likelist = Set(likelist)
            saveEncodableState(forKey: "likelist", data: userInfo.likelist)
        }
    }
}


// MARK: - WebView Login

class WebViewLoginViewModel: ObservableObject {
    @Published var isLoggedIn = false
    @Published var isLoading = true
    @Published var hasError = false
    @Published var errorMessage = ""
    @Published var debugInfo = "Initializing..."
    
    func checkLogin(from cookies: [HTTPCookie]) -> Bool {
        for cookie in cookies {
            if cookie.name == "MUSIC_U" && !cookie.value.isEmpty {
                return true
            }
        }
        return false
    }
    
    func getCookieString(from cookies: [HTTPCookie]) -> String {
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    
    func setError(_ message: String) {
        DispatchQueue.main.async {
            self.hasError = true
            self.errorMessage = message
            self.isLoading = false
            self.debugInfo = "Error: \(message)"
        }
    }
    
    func updateDebugInfo(_ info: String) {
        DispatchQueue.main.async {
            self.debugInfo = info
        }
    }
}

struct WebViewLogin: NSViewRepresentable {
    @ObservedObject var viewModel: WebViewLoginViewModel
    let onLoginSuccess: () -> Void
    @Binding var refreshTrigger: Bool

    static let loginUrl = URL(string: "https://music.163.com/login")!

    func makeNSView(context: Context) -> WKWebView {
        viewModel.updateDebugInfo("Creating WebView...")
        
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        
        let request = URLRequest(url: WebViewLogin.loginUrl)
        
        viewModel.updateDebugInfo("Loading: \(WebViewLogin.loginUrl.absoluteString)")
        webView.load(request)
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        if refreshTrigger {
            DispatchQueue.main.async {
                self.refreshTrigger = false
            }
            let request = URLRequest(url: WebViewLogin.loginUrl)
            viewModel.updateDebugInfo("🔄 Refreshing page...")
            nsView.load(request)
        }
    }
    
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.navigationDelegate = nil
        nsView.stopLoading()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            nsView.configuration.websiteDataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: Date.distantPast,
                completionHandler: {}
            )
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebViewLogin
        
        init(_ parent: WebViewLogin) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let url = webView.url?.absoluteString ?? "unknown"
            self.parent.viewModel.updateDebugInfo("✅ Loaded: \(url)")
            
            DispatchQueue.main.async {
                self.parent.viewModel.isLoading = false
            }
            
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                self.parent.viewModel.updateDebugInfo("🍪 Found \(cookies.count) cookies")
                
                DispatchQueue.main.async {
                    if self.parent.viewModel.checkLogin(from: cookies) {
                        self.parent.viewModel.updateDebugInfo("🎉 Login successful!")
                        let cookieString = self.parent.viewModel.getCookieString(from: cookies)
                        CloudMusicApi().setCookie(cookieString)
                        self.parent.viewModel.isLoggedIn = true
                        self.parent.onLoginSuccess()
                    }
                }
            }
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            self.parent.viewModel.updateDebugInfo("🔄 Starting navigation...")
            DispatchQueue.main.async {
                self.parent.viewModel.isLoading = true
            }
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.parent.viewModel.setError("Failed to load: \(error.localizedDescription)")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            self.parent.viewModel.setError("Navigation failed: \(error.localizedDescription)")
        }
        
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            self.parent.viewModel.updateDebugInfo("📝 Navigation committed")
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                print("Navigating to: \(url.absoluteString)")
                
                if url.host == "music.163.com" && !url.absoluteString.contains("/login") {
                    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                        DispatchQueue.main.async {
                            if self.parent.viewModel.checkLogin(from: cookies) {
                                let cookieString = self.parent.viewModel.getCookieString(from: cookies)
                                CloudMusicApi().setCookie(cookieString)
                                self.parent.viewModel.isLoggedIn = true
                                self.parent.onLoginSuccess()
                            }
                        }
                    }
                }
            }
            decisionHandler(.allow)
        }
    }
}

struct WebViewLoginSheet: View {
    @StateObject private var webViewLoginVM = WebViewLoginViewModel()
    @EnvironmentObject private var userInfo: UserInfo
    @Binding var isPresented: Bool
    @State private var refreshTrigger = false

    var body: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("login.title")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text(webViewLoginVM.debugInfo)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { refreshTrigger = true }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help("login.refresh")
                
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help("login.close")
            }
            .padding(.horizontal)
            .padding(.top, 16)
            .padding(.bottom, 4)
            
            if webViewLoginVM.hasError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    
                    Text("login.loading_error_title")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text(webViewLoginVM.errorMessage)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button("login.retry") {
                        webViewLoginVM.hasError = false
                        webViewLoginVM.isLoading = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ZStack {
                    if webViewLoginVM.isLoading {
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("login.loading")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.clear)
                    }
                    
                    WebViewLogin(
                        viewModel: webViewLoginVM,
                        onLoginSuccess: {
                            Task {
                                await initUserData(userInfo: userInfo)
                                isPresented = false
                            }
                        },
                        refreshTrigger: $refreshTrigger
                    )
                    .opacity(webViewLoginVM.isLoading ? 0 : 1)
                }
            }
        }
        .frame(width: 1100, height: 800)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 20)
    }
}

struct LoginView: View {
    @State private var showLoginSheet = false
    @EnvironmentObject private var userInfo: UserInfo

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "music.note")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            
            Text("login.welcome")
                .font(.title)
                .fontWeight(.bold)
            
            Text("login.subtitle")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button(action: {
                showLoginSheet = true
            }) {
                HStack {
                    Image(systemName: "person.circle")
                    Text("login.login_button")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.accentColor)
                .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showLoginSheet) {
            WebViewLoginSheet(isPresented: $showLoginSheet)
                .environmentObject(userInfo)
        }
    }
}

struct AccountView: View {
    @EnvironmentObject private var userInfo: UserInfo
    @EnvironmentObject private var playlistStatus: PlaylistStatus
    @StateObject private var appSettings = AppSettings.shared

    var body: some View {
        if userInfo.profile != nil {
            SettingsView()
                .environmentObject(userInfo)
                .environmentObject(appSettings)
                .environmentObject(playlistStatus)
        } else {
            LoginView()
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var userInfo: UserInfo
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var playlistStatus: PlaylistStatus

    var body: some View {
        ScrollView {
            HStack {
                Spacer()

                VStack(spacing: 24) {
                    // Profile Section
                    ProfileSection()
                        .environmentObject(userInfo)

                    Divider()

                    // General Settings Section
                    GeneralSettingsSection()
                        .environmentObject(appSettings)

                    Divider()

                    // Playlist Settings Section
                    PlaylistSettingsSection()
                        .environmentObject(appSettings)

                    Divider()

                    // Storage & Cache Section
                    StorageCacheSection()

                    Divider()

                    // Account Actions Section
                    AccountActionsSection()
                        .environmentObject(userInfo)
                        .environmentObject(playlistStatus)

                    Divider()

                    // About Section
                    AboutSection()

                    // Extra space for floating player control
                    Color.clear.frame(height: 64)
                }
                .frame(maxWidth: 500)
                .padding(.horizontal, 24)
                .padding(.top, 20)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct ProfileSection: View {
    @EnvironmentObject private var userInfo: UserInfo

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "person.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.title2)
                Text("login.profile")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }

            HStack(spacing: 16) {
                AsyncImageWithCache(url: URL(string: userInfo.profile?.avatarUrl.https ?? "")) {
                    image in
                    image.resizable()
                        .interpolation(.high)
                } placeholder: {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            Image(systemName: "person.fill")
                                .foregroundColor(.white)
                                .font(.title)
                        )
                }
                .scaledToFit()
                .clipShape(Circle())
                .frame(width: 80, height: 80)
                .shadow(radius: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text(userInfo.profile?.nickname ?? LanguageManager.shared.string("login.unknown"))
                        .font(.title3)
                        .fontWeight(.medium)

                    Text(String(format: LanguageManager.shared.string("login.user_id"), userInfo.profile?.userId ?? 0))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(String(format: LanguageManager.shared.string("login.playlists_count"), userInfo.playlists.count))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
    }
}

struct GeneralSettingsSection: View {
    @EnvironmentObject private var appSettings: AppSettings
    @StateObject private var languageManager = LanguageManager.shared

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.accentColor)
                    .font(.title2)
                Text("settings.general_settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }

            VStack(spacing: 12) {
                SettingRow(
                    icon: "moon.fill",
                    title: LanguageManager.shared.string("settings.prevent_sleep"),
                    description: LanguageManager.shared.string("settings.prevent_sleep_desc"),
                    control: AnyView(
                        Toggle("", isOn: $appSettings.preventSleepWhenPlaying)
                            .toggleStyle(SwitchToggleStyle())
                    )
                )

                SettingRow(
                    icon: "clock",
                    title: LanguageManager.shared.string("settings.show_timestamps"),
                    description: LanguageManager.shared.string("settings.show_timestamps_desc"),
                    control: AnyView(
                        Toggle("", isOn: $appSettings.showTimestamp)
                            .toggleStyle(SwitchToggleStyle())
                    )
                )

                SettingRow(
                    icon: "quote.bubble",
                    title: LanguageManager.shared.string("settings.show_roma"),
                    description: LanguageManager.shared.string("settings.show_roma_desc"),
                    control: AnyView(
                        Toggle("", isOn: $appSettings.showRoma)
                            .toggleStyle(SwitchToggleStyle())
                    )
                )

                SettingRow(
                    icon: "globe",
                    title: LanguageManager.shared.string("settings.language"),
                    description: LanguageManager.shared.string("settings.language_desc"),
                    control: AnyView(
                        Picker("", selection: $languageManager.currentLanguage) {
                            ForEach(AppLanguage.allCases) { lang in
                                Text(lang.displayName).tag(lang)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    )
                )

                SettingRow(
                    icon: "music.note",
                    title: LanguageManager.shared.string("settings.audio_quality"),
                    description: LanguageManager.shared.string("settings.audio_quality_desc"),
                    control: AnyView(
                        Picker("", selection: $appSettings.audioQuality) {
                            ForEach(AudioQuality.allCases) { quality in
                                Text(LanguageManager.shared.string("audio_quality.\(quality.rawValue)")).tag(quality)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    )
                )
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
    }
}

struct PlaylistSettingsSection: View {
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "music.note.list")
                    .foregroundColor(.accentColor)
                    .font(.title2)
                Text("settings.playlist")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Picker(selection: $appSettings.doubleClickPlayAction, label: EmptyView()) {
                    Text("settings.double_click_replace")
                        .fixedSize(horizontal: false, vertical: true)
                        .tag(DoubleClickPlayAction.replacePlaylistWithSongList)
                    Text("settings.double_click_append")
                        .fixedSize(horizontal: false, vertical: true)
                        .tag(DoubleClickPlayAction.appendSongToPlaylist)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
    }
}

struct StorageCacheSection: View {
    @State private var showingCleanAlert = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "internaldrive.fill")
                    .foregroundColor(.accentColor)
                    .font(.title2)
                Text("settings.storage_cache")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }

            VStack(spacing: 12) {
                SettingRow(
                    icon: "trash.fill",
                    title: LanguageManager.shared.string("settings.clear_cache"),
                    description: LanguageManager.shared.string("settings.clear_cache_desc"),
                    control: AnyView(
                        Button(action: {
                            cleanCache()
                        }) {
                            Text("settings.clean")
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(Color.red)
                                .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                    )
                )
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
    }

    private func cleanCache() {
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.cyncyn.Auralis")
        {
            let tmpFolderPath = containerURL.appendingPathComponent("tmp")
            if FileManager.default.fileExists(atPath: tmpFolderPath.path) {
                do {
                    try FileManager.default.removeItem(at: tmpFolderPath)
                    AlertModal.showAlert(LanguageManager.shared.string("alert.success"), LanguageManager.shared.string("alert.cache_cleaned"))
                } catch {
                    print("Error when deleting \(tmpFolderPath): \(error)")
                    AlertModal.showAlert(LanguageManager.shared.string("alert.error"), LanguageManager.shared.string("alert.clean_failed") + error.localizedDescription)
                }
            } else {
                AlertModal.showAlert(LanguageManager.shared.string("alert.info"), LanguageManager.shared.string("alert.no_cache"))
            }
        }
    }
}

struct AccountActionsSection: View {
    @EnvironmentObject private var userInfo: UserInfo
    @EnvironmentObject private var playlistStatus: PlaylistStatus

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "person.badge.key.fill")
                    .foregroundColor(.accentColor)
                    .font(.title2)
                Text("settings.account")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }

            VStack(spacing: 12) {
                SettingRow(
                    icon: "arrow.right.square.fill",
                    title: LanguageManager.shared.string("settings.sign_out"),
                    description: LanguageManager.shared.string("settings.sign_out_desc"),
                    control: AnyView(
                        Button(action: {
                            Task {
                                await signOut()
                            }
                        }) {
                            Text("settings.sign_out_btn")
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(Color.orange)
                                .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                    )
                )
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
    }

    private func signOut() async {
        await CloudMusicApi().logout()
        userInfo.profile = nil
        userInfo.likelist = []
        userInfo.playlists = []

        saveEncodableState(forKey: "profile", data: userInfo.profile)
        
        // Clear playlist and pause current playback
        playlistStatus.pausePlay()
        await playlistStatus.clearPlaylist()
    }
}

struct SettingRow: View {
    let icon: String
    let title: String
    let description: String
    let control: AnyView

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .font(.title3)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            control
        }
        .padding(.vertical, 4)
    }
}

struct AboutSection: View {
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.title2)
                Text("settings.about")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }

            VStack(spacing: 12) {
                SettingRow(
                    icon: "app.badge",
                    title: LanguageManager.shared.string("settings.version"),
                    description: BuildInfo.versionString,
                    control: AnyView(
                        Button(action: {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(BuildInfo.versionString, forType: .string)
                        }) {
                            Text("settings.copy")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(PlainButtonStyle())
                    )
                )

                if BuildInfo.gitCommit != "Development" && BuildInfo.gitCommit != "Unknown" {
                    SettingRow(
                        icon: "doc.text.fill",
                        title: LanguageManager.shared.string("settings.build_info"),
                        description: String(format: LanguageManager.shared.string("settings.build_info_desc"), BuildInfo.gitBranch, String(BuildInfo.gitCommit.prefix(8))),
                        control: AnyView(
                            Button(action: {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(BuildInfo.gitCommit, forType: .string)
                            }) {
                                Text("settings.copy_commit")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(PlainButtonStyle())
                        )
                    )
                }
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
        }
    }
}

struct AccountHeaderView: View {
    @EnvironmentObject private var userInfo: UserInfo

    var body: some View {
        HStack {
            if let profile = userInfo.profile {
                AsyncImageWithCache(url: URL(string: profile.avatarUrl.https)) { image in
                    image.resizable()
                        .interpolation(.high)
                } placeholder: {
                    Color.white
                }
                .scaledToFit()
                .clipShape(Circle())
                .frame(width: 40, height: 40)

                Text(profile.nickname)
                    .font(.system(size: 16))
            } else {
                Color.white
                    .scaledToFit()
                    .clipShape(Circle())
                    .frame(width: 40, height: 40)

                Text("settings.not_logged_in")
                    .font(.system(size: 16))
            }
        }
    }
}

//#Preview {
//    HomeContentView()
//}
