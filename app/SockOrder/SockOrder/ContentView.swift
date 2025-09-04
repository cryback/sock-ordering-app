import SwiftUI

// MARK: - Models

enum SockSize: String, Codable, CaseIterable, Identifiable {
    case I, T, S, M, L, XL, XXL, ONESIZE
    var id: String { rawValue }
    var label: String {
        switch self {
        case .I: return "Infant"
        case .T: return "Toddler"
        case .S: return "Small"
        case .M: return "Medium"
        case .L: return "Large"
        case .XL: return "X-Large"
        case .XXL: return "XX-Large"
        case .ONESIZE: return "One Size"
        }
    }
}

struct Park: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let city: String
    let state: String
}

struct Style: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let sizes: [SockSize]
    let image: URL? // optional; add "image" in catalog.json to show a thumbnail
}

struct Catalog: Codable {
    let parks: [Park]
    let styles: [Style]
    let casePacks: CasePacks

    struct CasePacks: Codable {
        // String keys in JSON (e.g., "I","T","S"...)
        let defaultMain: [String:Int]
        let byStyle: [String: CasePackRef]
    }

    enum CasePackRef: Codable {
        case alias(String)
        case explicit([String:Int])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .alias(s) }
            else { self = .explicit(try c.decode([String:Int].self)) }
        }

        func resolve(in catalog: Catalog) -> [String:Int] {
            switch self {
            case .alias(let s) where s == "defaultMain":
                return catalog.casePacks.defaultMain
            case .alias(_):
                return catalog.casePacks.defaultMain // fallback
            case .explicit(let m):
                return m
            }
        }
    }
}

struct Availability: Codable {
    // styles[styleId]?[sizeRaw] -> Bool
    let styles: [String: [String: Bool]]
    func isAvailable(styleId: String, size: SockSize) -> Bool {
        styles[styleId]?[size.rawValue] ?? false
    }
}

struct OrderLine: Identifiable, Codable {
    var id: String { "\(styleId)-\(size.rawValue)" }
    let styleId: String
    let styleName: String
    let size: SockSize
    let cases: Int
    let pairsPerCase: Int
    var totalPairs: Int { cases * pairsPerCase }
}

struct OrderPayload: Codable {
    let submittedAt: String
    let park: Park
    let lines: [OrderLine]
    let notes: String?
    var totalPairs: Int { lines.reduce(0) { $0 + $1.totalPairs } }
}

// MARK: - Networking / Service

@MainActor
final class DataService: ObservableObject {
    // Public raw GitHub JSON files:
    private let catalogURL = URL(string: "https://raw.githubusercontent.com/cryback/sock-ordering-app/main/data/catalog.json")!
    private let availabilityURL = URL(string: "https://raw.githubusercontent.com/cryback/sock-ordering-app/main/data/availability.json")!

    // Replace with your n8n (or other) webhook URL:
    private let orderWebhook = URL(string: "https://YOUR-N8N-OR-CLOUD-WEBHOOK")!

    @Published var catalog: Catalog?
    @Published var availability: Availability?

    func load() async throws {
        async let c: Catalog = fetch(catalogURL)
        async let a: Availability = fetch(availabilityURL)
        self.catalog = try await c
        self.availability = try await a
    }

    func submitOrder(_ payload: OrderPayload) async throws {
        var req = URLRequest(url: orderWebhook)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(payload)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw NSError(domain: "HTTP", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey:
                "HTTP \(http.statusCode) from \(url.absoluteString)\n\(body.prefix(500))"])
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let preview = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw NSError(domain: "DECODING", code: 0, userInfo: [NSLocalizedDescriptionKey:
                "Decoding error for \(url.lastPathComponent): \(error)\nSample:\n\(preview.prefix(500))"])
        }
    }
}

// MARK: - ViewModel

@MainActor
final class OrderVM: ObservableObject {
    @Published var selectedParkId: String = ""
    @Published var quantities: [String: Int] = [:] // key: "styleId|sizeRaw"
    @Published var notes: String = ""

    let svc: DataService
    init(svc: DataService) { self.svc = svc }

    func lineKey(styleId: String, size: SockSize) -> String { "\(styleId)|\(size.rawValue)" }

    func isDisabled(styleId: String, size: SockSize) -> Bool {
        guard let a = svc.availability else { return true }
        return !a.isAvailable(styleId: styleId, size: size)
    }

    func pairsPerCase(style: Style, size: SockSize) -> Int {
        guard let cat = svc.catalog else { return 0 }
        let sizeKey = size.rawValue
        if let ref = cat.casePacks.byStyle[style.id] {
            let resolved = ref.resolve(in: cat) // [String:Int]
            return resolved[sizeKey] ?? 0
        } else {
            return cat.casePacks.defaultMain[sizeKey] ?? 0
        }
    }

