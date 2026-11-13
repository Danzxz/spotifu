import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import SpotifuCore
#endif

@MainActor final class DownloadsForm: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var trackID = ""
    @Published var expectedDuration = ""
    @Published var directURL = ""
    @Published var importing = false
    @Published var showSettings = false
}

@MainActor public struct DownloadsView: View {
    @StateObject private var model = OfflineModel.shared
    @StateObject private var form = DownloadsForm()
    private let initialTitle: String
    private let initialArtist: String
    private let initialID: String
    private let initialDuration: Double
    private let beforePlay: (() -> Void)?
    public init(title: String = "", artist: String = "", trackID: String = "", duration: Double = 0, beforePlay: (() -> Void)? = nil) {
        initialTitle = title; initialArtist = artist; initialID = trackID; initialDuration = duration; self.beforePlay = beforePlay
    }
    public var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    if initialID.isEmpty {
                    TextField("Название песни", text: $form.title)
                    TextField("Исполнитель", text: $form.artist)
                    TextField("Spotify ID (необязательно)", text: $form.trackID)
                    TextField("Длительность в секундах (для сверки)", text: $form.expectedDuration)
                    } else {
                        Text(initialTitle).font(.headline)
                        Text(initialArtist).foregroundColor(.secondary)
                    }
                    Button("Скачать") { download("") }.disabled(model.busy || form.title.isEmpty || form.artist.isEmpty)
                    DisclosureGroup("Дополнительно") {
                    TextField("Или ссылка YouTube / SoundCloud / Bandcamp / Audius / Archive", text: $form.directURL)
                    Button("Скачать по ссылке") { download(form.directURL) }
                        .disabled(model.busy || form.directURL.isEmpty || form.title.isEmpty || form.artist.isEmpty)
                    Button("Импортировать аудиофайл") { form.importing = true }
                    }
                    Button("Настроить сервер загрузки") { form.showSettings = true }
                } header: { Text("Добавить для офлайна") }
                if model.busy { ProgressView() }
                if !model.status.isEmpty { Text(model.status).font(.caption) }
                Section(header: Text("Скачанное · \(model.tracks.count)")) {
                    if model.tracks.isEmpty { Text("Сохранённые треки появятся здесь и будут доступны без сети.").foregroundColor(.secondary) }
                    ForEach(model.tracks) { track in
                        HStack {
                            Button { model.play(track) } label: {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                    VStack(alignment: .leading) {
                                        Text(track.title)
                                        Text(track.artist + (track.lyrics == nil ? " · без текста" : " · текст сохранён")).font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }.buttonStyle(.plain)
                            Spacer()
                            Button { model.remove(track) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            if let track = model.current {
                VStack(spacing: 8) {
                    Text(track.title).font(.headline)
                    Text(track.artist).font(.caption)
                    HStack {
                        Button { model.toggle() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill") }
                        Slider(value: Binding(get: { model.position }, set: { model.seek($0) }), in: 0...max(model.duration, 1))
                        Text("\(Int(model.position)) / \(Int(model.duration))").font(.caption.monospacedDigit())
                        Button { model.next() } label: { Image(systemName: "forward.end.fill") }
                    }
                    if let lyrics = track.lyrics {
                        let lines = LyricLine.parse(lyrics)
                        if lines.isEmpty { ScrollView { Text(lyrics).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 160) }
                        else {
                            let active = lines.last(where: { $0.time <= model.position })?.id
                            ScrollViewReader { proxy in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 10) {
                                        ForEach(lines) { line in
                                            Text(line.text).font(.title3).fontWeight(line.id == active ? .bold : .regular)
                                                .foregroundColor(line.id == active ? .primary : .secondary).id(line.id)
                                                .onTapGesture { model.seek(line.time) }
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(height: 160)
                                    .onChange(of: active) { value in withAnimation { proxy.scrollTo(value, anchor: .center) } }
                            }
                        }
                    } else { Text("Текст не сохранён").foregroundColor(.secondary) }
                }.padding()
            }
        }
        .navigationTitle("Spotifu · Скачанное")
        .onAppear {
            if form.title.isEmpty { form.title = initialTitle; form.artist = initialArtist; form.trackID = initialID; form.expectedDuration = initialDuration > 0 ? String(initialDuration) : "" }
            model.beforePlay = beforePlay
        }
        .fileImporter(isPresented: $form.importing, allowedContentTypes: [.audio]) { result in
            do { try model.importFile(result.get(), title: form.title, artist: form.artist, id: form.trackID) }
            catch { model.error = error.localizedDescription }
        }
        .sheet(isPresented: $form.showSettings) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Сервер загрузки").font(.headline)
                Text("После сохранения песен сервер для прослушивания не нужен.").font(.caption)
                TextField("https://ваш-сервер", text: Binding(get: { model.endpoint }, set: { model.endpoint = $0 }))
                SecureField("Токен сервера", text: Binding(get: { model.token }, set: { model.token = $0 }))
                Button("Готово") { form.showSettings = false }
            }.padding().frame(minWidth: 300)
        }
        .alert("Spotifu", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private func download(_ url: String) {
        Task { await model.download(url: url, id: form.trackID, title: form.title, artist: form.artist, duration: Double(form.expectedDuration) ?? 0) }
    }
}