    func buildOrder() -> OrderPayload? {
        guard let cat = svc.catalog,
              let park = cat.parks.first(where: { $0.id == selectedParkId }) else { return nil }

        let lines: [OrderLine] = cat.styles.flatMap { style in
            style.sizes.compactMap { size -> OrderLine? in
                let key = lineKey(styleId: style.id, size: size)
                let cases = quantities[key] ?? 0
                let ppc = pairsPerCase(style: style, size: size)
                guard cases > 0, ppc > 0 else { return nil }
                return OrderLine(styleId: style.id, styleName: style.name, size: size, cases: cases, pairsPerCase: ppc)
            }
        }
        guard !lines.isEmpty else { return nil }
        let iso = ISO8601DateFormatter().string(from: Date())
        return OrderPayload(submittedAt: iso, park: park, lines: lines, notes: notes.isEmpty ? nil : notes)
    }
}

// MARK: - UI (ScrollView + LazyVStack)

struct ContentView: View {
    @StateObject private var svc = DataService()
    @StateObject private var vm: OrderVM
    @State private var loading = true
    @State private var alert: String?

    init() {
        let svc = DataService()
        _svc = StateObject(wrappedValue: svc)
        _vm = StateObject(wrappedValue: OrderVM(svc: svc))
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Loading catalog…")
                } else if let cat = svc.catalog {
                    ScrollView {
                        LazyVStack(spacing: 12) {

                            // Debug header
                            Text("Loaded parks: \(cat.parks.count), styles: \(cat.styles.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)

                            // Park picker
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Park").font(.headline)
                                Picker("Select park", selection: $vm.selectedParkId) {
                                    ForEach(cat.parks) { p in
                                        Text("\(p.name) (\(p.city), \(p.state))").tag(p.id)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                            .padding(.horizontal)

                            // Styles
                            ForEach(cat.styles, id: \.id) { style in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .center, spacing: 12) {
                                        if let url = style.image {
                                            AsyncImage(url: url) { phase in
                                                switch phase {
                                                case .empty:
                                                    ProgressView().frame(width: 64, height: 64)
                                                case .success(let img):
                                                    img.resizable()
                                                        .scaledToFill()
                                                        .frame(width: 64, height: 64)
                                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                                case .failure(_):
                                                    ZStack {
                                                        Color.gray.opacity(0.2)
                                                        Text(style.name.prefix(1))
                                                            .font(.headline)
                                                    }
                                                    .frame(width: 64, height: 64)
                                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                                @unknown default:
                                                    EmptyView()
                                                }
                                            }
                                        }

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(style.name).font(.headline)
                                            Text("id: \(style.id)").font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        Spacer()
                                    }

                                    ForEach(style.sizes, id: \.rawValue) { size in
                                        let key = vm.lineKey(styleId: style.id, size: size)
                                        let disabled = vm.isDisabled(styleId: style.id, size: size)
                                        let ppc = vm.pairsPerCase(style: style, size: size)

                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(size.label)
                                                Text("\(ppc) pairs/case")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                Text("avail: \(disabled ? "no" : "yes") size: \(size.rawValue)")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                            Spacer()
                                            Stepper(value: Binding(
                                                get: { vm.quantities[key] ?? 0 },
                                                set: { vm.quantities[key] = max(0, $0) }
                                            ), in: 0...999) {
                                                Text("\(vm.quantities[key] ?? 0) cases")
                                            }
                                            .disabled(disabled || ppc == 0)
                                        }
                                        .opacity((disabled || ppc == 0) ? 0.4 : 1.0)
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(.secondarySystemBackground))
                                )
                                .padding(.horizontal)
                            }

                            // Notes
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Notes (optional)").font(.headline)
                                TextField("Anything Ops should know?", text: $vm.notes, axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                            }
                            .padding(.horizontal)

                            // Submit
                            Button {
                                Task {
                                    guard let payload = vm.buildOrder() else {
                                        alert = "Please add at least one size."
                                        return
                                    }
                                    do {
                                        try await svc.submitOrder(payload)
                                        alert = "Order submitted. Total \(payload.totalPairs) pairs."
                                        vm.quantities.removeAll()
                                        vm.notes = ""
                                    } catch {
                                        alert = "Submit failed: \(error.localizedDescription)"
                                    }
                                }
                            } label: {
                                Text("Submit Order")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.horizontal)
                            .padding(.bottom, 24)
                            .disabled(vm.buildOrder() == nil)
                        }
                    }
                } else {
                    Text("Failed to load catalog.")
                        .foregroundStyle(.red)
                        .padding()
                }
            }
            .navigationTitle("Sock Order")
        }
        .task {
            do {
                try await svc.load()
                loading = false
                if vm.selectedParkId.isEmpty {
                    vm.selectedParkId = svc.catalog?.parks.first?.id ?? ""
                }
            } catch {
                loading = false
                alert = error.localizedDescription
            }
        }
        .alert(alert ?? "", isPresented: Binding(get: { alert != nil }, set: { _ in alert = nil })) {
            Button("OK", role: .cancel) { }
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
